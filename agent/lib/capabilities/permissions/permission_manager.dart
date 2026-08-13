import 'dart:convert';

import 'package:sanad_agent/capabilities/models/local_tool_spec.dart';
import 'package:sanad_agent/capabilities/tools/base_tool.dart';
import 'package:sanad_agent/evolution/models/suspended_checkpoint.dart';
import 'package:sanad_agent/interfaces/runtime/platform_runtime_bridge.dart';
import 'package:sanad_agent/interfaces/runtime/suspended_checkpoint_store.dart';

import 'workspace_policy.dart';
import 'workspace_policy_store.dart';

class PermissionManager {
  PermissionManager({
    WorkspacePolicyStore? policyStore,
    PlatformRuntimeBridge? platformRuntimeBridge,
    SuspendedCheckpointStore? checkpointStore,
  }) : _policyStore = policyStore ?? const WorkspacePolicyStore(),
       _platformRuntimeBridge =
           platformRuntimeBridge ?? PlatformRuntimeBridge(),
       _checkpointStore = checkpointStore ?? SuspendedCheckpointStore();

  final WorkspacePolicyStore _policyStore;
  final PlatformRuntimeBridge _platformRuntimeBridge;
  final SuspendedCheckpointStore _checkpointStore;

  final Map<String, Set<String>> _sessionAllow = {};
  final Map<String, Set<String>> _sessionDeny = {};
  final Map<String, Set<String>> _oneShotAllow = {};

  Future<void> syncWorkspacePermissionMode({
    required String workspacePath,
    String? permissionMode,
  }) async {
    if (permissionMode == null || permissionMode.trim().isEmpty) {
      return;
    }
    await _policyStore.savePermissionMode(
      workspacePath,
      WorkspacePermissionMode.fromValue(permissionMode),
    );
  }

  Future<void> ensureAuthorized({
    required LocalToolSpec tool,
    required Map<String, dynamic> arguments,
    required ToolContext context,
    String? approvalKeyOverride,
    Map<String, dynamic>? permissionDisplayArguments,
  }) async {
    if (!_requiresApproval(tool)) {
      return;
    }

    final sessionMetadata = context.metadata;
    final workspace = sessionMetadata['workspace'] is Map<String, dynamic>
        ? sessionMetadata['workspace'] as Map<String, dynamic>
        : null;
    final workspacePath = workspace?['path']?.toString();
    final workspaceId = workspace?['id']?.toString();
    final workspaceName = workspace?['name']?.toString();
    final approvalKey = approvalKeyOverride ?? _approvalKey(tool, arguments);
    final permissionClass =
        tool.approval['permission_class']?.toString() ?? tool.category;

    WorkspacePolicy? workspacePolicy;
    if (workspacePath != null && workspacePath.isNotEmpty) {
      workspacePolicy = await _policyStore.readPolicy(workspacePath);
      if (workspacePolicy.permissionMode ==
          WorkspacePermissionMode.fullAccess) {
        return;
      }

      if (workspacePolicy.permissions.allow.contains(approvalKey)) {
        return;
      }

      if (workspacePolicy.permissions.deny.contains(approvalKey)) {
        throw Exception('Tool ${tool.name} is denied by workspace policy.');
      }
    }

    if (_sessionAllow[context.sessionId]?.contains(approvalKey) ?? false) {
      return;
    }

    if (_sessionDeny[context.sessionId]?.contains(approvalKey) ?? false) {
      throw Exception('Tool ${tool.name} is denied for this session.');
    }

    final oneShotAllow = _oneShotAllow[context.sessionId];
    if (oneShotAllow != null && oneShotAllow.remove(approvalKey)) {
      if (oneShotAllow.isEmpty) {
        _oneShotAllow.remove(context.sessionId);
      }
      return;
    }

    final defaultScope =
        tool.approval['scope']?.toString() ??
        (workspacePath != null && workspacePath.isNotEmpty
            ? 'workspace'
            : 'once');
    final requestId = _nextPermissionRequestId();
    final toolCallId = context.toolCallId ?? 'toolcall-$requestId';
    final permissionPayload = <String, dynamic>{
      'request_id': requestId,
      'tool_name': tool.name,
      'permission_class': permissionClass,
      'scope': defaultScope,
      'workspace_id': workspaceId,
      'workspace_name': workspaceName,
      'workspace_path': workspacePath,
      'session_id': context.sessionId,
      'tool_input': permissionDisplayArguments ?? arguments,
      'approval_key': approvalKey,
      'tool': tool.toJson(),
    };

    await _checkpointStore.save(
      SuspendedCheckpoint(
        checkpointId: 'perm-$requestId',
        sessionId: context.sessionId,
        requestId: requestId,
        toolCallId: toolCallId,
        toolName: tool.name,
        status: 'awaiting_permission',
        toolArguments: Map<String, dynamic>.from(arguments),
        permissionPayload: permissionPayload,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ),
    );

    final decision = await _platformRuntimeBridge.requestToolPermission(
      sessionId: context.sessionId,
      payload: permissionPayload,
    );

    final isAllowed = decision['allowed'] == true;
    final scope = decision['scope']?.toString() ?? 'once';
    await _checkpointStore.updateStatus(
      requestId: requestId,
      status: isAllowed ? 'approved' : 'denied',
    );
    if (!isAllowed) {
      final denyComment = decision['comment']?.toString().trim();
      if (denyComment != null && denyComment.isNotEmpty) {
        throw Exception(
          'User denied permission for tool ${tool.name}.\nUser comment: $denyComment',
        );
      } else {
        throw Exception('User denied permission for tool ${tool.name}.');
      }
    }

    await _persistDecision(
      allowed: true,
      scope: scope,
      approvalKey: approvalKey,
      sessionId: context.sessionId,
      workspacePath: workspacePath,
      currentPolicy: workspacePolicy,
    );
  }

