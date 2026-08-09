import 'package:uuid/uuid.dart';

enum McpAuthType {
  none('None'),
  bearer('Bearer token'),
  oauth('OAuth'),
  customHeaders('Custom headers');

  final String displayName;
  const McpAuthType(this.displayName);
}

enum McpTransportType {
  auto('Auto-detect'),
  streamableHttp('Streamable HTTP'),
  sse('SSE'),
  stdio('STDIO');

  final String displayName;
  const McpTransportType(this.displayName);
}

class McpServerConfig {
  McpServerConfig({
    String? id,
    required this.name,
    this.description,
    this.serverUrl = '',
    this.authType = McpAuthType.none,
    this.transport = McpTransportType.auto,
    DateTime? createdAt,
    this.enabled = true,
    this.disabledTools = const [],
    this.command,
    this.args = const [],
    this.env = const {},
    this.secretEnv = const {},
    this.headers = const {},
    this.secretHeaders = const {},
    this.bearerTokenRef,
    this.oauthClientId,
    this.oauthClientSecretRef,
    this.oauthAuthUrl,
    this.oauthTokenUrl,
    this.oauthAccessTokenRef,
    this.oauthRefreshTokenRef,
    this.tokenExpiry,
  }) : id = id ?? const Uuid().v4(),
       createdAt = createdAt ?? DateTime.now().toUtc();

  final String id;
  final String name;
  final String? description;
  final String serverUrl;
  final McpAuthType authType;
  final McpTransportType transport;
  final DateTime createdAt;
  final bool enabled;
  final List<String> disabledTools;
  final String? command;
  final List<String> args;
  final Map<String, String> env;
  final Map<String, String> secretEnv;
  final Map<String, String> headers;
  final Map<String, String> secretHeaders;
  final String? bearerTokenRef;
  final String? oauthClientId;
  final String? oauthClientSecretRef;
  final String? oauthAuthUrl;
  final String? oauthTokenUrl;
  final String? oauthAccessTokenRef;
  final String? oauthRefreshTokenRef;
  final DateTime? tokenExpiry;

  McpTransportType get detectedTransport => transport;
  bool get hasConfiguredBearer => bearerTokenRef != null;
  bool get hasConfiguredOAuth =>
      oauthAccessTokenRef != null || oauthRefreshTokenRef != null;

  Map<String, dynamic> toConfigJson() {
    final json = <String, dynamic>{
      if (description?.trim().isNotEmpty == true) 'description': description,
      if (!enabled) 'disabled': true,
      if (disabledTools.isNotEmpty) 'disabledTools': disabledTools,
      'transport': transport.name,
      'authType': authType.name,
    };
    if (transport == McpTransportType.stdio) {
      json['command'] = command;
      if (args.isNotEmpty) json['args'] = args;
      if (env.isNotEmpty) json['env'] = env;
      if (secretEnv.isNotEmpty) json['secretEnv'] = secretEnv;
    } else {
      json['url'] = serverUrl;
      if (headers.isNotEmpty) json['headers'] = headers;
      if (secretHeaders.isNotEmpty) json['secretHeaders'] = secretHeaders;
      if (bearerTokenRef != null) json['bearerTokenRef'] = bearerTokenRef;
      final oauth = <String, dynamic>{
        if (oauthClientId?.isNotEmpty == true) 'clientId': oauthClientId,
        if (oauthClientSecretRef != null)
          'clientSecretRef': oauthClientSecretRef,
        if (oauthAuthUrl?.isNotEmpty == true) 'authUrl': oauthAuthUrl,
        if (oauthTokenUrl?.isNotEmpty == true) 'tokenUrl': oauthTokenUrl,
        if (oauthAccessTokenRef != null) 'accessTokenRef': oauthAccessTokenRef,
        if (oauthRefreshTokenRef != null)
          'refreshTokenRef': oauthRefreshTokenRef,
        if (tokenExpiry != null)
          'tokenExpiry': tokenExpiry!.toUtc().toIso8601String(),
      };
      if (oauth.isNotEmpty) json['oauth'] = oauth;
    }
    return json;
  }

  Map<String, dynamic> toSnapshotJson() {
    final json = toConfigJson();
    if (bearerTokenRef != null) {
      json.remove('bearerTokenRef');
      json['bearerConfigured'] = true;
    }
    if (secretEnv.isNotEmpty) {
      json['secretEnv'] = {
        for (final key in secretEnv.keys) key: const {'configured': true},
      };
    }
    if (secretHeaders.isNotEmpty) {
      json['secretHeaders'] = {
        for (final key in secretHeaders.keys) key: const {'configured': true},
      };
    }
    final oauth = json['oauth'];
    if (oauth is Map<String, dynamic>) {
      final configured =
          oauth.containsKey('clientSecretRef') ||
          oauth.containsKey('accessTokenRef') ||
          oauth.containsKey('refreshTokenRef');
      oauth
        ..remove('clientSecretRef')
        ..remove('accessTokenRef')
        ..remove('refreshTokenRef');
      if (configured) oauth['configured'] = true;
    }
    return json;
  }

