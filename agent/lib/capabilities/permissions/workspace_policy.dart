import 'execution_mode.dart';
import 'host_discovery_policy.dart';

export 'execution_mode.dart';
export 'host_discovery_policy.dart';

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

  /// Parses an untrusted mutation value; `null` when it is not recognized.
  static WorkspacePermissionMode? tryParse(String? value) {
    for (final mode in WorkspacePermissionMode.values) {
      if (mode.value == value) return mode;
    }
    return null;
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

/// Daemon-authoritative workspace security policy projection.
///
/// The Agent state database owns every field. Workspace files never supply
/// or widen any of them. [revision] is `0` until the owner stores a policy.
class WorkspacePolicy {
  final WorkspacePermissionMode permissionMode;
  final ExecutionMode executionMode;
  final HostDiscoveryPolicy hostDiscoveryPolicy;
  final WorkspaceToolPermissions permissions;
  final int revision;

  const WorkspacePolicy({
    this.permissionMode = WorkspacePermissionMode.defaultMode,
    this.executionMode = ExecutionMode.direct,
    this.hostDiscoveryPolicy = HostDiscoveryPolicy.ownerOnly,
    this.permissions = const WorkspaceToolPermissions(),
    this.revision = 0,
  });

  /// Clean defaults for a workspace without a stored policy.
  static const defaults = WorkspacePolicy();

  /// Parses a daemon projection (for example a Gateway response read by the
  /// CLI). Unknown restrictive fields resolve to their restrictive value.
  factory WorkspacePolicy.fromJson(Map<String, dynamic>? json) {
    if (json == null) {
      return const WorkspacePolicy();
    }

    return WorkspacePolicy(
      permissionMode: WorkspacePermissionMode.fromValue(
        json['permissionMode']?.toString(),
      ),
      executionMode: json['executionMode'] == null
          ? ExecutionMode.direct
          : ExecutionMode.fromStored(json['executionMode']?.toString()),
      hostDiscoveryPolicy: json['hostDiscoveryPolicy'] == null
          ? HostDiscoveryPolicy.ownerOnly
          : HostDiscoveryPolicy.fromStored(
              json['hostDiscoveryPolicy']?.toString(),
            ),
      permissions: WorkspaceToolPermissions.fromJson(
        json['permissions'] as Map<String, dynamic>?,
      ),
      revision: (json['revision'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{
      'permissionMode': permissionMode.value,
      'executionMode': executionMode.value,
      'hostDiscoveryPolicy': hostDiscoveryPolicy.value,
      'revision': revision,
    };
    if (!permissions.isEmpty) {
      json['permissions'] = permissions.toJson();
    }
    return json;
  }

  /// Whether moving from this policy to [next] widens authority on any axis.
  ///
  /// Widening requires proven owner authority; narrowing is always
  /// allowed for an authenticated caller.
  bool isWidenedBy(WorkspacePolicy next) =>
      (permissionMode == WorkspacePermissionMode.defaultMode &&
          next.permissionMode == WorkspacePermissionMode.fullAccess) ||
      (executionMode == ExecutionMode.protected &&
          next.executionMode == ExecutionMode.direct) ||
      (hostDiscoveryPolicy == HostDiscoveryPolicy.disabled &&
          next.hostDiscoveryPolicy == HostDiscoveryPolicy.ownerOnly);

  WorkspacePolicy copyWith({
    WorkspacePermissionMode? permissionMode,
    ExecutionMode? executionMode,
    HostDiscoveryPolicy? hostDiscoveryPolicy,
    WorkspaceToolPermissions? permissions,
    int? revision,
  }) {
    return WorkspacePolicy(
      permissionMode: permissionMode ?? this.permissionMode,
      executionMode: executionMode ?? this.executionMode,
      hostDiscoveryPolicy: hostDiscoveryPolicy ?? this.hostDiscoveryPolicy,
      permissions: permissions ?? this.permissions,
      revision: revision ?? this.revision,
    );
  }
}
