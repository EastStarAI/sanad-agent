import 'dart:async';

import 'package:path/path.dart' as p;
import 'package:sanad_agent/capabilities/registry/tools_registry.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/models/user_attachment.dart';
import 'package:sanad_agent/engine/agent_runner.dart';
import 'package:sanad_agent/engine/runtime/tool_execution_coordinator.dart';
import 'package:sanad_agent/evolution/attachments/attachment_store.dart';
import 'package:sanad_agent/capabilities/runtime/local_runtime_catalog.dart';
import 'package:sanad_agent/capabilities/runtime/runtime_context_builder.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/interfaces/models/agent_turn_request.dart';

import 'local_workspace_runtime_service.dart';

/// Coordinates runtime-rich turn requests before they reach the core agent.
///
/// This layer deliberately sits between the Sanad transport contract and the
/// engine so we can rebuild workspace context, permissions, skills, and MCP
/// state on every turn without coupling that orchestration to [AgentRunner].
class LocalRuntimeOrchestrator {
  LocalRuntimeOrchestrator(
    this._workspaceRuntimeService,
    this._runtimeCatalog, {
    RuntimeContextBuilder? runtimeContextBuilder,
  }) : _runtimeContextBuilder =
           runtimeContextBuilder ?? const RuntimeContextBuilder();

  final LocalWorkspaceRuntimeService _workspaceRuntimeService;
  final LocalRuntimeCatalog _runtimeCatalog;
  final RuntimeContextBuilder _runtimeContextBuilder;

  Future<Map<String, dynamic>> buildSessionMetadata(
    AgentTurnRequest request,
  ) async {
    final metadata = Map<String, dynamic>.from(request.toMetadata());
    final existingSessionMetadata = getIt.isRegistered<SessionManager>()
        ? getIt<SessionManager>().getSessionMetadata(request.sessionId)
        : null;

    final execRoot = request.executionRoot;
    final workspaceId = request.effectiveWorkspaceId;
    if (execRoot != null && execRoot.isNotEmpty) {
      final normalized = _runtimeContextBuilder.pathResolver
          .validateAndNormalizeExecutionRoot(execRoot);
      if (normalized != null) {
        metadata['execution_root'] = normalized;
      }
    } else if (workspaceId != null && workspaceId.startsWith('exec_root:')) {
      final path = workspaceId.substring('exec_root:'.length);
      final normalized = _runtimeContextBuilder.pathResolver
          .validateAndNormalizeExecutionRoot(path);
      if (normalized != null) {
        metadata['execution_root'] = normalized;
      }
    } else if ((workspaceId == null || workspaceId.isEmpty) &&
        metadata['execution_root'] == null &&
        existingSessionMetadata?['execution_root'] != null) {
      final normalized = _runtimeContextBuilder.pathResolver
          .validateAndNormalizeExecutionRoot(
            existingSessionMetadata!['execution_root']?.toString(),
          );
      if (normalized != null) {
        metadata['execution_root'] = normalized;
      }
    }

    if (request.metadata.containsKey('allow_all_tools')) {
      metadata['allow_all_tools'] =
          request.metadata['allow_all_tools'] == true ||
          request.metadata['allow_all_tools'] == 'true';
    } else {
      metadata['allow_all_tools'] = false;
    }
    if (metadata['allow_all_tools'] != true &&
        metadata['permission_mode'] == 'full_access') {
      metadata['permission_mode'] = 'default_mode';
    }

    if (workspaceId != null && workspaceId.startsWith('exec_root:')) {
      return metadata;
    }

    if (workspaceId == null || workspaceId.isEmpty) {
      return metadata;
    }

    final workspace = await _workspaceRuntimeService.describeWorkspace(
      workspaceId,
    );
    if (workspace != null) {
      if (workspace['is_missing'] == true) {
        throw StateError(
          'Workspace folder is unavailable. Reconnect it before continuing.',
        );
      }
      final resolvedWorkspaceId = workspace['id']?.toString();
      if (resolvedWorkspaceId != null && resolvedWorkspaceId.isNotEmpty) {
        metadata['workspace_id'] = resolvedWorkspaceId;
      }
      metadata['workspace'] = workspace;
      final workspaceName = workspace['name']?.toString();
      final workspacePath = workspace['path'] as String?;
      if (workspaceName != null && workspaceName.isNotEmpty) {
        metadata['workspace_name'] = workspaceName;
      }
      if (workspacePath != null && workspacePath.isNotEmpty) {
        metadata['workspace_path'] = workspacePath;
      }
    }
    return metadata;
  }

