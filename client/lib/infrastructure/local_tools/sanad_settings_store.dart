import 'dart:convert';
import 'dart:io';

import 'package:sanad_client/core/config/app_config.dart';
import 'package:sanad_client/features/mcp/domain/models/mcp_server_config.dart';
import 'package:sanad_client/infrastructure/local_tools/secure_sanad_home_writer.dart';

class SanadSettingsStore {
  const SanadSettingsStore({
    this.homeDirectoryPath,
    this.sanadHomePath,
    this.environment,
  });

  final String? homeDirectoryPath;
  final String? sanadHomePath;
  final Map<String, String>? environment;

  Future<List<McpServerConfig>> readUserMcpServers() async {
    final settings = await readUserMcpConfigDocument();
    return parseMcpServersDocument(settings);
  }

  Future<List<McpServerConfig>> readWorkspaceMcpServers(String workspacePath) async {
    final settings = await readWorkspaceMcpConfigDocument(workspacePath);
    return parseMcpServersDocument(settings);
  }

  Future<List<McpServerConfig>> readEffectiveMcpServers({String? workspacePath}) async {
    final merged = <String, McpServerConfig>{};

    for (final server in await readUserMcpServers()) {
      merged[server.name] = server;
    }

    final normalizedWorkspacePath = _normalizeWorkspacePath(workspacePath);
    if (normalizedWorkspacePath != null) {
      for (final server in await readWorkspaceMcpServers(normalizedWorkspacePath)) {
        merged[server.name] = server;
      }
    }

    return merged.values.toList(growable: false);
  }

  Future<void> saveUserMcpServers(List<McpServerConfig> servers) async {
    await _writeSecureHomeSettings(
      'mcp_config.json',
      encodeMcpServersDocument(servers),
    );
  }

  Future<void> saveWorkspaceMcpServers(
    String workspacePath,
    List<McpServerConfig> servers,
  ) async {
    final file = _workspaceMcpConfigFile(workspacePath);
    await _writeSettingsMap(file, encodeMcpServersDocument(servers));
  }

  static File mcpConfigFileForWorkspace(String workspacePath) {
    final normalizedPath = _normalizeWorkspacePath(workspacePath) ?? workspacePath.trim();
    return File('$normalizedPath${Platform.pathSeparator}.sanad${Platform.pathSeparator}mcp_config.json');
  }

  Future<Map<String, dynamic>> _readSettingsMap(File file) async {
    if (!await file.exists()) {
      return <String, dynamic>{};
    }

    final raw = await file.readAsString();
    if (raw.trim().isEmpty) {
      return <String, dynamic>{};
    }

    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Sanad settings must be a JSON object.');
    }
    return decoded;
  }

  Future<Map<String, dynamic>> readUserMcpConfigDocument() async {
    return _readSettingsMap(
      await _secureHomeWriter().resolveFile('mcp_config.json'),
    );
  }

  Future<Map<String, dynamic>> readWorkspaceMcpConfigDocument(String workspacePath) async {
    return _readSettingsMap(_workspaceMcpConfigFile(workspacePath));
  }

  Future<Map<String, dynamic>> readEffectiveMcpConfigDocument({String? workspacePath}) async {
    return encodeMcpServersDocument(
      await readEffectiveMcpServers(workspacePath: workspacePath),
    );
  }

  Future<void> _writeSettingsMap(File file, Map<String, dynamic> settings) async {
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(settings),
    );
  }

  Future<void> _writeSecureHomeSettings(
    String relativeName,
    Map<String, dynamic> settings,
  ) async {
    await _secureHomeWriter().writeText(
      relativeName,
      const JsonEncoder.withIndent('  ').convert(settings),
    );
  }

  File _workspaceMcpConfigFile(String workspacePath) {
    return mcpConfigFileForWorkspace(workspacePath);
  }

  Future<Map<String, dynamic>> readAuthDocument() async {
    return _readSettingsMap(
      await _secureHomeWriter().resolveFile('auth.json'),
    );
  }

  Future<void> saveAuthDocument(Map<String, dynamic> authData) async {
    await _writeSecureHomeSettings('auth.json', authData);
  }

  Future<void> deleteAuthDocument() async {
    await _secureHomeWriter().delete('auth.json');
  }

  SecureSanadHomeWriter _secureHomeWriter() {
    return SecureSanadHomeWriter(_resolveSanadHomeDirectory());
  }

  String _resolveSanadHomeDirectory() {
    final explicitSanadHome = sanadHomePath?.trim();
    if (explicitSanadHome != null && explicitSanadHome.isNotEmpty) {
      return explicitSanadHome;
    }
    if (AppConfig.sanadHome.trim().isNotEmpty) {
      return AppConfig.sanadHome.trim();
    }
    final explicitHomeDirectory = homeDirectoryPath?.trim();
    if (explicitHomeDirectory != null && explicitHomeDirectory.isNotEmpty) {
      return '$explicitHomeDirectory${Platform.pathSeparator}.sanad';
    }
    final runtimeHome = (environment ?? Platform.environment)['SANAD_HOME']?.trim();
    if (runtimeHome != null && runtimeHome.isNotEmpty) {
      return runtimeHome;
    }
    return '${_resolveHomeDirectory()}${Platform.pathSeparator}.sanad';
  }

  String _resolveHomeDirectory() {
    final explicitPath = homeDirectoryPath?.trim();
    if (explicitPath != null && explicitPath.isNotEmpty) {
      return explicitPath;
    }

    final environment = this.environment ?? Platform.environment;
    final home = environment['HOME']?.trim();
    if (home != null && home.isNotEmpty) {
      return home;
    }

    final userProfile = environment['USERPROFILE']?.trim();
    if (userProfile != null && userProfile.isNotEmpty) {
      return userProfile;
    }

    final homeDrive = environment['HOMEDRIVE']?.trim();
    final homePath = environment['HOMEPATH']?.trim();
    if (homeDrive != null && homeDrive.isNotEmpty && homePath != null && homePath.isNotEmpty) {
      return '$homeDrive$homePath';
    }

    throw const FileSystemException('Unable to resolve the user home directory for ~/.sanad settings.');
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

  List<McpServerConfig> parseMcpServersDocument(Map<String, dynamic> document) {
    return _parseMcpServers(document['mcpServers']);
  }

  Map<String, dynamic> encodeMcpServersDocument(List<McpServerConfig> servers) {
    return {
      'mcpServers': _encodeMcpServers(servers),
    };
  }

  List<McpServerConfig> _parseMcpServers(dynamic rawValue) {
    if (rawValue is List) {
      return rawValue
          .whereType<Map>()
          .map((item) => McpServerConfig.fromJson(Map<String, dynamic>.from(item)))
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

  Map<String, dynamic> _encodeMcpServers(List<McpServerConfig> servers) {
    final encoded = <String, dynamic>{};
    for (final server in servers) {
      encoded[server.name] = server.toConfigJson();
    }
    return encoded;
  }
}
