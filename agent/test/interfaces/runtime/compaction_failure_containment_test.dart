import 'dart:async';

import 'package:logging/logging.dart';
import 'package:sanad_agent/capabilities/models/tool_schema.dart';
import 'package:sanad_agent/core/agent_runtime_service.dart';
import 'package:sanad_agent/core/auth/auth_manager.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_selection_errors.dart';
import 'package:sanad_agent/engine/adapters/llm_http_exception.dart';
import 'package:sanad_agent/engine/adapters/llm_request_options.dart';
import 'package:sanad_agent/engine/agent_runner.dart';
import 'package:sanad_agent/engine/compaction/compaction.dart';
import 'package:sanad_agent/engine/context/context.dart';
import 'package:sanad_agent/engine/runtime/compaction_coordinator.dart';
import 'package:sanad_agent/evolution/compaction/compaction_activation_service.dart';
import 'package:sanad_agent/evolution/compaction/model_projection_builder.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/compaction_boundary_repository.dart';
import 'package:sanad_agent/evolution/db/session_db.dart';
import 'package:sanad_agent/evolution/db/session_history_revision_repository.dart';
import 'package:sanad_agent/evolution/db/session_projection_revision_repository.dart';
import 'package:sanad_agent/evolution/models/session_state.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/handlers/session_compact_command_handler.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/handlers/session_query_handler.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/sanad_protocol_bridge.dart';
import 'package:sanad_agent/interfaces/runtime/session_run_orchestrator.dart';
import 'package:test/test.dart';

import '../../support/memory_agent_secret_store.dart';

RouteSignature _testRoute() => const RouteSignature(
  providerInstanceId: 'provider-test',
  templateId: 'openai',
  protocol: 'openai_compatible',
  normalizedBaseUrl: 'https://api.example.com/v1',
  modelId: 'gpt-4o',
  configRevision: 1,
  credentialRevision: 1,
);

List<IndexedConversationMessage> _heavyTimeline() {
  return [
    IndexedConversationMessage(
      rowId: 1,
      message: Message(
        role: MessageRole.user,
        content: 'goal: ship compaction safely',
      ),
    ),
    for (var i = 2; i <= 30; i++)
      IndexedConversationMessage(
        rowId: i,
        message: Message(
          role: MessageRole.user,
          content: 'filler $i ${'x' * 200}',
        ),
      ),
  ];
}

class _MockRunnerWithThinkingError implements AgentRunner {
  final String targetSessionId;
  final ThinkingSelectionException errorToThrow;

  _MockRunnerWithThinkingError({
    required this.targetSessionId,
    required this.errorToThrow,
  });

