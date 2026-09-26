const int clientCliRecordVersion = 1;

class ClientCliRecord {
  final int version;
  final int pid;
  final int port;
  final String token;
  final String sanadHome;
  final String clientVersion;
  final bool enabled;
  final String permissionMode;
  final DateTime updatedAt;

  const ClientCliRecord({
    this.version = clientCliRecordVersion,
    required this.pid,
    required this.port,
    required this.token,
    required this.sanadHome,
    required this.clientVersion,
    required this.enabled,
    required this.permissionMode,
    required this.updatedAt,
  });

  Map<String, dynamic> toJson() => {
    'version': version,
    'pid': pid,
    'port': port,
    'token': token,
    'sanad_home': sanadHome,
    'client_version': clientVersion,
    'enabled': enabled,
    'permission_mode': permissionMode,
    'updated_at': updatedAt.toUtc().toIso8601String(),
  };

  factory ClientCliRecord.fromJson(Map<String, dynamic> json) {
    final version = json['version'] as int? ?? clientCliRecordVersion;
    if (version != clientCliRecordVersion) {
      throw FormatException('Unsupported Client CLI record version: $version');
    }
    return ClientCliRecord(
      version: version,
      pid: json['pid'] as int,
      port: json['port'] as int,
      token: json['token'] as String,
      sanadHome: json['sanad_home'] as String,
      clientVersion: json['client_version'] as String? ?? 'unknown',
      enabled: json['enabled'] as bool? ?? false,
      permissionMode: json['permission_mode'] as String? ?? 'default',
      updatedAt: json['updated_at'] != null
          ? DateTime.parse(json['updated_at'] as String).toUtc()
          : DateTime.now().toUtc(),
    );
  }

  ClientCliRecord copyWith({
    int? pid,
    int? port,
    String? token,
    String? sanadHome,
    String? clientVersion,
    bool? enabled,
    String? permissionMode,
    DateTime? updatedAt,
  }) {
    return ClientCliRecord(
      version: version,
      pid: pid ?? this.pid,
      port: port ?? this.port,
      token: token ?? this.token,
      sanadHome: sanadHome ?? this.sanadHome,
      clientVersion: clientVersion ?? this.clientVersion,
      enabled: enabled ?? this.enabled,
      permissionMode: permissionMode ?? this.permissionMode,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  String toString() =>
      'ClientCliRecord(pid: $pid, port: $port, enabled: $enabled, mode: $permissionMode, home: $sanadHome)';
}
