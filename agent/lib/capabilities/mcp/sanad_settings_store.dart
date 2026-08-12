import 'dart:convert';
import 'dart:io';

import 'package:sanad_agent/capabilities/permissions/workspace_policy.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/sanad_home/sanad_home_bootstrap.dart';

import 'mcp_secret_store.dart';
import 'mcp_server_config.dart';

class SanadSettingsStore {
  const SanadSettingsStore({this.homeDirectoryPath});

  final String? homeDirectoryPath;

  McpSecretStore get _secrets =>
      McpSecretStore(homeDirectoryPath: _resolveSanadHomeDirectory());

  Future<WorkspacePolicy> readWorkspacePolicy(String workspacePath) async =>
      WorkspacePolicy.fromJson(
        await readWorkspaceSettingsDocument(workspacePath),
      );

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

  Future<List<McpServerConfig>> readUserMcpServers() async =>
      parseMcpServersDocument(await readUserMcpConfigDocument());

  Future<List<McpServerConfig>> readWorkspaceMcpServers(
    String workspacePath,
  ) async => parseMcpServersDocument(
    await readWorkspaceMcpConfigDocument(workspacePath),
  );

  Future<List<McpServerConfig>> readEffectiveMcpServers({
    String? workspacePath,
  }) async {
    final merged = <String, McpServerConfig>{};
    for (final server in await readUserMcpServers()) {
      merged[server.name.trim().toLowerCase()] = server;
    }
    final normalized = _normalizeWorkspacePath(workspacePath);
    if (normalized != null) {
      for (final server in await readWorkspaceMcpServers(normalized)) {
        merged[server.name.trim().toLowerCase()] = server;
      }
    }
    return merged.values.toList(growable: false);
  }

  Future<Map<String, dynamic>> readUserMcpConfigDocument() =>
      _readAndMigrateMcpDocument(_userMcpConfigFile());

  Future<void> saveUserMcpConfigDocument(Map<String, dynamic> document) =>
      _writeSettingsMap(_userMcpConfigFile(), document);

  Future<Map<String, dynamic>> readWorkspaceMcpConfigDocument(
    String workspacePath,
  ) => _readAndMigrateMcpDocument(_workspaceMcpConfigFile(workspacePath));

  Future<void> saveWorkspaceMcpConfigDocument(
    String workspacePath,
    Map<String, dynamic> document,
  ) => _writeSettingsMap(_workspaceMcpConfigFile(workspacePath), document);

  Future<Map<String, dynamic>> readWorkspaceSettingsDocument(
    String workspacePath,
  ) => _readSettingsMap(settingsFileForWorkspace(workspacePath));

  Future<void> saveWorkspaceSettingsDocument(
    String workspacePath,
    Map<String, dynamic> settings,
  ) => _writeSettingsMap(settingsFileForWorkspace(workspacePath), settings);

  Map<String, dynamic> encodeMcpServersDocument(
    List<McpServerConfig> servers,
  ) => {'mcpServers': _encodeMcpServers(servers)};

  Map<String, dynamic> encodeMcpSnapshotDocument(
    List<McpServerConfig> servers,
  ) => {'mcpServers': _encodeMcpServers(servers, snapshot: true)};

  List<McpServerConfig> parseMcpServersDocument(
    Map<String, dynamic> document,
  ) => _parseMcpServers(document['mcpServers'] ?? document['mcp_servers']);

