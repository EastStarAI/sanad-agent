import 'dart:async';
import 'package:logging/logging.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_recovery_exception.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_recovery_service.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_failure_reason.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_selection_errors.dart';
import 'package:sanad_agent/core/secrets_redactor.dart';
import 'package:sanad_agent/engine/agent_runner.dart';
import 'package:sanad_agent/engine/runtime/llm_route_snapshot.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/evolution/models/session_state.dart';
import 'package:sanad_agent/evolution/db/persisted_runtime_state_repository.dart';
import 'package:sanad_agent/evolution/db/runtime/session_execution_state_coordinator.dart';
import 'package:sanad_agent/evolution/title_service.dart';
import 'package:sanad_agent/interfaces/models/agent_turn_request.dart';
import 'package:sanad_agent/interfaces/models/gateway_event.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';
import 'package:sanad_agent/interfaces/runtime/local_runtime_orchestrator.dart';
import 'package:sanad_agent/interfaces/session_payload_builder.dart';

class ActiveRun {
  final String sessionId;
  final int generation;
  final String runId;
  final String? workItemId;
  final Completer<void> completer;
  final AgentRunner agentRunner;
  StreamSubscription<String>? _subscription;
  bool stopRequested = false;
  bool invalidated = false;

  ActiveRun({
    required this.sessionId,
    required this.generation,
    required this.runId,
    required this.workItemId,
    required this.completer,
    required this.agentRunner,
  });

  void attach(StreamSubscription<String> subscription) {
    _subscription = subscription;
  }

  Future<void> requestStop() async {
    stopRequested = true;
    invalidated = true;
    agentRunner.requestStop();
    await cancelSubscription();
    complete();
  }

  Future<void> cancelSubscription() async {
    final subscription = _subscription;
    if (subscription == null) {
      return;
    }
    _subscription = null;
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
    ActiveRun? activeRun;

    try {
      activeRun = ActiveRun(
        sessionId: event.sessionId,
        generation: generation,
        runId: runId,
        workItemId: workItemId,
        completer: Completer<void>(),
        agentRunner: agentRunner,
      );
      final owner = activeRun;
      activeRuns[event.sessionId] = activeRun;
      agentRunner.beginAuthoritativeRun(
        runId,
        workItemId: workItemId,
        generation: generation,
      );
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

      if (!isResume) {
        final receivedAt = turnRequest.metadata['received_at']?.toString();
        emitResponse(
          GatewayResponse(
            sessionId: event.sessionId,
            platformId: event.platformId,
            message: Message(
              role: MessageRole.user,
              content: content,
              metadata: {
                if (turnRequest.requestId != null)
                  'request_id': turnRequest.requestId,
                'received_at': receivedAt,
              },
            ),
            isComplete: true,
            runId: runId,
          ),
        );
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
          if (!ownsRun(owner)) {
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
              modelStepId: agentRunner.currentModelStepId,
            ),
          );
        },
        onDone: () {
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
      emitResponse(
        GatewayResponse(
          sessionId: event.sessionId,
          platformId: event.platformId,
          message: terminalMessage,
          isComplete: true,
          runId: activeRun.runId,
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
    } on ThinkingSelectionException catch (e) {
      if (activeRun == null || !ownsRun(activeRun)) {
        return;
      }
      sessionManager.clearInFlightSnapshot(event.sessionId);
      emitResponse(
        GatewayResponse(
          sessionId: event.sessionId,
          platformId: event.platformId,
          message: Message(
            role: MessageRole.assistant,
            content: e.message,
            metadata: {
              'error_code': e.code,
              'thinking_selection_error': true,
            },
          ),
          isComplete: true,
          runId: activeRun.runId,
          modelStepId: agentRunner.currentModelStepId,
        ),
      );
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
    if (!ownsRun(owner)) {
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
    if (thought.isEmpty || !ownsRun(owner)) {
      return;
    }
    _appendInFlightSnapshot(
      sessionId: event.sessionId,
      runId: owner.runId,
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
    if (reasoning.isEmpty || !ownsRun(owner)) {
      return;
    }
    _appendInFlightSnapshot(
      sessionId: event.sessionId,
      runId: owner.runId,
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
        modelStepId: agentRunner.currentModelStepId,
      ),
    );
  }

  void _appendInFlightSnapshot({
    required String sessionId,
    required String runId,
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
        existing['model_step_id'] == modelStepId &&
        existing['content'] is String;
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    sessionManager.saveInFlightSnapshot(sessionId, {
      'type': type,
      'status': 'running',
      'session_id': sessionId,
      'run_id': runId,
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
    if (content.isEmpty || !ownsRun(owner)) return;
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
              'model_step_id': ?modelStepId,
            },
          },
        ),
        isComplete: false,
        runId: owner.runId,
        modelStepId: modelStepId,
      ),
    );
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