  Stream<String> streamTurn({
    required AgentRunner agentRunner,
    required AgentTurnRequest request,
    ToolEventCallback? onToolEvent,
    void Function()? onSteerContinuation,
    FutureOr<void> Function(String thought)? onThoughtDelta,
    FutureOr<void> Function(String reasoning)? onReasoningDelta,
  }) {
    agentRunner.setTurnRequestId(request.requestId);
    final receivedAt = _readReceivedAt(request);
    final rawAttachmentIds = request.metadata['attachment_ids'];
    final attachmentIds = rawAttachmentIds is List
        ? rawAttachmentIds.whereType<String>().toList(growable: false)
        : const <String>[];
    if (attachmentIds.isNotEmpty &&
        (request.requestId == null || request.requestId!.isEmpty)) {
      throw StateError('Attachment admission requires a request identity.');
    }
    final attachments = attachmentIds.isEmpty
        ? const <UserAttachment>[]
        : getIt<AttachmentStore>().loadAdmission(
            sessionId: request.sessionId,
            admissionId: request.requestId!,
            attachmentIds: attachmentIds,
          );
    agentRunner.configureUserAttachments(attachments);
    return Stream.fromFuture(
      _runtimeCatalog.buildTools(
        registry: agentRunner.registry,
        request: request,
        pendingAttachmentIds: attachments
            .map((attachment) => attachment.id)
            .toList(growable: false),
      ),
    ).asyncExpand((tools) {
      agentRunner.registry.registerTools(tools);
      return Stream.fromFuture(
        buildRuntimeContext(request, registry: agentRunner.registry),
      ).asyncExpand((runtimeContext) {
        final effectiveProviderId = request.effectiveProviderInstanceId;
        if (runtimeContext == null &&
            effectiveProviderId == null &&
            request.model == null &&
            request.thinkingMode == null) {
          return agentRunner.streamMessage(
            request.message,
            receivedAt: receivedAt,
            onToolEvent: onToolEvent,
            onSteerContinuation: onSteerContinuation,
            onThoughtDelta: onThoughtDelta,
            onReasoningDelta: onReasoningDelta,
          );
        }
        return agentRunner.streamMessage(
          request.message,
          runtimeSystemPrompt: runtimeContext,
          providerId: effectiveProviderId,
          model: request.model,
          thinkingMode: request.thinkingMode,
          receivedAt: receivedAt,
          onToolEvent: onToolEvent,
          onSteerContinuation: onSteerContinuation,
          onThoughtDelta: onThoughtDelta,
          onReasoningDelta: onReasoningDelta,
        );
      });
    });
  }