  Future<McpServerConfig> applySecretMutations(
    McpServerConfig config,
    Map<String, dynamic> mutations,
  ) async {
    var next = config;
    final bearer = mutations['bearer_token'];
    if (bearer is String && bearer.isNotEmpty) {
      next = next.copyWith(
        bearerTokenRef: await _secrets.put(
          bearer,
          existingRef: config.bearerTokenRef,
        ),
      );
    } else if (mutations['remove_bearer'] == true) {
      await _secrets.remove(config.bearerTokenRef);
      next = next.copyWith(clearBearerToken: true);
    }

    final secretHeaders = _stringMap(mutations['secret_headers']);
    if (secretHeaders.isNotEmpty) {
      final refs = await _secrets.putMany(
        secretHeaders,
        existingRefs: config.secretHeaders,
      );
      next = next.copyWith(secretHeaders: {...config.secretHeaders, ...refs});
    }
    final removedHeaders = _stringList(mutations['remove_secret_headers']);
    if (removedHeaders.isNotEmpty) {
      final refs = Map<String, String>.from(next.secretHeaders);
      for (final name in removedHeaders) {
        await _secrets.remove(refs.remove(name));
      }
      next = next.copyWith(secretHeaders: refs);
    }

    final secretEnv = _stringMap(mutations['secret_env']);
    if (secretEnv.isNotEmpty) {
      final refs = await _secrets.putMany(
        secretEnv,
        existingRefs: config.secretEnv,
      );
      next = next.copyWith(secretEnv: {...config.secretEnv, ...refs});
    }
    final removedEnv = _stringList(mutations['remove_secret_env']);
    if (removedEnv.isNotEmpty) {
      final refs = Map<String, String>.from(next.secretEnv);
      for (final name in removedEnv) {
        await _secrets.remove(refs.remove(name));
      }
      next = next.copyWith(secretEnv: refs);
    }

    final oauth = _stringMap(mutations['oauth']);
    if (oauth['client_secret'] case final value?) {
      next = next.copyWith(
        oauthClientSecretRef: await _secrets.put(
          value,
          existingRef: config.oauthClientSecretRef,
        ),
      );
    }
    if (oauth['access_token'] case final value?) {
      next = next.copyWith(
        oauthAccessTokenRef: await _secrets.put(
          value,
          existingRef: config.oauthAccessTokenRef,
        ),
      );
    }
    if (oauth['refresh_token'] case final value?) {
      next = next.copyWith(
        oauthRefreshTokenRef: await _secrets.put(
          value,
          existingRef: config.oauthRefreshTokenRef,
        ),
      );
    }
    return next;
  }

  Map<String, String> resolveHeaders(McpServerConfig config) {
    final result = <String, String>{
      ...config.headers,
      ..._secrets.resolveMany(config.secretHeaders),
    };
    final reference = config.authType == McpAuthType.bearer
        ? config.bearerTokenRef
        : config.authType == McpAuthType.oauth
        ? config.oauthAccessTokenRef
        : null;
    final token = _secrets.resolve(reference);
    if (token != null) result['Authorization'] = 'Bearer $token';
    return result;
  }

  String? resolveOAuthRefreshToken(McpServerConfig config) =>
      _secrets.resolve(config.oauthRefreshTokenRef);

  String? resolveOAuthClientSecret(McpServerConfig config) =>
      _secrets.resolve(config.oauthClientSecretRef);

  List<String> resolveArguments(McpServerConfig config) {
    if (config.secretArgs.isEmpty) return config.args;
    final resolved = List<String>.from(config.args);
    for (final entry in config.secretArgs.entries) {
      if (entry.key < 0 || entry.key >= resolved.length) {
        throw StateError('MCP secret argument index ${entry.key} is invalid.');
      }
      final value = _secrets.resolve(entry.value);
      if (value == null) {
        throw StateError('MCP secret argument ${entry.key} is unavailable.');
      }
      resolved[entry.key] = value;
    }
    return resolved;
  }

  Map<String, String> resolveEnvironment(McpServerConfig config) => {
    ...config.env,
    ..._secrets.resolveMany(config.secretEnv),
  };

  static Directory sanadDirectoryForWorkspace(
    String workspacePath,
  ) => Directory(
    '${_normalizeWorkspacePath(workspacePath) ?? workspacePath.trim()}${Platform.pathSeparator}.sanad',
  );

  static File settingsFileForWorkspace(String workspacePath) => File(
    '${sanadDirectoryForWorkspace(workspacePath).path}${Platform.pathSeparator}settings.json',
  );

