import 'dart:async';

import 'package:path/path.dart' as p;
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_recovery_service.dart';
import 'package:sanad_agent/capabilities/permissions/permission_manager.dart';
import 'package:sanad_agent/engine/agent_runner.dart';
import 'package:sanad_agent/evolution/db/persisted_runtime_state_repository.dart';
import 'package:sanad_agent/evolution/db/runtime/session_execution_state_coordinator.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/interfaces/models/agent_turn_request.dart';
import 'package:sanad_agent/interfaces/models/gateway_event.dart';

import 'local_workspace_runtime_service.dart';
import 'session_run_orchestrator.dart';
import 'session_turn_executor.dart';
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
  }) => _resumeFromDecision(
    requestId: requestId,
    decision: decision,
    emitResponse: emitResponse,
    onClaimed: onClaimed,
    reclaimPersistedDecision: false,
  );

  Future<bool> resumePersistedDecision({
    required String requestId,
    required Map<String, dynamic> decision,
    required SuspendedResponseEmitter emitResponse,
  }) => _resumeFromDecision(
    requestId: requestId,
    decision: decision,
    emitResponse: emitResponse,
    reclaimPersistedDecision: true,
  );

  Future<bool> _resumeFromDecision({
    required String requestId,
    required Map<String, dynamic> decision,
    required SuspendedResponseEmitter emitResponse,
    SuspendedDecisionClaimed? onClaimed,
    required bool reclaimPersistedDecision,
  }) async {
    final foundCheckpoint = await _checkpointStore.getByRequestId(requestId);
    if (foundCheckpoint == null) return false;
    var checkpoint = foundCheckpoint;

    final decisionSessionId = decision['session_id']?.toString();
    if (decisionSessionId != null &&
        decisionSessionId.isNotEmpty &&
        decisionSessionId != checkpoint.sessionId) {
      return false;
    }

    final expectedStatus = reclaimPersistedDecision
        ? 'decision_ready'
        : 'awaiting_permission';
    if (checkpoint.status != expectedStatus) {
      return false;
    }

    final isAskUser = checkpoint.toolName == 'system_ask_user';
    if (isAskUser) {
      final answer = decision['answer']?.toString().trim();
      if (answer == null || answer.isEmpty) {
        return false;
      }
    } else {
      final hasAllowed =
          decision.containsKey('allowed') || decision.containsKey('decision');
      if (!hasAllowed) {
        return false;
      }
    }

    final persistedState = _persistedState;
    SuspendedDecisionClaim? durableClaim;
    if (persistedState != null) {
      durableClaim = persistedState.claimSuspendedDecision(
        checkpoint: checkpoint,
        decision: decision,
        reclaimPersistedDecision: reclaimPersistedDecision,
      );
      if (durableClaim == null) return false;
      checkpoint = durableClaim.checkpoint;
    } else {
      if (reclaimPersistedDecision) return false;
      final claimed = await _checkpointStore.claimDecision(
        requestId: requestId,
        status: 'decision_ready',
      );
      if (!claimed) return false;
    }
    final resumeOwner = durableClaim == null
        ? null
        : (
            workItemId: durableClaim.workItem.workItemId,
            runId: durableClaim.runId,
            generation: durableClaim.generation,
          );
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
    SessionRunOrchestrator? orchestrator;
    ActiveRun? activeRun;
    if (resumeOwner != null) {
      if (getIt.isRegistered<SessionRunOrchestrator>()) {
        orchestrator = getIt<SessionRunOrchestrator>();
        activeRun = orchestrator.adoptPersistedSuspendedRun(
          sessionId: checkpoint.sessionId,
          workItemId: resumeOwner.workItemId,
          runId: resumeOwner.runId,
          generation: resumeOwner.generation,
          agentRunner: agentRunner,
        );
      } else {
        agentRunner.beginAuthoritativeRun(
          resumeOwner.runId,
          workItemId: resumeOwner.workItemId,
          generation: resumeOwner.generation,
        );
      }
      final persistedWork = _persistedState?.findWorkItem(
        resumeOwner.workItemId,
      );
      if (persistedWork != null) {
        agentRunner.runStartTime = persistedWork.createdAt;
      }
      _clearStaleRecoveryNotice(checkpoint.sessionId);
    }
    bool canPublish() =>
        activeRun == null || orchestrator!.ownsPersistedSuspendedRun(activeRun);
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
        ? decision['answer']!.toString()
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

    if (!isAskUser && decision['allowed'] == true) {
      // Crossing this marker means startup must never replay the approved
      // side effect. If the process exits afterward, normal interrupted-tool
      // recovery records an unknown outcome instead.
      await _checkpointStore.updateStatus(
        requestId: requestId,
        status: 'executing_tool',
      );
    }

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
              if (!canPublish()) return;
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
        onReasoningDelta: (reasoning) async {
          if (!canPublish()) return;
          await emitResponse(
            GatewayResponse(
              sessionId: checkpoint.sessionId,
              message: Message(role: MessageRole.assistant, content: reasoning),
              isComplete: false,
              runId: ownerRunId,
              turnId: activeRun?.turnId,
              modelStepId: agentRunner.currentModelStepId,
            ),
          );
        },
      )) {
        if (!canPublish()) continue;
        fullContent += chunk;
        await emitResponse(
          GatewayResponse(
            sessionId: checkpoint.sessionId,
            message: Message(role: MessageRole.assistant, content: chunk),
            isComplete: false,
            runId: ownerRunId,
            turnId: activeRun?.turnId,
            modelStepId: agentRunner.currentModelStepId,
          ),
        );
      }

      if (!canPublish()) return true;
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
          if (activeRun?.turnId != null) 'turn_id': activeRun!.turnId,
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
      if (!canPublish()) return true;
      await emitResponse(
        GatewayResponse(
          sessionId: checkpoint.sessionId,
          message: terminalMessage,
          isComplete: true,
          runId: resumeOwner?.runId ?? ownerRunId,
          turnId: activeRun?.turnId,
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
      if (activeRun != null) {
        orchestrator!.releasePersistedSuspendedRun(activeRun);
      } else if (resumeOwner != null) {
        agentRunner.endAuthoritativeRun(resumeOwner.runId);
      }
      if (terminalCommitted) {
        _onTerminalCommitted?.call(checkpoint.sessionId);
      }
    }
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
    final execRoot = request.executionRoot;
    String? workspacePath;
    String? workspaceName;

    if (execRoot != null && execRoot.isNotEmpty) {
      workspacePath = _runtimeContextBuilder.pathResolver
          .validateAndNormalizeExecutionRoot(execRoot);
      workspaceName = p.basename(workspacePath!);
    } else {
      final workspaceId = request.workspaceId;
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

    return _runtimeContextBuilder.build(
      workspacePath: workspacePath,
      workspaceName: workspaceName,
      registry: agentRunner.registry,
    );
  }
}
