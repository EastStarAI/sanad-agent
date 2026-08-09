import 'dart:convert';

import 'mcp_server_config.dart';

class McpConfigPreview {
  const McpConfigPreview({
    required this.servers,
    required this.warnings,
    required this.unsupportedFields,
    required this.revision,
    this.diff = const [],
  });

  final List<McpServerConfig> servers;
  final List<String> warnings;
  final List<String> unsupportedFields;
  final String revision;
  final List<Map<String, dynamic>> diff;

  Map<String, dynamic> toJson() => {
    'servers': [
      for (final server in servers)
        {'name': server.name, 'config': server.toSnapshotJson()},
    ],
    'warnings': warnings,
    'unsupported_fields': unsupportedFields,
    'revision': revision,
    if (diff.isNotEmpty) 'diff': diff,
  };
}

class McpConfigCodec {
  const McpConfigCodec();

  static const maxInputBytes = 256 * 1024;
  static const maxServers = 100;
  static const maxFieldsPerServer = 128;

  static final RegExp _headerName = RegExp(r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$");
  static const _deniedHeaders = {
    'authorization',
    'host',
    'content-length',
    'transfer-encoding',
    'connection',
    'proxy-authorization',
    'proxy-authenticate',
  };
  static const _supportedFields = {
    'name',
    'description',
    'url',
    'serverUrl',
    'command',
    'args',
    'env',
    'secretEnv',
    'headers',
    'secretHeaders',
    'transport',
    'type',
    'auth',
    'authType',
    'disabled',
    'disabledTools',
    'oauth',
    'bearerConfigured',
  };

  McpConfigPreview previewImport(String input) {
    if (utf8.encode(input).length > maxInputBytes) {
      throw const FormatException('MCP import exceeds 256 KiB.');
    }
    final decoded = jsonDecode(input);
    if (decoded is! Map) {
      throw const FormatException('MCP import root must be an object.');
    }
    final root = Map<String, dynamic>.from(decoded);
    final Object? wrapped = root['mcpServers'] ?? root['mcp_servers'];
    late Map<String, dynamic> entries;
    if (_isServerShape(root) && root['name'] is String) {
      final name = root['name'].toString();
      entries = {name: Map<String, dynamic>.from(root)..remove('name')};
    } else if (wrapped is Map) {
      entries = Map<String, dynamic>.from(wrapped);
    } else {
      entries = root;
    }
    if (entries.length > maxServers) {
      throw const FormatException('MCP import contains too many servers.');
    }

    final names = <String>{};
    final servers = <McpServerConfig>[];
    final warnings = <String>[];
    final unsupported = <String>[];
    for (final entry in entries.entries) {
      if (entry.value is! Map) {
        throw FormatException('${entry.key} must be a server object.');
      }
      final name = entry.key.trim();
      if (name.isEmpty) throw const FormatException('Server name is required.');
      if (!names.add(name.toLowerCase())) {
        throw FormatException('Duplicate MCP server name: $name.');
      }
      final json = Map<String, dynamic>.from(entry.value as Map);
      if (json.length > maxFieldsPerServer) {
        throw FormatException('$name contains too many fields.');
      }
      if (_nonEmpty(json['command']) &&
          (_nonEmpty(json['url']) || _nonEmpty(json['serverUrl']))) {
        throw FormatException('$name cannot contain both command and URL.');
      }
      if (json.containsKey('bearerToken') ||
          json.containsKey('bearer_token') ||
          json.containsKey('accessToken') ||
          json.containsKey('refreshToken')) {
        throw FormatException('$name contains unsupported inline credentials.');
      }
      final unknown = json.keys
          .where((key) => !_supportedFields.contains(key))
          .toList();
      unsupported.addAll(unknown.map((field) => '$name.$field'));
      if (json.remove('type') case final alias?
          when json['transport'] == null) {
        json['transport'] = alias;
        warnings.add('$name.type was normalized to transport.');
      }
      json['name'] = name;
      final server = McpServerConfig.fromJson(json);
      validate(server);
      servers.add(server);
    }
    final canonical = _canonicalDocument(servers);
    return McpConfigPreview(
      servers: servers,
      warnings: warnings,
      unsupportedFields: unsupported,
      revision: revisionFor(canonical),
    );
  }

  McpConfigPreview previewAdvanced({
    required String serverName,
    required McpServerConfig current,
    required String input,
  }) {
    final preview = previewImport(input);
    if (preview.servers.length != 1 ||
        preview.servers.single.name.toLowerCase() != serverName.toLowerCase()) {
      throw const FormatException(
        'Advanced JSON must contain only the selected server.',
      );
    }
    final candidate = preview.servers.single;
    final before = current.toSnapshotJson();
    final after = candidate.toSnapshotJson();
    final keys = {...before.keys, ...after.keys}.toList()..sort();
    final diff = <Map<String, dynamic>>[];
    for (final key in keys) {
      if (jsonEncode(before[key]) != jsonEncode(after[key])) {
        diff.add({'field': key, 'before': before[key], 'after': after[key]});
      }
    }
    return McpConfigPreview(
      servers: preview.servers,
      warnings: preview.warnings,
      unsupportedFields: preview.unsupportedFields,
      revision: preview.revision,
      diff: diff,
    );
  }

  String exportServers(List<McpServerConfig> servers) =>
      const JsonEncoder.withIndent('  ').convert(_canonicalDocument(servers));

  String advancedJson(McpServerConfig server) =>
      const JsonEncoder.withIndent('  ').convert(_canonicalDocument([server]));

  void validate(McpServerConfig server, {bool allowMissingBearer = false}) {
    if (server.name.trim().isEmpty) {
      throw const FormatException('Server name is required.');
    }
    if (server.transport == McpTransportType.stdio) {
      if (server.command?.trim().isNotEmpty != true) {
        throw const FormatException('STDIO command is required.');
      }
      if (server.serverUrl.isNotEmpty) {
        throw const FormatException('STDIO server cannot contain a URL.');
      }
    } else if (server.serverUrl.trim().isEmpty) {
      throw const FormatException('Remote server URL is required.');
    }
    if (server.transport != McpTransportType.stdio &&
        server.command?.trim().isNotEmpty == true) {
      throw const FormatException('Remote server cannot contain a command.');
    }
    if (server.authType == McpAuthType.bearer &&
        !server.hasConfiguredBearer &&
        !allowMissingBearer) {
      throw const FormatException('Bearer token is not configured.');
    }
    for (final name in {...server.headers.keys, ...server.secretHeaders.keys}) {
      validateHeaderName(name);
    }
    for (final value in server.headers.values) {
      if (value.contains('\r') || value.contains('\n')) {
        throw const FormatException(
          'Header values cannot contain line breaks.',
        );
      }
    }
  }

  void validateHeaderName(String name) {
    final normalized = name.trim().toLowerCase();
    if (normalized.isEmpty ||
        name.startsWith(':') ||
        !_headerName.hasMatch(name) ||
        _deniedHeaders.contains(normalized)) {
      throw FormatException('Header name is not allowed: $name.');
    }
  }

  String revisionFor(Map<String, dynamic> document) {
    final input = utf8.encode(jsonEncode(document));
    var hash = 0xcbf29ce484222325;
    for (final byte in input) {
      hash ^= byte;
      hash = (hash * 0x100000001b3) & 0x7fffffffffffffff;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }

  Map<String, dynamic> _canonicalDocument(List<McpServerConfig> servers) {
    final sorted = [...servers]..sort((a, b) => a.name.compareTo(b.name));
    return {
      'mcpServers': {
        for (final server in sorted) server.name: _exportConfig(server),
      },
    };
  }

  Map<String, dynamic> _exportConfig(McpServerConfig server) {
    final json = server.toSnapshotJson()
      ..remove('bearerConfigured')
      ..remove('secretEnv')
      ..remove('secretHeaders');
    final oauth = json['oauth'];
    if (oauth is Map) {
      oauth.remove('configured');
      if (oauth.isEmpty) json.remove('oauth');
    }
    return json;
  }

  bool _isServerShape(Map<String, dynamic> value) =>
      _nonEmpty(value['command']) ||
      _nonEmpty(value['url']) ||
      _nonEmpty(value['serverUrl']);

  bool _nonEmpty(Object? value) => value is String && value.trim().isNotEmpty;
}