  Stream<String> resumeTurn({
    required AgentRunner agentRunner,
    required AgentTurnRequest request,
    ToolEventCallback? onToolEvent,
    void Function()? onSteerContinuation,
    FutureOr<void> Function(String thought)? onThoughtDelta,
    FutureOr<void> Function(String reasoning)? onReasoningDelta,
  }) {
    agentRunner.setTurnRequestId(request.requestId);
    return Stream.fromFuture(
      _runtimeCatalog.buildTools(
        registry: agentRunner.registry,
        request: request,
      ),
    ).asyncExpand((tools) {
      agentRunner.registry.registerTools(tools);
      return Stream.fromFuture(
        buildRuntimeContext(request, registry: agentRunner.registry),
      ).asyncExpand((runtimeContext) {
        final effectiveProviderId = request.effectiveProviderInstanceId;
        if (runtimeContext == null &&
            effectiveProviderId == null &&
            request.model == null &&
            request.thinkingMode == null) {
          return agentRunner.resumeStream(
            onToolEvent: onToolEvent,
            onSteerContinuation: onSteerContinuation,
            onThoughtDelta: onThoughtDelta,
            onReasoningDelta: onReasoningDelta,
          );
        }
        return agentRunner.resumeStream(
          runtimeSystemPrompt: runtimeContext,
          providerId: effectiveProviderId,
          model: request.model,
          thinkingMode: request.thinkingMode,
          onToolEvent: onToolEvent,
          onSteerContinuation: onSteerContinuation,
          onThoughtDelta: onThoughtDelta,
          onReasoningDelta: onReasoningDelta,
        );
      });
    });
  }

  /// The request an idle session operation stands in for: the session's
  /// persisted workspace, route and permission metadata, with no new message.
  static AgentTurnRequest idleRequestFor(
    String sessionId,
    Map<String, dynamic> sessionMetadata,
  ) => AgentTurnRequest(
    sessionId: sessionId,
    message: '',
    workspaceId: sessionMetadata['workspace_id']?.toString(),
    model: sessionMetadata['model']?.toString(),
    thinkingMode: sessionMetadata['thinking_mode']?.toString(),
    requestId: sessionMetadata['request_id']?.toString(),
    metadata: Map<String, dynamic>.from(sessionMetadata),
  );

  /// Prepares [agentRunner] for an idle request of [sessionId], such as manual
  /// compaction (Task 118b): registers the same per-turn tool catalog and
  /// returns the same runtime context an ordinary request of the session
  /// builds, so the idle request carries exactly what the next ordinary
  /// request will transmit.
  Future<String?> prepareIdleRequest({
    required AgentRunner agentRunner,
    required String sessionId,
  }) async {
    final sessionMetadata = getIt.isRegistered<SessionManager>()
        ? getIt<SessionManager>().getSessionMetadata(sessionId)
        : null;
    final request = idleRequestFor(sessionId, sessionMetadata ?? const {});
    final tools = await _runtimeCatalog.buildTools(
      registry: agentRunner.registry,
      request: request,
    );
    agentRunner.registry.registerTools(tools);
    return buildRuntimeContext(request, registry: agentRunner.registry);
  }

  Future<String?> buildRuntimeContext(
    AgentTurnRequest request, {
    ToolsRegistry? registry,
  }) async {
    final execRoot = request.executionRoot;
    String? workspacePath;
    String? workspaceName;

    if (execRoot != null && execRoot.isNotEmpty) {
      workspacePath = _runtimeContextBuilder.pathResolver
          .validateAndNormalizeExecutionRoot(execRoot);
      workspaceName = p.basename(workspacePath!);
    } else {
      final workspaceId = request.effectiveWorkspaceId;
      if (workspaceId == null || workspaceId.isEmpty) {
        return _runtimeContextBuilder.buildWithoutWorkspace();
      }

      final workspace = await _workspaceRuntimeService.describeWorkspace(
        workspaceId,
      );
      workspacePath = workspace?['path'] as String?;
      workspaceName = workspace?['name'] as String?;
    }

    if (workspacePath == null || workspacePath.isEmpty) {
      return _runtimeContextBuilder.buildWithoutWorkspace();
    }

    final runtimeContext = await _runtimeContextBuilder.build(
      workspacePath: workspacePath,
      workspaceName: workspaceName,
      registry: registry,
    );
    return runtimeContext;
  }

  DateTime? _readReceivedAt(AgentTurnRequest request) {
    final raw = request.metadata['received_at'];
    if (raw == null) {
      return null;
    }
    return DateTime.tryParse(raw.toString());
  }
}
