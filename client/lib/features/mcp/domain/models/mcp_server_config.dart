import 'package:uuid/uuid.dart';

enum McpAuthType {
  none('None'),
  bearer('Bearer token'),
  oauth('OAuth'),
  customHeaders('Custom headers')
  ;

  const McpAuthType(this.displayName);
  final String displayName;
}

enum McpTransportType {
  auto('Auto-detect'),
  streamableHttp('Streamable HTTP'),
  sse('SSE'),
  stdio('STDIO')
  ;

  const McpTransportType(this.displayName);
  final String displayName;
}

class McpServerConfig {
  McpServerConfig({
    String? id,
    required this.name,
    this.description,
    this.serverUrl = '',
    this.authType = McpAuthType.none,
    McpTransportType? transport,
    McpTransportType? detectedTransport,
    DateTime? createdAt,
    this.lastUsedAt,
    this.enabled = true,
    this.disabledTools = const [],
    this.command,
    this.args = const [],
    this.env = const {},
    this.secretEnvConfigured = const {},
    this.headers = const {},
    this.secretHeadersConfigured = const {},
    this.bearerConfigured = false,
    this.oauthConfigured = false,
    this.oauthClientId,
    this.oauthAuthUrl,
    this.oauthTokenUrl,
  }) : id = id ?? const Uuid().v4(),
       transport = transport ?? detectedTransport ?? McpTransportType.auto,
       createdAt = createdAt ?? DateTime.now();

  final String id;
  final DateTime createdAt;
  final DateTime? lastUsedAt;
  final String name;
  final String? description;
  final String serverUrl;
  final McpAuthType authType;
  final McpTransportType transport;
  final bool enabled;
  final List<String> disabledTools;
  final String? command;
  final List<String> args;
  final Map<String, String> env;
  final Set<String> secretEnvConfigured;
  final Map<String, String> headers;
  final Set<String> secretHeadersConfigured;
  final bool bearerConfigured;
  final bool oauthConfigured;
  final String? oauthClientId;
  final String? oauthAuthUrl;
  final String? oauthTokenUrl;

