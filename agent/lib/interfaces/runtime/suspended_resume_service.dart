import 'dart:async';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_recovery_service.dart';
import 'package:sanad_agent/capabilities/permissions/permission_manager.dart';
import 'package:sanad_agent/engine/agent_runner.dart';
import 'package:sanad_agent/evolution/db/persisted_runtime_state_repository.dart';
import 'package:sanad_agent/evolution/db/runtime/session_execution_state_coordinator.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/evolution/models/suspended_checkpoint.dart';
import 'package:sanad_agent/interfaces/models/agent_turn_request.dart';
import 'package:sanad_agent/interfaces/models/gateway_event.dart';

import 'local_workspace_runtime_service.dart';
import 'suspended_checkpoint_store.dart';
import 'package:sanad_agent/capabilities/runtime/local_runtime_catalog.dart';
import 'package:sanad_agent/capabilities/runtime/runtime_context_builder.dart';

typedef SuspendedResponseEmitter =
    Future<void> Function(GatewayResponse response);
typedef SuspendedDecisionClaimed = Future<void> Function();
typedef SuspendedTerminalCommitted = void Function(String sessionId);

class SuspendedResumeService {
  SuspendedResumeService({
    SuspendedCheckpointStore? checkpointStore,
    SessionManager? sessionManager,
    LocalRuntimeCatalog? runtimeCatalog,
    RuntimeContextBuilder? runtimeContextBuilder,
    LocalWorkspaceRuntimeService? workspaceRuntimeService,
    PermissionManager? permissionManager,
    PersistedRuntimeStateRepository? persistedState,
    RuntimeRecoveryService? runtimeRecovery,
    SuspendedTerminalCommitted? onTerminalCommitted,
  }) : _checkpointStore = checkpointStore ?? SuspendedCheckpointStore(),
       _sessionManagerProvided = sessionManager,
       _persistedStateProvided = persistedState,
       _runtimeRecoveryProvided = runtimeRecovery,
       _onTerminalCommitted = onTerminalCommitted,
       _runtimeCatalog = runtimeCatalog ?? getIt<LocalRuntimeCatalog>(),
       _runtimeContextBuilder =
           runtimeContextBuilder ?? getIt<RuntimeContextBuilder>(),
       _workspaceRuntimeService =
           workspaceRuntimeService ?? getIt<LocalWorkspaceRuntimeService>(),
       _permissionManager = permissionManager ?? getIt<PermissionManager>();

  final SuspendedCheckpointStore _checkpointStore;
  SessionManager? _sessionManagerProvided;
  final PersistedRuntimeStateRepository? _persistedStateProvided;
  final RuntimeRecoveryService? _runtimeRecoveryProvided;
  final SuspendedTerminalCommitted? _onTerminalCommitted;
  SessionManager get _sessionManager =>
      _sessionManagerProvided ??= SessionManager();
  PersistedRuntimeStateRepository? get _persistedState =>
      _persistedStateProvided ??
      (getIt.isRegistered<PersistedRuntimeStateRepository>()
          ? getIt<PersistedRuntimeStateRepository>()
          : null);
  RuntimeRecoveryService? get _runtimeRecovery =>
      _runtimeRecoveryProvided ??
      (getIt.isRegistered<RuntimeRecoveryService>()
          ? getIt<RuntimeRecoveryService>()
          : null);
  final LocalRuntimeCatalog _runtimeCatalog;
  final RuntimeContextBuilder _runtimeContextBuilder;
  final LocalWorkspaceRuntimeService _workspaceRuntimeService;
  final PermissionManager _permissionManager;

