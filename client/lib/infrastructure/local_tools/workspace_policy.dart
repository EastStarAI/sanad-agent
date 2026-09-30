enum WorkspacePermissionMode {
  defaultMode('default'),
  fullAccess('full_access');

  const WorkspacePermissionMode(this.value);

  final String value;

  static WorkspacePermissionMode fromValue(String? value) {
    for (final mode in WorkspacePermissionMode.values) {
      if (mode.value == value) {
        return mode;
      }
    }
    return WorkspacePermissionMode.defaultMode;
  }
}

class WorkspaceToolPermissions {
  final List<String> allow;
  final List<String> deny;
  final List<String> ask;

  const WorkspaceToolPermissions({
    this.allow = const [],
    this.deny = const [],
    this.ask = const [],
  });

  factory WorkspaceToolPermissions.fromJson(Map<String, dynamic>? json) {
    if (json == null) {
      return const WorkspaceToolPermissions();
    }

    List<String> readList(String key) {
      final value = json[key];
      if (value is! List) {
        return const [];
      }
      return value.map((item) => item.toString()).toList(growable: false);
    }

    return WorkspaceToolPermissions(
      allow: readList('allow'),
      deny: readList('deny'),
      ask: readList('ask'),
    );
  }

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{};
    if (allow.isNotEmpty) {
      json['allow'] = allow;
    }
    if (deny.isNotEmpty) {
      json['deny'] = deny;
    }
    if (ask.isNotEmpty) {
      json['ask'] = ask;
    }
    return json;
  }

  bool get isEmpty => allow.isEmpty && deny.isEmpty && ask.isEmpty;
}

class WorkspacePolicy {
  final WorkspacePermissionMode permissionMode;
  final WorkspaceToolPermissions permissions;

  const WorkspacePolicy({
    this.permissionMode = WorkspacePermissionMode.defaultMode,
    this.permissions = const WorkspaceToolPermissions(),
  });

  factory WorkspacePolicy.fromJson(Map<String, dynamic>? json) {
    if (json == null) {
      return const WorkspacePolicy();
    }

    return WorkspacePolicy(
      permissionMode: WorkspacePermissionMode.fromValue(json['permissionMode']?.toString()),
      permissions: WorkspaceToolPermissions.fromJson(json['permissions'] as Map<String, dynamic>?),
    );
  }

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{
      'permissionMode': permissionMode.value,
    };
    if (!permissions.isEmpty) {
      json['permissions'] = permissions.toJson();
    }
    return json;
  }

  WorkspacePolicy copyWith({
    WorkspacePermissionMode? permissionMode,
    WorkspaceToolPermissions? permissions,
  }) {
    return WorkspacePolicy(
      permissionMode: permissionMode ?? this.permissionMode,
      permissions: permissions ?? this.permissions,
    );
  }
}
