import 'dart:convert';
import 'dart:io';

import 'package:sanad_agent/capabilities/permissions/workspace_policy.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/sanad_home/sanad_home_bootstrap.dart';

import 'mcp_server_config.dart';

class SanadSettingsStore {
  const SanadSettingsStore({this.homeDirectoryPath});

  final String? homeDirectoryPath;

  Future<WorkspacePolicy> readWorkspacePolicy(String workspacePath) async {
    final settings = await readWorkspaceSettingsDocument(workspacePath);
    return WorkspacePolicy.fromJson(settings);
  }

  Future<void> saveWorkspacePolicy(
    String workspacePath,
    WorkspacePolicy policy,
  ) async {
    final file = settingsFileForWorkspace(workspacePath);
    final current = await _readSettingsMap(file);
    final merged = Map<String, dynamic>.from(current)
      ..remove('permissionMode')
      ..remove('permissions')
      ..addAll(policy.toJson());
    await _writeSettingsMap(file, merged);
  }

  Future<List<McpServerConfig>> readUserMcpServers() async {
    final settings = await readUserMcpConfigDocument();
    return parseMcpServersDocument(settings);
  }

  Future<List<McpServerConfig>> readWorkspaceMcpServers(
    String workspacePath,
  ) async {
    final settings = await readWorkspaceMcpConfigDocument(workspacePath);
    return parseMcpServersDocument(settings);
  }

  Future<List<McpServerConfig>> readEffectiveMcpServers({
    String? workspacePath,
  }) async {
    final merged = <String, McpServerConfig>{};

    for (final server in await readUserMcpServers()) {
      merged[server.name] = server;
    }

    final normalizedWorkspacePath = _normalizeWorkspacePath(workspacePath);
    if (normalizedWorkspacePath != null) {
      for (final server in await readWorkspaceMcpServers(
        normalizedWorkspacePath,
      )) {
        merged[server.name] = server;
      }
    }

    return merged.values.toList(growable: false);
  }

  Future<Map<String, dynamic>> readUserMcpConfigDocument() async {
    return _readSettingsMap(_userMcpConfigFile());
  }

  Future<void> saveUserMcpConfigDocument(Map<String, dynamic> document) async {
    await _writeSettingsMap(_userMcpConfigFile(), document);
  }

  Future<Map<String, dynamic>> readWorkspaceMcpConfigDocument(
    String workspacePath,
  ) async {
    return _readSettingsMap(_workspaceMcpConfigFile(workspacePath));
  }

  Future<void> saveWorkspaceMcpConfigDocument(
    String workspacePath,
    Map<String, dynamic> document,
  ) async {
    await _writeSettingsMap(_workspaceMcpConfigFile(workspacePath), document);
  }

  Future<Map<String, dynamic>> readWorkspaceSettingsDocument(
    String workspacePath,
  ) async {
    return _readSettingsMap(settingsFileForWorkspace(workspacePath));
  }

  Future<void> saveWorkspaceSettingsDocument(
    String workspacePath,
    Map<String, dynamic> settings,
  ) async {
    await _writeSettingsMap(settingsFileForWorkspace(workspacePath), settings);
  }

  Map<String, dynamic> encodeMcpServersDocument(List<McpServerConfig> servers) {
    return {'mcpServers': _encodeMcpServers(servers)};
  }

  List<McpServerConfig> parseMcpServersDocument(Map<String, dynamic> document) {
    return _parseMcpServers(document['mcpServers']);
  }

  static Directory sanadDirectoryForWorkspace(String workspacePath) {
    final normalizedPath =
        _normalizeWorkspacePath(workspacePath) ?? workspacePath.trim();
    return Directory('$normalizedPath${Platform.pathSeparator}.sanad');
  }

  static File settingsFileForWorkspace(String workspacePath) {
    final directory = sanadDirectoryForWorkspace(workspacePath);
    return File('${directory.path}${Platform.pathSeparator}settings.json');
  }

  static File mcpConfigFileForWorkspace(String workspacePath) {
    final directory = sanadDirectoryForWorkspace(workspacePath);
    return File('${directory.path}${Platform.pathSeparator}mcp_config.json');
  }

  Future<Map<String, dynamic>> _readSettingsMap(File file) async {
    final isUserFile = file.path == _userMcpConfigFile().path;
    final boundary = isUserFile
        ? SanadHomeBootstrap.atRoot(
            _resolveSanadHomeDirectory(),
            scope: SanadHomeScope.identity,
          )
        : null;
    if (isUserFile
        ? !boundary!.fileExists('mcp_config.json')
        : !await file.exists()) {
      return <String, dynamic>{};
    }

    final raw = isUserFile
        ? utf8.decode(boundary!.readSecretBytes('mcp_config.json'))
        : await file.readAsString();
    if (raw.trim().isEmpty) {
      return <String, dynamic>{};
    }

    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Sanad settings must be a JSON object.');
    }
    return decoded;
  }

  File _userMcpConfigFile() {
    final sanadHome = _resolveSanadHomeDirectory();
    return File('$sanadHome${Platform.pathSeparator}mcp_config.json');
  }

  File _workspaceMcpConfigFile(String workspacePath) {
    return mcpConfigFileForWorkspace(workspacePath);
  }

  String _resolveSanadHomeDirectory() {
    final explicitPath = homeDirectoryPath?.trim();
    if (explicitPath != null && explicitPath.isNotEmpty) {
      return explicitPath;
    }

    return getSanadHome();
  }

  static String? _normalizeWorkspacePath(String? workspacePath) {
    final trimmed = workspacePath?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      return null;
    }

    final directory = Directory(trimmed);
    try {
      return directory.resolveSymbolicLinksSync();
    } catch (_) {
      return directory.absolute.path;
    }
  }

  List<McpServerConfig> _parseMcpServers(dynamic rawValue) {
    if (rawValue is List) {
      return rawValue
          .whereType<Map>()
          .map(
            (item) => McpServerConfig.fromJson(Map<String, dynamic>.from(item)),
          )
          .toList(growable: false);
    }

    if (rawValue is! Map) {
      return const [];
    }

    final configs = <McpServerConfig>[];
    for (final entry in rawValue.entries) {
      if (entry.value is! Map) {
        continue;
      }
      final json = Map<String, dynamic>.from(entry.value as Map);
      json.putIfAbsent('name', () => entry.key.toString());
      configs.add(McpServerConfig.fromJson(json));
    }
    return configs;
  }

  Future<void> _writeSettingsMap(
    File file,
    Map<String, dynamic> settings,
  ) async {
    if (file.path == _userMcpConfigFile().path) {
      await SanadHomeBootstrap.atRoot(
        _resolveSanadHomeDirectory(),
        scope: SanadHomeScope.identity,
      ).writeConfigText(
        'mcp_config.json',
        const JsonEncoder.withIndent('  ').convert(settings),
      );
      return;
    }
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(settings),
    );
  }

  Map<String, dynamic> _encodeMcpServers(List<McpServerConfig> servers) {
    final encoded = <String, dynamic>{};
    for (final server in servers) {
      encoded[server.name] = server.toConfigJson();
    }
    return encoded;
  }
}