  Future<bool> resumeFromDecision({
    required String requestId,
    required Map<String, dynamic> decision,
    required SuspendedResponseEmitter emitResponse,
    SuspendedDecisionClaimed? onClaimed,
  }) async {
    final checkpoint = await _checkpointStore.getByRequestId(requestId);
    if (checkpoint == null) {
      return false;
    }

    final isAskUser = checkpoint.toolName == 'system_ask_user';

    final claimed = await _checkpointStore.claimDecision(
      requestId: requestId,
      status: isAskUser
          ? 'resuming'
          : (decision['allowed'] == true ? 'resuming' : 'denied'),
    );
    if (!claimed) {
      return false;
    }
    final resumeOwner = _claimDurableResume(checkpoint);
    if (_persistedState != null && resumeOwner == null) {
      return false;
    }
    await onClaimed?.call();

    if (!isAskUser) {
      await _permissionManager.applyResolvedDecision(
        permissionPayload: checkpoint.permissionPayload,
        decision: decision,
      );
    }

    final sessionMetadata =
        _sessionManager.getSessionMetadata(checkpoint.sessionId) ?? const {};
    final runtimeRequest = AgentTurnRequest(
      sessionId: checkpoint.sessionId,
      message: '',
      workspaceId: sessionMetadata['workspace_id']?.toString(),
      model: sessionMetadata['model']?.toString(),
      thinkingMode: sessionMetadata['thinking_mode']?.toString(),
      requestId: sessionMetadata['request_id']?.toString(),
      metadata: Map<String, dynamic>.from(sessionMetadata),
    );
    final agentRunner = getIt<AgentRunner>(param1: checkpoint.sessionId);
    if (resumeOwner != null) {
      agentRunner.beginAuthoritativeRun(
        resumeOwner.runId,
        workItemId: resumeOwner.workItemId,
        generation: resumeOwner.generation,
      );
      final persistedWork = _persistedState?.findWorkItem(
        resumeOwner.workItemId,
      );
      if (persistedWork != null) {
        agentRunner.runStartTime = persistedWork.createdAt;
      }
      _clearStaleRecoveryNotice(checkpoint.sessionId);
    }
    final tools = await _runtimeCatalog.buildTools(
      registry: agentRunner.registry,
      request: runtimeRequest,
    );
    agentRunner.registry.registerTools(tools);
    final runtimeSystemPrompt = await _buildRuntimeContext(
      runtimeRequest,
      agentRunner,
    );

    final denyComment = decision['comment']?.toString().trim();
    final forcedOutput = isAskUser
        ? (decision['answer']?.toString() ?? '')
        : (decision['allowed'] == true
              ? null
              : [
                  'Error executing tool: Exception: User denied permission for tool ${checkpoint.toolName}.',
                  if (denyComment != null && denyComment.isNotEmpty)
                    'User comment: $denyComment',
                ].join('\n'));
    final forcedIsError = isAskUser ? false : (decision['allowed'] != true);
    final ownerRunId =
        resumeOwner?.runId ?? sessionMetadata['run_id']?.toString();
    var terminalCommitted = false;

    try {
      String fullContent = '';
      await for (final chunk in agentRunner.resumeAfterToolCall(
        toolCallId: checkpoint.toolCallId,
        toolName: checkpoint.toolName,
        arguments: checkpoint.toolArguments,
        runtimeSystemPrompt: runtimeSystemPrompt,
        forcedOutput: forcedOutput,
        forcedIsError: forcedIsError,
        onToolEvent:
            ({
              required String toolName,
              String? input,
              String? output,
              required bool isError,
              required bool isStart,
              String? toolRunId,
            }) async {
              await emitResponse(
                GatewayResponse(
                  sessionId: checkpoint.sessionId,
                  message: Message(
                    role: MessageRole.tool,
                    content: isStart ? input : output,
                  ),
                  isComplete: false,
                  runId: ownerRunId,
                  modelStepId: agentRunner.currentModelStepId,
                  toolCallId: toolRunId ?? checkpoint.toolCallId,
                  toolName: toolName,
                  isToolUse: isStart,
                  isToolResult: !isStart,
                  isToolError: !isStart && isError,
                ),
              );
            },
        onReasoningDelta: (reasoning) => emitResponse(
          GatewayResponse(
            sessionId: checkpoint.sessionId,
            message: Message(role: MessageRole.assistant, content: reasoning),
            isComplete: false,
            runId: ownerRunId,
            modelStepId: agentRunner.currentModelStepId,
          ),
        ),
      )) {
        fullContent += chunk;
        await emitResponse(
          GatewayResponse(
            sessionId: checkpoint.sessionId,
            message: Message(role: MessageRole.assistant, content: chunk),
            isComplete: false,
            runId: ownerRunId,
            modelStepId: agentRunner.currentModelStepId,
          ),
        );
      }

      final contextUsage = await agentRunner.getContextUsageSnapshot();
      final contextTokens = await agentRunner.getContextTokens();
      final turnMetadata = <String, dynamic>{
        ...sessionMetadata,
        if (agentRunner.activeModel != null) 'model': agentRunner.activeModel,
        if (agentRunner.activeModelDisplay != null)
          'model_display': agentRunner.activeModelDisplay,
        if (agentRunner.activeProvider != null)
          'provider': agentRunner.activeProvider,
        if (agentRunner.runtimeMs != null) 'runtime_ms': agentRunner.runtimeMs,
        'context_tokens': contextTokens,
        'usage': agentRunner.lastUsage,
        'context_usage': ?contextUsage,
      };
      if (contextUsage != null) {
        _sessionManager.saveSessionMetadata(checkpoint.sessionId, {
          ...?_sessionManager.getSessionMetadata(checkpoint.sessionId),
          'context_usage': contextUsage,
        });
      }
      agentRunner.attachMetadataToLastAssistantMessage(turnMetadata);
      final terminalMessage = Message(
        role: MessageRole.assistant,
        content: fullContent,
        metadata: {
          ...turnMetadata,
          if (resumeOwner != null) 'run_id': resumeOwner.runId,
          if (agentRunner.currentModelStepId != null)
            'model_step_id': agentRunner.currentModelStepId,
        },
      );
      if (resumeOwner != null) {
        final outcome = _persistedState!.commitTerminal(
          sessionId: checkpoint.sessionId,
          workItemId: resumeOwner.workItemId,
          runId: resumeOwner.runId,
          generation: resumeOwner.generation,
          assistantResult: terminalMessage,
        );
        if (outcome != TerminalCommitOutcome.committed) {
          throw StateError(
            'Persisted suspended resume terminal commit failed: $outcome',
          );
        }
        terminalCommitted = true;
      }
      await emitResponse(
        GatewayResponse(
          sessionId: checkpoint.sessionId,
          message: terminalMessage,
          isComplete: true,
          runId: resumeOwner?.runId ?? ownerRunId,
          modelStepId: agentRunner.currentModelStepId,
          usage: agentRunner.lastUsage,
          contextUsage: contextUsage,
          runtimeMs: agentRunner.runtimeMs,
          model: agentRunner.activeModel,
          modelDisplay: agentRunner.activeModelDisplay,
          provider: agentRunner.activeProvider,
          contextTokens: contextTokens,
        ),
      );
      await _checkpointStore.deleteByRequestId(requestId);
      return true;
    } finally {
      if (terminalCommitted) {
        _onTerminalCommitted?.call(checkpoint.sessionId);
      }
      if (resumeOwner != null) {
        agentRunner.endAuthoritativeRun(resumeOwner.runId);
      }
    }
  }

