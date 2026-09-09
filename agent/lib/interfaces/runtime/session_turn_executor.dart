import 'dart:async';

import 'package:logging/logging.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_recovery_exception.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_recovery_service.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_failure_reason.dart';
import 'package:sanad_agent/core/secrets_redactor.dart';
import 'package:sanad_agent/engine/agent_runner.dart';
import 'package:sanad_agent/engine/runtime/llm_route_snapshot.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/evolution/models/pending_steer_record.dart';
import 'package:sanad_agent/evolution/models/session_state.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/message_history_identity.dart';
import 'package:sanad_agent/evolution/db/persisted_runtime_state_repository.dart';
import 'package:sanad_agent/evolution/db/session_history_revision_repository.dart';
import 'package:sanad_agent/evolution/db/runtime/session_execution_state_coordinator.dart';
import 'package:sanad_agent/evolution/title_service.dart';
import 'package:sanad_agent/interfaces/models/agent_turn_request.dart';
import 'package:sanad_agent/interfaces/models/gateway_event.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';
import 'package:sanad_agent/engine/runtime/run_cancellation_scope.dart';
import 'package:sanad_agent/engine/runtime/steer_coordinator.dart';
import 'package:sanad_agent/interfaces/runtime/local_runtime_orchestrator.dart';
import 'package:sanad_agent/interfaces/session_payload_builder.dart';

class ActiveRun {
  final String sessionId;
  final int generation;
  final String runId;
  final String? workItemId;
  final Completer<void> completer;
  String? _turnId;
  final AgentRunner agentRunner;
  final RunCancellationScope cancellationScope;
  StreamSubscription<String>? _subscription;
  RunCancellationResourceHandle? _subscriptionHandle;
  bool stopRequested = false;
  bool invalidated = false;

  ActiveRun({
    required this.sessionId,
    required this.generation,
    required this.runId,
    required this.workItemId,
    required this.completer,
    required this.agentRunner,
    String? turnId,
  }) : _turnId = turnId,
       cancellationScope = RunCancellationScope(
         sessionId: sessionId,
         runId: runId,
         workItemId: workItemId,
         generation: generation,
       );

  String? get turnId => _turnId;

  void bindTurnId(String turnId) {
    if (turnId.isEmpty) {
      throw ArgumentError.value(turnId, 'turnId', 'must not be empty');
    }
    final current = _turnId;
    if (current != null && current != turnId) {
      throw StateError('Active run turn identity cannot change.');
    }
    _turnId = turnId;
  }

  void attach(StreamSubscription<String> subscription) {
    _subscription = subscription;
    _subscriptionHandle?.release();
    _subscriptionHandle = cancellationScope.register(
      'turn_stream_subscription',
      () async {
        await subscription.cancel();
      },
    );
  }

  Future<void> requestStop({
    Duration cleanupDeadline = RunCancellationScope.defaultCleanupDeadline,
  }) async {
    stopRequested = true;
    invalidated = true;
    agentRunner.requestStop();
    await cancellationScope.cancel(
      reason: RunCancellationReason.userStop,
      cleanupDeadline: cleanupDeadline,
    );
    _subscription = null;
    _subscriptionHandle?.release();
    _subscriptionHandle = null;
    complete();
  }

  Future<void> cancelSubscription() async {
    final subscription = _subscription;
    if (subscription == null) {
      return;
    }
    _subscription = null;
    _subscriptionHandle?.release();
    _subscriptionHandle = null;
    await subscription.cancel();
  }

  void complete() {
    if (!completer.isCompleted) {
      completer.complete();
    }
  }

  void completeError(Object error, StackTrace stackTrace) {
    if (!completer.isCompleted) {
      completer.completeError(error, stackTrace);
    }
  }
}

class SessionTurnExecutor {
  static final Logger _logger = Logger('SessionTurnExecutor');
  static const _secretsRedactor = SecretsRedactor();

  final Map<String, ActiveRun> activeRuns = {};
  final Map<String, int> _sessionGenerations = {};
  final Set<String> _titleGenerationSessions = {};
  final void Function(GatewayResponse) emitResponse;
  final PersistedRuntimeStateRepository? Function() getPersistedState;

