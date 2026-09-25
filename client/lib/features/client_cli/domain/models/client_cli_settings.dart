class ClientCliSettings {
  final bool enabled;
  final String permissionMode; // 'default' | 'full_access'

  const ClientCliSettings({
    this.enabled = false,
    this.permissionMode = defaultMode,
  });

  static const String defaultMode = 'default';
  static const String fullAccessMode = 'full_access';

  ClientCliSettings copyWith({
    bool? enabled,
    String? permissionMode,
  }) {
    return ClientCliSettings(
      enabled: enabled ?? this.enabled,
      permissionMode: permissionMode ?? this.permissionMode,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ClientCliSettings &&
          runtimeType == other.runtimeType &&
          enabled == other.enabled &&
          permissionMode == other.permissionMode;

  @override
  int get hashCode => enabled.hashCode ^ permissionMode.hashCode;

  @override
  String toString() =>
      'ClientCliSettings(enabled: $enabled, permissionMode: $permissionMode)';
}
