/// Configuration model for an agent backend
class DeviceConfig {
  /// Stable client-only identity for the synthetic desktop inventory entry.
  ///
  /// This value identifies an inventory row. It must never be used to infer
  /// which transport should carry a request.
  static const syntheticLocalId = 'local-agent';
  static const int maxNameLength = 255;

  final String id;
  final String name;
  final String? hardwareId; // For Sanad Agent - device ID
  final String? token; // For Sanad Agent - connection token
  final String? sessionId; // Session ID for sessions
  final Map<String, dynamic>? metadata;
  bool isOnline; // Connection status (mutable)
  final DateTime? createdAt;
  final DateTime? updatedAt;

  DeviceConfig({
    required this.id,
    required this.name,
    this.hardwareId,
    this.token,
    this.sessionId,
    this.metadata,
    this.isOnline = false,
    this.createdAt,
    this.updatedAt,
  });

  bool get isLocalReachable => metadata?['is_local_reachable'] == true;
  bool get isLocalCandidate => metadata?['is_local_candidate'] == true;
  bool get isSyntheticLocal => id == syntheticLocalId;

  /// Cloud inventory identity represented by this device after a same-hardware
  /// cloud/local entry is merged into the canonical local entry.
  String? get cloudDeviceId => metadata?['cloud_device_id'] as String?;

  /// The account-owned id that can be used for inventory mutations.
  String? get accountDeviceId => cloudDeviceId ?? (isSyntheticLocal ? null : id);

  bool representsDeviceId(String deviceId) => id == deviceId || cloudDeviceId == deviceId;

  /// Display/debug metadata populated by DeviceConnectionCoordinator.
  /// Do not use this as the source of truth for transport selection.
  String? get preferredConnectionScope => metadata?['preferred_connection_scope'] as String?;

  /// Convenience flag for UI display only. Transport binding remains owned
  /// by DeviceConnectionCoordinator.
  bool get prefersLocalConnection => preferredConnectionScope == 'local';

  /// Create from JSON (API response)
  factory DeviceConfig.fromApiResponse(Map<String, dynamic> json) {
    return DeviceConfig(
      id: json['id'] as String,
      name: json['name'] as String,
      hardwareId: json['hardware_id'] as String?,
      token: json['token'] as String?,
      metadata: json['metadata'] as Map<String, dynamic>?,
      isOnline: json['is_online'] as bool? ?? false,
      createdAt: json['created_at'] != null ? DateTime.tryParse(json['created_at'] as String) : null,
      updatedAt: json['updated_at'] != null ? DateTime.tryParse(json['updated_at'] as String) : null,
    );
  }

  /// Create from JSON (local storage)
  factory DeviceConfig.fromJson(Map<String, dynamic> json) {
    return DeviceConfig(
      id: json['id'] as String,
      name: json['name'] as String,
      hardwareId: json['hardwareId'] as String?,
      token: json['token'] as String?,
      sessionId: json['sessionId'] as String?,
      metadata: json['metadata'] as Map<String, dynamic>?,
      isOnline: json['isOnline'] as bool? ?? false,
      createdAt: json['createdAt'] != null ? DateTime.tryParse(json['createdAt'] as String) : null,
      updatedAt: json['updatedAt'] != null ? DateTime.tryParse(json['updatedAt'] as String) : null,
    );
  }

  /// Convert to JSON (local storage)
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      if (hardwareId != null) 'hardwareId': hardwareId,
      if (token != null) 'token': token,
      if (sessionId != null) 'sessionId': sessionId,
      if (metadata != null) 'metadata': metadata,
      'isOnline': isOnline,
      if (createdAt != null) 'createdAt': createdAt!.toIso8601String(),
      if (updatedAt != null) 'updatedAt': updatedAt!.toIso8601String(),
    };
  }

  /// Create a copy with updated fields
  DeviceConfig copyWith({
    String? id,
    String? name,
    String? hardwareId,
    String? token,
    String? sessionId,
    Map<String, dynamic>? metadata,
    bool? isOnline,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return DeviceConfig(
      id: id ?? this.id,
      name: name ?? this.name,
      hardwareId: hardwareId ?? this.hardwareId,
      token: token ?? this.token,
      sessionId: sessionId ?? this.sessionId,
      metadata: metadata ?? this.metadata,
      isOnline: isOnline ?? this.isOnline,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is DeviceConfig &&
        other.id == id &&
        other.name == name &&
        other.hardwareId == hardwareId &&
        other.token == token &&
        other.sessionId == sessionId &&
        _mapEquals(other.metadata, metadata) &&
        other.isOnline == isOnline &&
        other.createdAt == createdAt &&
        other.updatedAt == updatedAt;
  }

  @override
  int get hashCode => Object.hash(
    id,
    name,
    hardwareId,
    token,
    sessionId,
    _metadataHash(metadata),
    isOnline,
    createdAt,
    updatedAt,
  );

  @override
  String toString() => 'DeviceConfig(id: $id, name: $name, isOnline: $isOnline)';

  static bool _mapEquals(Map<String, dynamic>? a, Map<String, dynamic>? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null) return a == b;
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }

  static int _metadataHash(Map<String, dynamic>? metadata) {
    if (metadata == null || metadata.isEmpty) return 0;
    final entries = metadata.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
    return Object.hashAll(entries.map((entry) => Object.hash(entry.key, entry.value)));
  }
}

/// Enum representing connection status
enum ConnectionStatus {
  disconnected,
  connecting,
  connected,
  error,
}

extension ConnectionStatusExtension on ConnectionStatus {
  String get displayName {
    switch (this) {
      case ConnectionStatus.connected:
        return 'متصل';
      case ConnectionStatus.connecting:
        return 'جاري الاتصال';
      case ConnectionStatus.disconnected:
        return 'غير متصل';
      case ConnectionStatus.error:
        return 'خطأ';
    }
  }
}
