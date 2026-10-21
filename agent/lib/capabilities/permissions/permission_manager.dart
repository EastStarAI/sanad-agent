import 'dart:async';
import 'dart:convert';

import 'package:sanad_agent/capabilities/models/local_tool_spec.dart';
import 'package:sanad_agent/capabilities/tools/base_tool.dart';
import 'package:sanad_agent/evolution/models/suspended_checkpoint.dart';
import 'package:sanad_agent/interfaces/runtime/platform_runtime_bridge.dart';
import 'package:sanad_agent/interfaces/runtime/suspended_checkpoint_store.dart';

import 'command_authority.dart';
import 'workspace_policy.dart';
import 'workspace_policy_scope.dart';
import 'workspace_policy_store.dart';

/// The user or workspace policy refused a tool call; the tool never ran.
///
/// Keeps the exact model-facing text of the previous plain exception.
class ToolPermissionDeniedException implements Exception {
  const ToolPermissionDeniedException(this.message);

  final String message;

  @override
  String toString() => 'Exception: $message';
}

class PermissionManager {
  PermissionManager({
    WorkspacePolicyStore? policyStore,
    PlatformRuntimeBridge? platformRuntimeBridge,
    SuspendedCheckpointStore? checkpointStore,
  }) : _policyStore = policyStore ?? WorkspacePolicyStore(),
       _platformRuntimeBridge =
           platformRuntimeBridge ?? PlatformRuntimeBridge(),
       _checkpointStore = checkpointStore ?? SuspendedCheckpointStore();

  final WorkspacePolicyStore _policyStore;
  final PlatformRuntimeBridge _platformRuntimeBridge;
  final SuspendedCheckpointStore _checkpointStore;

  final Map<String, Set<String>> _sessionAllow = {};
  final Map<String, Set<String>> _sessionDeny = {};
  final Map<String, Set<String>> _oneShotAllow = {};
  final Map<String, Future<void>> _sessionPermissionTails = {};

  Future<void> ensureAuthorized({
    required LocalToolSpec tool,
    required Map<String, dynamic> arguments,
    required ToolContext context,
    String? approvalKeyOverride,
    Map<String, dynamic>? permissionDisplayArguments,
  }) {
    if (!_requiresApproval(tool)) {
      return Future<void>.value();
    }

    return _serializeForSession(
      context.sessionId,
      () => _ensureAuthorized(
        tool: tool,
        arguments: arguments,
        context: context,
        approvalKeyOverride: approvalKeyOverride,
        permissionDisplayArguments: permissionDisplayArguments,
      ),
    );
  }

  Future<void> _ensureAuthorized({
    required LocalToolSpec tool,
    required Map<String, dynamic> arguments,
    required ToolContext context,
    String? approvalKeyOverride,
    Map<String, dynamic>? permissionDisplayArguments,
  }) async {
    final sessionMetadata = context.metadata;
    final workspaceScope = WorkspacePolicyScope.fromMetadata(sessionMetadata);
    final workspacePath = workspaceScope.path;
    final workspaceId = workspaceScope.id;
    final workspaceName = workspaceScope.name;
    final approvalKey = approvalKeyOverride ?? _approvalKey(tool, arguments);
    final permissionClass =
        tool.approval['permission_class']?.toString() ?? tool.category;

    final effective = await _policyStore.resolveForRoot(
      WorkspacePolicyScope.toolRoot(sessionMetadata),
    );
    final policyKey = effective?.key;
    if (effective != null) {
      final workspacePolicy = effective.policy;
      if (workspacePolicy.permissions.deny.contains(approvalKey)) {
        throw ToolPermissionDeniedException('Tool ${tool.name} is denied by workspace policy.');
      }
      if (workspacePolicy.permissionMode ==
          WorkspacePermissionMode.fullAccess) {
        return;
      }

      if (workspacePolicy.permissions.allow.contains(approvalKey)) {
        return;
      }
    }

    // A turn-level bypass is honored only when transport ingress stamped the
    // turn as owner authority (for example `sanad run --yes` or an authenticated client). Turn
    // payload content can never claim it.
    if (_isOwnerBypass(sessionMetadata)) {
      return;
    }

    if (_sessionAllow[context.sessionId]?.contains(approvalKey) ?? false) {
      return;
    }

    if (_sessionDeny[context.sessionId]?.contains(approvalKey) ?? false) {
      throw ToolPermissionDeniedException('Tool ${tool.name} is denied for this session.');
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
        (policyKey != null ? 'workspace' : 'once');
    final requestId = _nextPermissionRequestId();
    final toolCallId = context.toolCallId ?? 'toolcall-$requestId';
    final permissionPayload = <String, dynamic>{
      'request_id': requestId,
      'tool_name': tool.name,
      'permission_class': permissionClass,
      'scope': defaultScope,
      'workspace_id': workspaceId,
      'policy_key': policyKey,
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
        throw ToolPermissionDeniedException(
          'User denied permission for tool ${tool.name}.\nUser comment: $denyComment',
        );
      } else {
        throw ToolPermissionDeniedException('User denied permission for tool ${tool.name}.');
      }
    }

    await _persistDecision(
      allowed: true,
      scope: scope,
      approvalKey: approvalKey,
      sessionId: context.sessionId,
      workspaceId: policyKey,
    );
  }

  Future<void> _serializeForSession(
    String sessionId,
    Future<void> Function() action,
  ) async {
    final predecessor =
        _sessionPermissionTails[sessionId] ?? Future<void>.value();
    final completion = Completer<void>();
    final currentTail = completion.future;
    _sessionPermissionTails[sessionId] = currentTail;

    await predecessor;
    try {
      await action();
    } finally {
      completion.complete();
      if (identical(_sessionPermissionTails[sessionId], currentTail)) {
        _sessionPermissionTails.remove(sessionId);
      }
    }
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
    final rawWorkspaceId =
        (permissionPayload['policy_key'] ?? permissionPayload['workspace_id'])
            ?.toString()
            .trim();
    final workspaceId = rawWorkspaceId == null || rawWorkspaceId.isEmpty
        ? null
        : rawWorkspaceId;
    final scope = decision['scope']?.toString() ?? 'once';
    final allowed = decision['allowed'] == true;
    final approvalKey =
        permissionPayload['approval_key']?.toString() ??
        _approvalKey(tool, arguments);

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
      workspaceId: workspaceId,
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
    required String? workspaceId,
  }) async {
    var effectiveScope = scope;
    if (scope == 'workspace') {
      if (workspaceId != null) {
        try {
          await _policyStore.recordDecision(
            workspaceId,
            approvalKey: approvalKey,
            allowed: allowed,
          );
          return;
        } on StateError {
          // The workspace is no longer registered or storage is unavailable;
          // keep the decision for this session instead of dropping it.
        }
      }
      effectiveScope = 'session';
    }

    if (effectiveScope == 'session' || effectiveScope == 'thread') {
      final cache = allowed ? _sessionAllow : _sessionDeny;
      cache.putIfAbsent(sessionId, () => <String>{}).add(approvalKey);
    }
  }

  static bool _isOwnerBypass(Map<String, dynamic> metadata) {
    final requested =
        metadata['allow_all_tools'] == true ||
        metadata['allow_all_tools'] == 'true';
    return requested &&
        CommandAuthority.fromStamped(
          metadata[CommandAuthority.payloadKey],
        ).isOwner;
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