  @override
  Future<CompactionProviderSeed> prepareCompactionProviderSeed({
    String? runtimeSystemPrompt,
  }) async {
    throw errorToThrow;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FailingSummarizer implements CompactionSummarizer {
  final Object errorToThrow;

  _FailingSummarizer(this.errorToThrow);

  @override
  Future<String> summarize({required String prompt}) async {
    throw errorToThrow;
  }
}

class _MockRunnerWithSeed implements AgentRunner {
  _MockRunnerWithSeed({required this.targetSessionId});

  final String targetSessionId;

  @override
  Future<CompactionProviderSeed> prepareCompactionProviderSeed({
    String? runtimeSystemPrompt,
  }) async {
    return CompactionProviderSeed(
      projection: [
        Message(role: MessageRole.user, content: 'goal: ship compaction safely'),
      ],
      tools: const <ToolSchema>[],
      options: LLMRequestOptions(
        sessionId: targetSessionId,
        providerInstanceId: 'provider-test',
        thinkingMode: 'high',
      ),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MockRuntimeService extends AgentRuntimeService {
  _MockRuntimeService(super.config, super.repo);

  @override
  RouteSignature resolveSignature({String? providerId, String? modelId}) {
    return const RouteSignature(
      providerInstanceId: 'provider-test',
      templateId: 'openai',
      protocol: 'openai_compatible',
      normalizedBaseUrl: 'https://api.example.com/v1',
      modelId: 'gpt-4o',
      configRevision: 1,
      credentialRevision: 1,
    );
  }
}

class _GatedFailingSummarizer implements CompactionSummarizer {
  _GatedFailingSummarizer({required this.entered, required this.release});

  final Completer<void> entered;
  final Completer<void> release;

  @override
  Future<String> summarize({required String prompt}) async {
    entered.complete();
    await release.future;
    throw TimeoutException('Injected gated provider failure');
  }
}

class _StubCompactOrchestrator implements SessionRunOrchestrator {
  @override
  Future<Map<String, dynamic>> handleCompactCommand({
    required String sessionId,
    required String requestId,
  }) async {
    return {
      'session_id': sessionId,
      'request_id': requestId,
      'outcome': 'failed',
      'failure_reason': 'summarization_failed',
      'failure_stage': 'provider',
      'failure_cause': 'timeout',
    };
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FailingPruner extends CompactionToolPruner {
  final Object errorToThrow;

  const _FailingPruner(this.errorToThrow);

  @override
  List<IndexedConversationMessage> pruneSourceMessages(
    List<IndexedConversationMessage> messages, {
    required int protectedTailStartRowId,
  }) {
    throw errorToThrow;
  }
}

void main() {
  group('Plan 106 G8 — Compaction Failure Containment and Safe Diagnostics', () {
    late AgentStateDatabase stateDb;
    late SessionDB sessionDb;
    late SessionHistoryRevisionRepository historyRepo;
    late SessionProjectionRevisionRepository projRepo;
    late CompactionBoundaryRepository boundaryRepo;
    late CompactionActivationService activationService;
    late ModelProjectionBuilder projBuilder;
    late SessionRunOrchestrator orchestrator;

    setUp(() async {
      // Await the reset: an un-awaited GetIt reset continues asynchronously
      // and can wipe freshly registered singletons at the next event-loop
      // yield, silently breaking any test that pumps timers.
      await getIt.reset();
      getIt.allowReassignment = true;
      SessionManager.resetForTesting();

      stateDb = AgentStateDatabase.inMemory();
      sessionDb = SessionDB.fromState(stateDb);
      historyRepo = SessionHistoryRevisionRepository(stateDb);
      projRepo = SessionProjectionRevisionRepository(stateDb);
      boundaryRepo = CompactionBoundaryRepository(stateDb, historyRepo);
      activationService = CompactionActivationService(
        boundaries: boundaryRepo,
        projectionRevisions: projRepo,
      );
      projBuilder = ModelProjectionBuilder(
        sessions: sessionDb,
        boundaries: boundaryRepo,
      );

      getIt.registerSingleton<AgentStateDatabase>(stateDb);
      getIt.registerSingleton<SessionHistoryRevisionRepository>(historyRepo);
      getIt.registerSingleton<SessionProjectionRevisionRepository>(projRepo);
      getIt.registerSingleton<CompactionBoundaryRepository>(boundaryRepo);
      getIt.registerSingleton<CompactionActivationService>(activationService);
      getIt.registerSingleton<ModelProjectionBuilder>(projBuilder);
      getIt.registerSingleton<SessionManager>(SessionManager());
      // Inject an in-memory vault: the default platform secret store derives
      // its scope from a prepared Sanad Home, which a clean CI runner does not
      // have. Tests must never reach the developer's real Home vault.
      getIt.registerSingleton<AuthManager>(
        AuthManager(secretStore: MemoryAgentSecretStore()),
      );

      final coordinator = CompactionCoordinator(
        engine: ContextCompactionEngine(),
        boundaries: boundaryRepo,
        activation: activationService,
        projectionBuilder: projBuilder,
      );
      getIt.registerSingleton<CompactionCoordinator>(coordinator);

      orchestrator = SessionRunOrchestrator();
      getIt.registerSingleton<SessionRunOrchestrator>(orchestrator);

      final now = DateTime.utc(2026, 10, 18);
      sessionDb.saveSession(
        SessionState(
          sessionId: 'session-alpha',
          model: 'gpt-4o',
          providerId: 'provider-test',
          thinkingMode: 'high',
          createdAt: now,
          updatedAt: now,
          lastUserMessageAt: now,
        ),
      );
      sessionDb.saveSession(
        SessionState(
          sessionId: 'session-beta',
          model: 'gpt-4o',
          providerId: 'provider-test',
          thinkingMode: 'medium',
          createdAt: now,
          updatedAt: now,
          lastUserMessageAt: now,
        ),
      );
      sessionDb.replaceMessages(
        'session-alpha',
        _heavyTimeline().map((e) => e.message).toList(),
      );
      sessionDb.replaceMessages('session-beta', [
        Message(role: MessageRole.user, content: 'Beta user ask'),
        Message(role: MessageRole.assistant, content: 'Beta reply'),
      ]);
    });

    tearDown(() async {
      SessionManager.resetForTesting();
      await getIt.reset();
      stateDb.dispose();
    });

    group('Pre-claim preparation failure containment', () {
      test('unsupported thinking selection in runner preparation is contained without creating claim', () async {
        const thinkingError = ThinkingSelectionException(
          code: ThinkingSelectionErrorCode.capabilityUnsupported,
          message: 'Model does not support thinkingMode high',
        );
        getIt.registerFactoryParam<AgentRunner, String, void>(
          (sessionId, _) => _MockRunnerWithThinkingError(
            targetSessionId: sessionId,
            errorToThrow: thinkingError,
          ),
        );

        final result = await orchestrator.handleCompactCommand(
          sessionId: 'session-alpha',
          requestId: 'req-thinking-unsupported',
        );

        expect(result['outcome'], 'failed');
        expect(result['failure_reason'], CompactionFailureReason.summarizationFailed.wireValue);
        expect(result['failure_stage'], CompactionFailureStage.preparation);
        expect(result['failure_cause'], CompactionFailureCause.thinkingUnsupported);
        expect(result['compaction_id'], isNull);

        // Verification: no started row was created in the database
        expect(boundaryRepo.findStartedForSession('session-alpha'), isNull);
        // Stored session thinking selection remains intact
        final session = sessionDb.getSession('session-alpha');
        expect(session?.thinkingMode, 'high');
      });

      test('unknown thinking capability code maps safely to thinking_capability_unknown', () async {
        const thinkingError = ThinkingSelectionException(
          code: ThinkingSelectionErrorCode.capabilityUnknown,
          message: 'Provider capability unknown',
        );
        getIt.registerFactoryParam<AgentRunner, String, void>(
          (sessionId, _) => _MockRunnerWithThinkingError(
            targetSessionId: sessionId,
            errorToThrow: thinkingError,
          ),
        );

        final result = await orchestrator.handleCompactCommand(
          sessionId: 'session-alpha',
          requestId: 'req-thinking-unknown',
        );

        expect(result['outcome'], 'failed');
        expect(result['failure_stage'], CompactionFailureStage.preparation);
        expect(result['failure_cause'], CompactionFailureCause.thinkingUnknown);
        expect(boundaryRepo.findStartedForSession('session-alpha'), isNull);
      });

      test('pre-claim admission rejections carry preparation stage and safe cause', () async {
        // 1. Session busy rejection
        orchestrator.debugMarkSessionBusy('session-alpha');
        final busyResult = await orchestrator.handleCompactCommand(
          sessionId: 'session-alpha',
          requestId: 'req-busy-test',
        );
        expect(busyResult['outcome'], CompactionFailureReason.sessionBusy.wireValue);
        expect(busyResult['failure_reason'], CompactionFailureReason.sessionBusy.wireValue);
        expect(busyResult['failure_stage'], CompactionFailureStage.preparation);
        expect(busyResult['failure_cause'], CompactionFailureCause.sessionBusy);
        orchestrator.debugClearSessionBusy('session-alpha');

        // 2. Compaction in progress barrier
        orchestrator.debugEnterCompactionBarrier('session-alpha');
        final inProgResult = await orchestrator.handleCompactCommand(
          sessionId: 'session-alpha',
          requestId: 'req-in-prog',
        );
        expect(inProgResult['outcome'], CompactionFailureReason.compactionInProgress.wireValue);
        expect(inProgResult['failure_stage'], CompactionFailureStage.preparation);
        expect(inProgResult['failure_cause'], CompactionFailureCause.compactionInProgress);
        orchestrator.debugExitCompactionBarrier('session-alpha');

        // 3. Unavailable when coordinator not registered
        final activeCoordinator = getIt<CompactionCoordinator>();
        getIt.unregister<CompactionCoordinator>();
        final unregResult = await orchestrator.handleCompactCommand(
          sessionId: 'session-alpha',
          requestId: 'req-unavail',
        );
        expect(unregResult['outcome'], 'unavailable');
        expect(unregResult['failure_stage'], CompactionFailureStage.preparation);
        expect(unregResult['failure_cause'], CompactionFailureCause.unavailable);
        getIt.registerSingleton<CompactionCoordinator>(activeCoordinator);
      });
    });

    group('Claimed failure diagnostics, lifecycle events, and history hydration', () {
      test('provider timeout during summarization persists stage provider and cause timeout', () async {
        final coordinatorEvents = <CompactionLifecycleEvent>[];
        final engine = ContextCompactionEngine(
          summarizer: _FailingSummarizer(TimeoutException('Request timed out')),
          pressureEvaluator: RequestPressureEvaluator(),
        );
        final coordinator = CompactionCoordinator(
          engine: engine,
          boundaries: boundaryRepo,
          activation: activationService,
          projectionBuilder: projBuilder,
          onLifecycleEvent: coordinatorEvents.add,
        );
        getIt.registerSingleton<CompactionCoordinator>(coordinator);

        final outcome = await coordinator.runCompaction(
          request: CompactionEngineRequest(
            compactionId: 'cmp-claimed-timeout',
            sessionId: 'session-alpha',
            trigger: CompactionTrigger.manual,
            sourceRevision: const CompactionHistoryRevision(1),
            routeSignature: _testRoute(),
            contextWindowTokens: 100_000,
            timeline: _heavyTimeline(),
            systemPrompt: 'System',
            runtimeContext: '',
            toolSchemas: const [],
            projectionRevision: 1,
            targetRequestTokens: 10_000,
            thresholdRatio: 0.9,
          ),
          force: true,
        );

        expect(outcome, isNotNull);
        expect(outcome!.status, CompactionStatus.failed);
        expect(outcome.failureReason, CompactionFailureReason.summarizationFailed);
        expect(outcome.failureStage, CompactionFailureStage.provider);
        expect(outcome.failureCause, CompactionFailureCause.timeout);

        // Verification: lifecycle events emitted
        final failedEvents = coordinatorEvents.where((e) => e.status == CompactionStatus.failed);
        expect(failedEvents, hasLength(1));
        final failedEvent = failedEvents.first;
        expect(failedEvent.failureStage, CompactionFailureStage.provider);
        expect(failedEvent.failureCause, CompactionFailureCause.timeout);

        // Verification: database persistence carries safe stage and cause in failure_detail_json
        final operations = boundaryRepo.listLifecycleForSession('session-alpha');
        final op = operations.firstWhere((o) => o.compactionId == 'cmp-claimed-timeout');
        expect(op.status, CompactionStatus.failed);
        expect(op.failureReason, CompactionFailureReason.summarizationFailed);
        expect(op.failureStage, CompactionFailureStage.provider);
        expect(op.failureCause, CompactionFailureCause.timeout);

        // Verification: hydrated history from SessionQueryHandler carries identical failure_stage and failure_cause
        final queryHandler = SessionQueryHandler(
          sessionManager: getIt<SessionManager>(),
          bridge: SanadProtocolBridge(),
          compactionBoundaries: boundaryRepo,
        );
        final envelope = queryHandler.buildHistoryEnvelope(
          CanonicalEvent(
            type: CanonicalEventTypes.getSessionHistory,
            sessionId: 'session-alpha',
            payload: {'session_id': 'session-alpha', 'request_id': 'history-req'},
          ),
        );
        final messages = (envelope['payload'] as Map)['messages'] as List;
        final historyCompaction = messages.firstWhere(
          (m) => m is Map && m['compaction_id'] == 'cmp-claimed-timeout',
        ) as Map;
        expect(historyCompaction['type'], CanonicalEventTypes.contextCompactionFailed);
        expect(historyCompaction['failure_reason'], CompactionFailureReason.summarizationFailed.wireValue);
        expect(historyCompaction['failure_stage'], CompactionFailureStage.provider);
        expect(historyCompaction['failure_cause'], CompactionFailureCause.timeout);
      });

      test('tool-result pruning failure classifies under stage pruning with safe cause', () async {
        final engine = ContextCompactionEngine(
          toolPruner: _FailingPruner(ArgumentError('Invalid message: content != toolResult.displayText')),
          pressureEvaluator: RequestPressureEvaluator(),
        );
        final coordinator = CompactionCoordinator(
          engine: engine,
          boundaries: boundaryRepo,
          activation: activationService,
          projectionBuilder: projBuilder,
        );
        getIt.registerSingleton<CompactionCoordinator>(coordinator);

        final outcome = await coordinator.runCompaction(
          request: CompactionEngineRequest(
            compactionId: 'cmp-pruning-fail',
            sessionId: 'session-alpha',
            trigger: CompactionTrigger.manual,
            sourceRevision: const CompactionHistoryRevision(1),
            routeSignature: _testRoute(),
            contextWindowTokens: 100_000,
            timeline: _heavyTimeline(),
            systemPrompt: 'System',
            runtimeContext: '',
            toolSchemas: const [],
            projectionRevision: 1,
            targetRequestTokens: 10_000,
            thresholdRatio: 0.9,
          ),
          force: true,
        );

        expect(outcome, isNotNull);
        expect(outcome!.status, CompactionStatus.failed);
        expect(outcome.failureReason, CompactionFailureReason.summarizationFailed);
        expect(outcome.failureStage, CompactionFailureStage.pruning);
        expect(outcome.failureCause, CompactionFailureCause.toolResultMalformed);

        final op = boundaryRepo.listLifecycleForSession('session-alpha')
            .firstWhere((o) => o.compactionId == 'cmp-pruning-fail');
        expect(op.failureStage, CompactionFailureStage.pruning);
        expect(op.failureCause, CompactionFailureCause.toolResultMalformed);
      });

      test('rate-limited 429 provider exception classifies safely as rate_limited without leaking body', () async {
        final httpError = LlmHttpException(
          statusCode: 429,
          body: '{"error": {"message": "Rate limit exceeded; token secret=xyz"}}',
          headers: {'retry-after': '30'},
          operation: 'chat.completions',
        );

        final diagnostics = CompactionDiagnostics.classify(httpError);
        expect(diagnostics.failureReason, CompactionFailureReason.summarizationFailed);
        expect(diagnostics.stage, CompactionFailureStage.provider);
        expect(diagnostics.cause, CompactionFailureCause.rateLimited);

        final detail = diagnostics.toDetailMap();
        expect(detail['stage'], 'provider');
        expect(detail['cause'], 'rate_limited');
        // Proof of no secret or payload leakage:
        expect(detail.toString(), isNot(contains('secret')));
        expect(detail.toString(), isNot(contains('Rate limit exceeded')));
      });
    });

    group('Ownership safety and sibling session responsiveness', () {
      test(
        'stale owner finishing after a newer owner takes over cannot clear or drain it',
        () async {
          final entered = Completer<void>();
          final release = Completer<void>();
          getIt.registerSingleton<AgentRuntimeService>(
            _MockRuntimeService(Config(), ProviderInstanceRepository(stateDb)),
          );
          getIt.registerFactoryParam<AgentRunner, String, void>(
            (sessionId, _) => _MockRunnerWithSeed(targetSessionId: sessionId),
          );
          getIt.registerSingleton<CompactionCoordinator>(
            CompactionCoordinator(
              engine: ContextCompactionEngine(
                summarizer: _GatedFailingSummarizer(
                  entered: entered,
                  release: release,
                ),
              ),
              boundaries: boundaryRepo,
              activation: activationService,
              projectionBuilder: projBuilder,
            ),
          );

          final pending = orchestrator.handleCompactCommand(
            sessionId: 'session-alpha',
            requestId: 'req-stale-owner',
          );
          await entered.future;
          expect(orchestrator.isSessionCompacting('session-alpha'), isTrue);

          // While the first command is still in flight, a newer owner replaces
          // the in-memory entry for the same session.
          orchestrator.debugEnterCompactionBarrier('session-alpha');

          release.completeError(TimeoutException('gated provider failure'));
          final result = await pending;
          expect(result['outcome'], 'failed');
          expect(result['failure_stage'], CompactionFailureStage.provider);
          expect(result['failure_cause'], CompactionFailureCause.timeout);

          // The stale owner must not clear the newer owner or drain its queue.
          expect(orchestrator.isSessionCompacting('session-alpha'), isTrue);

          orchestrator.debugExitCompactionBarrier('session-alpha');
          expect(orchestrator.isSessionCompacting('session-alpha'), isFalse);
        },
      );

      test(
        'a sibling session stays responsive while another session compacts',
        () async {
          orchestrator.debugEnterCompactionBarrier('session-alpha');
          expect(orchestrator.isSessionCompacting('session-alpha'), isTrue);

          final betaResult = await orchestrator.handleCompactCommand(
            sessionId: 'session-beta',
            requestId: 'req-beta',
          );
          // Beta is not blocked by alpha's barrier.
          expect(
            betaResult['outcome'],
            isNot(CompactionFailureReason.compactionInProgress.wireValue),
          );
          expect(betaResult['session_id'], 'session-beta');

          orchestrator.debugExitCompactionBarrier('session-alpha');
          expect(orchestrator.isSessionCompacting('session-alpha'), isFalse);
        },
      );

      test('SessionCompactCommandHandler catches unexpected error and emits sessionCompactResult envelope', () async {
        final envelopes = <Map<String, dynamic>>[];
        final bridge = SanadProtocolBridge();
        final handler = SessionCompactCommandHandler(
          orchestrator: orchestrator,
          bridge: bridge,
        );

        // Send invalid request (empty session_id)
        await handler.handle(
          CanonicalEvent(
            type: CanonicalEventTypes.sessionCompact,
            sessionId: '',
            payload: {'session_id': '', 'request_id': 'req-bad'},
          ),
          (env) async => envelopes.add(env),
        );

        expect(envelopes, hasLength(1));
        final payload = (envelopes.first['payload'] ?? envelopes.first['event']?['payload']) as Map;
        expect(payload['outcome'], 'invalid_request');
        expect(payload['failure_stage'], CompactionFailureStage.preparation);
        expect(payload['failure_cause'], CompactionFailureCause.invalidRequest);
      });

      test('SanadProtocolBridge safely contains sessionCompact errors so event loop survives', () async {
        final bridge = SanadProtocolBridge();
        // Sending compact command with valid session and request through protocol event dispatcher
        final envelopes = <Map<String, dynamic>>[];
        await bridge.handleProtocolEvent(
          CanonicalEvent(
            type: CanonicalEventTypes.sessionCompact,
            sessionId: 'session-alpha',
            payload: {'session_id': 'session-alpha', 'request_id': 'req-safe-async'},
          ),
          (env) async => envelopes.add(env),
        );

        // Emitted result envelope is safely received
        expect(envelopes, hasLength(1));
        final payload = (envelopes.first['payload'] ?? envelopes.first['event']?['payload']) as Map;
        expect(payload['request_id'], 'req-safe-async');
        expect(payload['failure_stage'], isNotNull);
        expect(payload['failure_cause'], isNotNull);
      });

      test(
        'sessionCompact transport containment logs bounded diagnostics without sensitive payloads',
        () async {
          const sensitiveToken = 'sk-fixture-sensitive-token-123';
          const sensitiveNote = 'private user note: bank transfer details';
          getIt.registerSingleton<SessionRunOrchestrator>(
            _StubCompactOrchestrator(),
          );

          final logged = <LogRecord>[];
          final bridgeLogger = Logger('SanadProtocolBridge');
          final subscription = bridgeLogger.onRecord.listen(logged.add);
          addTearDown(subscription.cancel);

          final bridge = SanadProtocolBridge();
          // The envelope callback fails with a sensitive payload after the
          // handler's own safe conversion, so the failure reaches the bridge's
          // last-resort containment boundary. Internal logs must stay bounded.
          await bridge.handleProtocolEvent(
            CanonicalEvent(
              type: CanonicalEventTypes.sessionCompact,
              sessionId: 'session-log-fixture',
              payload: {
                'session_id': 'session-log-fixture',
                'request_id': 'req-log-fixture',
              },
            ),
            (envelope) async {
              throw StateError(
                'provider body: {"api_key":"$sensitiveToken"}; $sensitiveNote',
              );
            },
          );
          await pumpEventQueue();

          final combined = logged
              .map(
                (record) =>
                    '${record.message}|${record.error}|${record.stackTrace}',
              )
              .join('\n');
          expect(combined, isNot(contains(sensitiveToken)));
          expect(combined, isNot(contains('bank transfer')));
          expect(combined, isNot(contains('provider body')));
          expect(combined, isNot(contains('StateError')));

          // Bounded allowlisted diagnostics with correlation are still emitted.
          expect(logged, isNotEmpty);
          expect(combined, contains('unexpected_error'));
          expect(combined, contains('session-log-fixture'));
          expect(combined, contains('req-log-fixture'));

          // Containment: the bridge survives and keeps dispatching commands.
          final envelopes = <Map<String, dynamic>>[];
          await bridge.handleProtocolEvent(
            CanonicalEvent(
              type: CanonicalEventTypes.sessionCompact,
              sessionId: 'session-log-fixture',
              payload: {
                'session_id': 'session-log-fixture',
                'request_id': 'req-log-fixture-2',
              },
            ),
            (envelope) async => envelopes.add(envelope),
          );
          expect(envelopes, hasLength(1));
        },
      );
    });
  });
}
