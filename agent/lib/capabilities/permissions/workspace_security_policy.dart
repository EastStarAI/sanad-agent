import 'workspace_policy.dart';

/// Authoritative Workspace Security Policy owned exclusively by the daemon state database.
///
/// This policy cannot be overridden by model-writable workspace files (e.g. `.sanad/settings.json`).
class WorkspaceSecurityPolicy {
  final String workspaceId;
  final String canonicalPath;
  final WorkspacePermissionMode permissionMode;
  final ExecutionMode executionMode;
  final HostDiscoveryPolicy hostDiscoveryPolicy;
  final WorkspaceToolPermissions permissions;
  final int revision;
  final DateTime? updatedAt;

  const WorkspaceSecurityPolicy({
    required this.workspaceId,
    required this.canonicalPath,
    this.permissionMode = WorkspacePermissionMode.defaultMode,
    this.executionMode = ExecutionMode.direct,
    this.hostDiscoveryPolicy = HostDiscoveryPolicy.ownerOnly,
    this.permissions = const WorkspaceToolPermissions(),
    this.revision = 1,
    this.updatedAt,
  });

  /// Clean defaults for an unregistered or newly registered workspace.
  factory WorkspaceSecurityPolicy.cleanDefault({
    required String workspaceId,
    required String canonicalPath,
  }) {
    return WorkspaceSecurityPolicy(
      workspaceId: workspaceId,
      canonicalPath: canonicalPath,
      permissionMode: WorkspacePermissionMode.defaultMode,
      executionMode: ExecutionMode.direct,
      hostDiscoveryPolicy: HostDiscoveryPolicy.ownerOnly,
      permissions: const WorkspaceToolPermissions(),
      revision: 1,
    );
  }

  /// Whether Host Discovery tool should be available in the tool catalog.
  ///
  /// Host Discovery is ONLY available if:
  /// 1. Policy is [HostDiscoveryPolicy.ownerOnly],
  /// 2. The caller is confirmed to be the device owner ([isOwner] is true),
  /// 3. The session does NOT already have equivalent access to the host PATH
  ///    ([hasEquivalentHostAccess] is false, e.g. in Direct Developer execution).
  ///
  /// If [hasEquivalentHostAccess] is true, the tool is omitted to prevent redundant
  /// context consumption and catalog clutter.
  /// If [isOwner] is false or [policy] is disabled, it is strictly omitted.
  static bool isHostDiscoveryPermitted({
    required HostDiscoveryPolicy policy,
    required bool isOwner,
    required bool hasEquivalentHostAccess,
  }) {
    if (policy == HostDiscoveryPolicy.disabled) return false;
    if (!isOwner) return false;
    if (hasEquivalentHostAccess) return false;
    return true;
  }

  /// Authority Precedence Check:
  /// Higher-level owner restrictions (e.g. required sandbox execution, disabled discovery)
  /// CANNOT be bypassed by Workspace-level Full Access.
  static bool canBypassApproval({
    required WorkspacePermissionMode permissionMode,
    required bool isOwnerRequiredRestrictionActive,
  }) {
    if (isOwnerRequiredRestrictionActive) return false;
    return permissionMode == WorkspacePermissionMode.fullAccess;
  }

  Map<String, dynamic> toJson() {
    return {
      'workspaceId': workspaceId,
      'canonicalPath': canonicalPath,
      'permissionMode': permissionMode.value,
      'executionMode': executionMode.value,
      'hostDiscoveryPolicy': hostDiscoveryPolicy.value,
      if (!permissions.isEmpty) 'permissions': permissions.toJson(),
      'revision': revision,
      if (updatedAt != null) 'updatedAt': updatedAt!.toIso8601String(),
    };
  }

  factory WorkspaceSecurityPolicy.fromJson(Map<String, dynamic> json) {
    return WorkspaceSecurityPolicy(
      workspaceId: json['workspaceId']?.toString() ?? '',
      canonicalPath: json['canonicalPath']?.toString() ?? '',
      permissionMode: WorkspacePermissionMode.fromValue(
        json['permissionMode']?.toString(),
      ),
      executionMode: ExecutionMode.fromValue(json['executionMode']?.toString()),
      hostDiscoveryPolicy: HostDiscoveryPolicy.fromValue(
        json['hostDiscoveryPolicy']?.toString(),
      ),
      permissions: WorkspaceToolPermissions.fromJson(
        json['permissions'] as Map<String, dynamic>?,
      ),
      revision: (json['revision'] as num?)?.toInt() ?? 1,
      updatedAt: json['updatedAt'] != null
          ? DateTime.tryParse(json['updatedAt'].toString())
          : null,
    );
  }

  WorkspaceSecurityPolicy copyWith({
    String? workspaceId,
    String? canonicalPath,
    WorkspacePermissionMode? permissionMode,
    ExecutionMode? executionMode,
    HostDiscoveryPolicy? hostDiscoveryPolicy,
    WorkspaceToolPermissions? permissions,
    int? revision,
    DateTime? updatedAt,
  }) {
    return WorkspaceSecurityPolicy(
      workspaceId: workspaceId ?? this.workspaceId,
      canonicalPath: canonicalPath ?? this.canonicalPath,
      permissionMode: permissionMode ?? this.permissionMode,
      executionMode: executionMode ?? this.executionMode,
      hostDiscoveryPolicy: hostDiscoveryPolicy ?? this.hostDiscoveryPolicy,
      permissions: permissions ?? this.permissions,
      revision: revision ?? this.revision,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