  _SuspendedResumeOwner? _claimDurableResume(SuspendedCheckpoint checkpoint) {
    final store = _persistedState;
    if (store == null) return null;
    final active = store.findActiveWorkItem(checkpoint.sessionId);
    if (active == null ||
        (active.state != SessionWorkState.waiting &&
            active.state != SessionWorkState.blocked)) {
      return null;
    }
    final executingTools = List<String>.from(
      active.continuationMetadata['currently_executing_tools'] as List? ??
          const [],
    );
    if (!executingTools.contains(checkpoint.toolCallId)) {
      return null;
    }
    final runId = active.continuationMetadata['owner_run_id']?.toString();
    final generationRaw = active.continuationMetadata['owner_generation'];
    final generation = switch (generationRaw) {
      int() => generationRaw,
      String() => int.tryParse(generationRaw),
      _ => null,
    };
    if (runId == null || runId.isEmpty || generation == null) {
      return null;
    }
    try {
      store.transitionWorkItemState(
        workItemId: active.workItemId,
        fromState: active.state,
        toState: SessionWorkState.resuming,
      );
    } catch (_) {
      return null;
    }
    return (
      workItemId: active.workItemId,
      runId: runId,
      generation: generation,
    );
  }

  void _clearStaleRecoveryNotice(String sessionId) {
    final recovery = _runtimeRecovery;
    if (recovery != null) {
      final notice = recovery.activeNotice(sessionId);
      recovery.clear(
        sessionId,
        runId: notice?.runId,
        reasonOverride: 'suspended_input_resumed',
      );
      return;
    }
    _persistedState?.deleteNotice(sessionId);
  }

  Future<String?> _buildRuntimeContext(
    AgentTurnRequest request,
    AgentRunner agentRunner,
  ) async {
    final workspaceId = request.workspaceId;
    if (workspaceId == null || workspaceId.isEmpty) {
      return _runtimeContextBuilder.buildWithoutWorkspace();
    }

    final workspace = await _workspaceRuntimeService.describeWorkspace(
      workspaceId,
    );
    final workspacePath = workspace?['path'] as String?;
    if (workspacePath == null || workspacePath.isEmpty) {
      return _runtimeContextBuilder.buildWithoutWorkspace();
    }

    return _runtimeContextBuilder.build(
      workspacePath: workspacePath,
      workspaceName: workspace?['name'] as String?,
      registry: agentRunner.registry,
    );
  }
}

typedef _SuspendedResumeOwner = ({
  String workItemId,
  String runId,
  int generation,
});