  Future<void> applyResolvedDecision({
    required Map<String, dynamic> permissionPayload,
    required Map<String, dynamic> decision,
  }) async {
    final toolPayload = permissionPayload['tool'];
    if (toolPayload is! Map) {
      return;
    }

    final tool = _toolFromJson(Map<String, dynamic>.from(toolPayload));
    final arguments = Map<String, dynamic>.from(
      permissionPayload['tool_input'] as Map? ?? const {},
    );
    final sessionId = permissionPayload['session_id']?.toString() ?? '';
    final workspacePath = permissionPayload['workspace_path']?.toString();
    final scope = decision['scope']?.toString() ?? 'once';
    final allowed = decision['allowed'] == true;
    final approvalKey =
        permissionPayload['approval_key']?.toString() ??
        _approvalKey(tool, arguments);
    final currentPolicy = workspacePath == null || workspacePath.isEmpty
        ? null
        : await _policyStore.readPolicy(workspacePath);

    if (!allowed) {
      return;
    }
    if (scope == 'once' && sessionId.isNotEmpty) {
      _oneShotAllow.putIfAbsent(sessionId, () => <String>{}).add(approvalKey);
      return;
    }

    await _persistDecision(
      allowed: allowed,
      scope: scope,
      approvalKey: approvalKey,
      sessionId: sessionId,
      workspacePath: workspacePath,
      currentPolicy: currentPolicy,
    );
  }

  bool _requiresApproval(LocalToolSpec tool) {
    final sensitive = tool.approval['sensitive'] == true;
    if (sensitive) {
      return true;
    }

    final mode = tool.approval['mode']?.toString();
    return mode == 'ask' || mode == 'always';
  }

  Future<void> _persistDecision({
    required bool allowed,
    required String scope,
    required String approvalKey,
    required String sessionId,
    required String? workspacePath,
    required WorkspacePolicy? currentPolicy,
  }) async {
    if (scope == 'workspace' &&
        workspacePath != null &&
        workspacePath.isNotEmpty) {
      final policy =
          currentPolicy ?? await _policyStore.readPolicy(workspacePath);
      final allow = [...policy.permissions.allow];
      final deny = [...policy.permissions.deny];
      allow.remove(approvalKey);
      deny.remove(approvalKey);
      if (allowed) {
        allow.add(approvalKey);
      } else {
        deny.add(approvalKey);
      }
      await _policyStore.savePolicy(
        workspacePath,
        policy.copyWith(
          permissions: WorkspaceToolPermissions(
            allow: allow,
            deny: deny,
            ask: policy.permissions.ask,
          ),
        ),
      );
      return;
    }

    if (scope == 'session' || scope == 'thread') {
      final cache = allowed ? _sessionAllow : _sessionDeny;
      cache.putIfAbsent(sessionId, () => <String>{}).add(approvalKey);
    }
  }

  String _approvalKey(LocalToolSpec tool, Map<String, dynamic> arguments) {
    if (tool.name == 'shell_execute') {
      final command = arguments['command']?.toString().trim();
      if (command != null && command.isNotEmpty) {
        return 'shell_execute::$command';
      }
    }

    final action = arguments['action']?.toString().trim();
    if (action != null && action.isNotEmpty) {
      return '${tool.name}::$action';
    }

    final fingerprint = const JsonEncoder().convert(arguments);
    return '${tool.name}::$fingerprint';
  }

  String _nextPermissionRequestId() {
    return 'permission-${DateTime.now().microsecondsSinceEpoch}';
  }

  LocalToolSpec _toolFromJson(Map<String, dynamic> json) {
    return LocalToolSpec(
      name: json['name']?.toString() ?? 'unknown',
      displayName: json['display_name']?.toString() ?? 'Unknown',
      description: json['description']?.toString() ?? '',
      inputSchema: Map<String, dynamic>.from(
        json['input_schema'] as Map? ?? const {},
      ),
      source: Map<String, dynamic>.from(json['source'] as Map? ?? const {}),
      category: json['category']?.toString() ?? 'unknown',
      workspaceRequired: json['workspace_required'] == true,
      approval: Map<String, dynamic>.from(json['approval'] as Map? ?? const {}),
      execution: Map<String, dynamic>.from(
        json['execution'] as Map? ?? const {},
      ),
      availability: Map<String, dynamic>.from(
        json['availability'] as Map? ?? const {'status': 'available'},
      ),
      serverName: json['server_name']?.toString(),
    );
  }
}
