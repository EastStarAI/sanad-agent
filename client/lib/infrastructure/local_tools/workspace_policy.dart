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

/// Where the Agent runs workspace commands. Unknown values read as
/// [protected], the restrictive posture.
enum WorkspaceExecutionMode {
  direct('direct'),
  protected('protected');

  const WorkspaceExecutionMode(this.value);

  final String value;

  static WorkspaceExecutionMode fromValue(String? value) {
    if (value == null) return WorkspaceExecutionMode.direct;
    for (final mode in WorkspaceExecutionMode.values) {
      if (mode.value == value) return mode;
    }
    return WorkspaceExecutionMode.protected;
  }
}

/// Owner ceiling for host tool discovery. Unknown values read as [disabled].
enum WorkspaceHostDiscoveryPolicy {
  disabled('disabled'),
  ownerOnly('owner_only');

  const WorkspaceHostDiscoveryPolicy(this.value);

  final String value;

  static WorkspaceHostDiscoveryPolicy fromValue(String? value) {
    if (value == null) return WorkspaceHostDiscoveryPolicy.ownerOnly;
    for (final policy in WorkspaceHostDiscoveryPolicy.values) {
      if (policy.value == value) return policy;
    }
    return WorkspaceHostDiscoveryPolicy.disabled;
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

/// Projection of the Agent-owned workspace security policy.
///
/// The Agent database is the only authority. [canWiden] is the Agent's
/// answer for this connection: when false, only stricter values are accepted.
class WorkspacePolicy {
  final WorkspacePermissionMode permissionMode;
  final WorkspaceExecutionMode executionMode;
  final WorkspaceHostDiscoveryPolicy hostDiscoveryPolicy;
  final WorkspaceToolPermissions permissions;
  final int revision;
  final bool canWiden;

  const WorkspacePolicy({
    this.permissionMode = WorkspacePermissionMode.defaultMode,
    this.executionMode = WorkspaceExecutionMode.direct,
    this.hostDiscoveryPolicy = WorkspaceHostDiscoveryPolicy.ownerOnly,
    this.permissions = const WorkspaceToolPermissions(),
    this.revision = 0,
    this.canWiden = false,
  });

  factory WorkspacePolicy.fromJson(Map<String, dynamic>? json) {
    if (json == null) {
      return const WorkspacePolicy();
    }

    return WorkspacePolicy(
      permissionMode: WorkspacePermissionMode.fromValue(json['permissionMode']?.toString()),
      executionMode: WorkspaceExecutionMode.fromValue(json['executionMode']?.toString()),
      hostDiscoveryPolicy: WorkspaceHostDiscoveryPolicy.fromValue(json['hostDiscoveryPolicy']?.toString()),
      permissions: WorkspaceToolPermissions.fromJson(json['permissions'] as Map<String, dynamic>?),
      revision: (json['revision'] as num?)?.toInt() ?? 0,
      canWiden: json['canWiden'] == true,
    );
  }

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{
      'permissionMode': permissionMode.value,
      'executionMode': executionMode.value,
      'hostDiscoveryPolicy': hostDiscoveryPolicy.value,
      'revision': revision,
      'canWiden': canWiden,
    };
    if (!permissions.isEmpty) {
      json['permissions'] = permissions.toJson();
    }
    return json;
  }

  WorkspacePolicy copyWith({
    WorkspacePermissionMode? permissionMode,
    WorkspaceExecutionMode? executionMode,
    WorkspaceHostDiscoveryPolicy? hostDiscoveryPolicy,
    WorkspaceToolPermissions? permissions,
    int? revision,
    bool? canWiden,
  }) {
    return WorkspacePolicy(
      permissionMode: permissionMode ?? this.permissionMode,
      executionMode: executionMode ?? this.executionMode,
      hostDiscoveryPolicy: hostDiscoveryPolicy ?? this.hostDiscoveryPolicy,
      permissions: permissions ?? this.permissions,
      revision: revision ?? this.revision,
      canWiden: canWiden ?? this.canWiden,
    );
  }
}