  factory McpServerConfig.fromJson(Map<String, dynamic> json) {
    final oauth = _stringMapDynamic(json['oauth']);
    final hasCommand = _string(json['command'])?.isNotEmpty == true;
    final transport = _parseTransport(json, hasCommand: hasCommand);
    return McpServerConfig(
      id: _string(json['id']),
      name: _string(json['name']) ?? '',
      description: _string(json['description']),
      serverUrl: _string(json['serverUrl']) ?? _string(json['url']) ?? '',
      authType: _parseAuth(json, oauth),
      transport: transport,
      createdAt: _date(json['createdAt']),
      enabled: json['disabled'] != true,
      disabledTools: _stringList(json['disabledTools']),
      command: _string(json['command']),
      args: _stringList(json['args']),
      env: _stringMap(json['env']),
      secretEnv: _secretRefMap(json['secretEnv']),
      headers: _stringMap(json['headers']),
      secretHeaders: _secretRefMap(json['secretHeaders']),
      bearerTokenRef: _string(json['bearerTokenRef']),
      oauthClientId:
          _string(json['oauthClientId']) ?? _string(oauth['clientId']),
      oauthClientSecretRef:
          _string(json['oauthClientSecretRef']) ??
          _string(oauth['clientSecretRef']),
      oauthAuthUrl:
          _string(json['oauthAuthUrl']) ??
          _string(oauth['authUrl']) ??
          _string(oauth['authorizationUrl']),
      oauthTokenUrl:
          _string(json['oauthTokenUrl']) ?? _string(oauth['tokenUrl']),
      oauthAccessTokenRef:
          _string(json['oauthAccessTokenRef']) ??
          _string(oauth['accessTokenRef']),
      oauthRefreshTokenRef:
          _string(json['oauthRefreshTokenRef']) ??
          _string(oauth['refreshTokenRef']),
      tokenExpiry: _date(json['tokenExpiry'] ?? oauth['tokenExpiry']),
    );
  }

  McpServerConfig copyWith({
    String? name,
    String? description,
    String? serverUrl,
    McpAuthType? authType,
    McpTransportType? transport,
    bool? enabled,
    List<String>? disabledTools,
    String? command,
    List<String>? args,
    Map<String, String>? env,
    Map<String, String>? secretEnv,
    Map<String, String>? headers,
    Map<String, String>? secretHeaders,
    String? bearerTokenRef,
    bool clearBearerToken = false,
    String? oauthClientId,
    String? oauthClientSecretRef,
    String? oauthAuthUrl,
    String? oauthTokenUrl,
    String? oauthAccessTokenRef,
    String? oauthRefreshTokenRef,
    DateTime? tokenExpiry,
  }) => McpServerConfig(
    id: id,
    name: name ?? this.name,
    description: description ?? this.description,
    serverUrl: serverUrl ?? this.serverUrl,
    authType: authType ?? this.authType,
    transport: transport ?? this.transport,
    createdAt: createdAt,
    enabled: enabled ?? this.enabled,
    disabledTools: disabledTools ?? this.disabledTools,
    command: command ?? this.command,
    args: args ?? this.args,
    env: env ?? this.env,
    secretEnv: secretEnv ?? this.secretEnv,
    headers: headers ?? this.headers,
    secretHeaders: secretHeaders ?? this.secretHeaders,
    bearerTokenRef: clearBearerToken
        ? null
        : bearerTokenRef ?? this.bearerTokenRef,
    oauthClientId: oauthClientId ?? this.oauthClientId,
    oauthClientSecretRef: oauthClientSecretRef ?? this.oauthClientSecretRef,
    oauthAuthUrl: oauthAuthUrl ?? this.oauthAuthUrl,
    oauthTokenUrl: oauthTokenUrl ?? this.oauthTokenUrl,
    oauthAccessTokenRef: oauthAccessTokenRef ?? this.oauthAccessTokenRef,
    oauthRefreshTokenRef: oauthRefreshTokenRef ?? this.oauthRefreshTokenRef,
    tokenExpiry: tokenExpiry ?? this.tokenExpiry,
  );

  bool isToolDisabled(String toolName) =>
      disabledTools.contains(toolName.trim());

  static McpTransportType _parseTransport(
    Map<String, dynamic> json, {
    required bool hasCommand,
  }) {
    final raw =
        _string(json['transport']) ??
        _string(json['detectedTransport']) ??
        _string(json['type']);
    for (final value in McpTransportType.values) {
      if (value.name.toLowerCase() == raw?.toLowerCase()) return value;
    }
    if (raw?.toLowerCase() == 'http') return McpTransportType.streamableHttp;
    if (hasCommand) return McpTransportType.stdio;
    return McpTransportType.auto;
  }

  static McpAuthType _parseAuth(
    Map<String, dynamic> json,
    Map<String, dynamic> oauth,
  ) {
    final raw = _string(json['authType']) ?? _string(json['auth']);
    for (final value in McpAuthType.values) {
      if (value.name.toLowerCase() == raw?.toLowerCase()) return value;
    }
    if (raw == 'noAuth' || raw == 'none') return McpAuthType.none;
    if (raw == 'header') return McpAuthType.bearer;
    if (oauth.isNotEmpty) return McpAuthType.oauth;
    if (_string(json['bearerTokenRef']) != null) return McpAuthType.bearer;
    if (_stringMap(json['headers']).isNotEmpty ||
        _secretRefMap(json['secretHeaders']).isNotEmpty) {
      return McpAuthType.customHeaders;
    }
    return McpAuthType.none;
  }

  static String? _string(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static DateTime? _date(Object? value) {
    final raw = _string(value);
    return raw == null ? null : DateTime.tryParse(raw);
  }

  static List<String> _stringList(Object? value) => value is List
      ? value.map((item) => item.toString()).toList(growable: false)
      : const [];

  static Map<String, String> _stringMap(Object? value) => value is Map
      ? value.map((key, item) => MapEntry(key.toString(), item.toString()))
      : const {};

  static Map<String, dynamic> _stringMapDynamic(Object? value) =>
      value is Map ? Map<String, dynamic>.from(value) : const {};

  static Map<String, String> _secretRefMap(Object? value) {
    if (value is! Map) return const {};
    final result = <String, String>{};
    for (final entry in value.entries) {
      if (entry.value is String) {
        result[entry.key.toString()] = entry.value as String;
      }
    }
    return result;
  }
}