  static File mcpConfigFileForWorkspace(String workspacePath) => File(
    '${sanadDirectoryForWorkspace(workspacePath).path}${Platform.pathSeparator}mcp_config.json',
  );

  Future<Map<String, dynamic>> _readAndMigrateMcpDocument(File file) async {
    final original = await _readSettingsMap(file);
    if (original.isEmpty) return original;
    final root = original['mcpServers'] ?? original['mcp_servers'];
    if (root is! Map) return original;

    var changed = false;
    final migrated = <String, dynamic>{};
    for (final entry in root.entries) {
      if (entry.value is! Map) continue;
      final server = Map<String, dynamic>.from(entry.value as Map);
      final oauth = server['oauth'] is Map
          ? Map<String, dynamic>.from(server['oauth'] as Map)
          : <String, dynamic>{};

      Future<String?> migrateValue(Object? raw, String? existingRef) async {
        if (raw is! String || raw.isEmpty) return existingRef;
        changed = true;
        return _secrets.put(raw, existingRef: existingRef);
      }

      final bearerRaw =
          server.remove('bearerToken') ?? server.remove('bearer_token');
      final bearerRef = await migrateValue(
        bearerRaw,
        server['bearerTokenRef'] as String?,
      );
      if (bearerRef != null) server['bearerTokenRef'] = bearerRef;

      final clientSecret =
          server.remove('oauthClientSecret') ?? oauth.remove('clientSecret');
      final accessToken =
          server.remove('accessToken') ?? oauth.remove('accessToken');
      final refreshToken =
          server.remove('refreshToken') ?? oauth.remove('refreshToken');
      final clientSecretRef = await migrateValue(
        clientSecret,
        oauth['clientSecretRef'] as String?,
      );
      final accessTokenRef = await migrateValue(
        accessToken,
        oauth['accessTokenRef'] as String?,
      );
      final refreshTokenRef = await migrateValue(
        refreshToken,
        oauth['refreshTokenRef'] as String?,
      );
      if (clientSecretRef != null) oauth['clientSecretRef'] = clientSecretRef;
      if (accessTokenRef != null) oauth['accessTokenRef'] = accessTokenRef;
      if (refreshTokenRef != null) oauth['refreshTokenRef'] = refreshTokenRef;
      if (oauth.isNotEmpty) server['oauth'] = oauth;

      final headers = _stringMap(server['headers']);
      final secretHeaders = _stringMap(server['secretHeaders']);
      for (final header in headers.keys.toList()) {
        if (header.toLowerCase() == 'authorization') {
          secretHeaders[header] = await _secrets.put(
            headers.remove(header)!,
            existingRef: secretHeaders[header],
          );
          changed = true;
        }
      }
      if (headers.isNotEmpty) {
        server['headers'] = headers;
      } else {
        server.remove('headers');
      }
      if (secretHeaders.isNotEmpty) server['secretHeaders'] = secretHeaders;

      final env = _stringMap(server['env']);
      final secretEnv = _stringMap(server['secretEnv']);
      for (final key in env.keys.toList()) {
        if (_likelySecretKey.hasMatch(key)) {
          secretEnv[key] = await _secrets.put(
            env.remove(key)!,
            existingRef: secretEnv[key],
          );
          changed = true;
        }
      }
      if (env.isNotEmpty) {
        server['env'] = env;
      } else {
        server.remove('env');
      }
      if (secretEnv.isNotEmpty) server['secretEnv'] = secretEnv;

      final args = _stringList(server['args']).toList(growable: false);
      final secretArgs = _indexedStringMap(server['secretArgs']);
      for (var index = 0; index < args.length - 1; index++) {
        if (!_secretArgumentFlags.contains(args[index].toLowerCase())) continue;
        final valueIndex = index + 1;
        final rawValue = args[valueIndex];
        if (rawValue.isEmpty ||
            rawValue == '<secret>' ||
            McpSecretStore.isReference(rawValue)) {
          continue;
        }
        secretArgs[valueIndex] = await _secrets.put(
          rawValue,
          existingRef: secretArgs[valueIndex],
        );
        args[valueIndex] = '<secret>';
        changed = true;
      }
      if (args.isNotEmpty) server['args'] = args;
      if (secretArgs.isNotEmpty) {
        server['secretArgs'] = {
          for (final item in secretArgs.entries)
            item.key.toString(): item.value,
        };
      }

      migrated[entry.key.toString()] = server;
    }
    if (!changed) return original;
    final next = Map<String, dynamic>.from(original)
      ..remove('mcp_servers')
      ..['mcpServers'] = migrated;
    await _writeSettingsMap(file, next);
    return next;
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
    if (raw.trim().isEmpty) return <String, dynamic>{};
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw const FormatException('Sanad settings must be a JSON object.');
    }
    return Map<String, dynamic>.from(decoded);
  }

  File _userMcpConfigFile() => File(
    '${_resolveSanadHomeDirectory()}${Platform.pathSeparator}mcp_config.json',
  );

  File _workspaceMcpConfigFile(String workspacePath) =>
      mcpConfigFileForWorkspace(workspacePath);

  String _resolveSanadHomeDirectory() =>
      homeDirectoryPath?.trim().isNotEmpty == true
      ? homeDirectoryPath!.trim()
      : getSanadHome();

  static String? _normalizeWorkspacePath(String? workspacePath) {
    final trimmed = workspacePath?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    try {
      return Directory(trimmed).resolveSymbolicLinksSync();
    } catch (_) {
      return Directory(trimmed).absolute.path;
    }
  }

  List<McpServerConfig> _parseMcpServers(Object? rawValue) {
    if (rawValue is List) {
      return rawValue
          .whereType<Map>()
          .map(
            (item) => McpServerConfig.fromJson(Map<String, dynamic>.from(item)),
          )
          .toList(growable: false);
    }
    if (rawValue is! Map) return const [];
    return rawValue.entries
        .where((entry) => entry.value is Map)
        .map((entry) {
          final json = Map<String, dynamic>.from(entry.value as Map)
            ..putIfAbsent('name', () => entry.key.toString());
          return McpServerConfig.fromJson(json);
        })
        .toList(growable: false);
  }

  Future<void> _writeSettingsMap(
    File file,
    Map<String, dynamic> settings,
  ) async {
    final text = const JsonEncoder.withIndent('  ').convert(settings);
    if (file.path == _userMcpConfigFile().path) {
      await SanadHomeBootstrap.atRoot(
        _resolveSanadHomeDirectory(),
        scope: SanadHomeScope.identity,
      ).writeConfigText('mcp_config.json', text);
      return;
    }
    await file.parent.create(recursive: true);
    await file.writeAsString(text);
  }

  Map<String, dynamic> _encodeMcpServers(
    List<McpServerConfig> servers, {
    bool snapshot = false,
  }) => {
    for (final server in servers)
      server.name: snapshot ? server.toSnapshotJson() : server.toConfigJson(),
  };

  static Map<String, String> _stringMap(Object? value) => value is Map
      ? value.map((key, item) => MapEntry(key.toString(), item.toString()))
      : <String, String>{};

  static List<String> _stringList(Object? value) => value is List
      ? value.map((item) => item.toString()).toList(growable: false)
      : const [];

  static Map<int, String> _indexedStringMap(Object? value) {
    if (value is! Map) return <int, String>{};
    final result = <int, String>{};
    for (final entry in value.entries) {
      final index = int.tryParse(entry.key.toString());
      if (index != null) result[index] = entry.value.toString();
    }
    return result;
  }

  static const _secretArgumentFlags = {
    '--api-key',
    '--apikey',
    '--api_key',
    '--token',
    '--access-token',
    '--access_token',
    '--client-secret',
    '--client_secret',
    '--password',
  };

  static final RegExp _likelySecretKey = RegExp(
    r'(token|secret|password|passwd|api[_-]?key|credential)',
    caseSensitive: false,
  );
}
