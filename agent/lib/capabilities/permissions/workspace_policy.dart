import 'execution_mode.dart';
import 'host_discovery_policy.dart';

export 'child_process_security_contract.dart';
export 'execution_mode.dart';
export 'host_discovery_policy.dart';
export 'workspace_security_policy.dart';


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
  final ExecutionMode executionMode;
  final HostDiscoveryPolicy hostDiscoveryPolicy;
  final int revision;
  final bool editableByOwner;
  final WorkspaceToolPermissions permissions;

  const WorkspacePolicy({
    this.permissionMode = WorkspacePermissionMode.defaultMode,
    this.executionMode = ExecutionMode.direct,
    this.hostDiscoveryPolicy = HostDiscoveryPolicy.ownerOnly,
    this.revision = 1,
    this.editableByOwner = true,
    this.permissions = const WorkspaceToolPermissions(),
  });

  factory WorkspacePolicy.fromJson(Map<String, dynamic>? json) {
    if (json == null) {
      return const WorkspacePolicy();
    }

    return WorkspacePolicy(
      permissionMode: WorkspacePermissionMode.fromValue(
        json['permissionMode']?.toString() ??
            json['permission_mode']?.toString(),
      ),
      executionMode: ExecutionMode.fromValue(
        json['executionMode']?.toString() ??
            json['execution_mode']?.toString(),
      ),
      hostDiscoveryPolicy: HostDiscoveryPolicy.fromValue(
        json['hostDiscoveryPolicy']?.toString() ??
            json['host_discovery_policy']?.toString(),
      ),
      revision: (json['revision'] as num?)?.toInt() ?? 1,
      editableByOwner: json['editableByOwner'] as bool? ??
          json['editable_by_owner'] as bool? ??
          true,
      permissions: WorkspaceToolPermissions.fromJson(
        json['permissions'] as Map<String, dynamic>?,
      ),
    );
  }

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{
      'permissionMode': permissionMode.value,
      'executionMode': executionMode.value,
      'hostDiscoveryPolicy': hostDiscoveryPolicy.value,
      'revision': revision,
      'editableByOwner': editableByOwner,
    };
    if (!permissions.isEmpty) {
      json['permissions'] = permissions.toJson();
    }
    return json;
  }

  WorkspacePolicy copyWith({
    WorkspacePermissionMode? permissionMode,
    ExecutionMode? executionMode,
    HostDiscoveryPolicy? hostDiscoveryPolicy,
    int? revision,
    bool? editableByOwner,
    WorkspaceToolPermissions? permissions,
  }) {
    return WorkspacePolicy(
      permissionMode: permissionMode ?? this.permissionMode,
      executionMode: executionMode ?? this.executionMode,
      hostDiscoveryPolicy: hostDiscoveryPolicy ?? this.hostDiscoveryPolicy,
      revision: revision ?? this.revision,
      editableByOwner: editableByOwner ?? this.editableByOwner,
      permissions: permissions ?? this.permissions,
    );
  }
}