  McpTransportType get detectedTransport => transport;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'createdAt': createdAt.toIso8601String(),
    if (lastUsedAt != null) 'lastUsedAt': lastUsedAt!.toIso8601String(),
    ...toConfigJson(),
  };

  Map<String, dynamic> toConfigJson() => {
    if (description?.trim().isNotEmpty == true) 'description': description,
    'transport': transport.name,
    'authType': authType.name,
    if (!enabled) 'disabled': true,
    if (disabledTools.isNotEmpty) 'disabledTools': disabledTools,
    if (transport == McpTransportType.stdio) ...{
      'command': command,
      if (args.isNotEmpty) 'args': args,
      if (env.isNotEmpty) 'env': env,
    } else ...{
      'url': serverUrl,
      if (headers.isNotEmpty) 'headers': headers,
      if (oauthClientId?.isNotEmpty == true || oauthAuthUrl?.isNotEmpty == true || oauthTokenUrl?.isNotEmpty == true)
        'oauth': {
          if (oauthClientId?.isNotEmpty == true) 'clientId': oauthClientId,
          if (oauthAuthUrl?.isNotEmpty == true) 'authUrl': oauthAuthUrl,
          if (oauthTokenUrl?.isNotEmpty == true) 'tokenUrl': oauthTokenUrl,
        },
    },
  };

  factory McpServerConfig.fromJson(Map<String, dynamic> json) {
    final oauth = json['oauth'] is Map ? Map<String, dynamic>.from(json['oauth'] as Map) : const <String, dynamic>{};
    final transportRaw =
        json['transport']?.toString() ?? json['detectedTransport']?.toString() ?? json['type']?.toString();
    final hasCommand = json['command']?.toString().trim().isNotEmpty == true;
    final transport = McpTransportType.values.firstWhere(
      (value) => value.name.toLowerCase() == transportRaw?.toLowerCase(),
      orElse: () => transportRaw?.toLowerCase() == 'http'
          ? McpTransportType.streamableHttp
          : hasCommand
          ? McpTransportType.stdio
          : McpTransportType.auto,
    );
    final authRaw = json['authType']?.toString() ?? json['auth']?.toString();
    final authType = McpAuthType.values.firstWhere(
      (value) => value.name.toLowerCase() == authRaw?.toLowerCase(),
      orElse: () => authRaw == 'header'
          ? McpAuthType.bearer
          : oauth.isNotEmpty
          ? McpAuthType.oauth
          : _configuredKeys(json['secretHeaders']).isNotEmpty
          ? McpAuthType.customHeaders
          : McpAuthType.none,
    );
    return McpServerConfig(
      id: json['id']?.toString(),
      name: json['name']?.toString() ?? '',
      createdAt: DateTime.tryParse(json['createdAt']?.toString() ?? ''),
      lastUsedAt: DateTime.tryParse(json['lastUsedAt']?.toString() ?? ''),
      description: json['description']?.toString(),
      serverUrl: json['serverUrl']?.toString() ?? json['url']?.toString() ?? '',
      authType: authType,
      transport: transport,
      enabled: json['disabled'] != true,
      disabledTools: _stringList(json['disabledTools']),
      command: json['command']?.toString(),
      args: _stringList(json['args']),
      env: _stringMap(json['env']),
      secretEnvConfigured: _configuredKeys(json['secretEnv']),
      headers: _stringMap(json['headers']),
      secretHeadersConfigured: _configuredKeys(json['secretHeaders']),
      bearerConfigured: json['bearerConfigured'] == true,
      oauthConfigured: oauth['configured'] == true,
      oauthClientId: oauth['clientId']?.toString(),
      oauthAuthUrl: oauth['authUrl']?.toString() ?? oauth['authorizationUrl']?.toString(),
      oauthTokenUrl: oauth['tokenUrl']?.toString(),
    );
  }

  McpServerConfig copyWith({
    String? name,
    String? description,
    DateTime? lastUsedAt,
    String? serverUrl,
    McpAuthType? authType,
    McpTransportType? transport,
    bool? enabled,
    List<String>? disabledTools,
    String? command,
    List<String>? args,
    Map<String, String>? env,
    Set<String>? secretEnvConfigured,
    Map<String, String>? headers,
    Set<String>? secretHeadersConfigured,
    bool? bearerConfigured,
    bool? oauthConfigured,
    String? oauthClientId,
    String? oauthAuthUrl,
    String? oauthTokenUrl,
  }) => McpServerConfig(
    id: id,
    name: name ?? this.name,
    createdAt: createdAt,
    lastUsedAt: lastUsedAt ?? this.lastUsedAt,
    description: description ?? this.description,
    serverUrl: serverUrl ?? this.serverUrl,
    authType: authType ?? this.authType,
    transport: transport ?? this.transport,
    enabled: enabled ?? this.enabled,
    disabledTools: disabledTools ?? this.disabledTools,
    command: command ?? this.command,
    args: args ?? this.args,
    env: env ?? this.env,
    secretEnvConfigured: secretEnvConfigured ?? this.secretEnvConfigured,
    headers: headers ?? this.headers,
    secretHeadersConfigured: secretHeadersConfigured ?? this.secretHeadersConfigured,
    bearerConfigured: bearerConfigured ?? this.bearerConfigured,
    oauthConfigured: oauthConfigured ?? this.oauthConfigured,
    oauthClientId: oauthClientId ?? this.oauthClientId,
    oauthAuthUrl: oauthAuthUrl ?? this.oauthAuthUrl,
    oauthTokenUrl: oauthTokenUrl ?? this.oauthTokenUrl,
  );

  bool isToolDisabled(String toolName) => disabledTools.contains(toolName.trim());

  static List<String> _stringList(Object? value) =>
      value is List ? value.map((item) => item.toString()).toList(growable: false) : const [];

  static Map<String, String> _stringMap(Object? value) =>
      value is Map ? value.map((key, item) => MapEntry(key.toString(), item.toString())) : const {};

  static Set<String> _configuredKeys(Object? value) {
    if (value is! Map) return const {};
    return value.entries
        .where((entry) {
          final marker = entry.value;
          return marker == true || (marker is Map && marker['configured'] == true);
        })
        .map((entry) => entry.key.toString())
        .toSet();
  }
}