  SessionTurnExecutor({
    required this.emitResponse,
    required this.getPersistedState,
  });

  bool isRunning(String sessionId) => activeRuns.containsKey(sessionId);

  Iterable<String> get activeSessionIds => activeRuns.keys;

  ActiveRun? getActiveRun(String sessionId) => activeRuns[sessionId];

  bool ownsRun(ActiveRun run) {
    return !run.invalidated &&
        identical(activeRuns[run.sessionId], run) &&
        _sessionGenerations[run.sessionId] == run.generation;
  }

  void removeActiveRun(String sessionId) => activeRuns.remove(sessionId);

  Future<void> stopActiveRun(String sessionId) async {
    final activeRun = activeRuns[sessionId];
    if (activeRun != null) {
      _logger.info(
        'Runtime stop: cancelling active run for session $sessionId',
      );
      await activeRun.requestStop();
    }
  }

  Future<void> runTurn({
    required GatewayEvent event,
    required AgentTurnRequest turnRequest,
    required AgentRunner agentRunner,
    String? workItemId,
    bool isResume = false,
    bool isNewSession = false,
    SessionState? existingSession,
    String? payloadModel,
    required void Function(
      GatewayEvent event,
      AgentTurnRequest request,
      AgentRunner runner,
      String? workItemId,
    )
    onRecoveryRequired,
    required FutureOr<void> Function() onTurnComplete,
  }) async {
    final runtimeOrchestrator = getIt<LocalRuntimeOrchestrator>();
    final sessionManager = getIt<SessionManager>();
    final content = turnRequest.message;
    if (content.isEmpty) return;

    final generation = (_sessionGenerations[event.sessionId] ?? 0) + 1;
    _sessionGenerations[event.sessionId] = generation;
    final runId =
        event.runId ??
        'run_${DateTime.now().microsecondsSinceEpoch}_$generation';
    final existingRoot = _findDurableMessage(
      sessionId: event.sessionId,
      role: MessageRole.user,
      requestId: turnRequest.requestId,
    );
    final existingTurnId = existingRoot == null
        ? (isResume ? _findLatestDurableTurnId(event.sessionId) : null)
        : MessageHistoryIdentity.read(existingRoot).turnId;
    ActiveRun? activeRun;

    try {
      activeRun = ActiveRun(
        sessionId: event.sessionId,
        generation: generation,
        runId: runId,
        workItemId: workItemId,
        completer: Completer<void>(),
        agentRunner: agentRunner,
        turnId: existingTurnId?.isEmpty == true ? null : existingTurnId,
      );
      final owner = activeRun;
      activeRuns[event.sessionId] = activeRun;
      agentRunner.attachCancellationScope(owner.cancellationScope);
      agentRunner.beginAuthoritativeRun(
        runId,
        workItemId: workItemId,
        generation: generation,
      );
      if (!isResume) {
        agentRunner.configureRootMessageCommitted((message) {
          final identity = MessageHistoryIdentity.read(message);
          owner.bindTurnId(identity.turnId);
          emitResponse(
            GatewayResponse(
              sessionId: event.sessionId,
              platformId: event.platformId,
              message: message,
              isComplete: true,
              runId: owner.runId,
              turnId: owner.turnId,
            ),
          );
        });
      }
      if (getIt.isRegistered<RuntimeRecoveryService>()) {
        getIt<RuntimeRecoveryService>().beginRun(
          event.sessionId,
          runId,
          adoptExistingNotice: isResume,
        );
      }
      final persistedState = getPersistedState();
      if (persistedState != null && activeRun.workItemId != null) {
        final bound = persistedState.bindRunOwnership(
          sessionId: event.sessionId,
          workItemId: activeRun.workItemId!,
          runId: runId,
          generation: generation,
        );
        if (!bound) {
          return;
        }
        if (isResume) {
          final persistedWork = persistedState.findWorkItem(
            activeRun.workItemId!,
          );
          if (persistedWork != null) {
            agentRunner.runStartTime = persistedWork.createdAt;
          }
        }
      }

      String fullContent = '';
      bool stoppedCleanly = false;
      final sessionMetadata = isResume
          ? (sessionManager.getSessionMetadata(event.sessionId) ??
                const <String, dynamic>{})
          : await runtimeOrchestrator.buildSessionMetadata(turnRequest);
      if (!ownsRun(activeRun)) return;
      if (sessionMetadata.isNotEmpty) {
        sessionManager.saveSessionMetadata(event.sessionId, {
          ...?sessionManager.getSessionMetadata(event.sessionId),
          ...sessionMetadata,
        });
      }

      final stream = isResume
          ? runtimeOrchestrator.resumeTurn(
              agentRunner: agentRunner,
              request: turnRequest,
              onToolEvent:
                  ({
                    required String toolName,
                    String? input,
                    String? output,
                    required bool isError,
                    required bool isStart,
                    String? toolRunId,
                  }) async {
                    await _emitToolEvent(
                      owner: owner,
                      event: event,
                      runId: runId,
                      toolName: toolName,
                      input: input,
                      output: output,
                      isError: isError,
                      isStart: isStart,
                      toolRunId: toolRunId,
                      onResetFullContent: () => fullContent = '',
                    );
                  },
              onSteerContinuation: () {
                if (!ownsRun(owner)) return;
                _emitCompletedSteerSegment(
                  owner: owner,
                  event: event,
                  content: fullContent,
                );
                fullContent = '';
                sessionManager.clearInFlightSnapshot(event.sessionId);
              },
              onThoughtDelta: (thought) => _emitThoughtDelta(
                owner: owner,
                event: event,
                agentRunner: agentRunner,
                thought: thought,
              ),
              onReasoningDelta: (reasoning) => _emitReasoningDelta(
                owner: owner,
                event: event,
                agentRunner: agentRunner,
                fallbackRunId: runId,
                reasoning: reasoning,
              ),
            )
          : runtimeOrchestrator.streamTurn(
              agentRunner: agentRunner,
              request: turnRequest,
              onToolEvent:
                  ({
                    required String toolName,
                    String? input,
                    String? output,
                    required bool isError,
                    required bool isStart,
                    String? toolRunId,
                  }) async {
                    await _emitToolEvent(
                      owner: owner,
                      event: event,
                      runId: runId,
                      toolName: toolName,
                      input: input,
                      output: output,
                      isError: isError,
                      isStart: isStart,
                      toolRunId: toolRunId,
                      onResetFullContent: () => fullContent = '',
                    );
                  },
              onSteerContinuation: () {
                if (!ownsRun(owner)) return;
                _emitCompletedSteerSegment(
                  owner: owner,
                  event: event,
                  content: fullContent,
                );
                fullContent = '';
                sessionManager.clearInFlightSnapshot(event.sessionId);
              },
              onThoughtDelta: (thought) => _emitThoughtDelta(
                owner: owner,
                event: event,
                agentRunner: agentRunner,
                thought: thought,
              ),
              onReasoningDelta: (reasoning) => _emitReasoningDelta(
                owner: owner,
                event: event,
                agentRunner: agentRunner,
                fallbackRunId: runId,
                reasoning: reasoning,
              ),
            );

      late StreamSubscription<String> runSubscription;

      runSubscription = stream.listen(
        (chunk) async {
          if (!ownsRun(owner) || !owner.cancellationScope.isPublicationOpen) {
            _logger.info(
              'Stream listener detected stop flag for session: ${event.sessionId}',
            );
            stoppedCleanly = true;
            await owner.cancelSubscription();
            owner.complete();
            return;
          }
          fullContent += chunk;
          _appendInFlightSnapshot(
            sessionId: event.sessionId,
            runId: owner.runId,
            turnId: owner.turnId,
            modelStepId: agentRunner.currentModelStepId,
            type: CanonicalEventTypes.thoughtStream,
            delta: chunk,
          );
          if (getIt.isRegistered<RuntimeRecoveryService>()) {
            getIt<RuntimeRecoveryService>().clearResumingOnProgress(
              event.sessionId,
              runId: owner.runId,
            );
          }
          emitResponse(
            GatewayResponse(
              sessionId: event.sessionId,
              platformId: event.platformId,
              message: Message(role: MessageRole.assistant, content: chunk),
              isComplete: false,
              runId: owner.runId,
              turnId: owner.turnId,
              modelStepId: agentRunner.currentModelStepId,
            ),
          );
        },
        onDone: () {
          owner.cancellationScope.markCompleted();
          owner.complete();
        },
        onError: (e, stack) {
          if (e is RuntimeRecoveryRequired || e is RuntimeRecoveryCancelled) {
            _logger.info('Runtime recovery transition in streamTurn: $e');
          } else {
            _logger.severe('Error in streamTurn: $e', e, stack);
          }
          owner.completeError(e, stack);
        },
        cancelOnError: true,
      );
      activeRun.attach(runSubscription);
      if (activeRun.stopRequested) {
        await activeRun.requestStop();
      }

      await activeRun.completer.future;

      _logger.fine('Streaming complete for session: ${event.sessionId}');

      if (stoppedCleanly || !ownsRun(activeRun)) {
        return;
      }

      final contextUsage = await _captureContextUsage(
        sessionId: event.sessionId,
        agentRunner: agentRunner,
      );
      final contextTokens = await agentRunner.getContextTokens();
      if (!ownsRun(activeRun)) return;
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

      agentRunner.attachMetadataToLastAssistantMessage(turnMetadata);

      final terminalMessage = Message(
        role: MessageRole.assistant,
        content: fullContent,
        metadata: {
          ...turnMetadata,
          'run_id': activeRun.runId,
          if (activeRun.turnId != null) 'turn_id': activeRun.turnId,
          if (agentRunner.currentModelStepId != null)
            'model_step_id': agentRunner.currentModelStepId,
        },
      );
      final repo = getPersistedState();
      final terminalOutcome = repo != null && activeRun.workItemId != null
          ? repo.commitTerminal(
              sessionId: event.sessionId,
              workItemId: activeRun.workItemId!,
              runId: activeRun.runId,
              generation: activeRun.generation,
              assistantResult: terminalMessage,
            )
          : TerminalCommitOutcome.committed;
      if (terminalOutcome == TerminalCommitOutcome.persistenceFailed) {
        emitResponse(
          GatewayResponse(
            sessionId: event.sessionId,
            platformId: event.platformId,
            message: Message(
              role: MessageRole.assistant,
              content:
                  'Error: The final response could not be saved safely. The request remains recoverable.',
            ),
            isComplete: true,
            runId: activeRun.runId,
            turnId: activeRun.turnId,
          ),
        );
        return;
      }
      if (terminalOutcome != TerminalCommitOutcome.committed) {
        _logger.warning(
          'Terminal commit rejected for session ${event.sessionId}, '
          'work item ${activeRun.workItemId}, run ${activeRun.runId}: '
          '$terminalOutcome',
        );
        return;
      }

      agentRunner.markProviderResponseTerminalCommitted();
      sessionManager.clearInFlightSnapshot(event.sessionId);
      final durableTerminal = _findDurableMessage(
        sessionId: event.sessionId,
        role: MessageRole.assistant,
        runId: activeRun.runId,
      );
      emitResponse(
        GatewayResponse(
          sessionId: event.sessionId,
          platformId: event.platformId,
          message: durableTerminal ?? terminalMessage,
          isComplete: true,
          runId: activeRun.runId,
          turnId: activeRun.turnId,
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

      final titleSession = sessionManager.getSession(event.sessionId);
      if (_shouldGenerateIntelligentTitle(
            isNewSession: isNewSession,
            existingSession: existingSession,
            currentSession: titleSession,
          ) &&
          _titleGenerationSessions.add(event.sessionId)) {
        final expectedTitle = titleSession?.title ?? existingSession?.title;
        unawaited(
          _generateAndEmitIntelligentTitle(
            sessionId: event.sessionId,
            platformId: event.platformId,
            expectedTitle: expectedTitle,
            userMessage: content,
            assistantResponse: fullContent,
            route: agentRunner.lastSuccessfulLlmRoute,
            runId: runId,
          ).whenComplete(
            () => _titleGenerationSessions.remove(event.sessionId),
          ),
        );
      }
      if (!ownsRun(activeRun)) return;
      if (getIt.isRegistered<RuntimeRecoveryService>()) {
        getIt<RuntimeRecoveryService>().clearResumingOnProgress(
          event.sessionId,
          runId: activeRun.runId,
        );
      }
    } on RuntimeRecoveryRequired {
      if (activeRun != null && ownsRun(activeRun)) {
        onRecoveryRequired(
          event,
          turnRequest,
          agentRunner,
          activeRun.workItemId,
        );
      }
    } catch (e, stack) {
      if (activeRun == null || activeRun.stopRequested || !ownsRun(activeRun)) {
        return;
      }
      final repo = getPersistedState();
      if (repo != null && activeRun.workItemId != null) {
        repo.transitionOwnedWorkItem(
          sessionId: event.sessionId,
          workItemId: activeRun.workItemId!,
          toState: SessionWorkState.blocked,
        );
      }
      if (isResume && getIt.isRegistered<RuntimeRecoveryService>()) {
        getIt<RuntimeRecoveryService>().reportFailure(
          sessionId: event.sessionId,
          reason: RuntimeFailureReason.unknown,
          requestId: turnRequest.requestId,
          providerInstanceId: turnRequest.effectiveProviderInstanceId,
          title: 'Resume checkpoint is not safe to continue',
          message:
              'The daemon could not validate the saved resume checkpoint. Execution was blocked to avoid replaying an unsafe partial turn.',
          forceBlocked: true,
          runId: activeRun.runId,
        );
      }
      final redactedError = _secretsRedactor.redact(e.toString());
      _logger.severe('Error handling event: $redactedError', e, stack);
      // The durable recovery notice is the terminal projection for a failed
      // resume. Emitting an assistant response here is translated into a
      // misleading `final_answer` even though no continuation succeeded.
      if (isResume) return;
      final contextUsageOnError = await _captureContextUsage(
        sessionId: event.sessionId,
        agentRunner: agentRunner,
      );
      final contextTokensOnError = await agentRunner.getContextTokens();
      if (!ownsRun(activeRun)) return;
      final errorMetadata = <String, dynamic>{
        ...?sessionManager.getSessionMetadata(event.sessionId),
        if (agentRunner.activeModel != null) 'model': agentRunner.activeModel,
        if (agentRunner.activeModelDisplay != null)
          'model_display': agentRunner.activeModelDisplay,
        if (agentRunner.activeProvider != null)
          'provider': agentRunner.activeProvider,
        'context_tokens': contextTokensOnError,
        'usage': agentRunner.lastUsage,
        'context_usage': ?contextUsageOnError,
      };
      agentRunner.attachMetadataToLastAssistantMessage(errorMetadata);
      sessionManager.clearInFlightSnapshot(event.sessionId);
      emitResponse(
        GatewayResponse(
          sessionId: event.sessionId,
          platformId: event.platformId,
          message: Message(
            role: MessageRole.assistant,
            content: 'Error: $redactedError',
          ),
          isComplete: true,
          runId: activeRun.runId,
          turnId: activeRun.turnId,
          modelStepId: agentRunner.currentModelStepId,
          usage: agentRunner.lastUsage,
          contextUsage: contextUsageOnError,
          runtimeMs: agentRunner.runtimeMs,
          model: agentRunner.activeModel,
          modelDisplay: agentRunner.activeModelDisplay,
          provider: agentRunner.activeProvider,
          contextTokens: contextTokensOnError,
        ),
      );
    } finally {
      if (activeRun != null) {
        final wasOwner = ownsRun(activeRun);
        if (wasOwner) {
          await onTurnComplete();
        }
        if (identical(activeRuns[event.sessionId], activeRun)) {
          activeRuns.remove(event.sessionId);
        }
        agentRunner.detachCancellationScope(activeRun.cancellationScope);
        agentRunner.endAuthoritativeRun(activeRun.runId);
        if (getIt.isRegistered<RuntimeRecoveryService>()) {
          getIt<RuntimeRecoveryService>().endRun(
            event.sessionId,
            activeRun.runId,
          );
        }
      }
    }
  }

  Future<Map<String, dynamic>?> _captureContextUsage({
    required String sessionId,
    required AgentRunner agentRunner,
  }) async {
    final snapshot = await agentRunner.getContextUsageSnapshot();
    if (snapshot == null) return null;
    final sessionManager = getIt<SessionManager>();
    sessionManager.saveSessionMetadata(sessionId, {
      ...?sessionManager.getSessionMetadata(sessionId),
      'context_usage': snapshot,
    });
    agentRunner.attachMetadataToLastAssistantMessage({
      'usage': agentRunner.lastUsage,
      'context_usage': snapshot,
      if (agentRunner.activeModel != null) 'model': agentRunner.activeModel,
      if (agentRunner.activeModelDisplay != null)
        'model_display': agentRunner.activeModelDisplay,
      if (agentRunner.activeProvider != null)
        'provider': agentRunner.activeProvider,
      if (snapshot['context_window_tokens'] != null)
        'context_tokens': snapshot['context_window_tokens'],
    });
    return snapshot;
  }

  Future<void> _emitToolEvent({
    required ActiveRun owner,
    required GatewayEvent event,
    required String runId,
    required String toolName,
    String? input,
    String? output,
    required bool isError,
    required bool isStart,
    String? toolRunId,
    required void Function() onResetFullContent,
  }) async {
    if (!ownsRun(owner) || !owner.cancellationScope.isPublicationOpen) {
      return;
    }
    final sessionManager = getIt<SessionManager>();
    if (isStart) {
      onResetFullContent();
      sessionManager.clearInFlightSnapshot(event.sessionId);
      final contextUsage = await _captureContextUsage(
        sessionId: event.sessionId,
        agentRunner: owner.agentRunner,
      );
      emitResponse(
        GatewayResponse(
          sessionId: event.sessionId,
          platformId: event.platformId,
          message: Message(role: MessageRole.tool, content: input),
          isComplete: false,
          runId: owner.runId,
          turnId: owner.turnId,
          modelStepId: owner.agentRunner.currentModelStepId,
          toolCallId: toolRunId,
          usage: owner.agentRunner.lastUsage,
          contextUsage: contextUsage,
          toolName: toolName,
          isToolUse: true,
        ),
      );
      return;
    }
    emitResponse(
      GatewayResponse(
        sessionId: event.sessionId,
        platformId: event.platformId,
        message: Message(role: MessageRole.tool, content: output),
        isComplete: false,
        runId: owner.runId,
        turnId: owner.turnId,
        modelStepId: owner.agentRunner.currentModelStepId,
        toolCallId: toolRunId,
        toolName: toolName,
        isToolResult: true,
        isToolError: isError,
      ),
    );
  }

  void _emitThoughtDelta({
    required ActiveRun owner,
    required GatewayEvent event,
    required AgentRunner agentRunner,
    required String thought,
  }) {
    if (thought.isEmpty ||
        !ownsRun(owner) ||
        !owner.cancellationScope.isPublicationOpen) {
      return;
    }
    _appendInFlightSnapshot(
      sessionId: event.sessionId,
      runId: owner.runId,
      turnId: owner.turnId,
      modelStepId: agentRunner.currentModelStepId,
      type: CanonicalEventTypes.thoughtStream,
      delta: thought,
    );
    emitResponse(
      GatewayResponse(
        sessionId: event.sessionId,
        platformId: event.platformId,
        message: Message(role: MessageRole.assistant, thought: thought),
        isComplete: false,
        runId: owner.runId,
        turnId: owner.turnId,
        modelStepId: agentRunner.currentModelStepId,
      ),
    );
  }

  void _emitReasoningDelta({
    required ActiveRun owner,
    required GatewayEvent event,
    required AgentRunner agentRunner,
    required String fallbackRunId,
    required String reasoning,
  }) {
    if (reasoning.isEmpty ||
        !ownsRun(owner) ||
        !owner.cancellationScope.isPublicationOpen) {
      return;
    }
    _appendInFlightSnapshot(
      sessionId: event.sessionId,
      runId: owner.runId,
      turnId: owner.turnId,
      modelStepId: agentRunner.currentModelStepId,
      type: CanonicalEventTypes.reasoningStream,
      delta: reasoning,
    );
    emitResponse(
      GatewayResponse(
        sessionId: event.sessionId,
        platformId: event.platformId,
        message: Message(role: MessageRole.assistant, reasoning: reasoning),
        isComplete: false,
        runId: owner.runId,
        turnId: owner.turnId,
        modelStepId: agentRunner.currentModelStepId,
      ),
    );
  }

  void _appendInFlightSnapshot({
    required String sessionId,
    required String runId,
    required String? turnId,
    required String? modelStepId,
    required String type,
    required String delta,
  }) {
    if (delta.isEmpty) return;
    final sessionManager = getIt<SessionManager>();
    final existing = sessionManager.getInFlightSnapshot(sessionId);
    final sameStream =
        existing != null &&
        existing['type'] == type &&
        existing['run_id'] == runId &&
        existing['turn_id'] == turnId &&
        existing['model_step_id'] == modelStepId &&
        existing['content'] is String;
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    sessionManager.saveInFlightSnapshot(sessionId, {
      'type': type,
      'status': 'running',
      'session_id': sessionId,
      'run_id': runId,
      'turn_id': ?turnId,
      'model_step_id': modelStepId,
      'content': sameStream ? '${existing['content']}$delta' : delta,
      'timestamp': timestamp,
      'updated_at': timestamp,
    });
  }

  void _emitCompletedSteerSegment({
    required ActiveRun owner,
    required GatewayEvent event,
    required String content,
  }) {
    if (content.isEmpty ||
        !ownsRun(owner) ||
        !owner.cancellationScope.isPublicationOpen) {
      return;
    }
    final modelStepId = owner.agentRunner.currentModelStepId;
    emitResponse(
      GatewayResponse(
        sessionId: event.sessionId,
        platformId: event.platformId,
        message: Message(
          role: MessageRole.assistant,
          content: content,
          metadata: {
            'canonical_event_type': CanonicalEventTypes.thought,
            'canonical_payload': {
              'content': content,
              'status': 'done',
              'session_id': event.sessionId,
              'run_id': owner.runId,
              if (owner.turnId != null) 'turn_id': owner.turnId,
              'model_step_id': ?modelStepId,
            },
          },
        ),
        isComplete: false,
        runId: owner.runId,
        turnId: owner.turnId,
        modelStepId: modelStepId,
      ),
    );
  }

  PendingSteerDeliveryCommit commitPendingSteerDelivery({
    required ActiveRun owner,
    required List<Message> history,
    required List<PendingSteerPlacement> placements,
  }) {
    final state = getIt<AgentStateDatabase>();
    final persistedState = getIt<PersistedRuntimeStateRepository>();
    final sessionManager = getIt<SessionManager>();
    return state.transaction((transaction) {
      final persisted = sessionManager.saveSessionHistoryInTransaction(
        owner.sessionId,
        history,
        transaction,
      );
      final historyRevision = SessionHistoryRevisionRepository(
        state,
      ).readInTransaction(transaction, owner.sessionId)?.value;
      if (historyRevision == null) {
        throw StateError(
          'Session history revision is missing after steer commit.',
        );
      }
      final records = <PendingSteerRecord>[];
      for (final placement in placements) {
        final requestId = placement.steer.requestId;
        if (requestId == null ||
            placement.anchorIndex < 0 ||
            placement.anchorIndex >= persisted.length) {
          continue;
        }
        final deliveredAt = persisted[placement.anchorIndex];
        final deliveredIdentity = MessageHistoryIdentity.isSteer(deliveredAt)
            ? MessageHistoryIdentity.read(deliveredAt)
            : _embeddedSteerIdentity(deliveredAt, requestId);
        if (deliveredIdentity == null || deliveredIdentity.messageId.isEmpty) {
          throw StateError('Persisted steer identity is missing after commit.');
        }
        final anchorIndex = MessageHistoryIdentity.isSteer(deliveredAt)
            ? placement.anchorIndex - 1
            : placement.anchorIndex;
        final anchor = anchorIndex >= 0 ? persisted[anchorIndex] : null;
        final anchorIdentity = anchor == null
            ? null
            : MessageHistoryIdentity.read(anchor);
        final record = persistedState.pendingInputs.markDelivered(
          sessionId: owner.sessionId,
          requestId: requestId,
          runId: owner.runId,
          generation: owner.generation,
          messageId: deliveredIdentity.messageId,
          turnId: deliveredIdentity.turnId,
          anchorMessageId: anchorIdentity?.messageId,
          anchorToolCallId:
              anchor?.toolCallId ??
              anchor?.metadata?['tool_call_id']?.toString(),
          historyRevision: historyRevision,
          transaction: transaction,
        );
        if (record == null) {
          throw StateError(
            'Pending steer owner changed during delivery commit.',
          );
        }
        records.add(record);
      }
      return PendingSteerDeliveryCommit(history: persisted, records: records);
    });
  }

  MessageHistoryIdentity? _embeddedSteerIdentity(
    Message anchor,
    String requestId,
  ) {
    final raw = anchor.metadata?['steer_messages'];
    if (raw is! List) return null;
    for (final item in raw) {
      if (item is! Map || item['request_id']?.toString() != requestId) continue;
      return MessageHistoryIdentity.read(
        Message(
          role: MessageRole.user,
          content: item['text']?.toString(),
          metadata: Map<String, dynamic>.from(item),
        ),
      );
    }
    return null;
  }

  String? _findLatestDurableTurnId(String sessionId) {
    final messages = getIt<SessionManager>().getMessages(sessionId);
    for (final message in messages.reversed) {
      final turnId = MessageHistoryIdentity.read(message).turnId;
      if (turnId.isNotEmpty) return turnId;
    }
    return null;
  }

  Message? _findDurableMessage({
    required String sessionId,
    required MessageRole role,
    String? requestId,
    String? runId,
  }) {
    final messages = getIt<SessionManager>().getMessages(sessionId);
    for (final message in messages.reversed) {
      if (message.role != role) continue;
      final metadata = message.metadata;
      if (requestId != null && metadata?['request_id'] == requestId) {
        return message;
      }
      if (runId != null && metadata?['run_id'] == runId) {
        return message;
      }
    }
    return null;
  }

  bool _shouldGenerateIntelligentTitle({
    required bool isNewSession,
    required SessionState? existingSession,
    required SessionState? currentSession,
  }) {
    if (currentSession != null) {
      return currentSession.titleStatus == SessionTitleStatus.pending;
    }
    if (existingSession != null) {
      return existingSession.titleStatus == SessionTitleStatus.pending;
    }
    return isNewSession;
  }

  Future<void> _generateAndEmitIntelligentTitle({
    required String sessionId,
    required String platformId,
    required String? expectedTitle,
    required String userMessage,
    required String assistantResponse,
    required LLMRouteSnapshot? route,
    String? runId,
  }) async {
    try {
      final titleService = getIt<TitleService>();
      final newTitle = await titleService.generateTitle(
        sessionId: sessionId,
        userMessage: userMessage,
        assistantResponse: assistantResponse,
        route: route,
      );

      final sessionManager = getIt<SessionManager>();
      final updated = sessionManager.updateSessionTitleIfCurrent(
        sessionId,
        expectedTitle: expectedTitle,
        title: newTitle,
      );
      if (!updated) {
        _logger.fine('Discarded stale generated title for session $sessionId.');
        return;
      }

      final updatedSession = sessionManager.getSession(sessionId);
      emitResponse(
        GatewayResponse(
          sessionId: sessionId,
          platformId: platformId,
          message: Message(role: MessageRole.assistant, content: newTitle),
          isSessionUpdated: true,
          isComplete: true,
          runId: runId,
          sessionPayload: updatedSession != null
              ? buildSessionPayload(
                  session: updatedSession,
                  sessionMetadata: sessionManager.getSessionMetadata(sessionId),
                )
              : null,
        ),
      );
    } catch (e) {
      _logger.warning('Failed to generate and emit intelligent title: $e');
    }
  }
}
