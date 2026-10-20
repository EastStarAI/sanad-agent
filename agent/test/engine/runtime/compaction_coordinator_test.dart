import 'dart:async';

import 'package:sanad_agent/core/agent_runtime_service.dart';
import 'package:sanad_agent/core/models/message.dart';
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
import 'package:test/test.dart';

RouteSignature _route() => const RouteSignature(
  providerInstanceId: 'provider-1',
  templateId: 'openai',
  protocol: 'openai_compatible',
  normalizedBaseUrl: 'https://api.example.com/v1',
  modelId: 'gpt-4o',
  configRevision: 1,
  credentialRevision: 1,
);

class _BlockingSummarizer implements CompactionSummarizer {
  final entered = Completer<void>();
  final release = Completer<void>();
  final _delegate = StructuredCompactionSummarizer();

  @override
  Future<String> summarize({required String prompt}) async {
    if (!entered.isCompleted) entered.complete();
    await release.future;
    return _delegate.summarize(prompt: prompt);
  }
}

class _ThrowingSummarizer implements CompactionSummarizer {
  @override
  Future<String> summarize({required String prompt}) {
    throw StateError('synthetic summarizer failure');
  }
}

class _ThrowingProviderSummarizer
    implements CompactionSummarizer, ProviderProjectionCompactionSummarizer {
  @override
  Future<String> summarize({required String prompt}) async {
    throw StateError('synthetic summarizer failure');
  }

  @override
  Future<CompactionProviderResult> summarizeProvider(
    CompactionProviderRequest request,
  ) async {
    throw const CompactionInvalidProviderResponse(
      'invalid_json_syntax',
      usage: {'input_tokens': 1200, 'output_tokens': 40},
      duration: Duration(milliseconds: 250),
    );
  }
}

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

void main() {
  late AgentStateDatabase state;
  late SessionDB sessions;
  late CompactionBoundaryRepository boundaries;
  late SessionHistoryRevisionRepository revisions;
  late CompactionActivationService activation;
  late CompactionCoordinator coordinator;
  late List<CompactionLifecycleEvent> lifecycle;

  CompactionEngineRequest requestFor({
    required String sessionId,
    required List<IndexedConversationMessage> timeline,
    CompactionTrigger trigger = CompactionTrigger.auto,
    int contextWindowTokens = 3_000,
    int targetRequestTokens = 2_000,
    String? compactionId,
    List<Message>? providerProjection,
  }) {
    final revision = revisions.read(sessionId)!;
    return CompactionEngineRequest(
      compactionId: compactionId ?? 'cmp-coordinator',
      sessionId: sessionId,
      trigger: trigger,
      sourceRevision: revision.toCompactionRevision(),
      routeSignature: _route(),
      contextWindowTokens: contextWindowTokens,
      timeline: timeline,
      systemPrompt: 'system',
      runtimeContext: 'runtime',
      toolSchemas: const [],
      targetRequestTokens: targetRequestTokens,
      providerProjection: providerProjection,
    );
  }

  setUp(() {
    state = AgentStateDatabase.inMemory();
    sessions = SessionDB.fromState(state);
    boundaries = CompactionBoundaryRepository(
      state,
      SessionHistoryRevisionRepository(state),
    );
    revisions = SessionHistoryRevisionRepository(state);
    final projectionRevisions = SessionProjectionRevisionRepository(state);
    activation = CompactionActivationService(
      boundaries: boundaries,
      projectionRevisions: projectionRevisions,
    );
    lifecycle = [];
    coordinator = CompactionCoordinator(
      engine: ContextCompactionEngine(
        summarizer: StructuredCompactionSummarizer(),
      ),
      boundaries: boundaries,
      activation: activation,
      projectionBuilder: ModelProjectionBuilder(
        sessions: sessions,
        boundaries: boundaries,
      ),
      onLifecycleEvent: lifecycle.add,
    );
    final now = DateTime.utc(2026, 8, 29);
    for (final sessionId in ['session-a', 'session-b']) {
      sessions.saveSession(
        SessionState(
          sessionId: sessionId,
          model: 'gpt-4o',
          createdAt: now,
          updatedAt: now,
          lastUserMessageAt: now,
        ),
      );
      sessions.replaceMessages(sessionId, [
        Message(role: MessageRole.user, content: 'goal: retain $sessionId'),
        Message(role: MessageRole.assistant, content: 'ok'),
        Message(role: MessageRole.user, content: 'three'),
      ]);
    }
  });

  tearDown(() {
    sessions.dispose();
    state.dispose();
  });

  test('returns null for auto compaction below pressure threshold', () async {
    final outcome = await coordinator.runCompaction(
      request: requestFor(
        sessionId: 'session-a',
        timeline: [
          IndexedConversationMessage(
            rowId: 1,
            message: Message(role: MessageRole.user, content: 'short'),
          ),
        ],
        contextWindowTokens: 128_000,
        targetRequestTokens: 90_000,
      ),
    );
    expect(outcome, isNull);
    expect(lifecycle, isEmpty);
  });

  test(
    'force manual compaction emits started then completed lifecycle',
    () async {
      sessions.replaceMessages(
        'session-a',
        _heavyTimeline().map((entry) => entry.message).toList(),
      );
      final canonical = ModelProjectionBuilder(
        sessions: sessions,
        boundaries: boundaries,
      ).loadCanonicalTimeline('session-a');
      final outcome = await coordinator.runCompaction(
        request: requestFor(
          sessionId: 'session-a',
          timeline: [
            for (final entry in canonical.messages)
              IndexedConversationMessage(
                rowId: entry.rowId,
                message: entry.message,
              ),
          ],
          trigger: CompactionTrigger.manual,
        ),
        force: true,
      );

      expect(
        outcome?.status,
        CompactionStatus.completed,
        reason: outcome?.failureReason?.wireValue,
      );
      expect(lifecycle.map((e) => e.status), [
        CompactionStatus.started,
        CompactionStatus.completed,
      ]);
      expect(lifecycle.first.trigger, CompactionTrigger.manual);
      expect(lifecycle.first.providerInstanceId, 'provider-1');
      expect(lifecycle.first.modelId, 'gpt-4o');
      expect(lifecycle.last.providerInstanceId, 'provider-1');
      expect(lifecycle.last.modelId, 'gpt-4o');
      expect(boundaries.findLatestCompletedForSession('session-a'), isNotNull);
    },
  );

  test(
    'first provider response persists and republishes confirmed after',
    () async {
      sessions.replaceMessages(
        'session-a',
        _heavyTimeline().map((entry) => entry.message).toList(),
      );
      final canonical = ModelProjectionBuilder(
        sessions: sessions,
        boundaries: boundaries,
      ).loadCanonicalTimeline('session-a');
      final outcome = await coordinator.runCompaction(
        request: requestFor(
          sessionId: 'session-a',
          timeline: [
            for (final entry in canonical.messages)
              IndexedConversationMessage(
                rowId: entry.rowId,
                message: entry.message,
              ),
          ],
          trigger: CompactionTrigger.manual,
        ),
        force: true,
      );

      expect(
        coordinator.reconcileLatestProviderUsage(
          sessionId: 'session-a',
          routeSignature: _route(),
          inputTokens: 1_250,
        ),
        isTrue,
      );
      expect(lifecycle.map((event) => event.status), [
        CompactionStatus.started,
        CompactionStatus.completed,
        CompactionStatus.completed,
      ]);
      expect(lifecycle.last.eventId, lifecycle[1].eventId);
      expect(
        lifecycle.last.metrics?.providerConfirmedRequestTokensAfter,
        1_250,
      );
      expect(
        boundaries
            .findById(outcome!.compactionId)
            ?.metrics
            ?.providerConfirmedRequestTokensAfter,
        1_250,
      );
      expect(
        coordinator.reconcileLatestProviderUsage(
          sessionId: 'session-a',
          routeSignature: _route(),
          inputTokens: 1_500,
        ),
        isFalse,
      );
    },
  );

  test('claims and emits started before awaiting the summarizer', () async {
    sessions.replaceMessages(
      'session-a',
      _heavyTimeline().map((entry) => entry.message).toList(),
    );
    final canonical = ModelProjectionBuilder(
      sessions: sessions,
      boundaries: boundaries,
    ).loadCanonicalTimeline('session-a');
    final summarizer = _BlockingSummarizer();
    final blockingCoordinator = CompactionCoordinator(
      engine: ContextCompactionEngine(summarizer: summarizer),
      boundaries: boundaries,
      activation: CompactionActivationService(
        boundaries: boundaries,
        projectionRevisions: SessionProjectionRevisionRepository(state),
      ),
      projectionBuilder: ModelProjectionBuilder(
        sessions: sessions,
        boundaries: boundaries,
      ),
      onLifecycleEvent: lifecycle.add,
    );

    final pending = blockingCoordinator.runCompaction(
      request: requestFor(
        sessionId: 'session-a',
        timeline: [
          for (final entry in canonical.messages)
            IndexedConversationMessage(
              rowId: entry.rowId,
              message: entry.message,
            ),
        ],
        trigger: CompactionTrigger.manual,
      ),
      force: true,
    );
    await summarizer.entered.future;

    expect(boundaries.findStartedForSession('session-a'), isNotNull);
    expect(lifecycle.map((event) => event.status), [CompactionStatus.started]);

    summarizer.release.complete();
    expect((await pending)?.status, CompactionStatus.completed);
  });

  test('activation failure persists its terminal repository outcome', () async {
    sessions.replaceMessages(
      'session-a',
      _heavyTimeline().map((entry) => entry.message).toList(),
    );
    final canonical = ModelProjectionBuilder(
      sessions: sessions,
      boundaries: boundaries,
    ).loadCanonicalTimeline('session-a');
    final summarizer = _BlockingSummarizer();
    final blockingCoordinator = CompactionCoordinator(
      engine: ContextCompactionEngine(summarizer: summarizer),
      boundaries: boundaries,
      activation: CompactionActivationService(
        boundaries: boundaries,
        projectionRevisions: SessionProjectionRevisionRepository(state),
      ),
      projectionBuilder: ModelProjectionBuilder(
        sessions: sessions,
        boundaries: boundaries,
      ),
      onLifecycleEvent: lifecycle.add,
    );
    final pending = blockingCoordinator.runCompaction(
      request: requestFor(
        sessionId: 'session-a',
        timeline: [
          for (final entry in canonical.messages)
            IndexedConversationMessage(
              rowId: entry.rowId,
              message: entry.message,
            ),
        ],
      ),
      force: true,
    );
    await summarizer.entered.future;
    SessionHistoryRevisionRepository.bumpDatabase(state.db, 'session-a');
    summarizer.release.complete();

    final outcome = await pending;
    final persisted = boundaries.findById(outcome!.compactionId);
    expect(outcome.failureReason, CompactionFailureReason.persistenceFailed);
    expect(outcome.failureStage, CompactionFailureStage.persistence);
    expect(outcome.failureCause, CompactionFailureCause.sourceRevisionStale);
    expect(persisted?.failureDetailJson, contains('sourceRevisionStale'));
    expect(persisted?.failureStage, CompactionFailureStage.persistence);
    expect(persisted?.failureCause, CompactionFailureCause.sourceRevisionStale);
  });

  test('summarizer failure closes the early claim as typed failed', () async {
    sessions.replaceMessages(
      'session-a',
      _heavyTimeline().map((entry) => entry.message).toList(),
    );
    final canonical = ModelProjectionBuilder(
      sessions: sessions,
      boundaries: boundaries,
    ).loadCanonicalTimeline('session-a');
    final failingCoordinator = CompactionCoordinator(
      engine: ContextCompactionEngine(summarizer: _ThrowingSummarizer()),
      boundaries: boundaries,
      activation: CompactionActivationService(
        boundaries: boundaries,
        projectionRevisions: SessionProjectionRevisionRepository(state),
      ),
      projectionBuilder: ModelProjectionBuilder(
        sessions: sessions,
        boundaries: boundaries,
      ),
      onLifecycleEvent: lifecycle.add,
    );

    final outcome = await failingCoordinator.runCompaction(
      request: requestFor(
        sessionId: 'session-a',
        timeline: [
          for (final entry in canonical.messages)
            IndexedConversationMessage(
              rowId: entry.rowId,
              message: entry.message,
            ),
        ],
        trigger: CompactionTrigger.manual,
      ),
      force: true,
    );

    expect(outcome?.status, CompactionStatus.failed);
    expect(outcome?.failureReason, CompactionFailureReason.summarizationFailed);
    expect(boundaries.findStartedForSession('session-a'), isNull);
    expect(lifecycle.map((event) => event.status), [
      CompactionStatus.started,
      CompactionStatus.failed,
    ]);
  });

  test(
    'concurrent claim returns compactionInProgress without second started event',
    () async {
      boundaries.tryClaim(
        compactionId: 'cmp-in-flight',
        sessionId: 'session-a',
        trigger: CompactionTrigger.auto,
        sourceRange: CompactionMessageRange(
          start: const CompactionMessageIdentity(1),
          end: const CompactionMessageIdentity(1),
        ),
        retainedTailRange: CompactionMessageRange(
          start: const CompactionMessageIdentity(2),
          end: const CompactionMessageIdentity(3),
        ),
        routeSignature: _route(),
        startedAt: DateTime.utc(2026, 8, 29),
      );

      final outcome = await coordinator.runCompaction(
        request: requestFor(sessionId: 'session-a', timeline: _heavyTimeline()),
        force: true,
      );

      expect(outcome?.status, CompactionStatus.failed);
      expect(
        outcome?.failureReason,
        CompactionFailureReason.compactionInProgress,
      );
      expect(lifecycle, isEmpty);
    },
  );

  test('session B boundary is unaffected by session A compaction', () async {
    sessions.replaceMessages(
      'session-a',
      _heavyTimeline().map((entry) => entry.message).toList(),
    );
    final canonical = ModelProjectionBuilder(
      sessions: sessions,
      boundaries: boundaries,
    ).loadCanonicalTimeline('session-a');
    await coordinator.runCompaction(
      request: requestFor(
        sessionId: 'session-a',
        timeline: [
          for (final entry in canonical.messages)
            IndexedConversationMessage(
              rowId: entry.rowId,
              message: entry.message,
            ),
        ],
        trigger: CompactionTrigger.manual,
      ),
      force: true,
    );

    expect(boundaries.findLatestCompletedForSession('session-a'), isNotNull);
    expect(boundaries.findLatestCompletedForSession('session-b'), isNull);
    expect(boundaries.findStartedForSession('session-b'), isNull);
  });

  test('exact post-boundary binding binds to exact compactionId and preserves receipt against later growth', () async {
    sessions.replaceMessages(
      'session-a',
      _heavyTimeline().map((entry) => entry.message).toList(),
    );
    final canonical = ModelProjectionBuilder(
      sessions: sessions,
      boundaries: boundaries,
    ).loadCanonicalTimeline('session-a');
    final outcome = await coordinator.runCompaction(
      request: requestFor(
        sessionId: 'session-a',
        timeline: [
          for (final entry in canonical.messages)
            IndexedConversationMessage(
              rowId: entry.rowId,
              message: entry.message,
            ),
        ],
        trigger: CompactionTrigger.manual,
        contextWindowTokens: 100_000,
      ),
      force: true,
    );
    expect(outcome?.status, CompactionStatus.completed);

    final observedAt = DateTime.utc(2026, 8, 29, 3, 0);

    // Unreserved attempt fails closed
    final unreserved = coordinator.reconcilePostBoundaryUsage(
      compactionId: outcome!.compactionId,
      requestId: 'req-first-call',
      observedAt: observedAt,
      inputTokens: 1_250,
      cachedTokens: 300,
      routeSignature: _route(),
    );
    expect(unreserved, isFalse);

    // Reserve first dispatched call
    final reserved = coordinator.reservePostBoundaryDispatch(
      compactionId: outcome.compactionId,
      requestId: 'req-first-call',
      routeSignature: _route(),
      dispatchedAt: observedAt,
    );
    expect(reserved, isTrue);

    // Exact reconciliation succeeds
    final ok = coordinator.reconcilePostBoundaryUsage(
      compactionId: outcome.compactionId,
      requestId: 'req-first-call',
      observedAt: observedAt,
      inputTokens: 1_250,
      cachedTokens: 300,
      routeSignature: _route(),
    );
    expect(ok, isTrue);

    final record = boundaries.findById(outcome.compactionId);
    expect(record?.metrics?.providerConfirmedRequestTokensAfter, 1_250);
    expect(record?.diagnostics?.postBoundary.status, 'confirmed');
    expect(record?.diagnostics?.postBoundary.targetOutcome, TargetOutcome.unknown);
    expect(record?.diagnostics?.postBoundary.requestId, 'req-first-call');
    expect(record?.diagnostics?.postBoundary.cachedTokens, 300);

    // Later growth turn must NOT overwrite the first-call receipt
    coordinator.reconcilePostBoundaryUsage(
      compactionId: outcome.compactionId,
      requestId: 'req-later-grown-turn',
      observedAt: DateTime.utc(2026, 8, 29, 3, 5),
      inputTokens: 45_000,
      cachedTokens: 1_000,
      routeSignature: _route(),
    );

    final recordAfterGrowth = boundaries.findById(outcome.compactionId);
    expect(recordAfterGrowth?.metrics?.providerConfirmedRequestTokensAfter, 1_250);
    expect(recordAfterGrowth?.diagnostics?.postBoundary.requestId, 'req-first-call');
  });

  test('recordPostBoundaryMissingUsage marks status missing on exact compactionId', () async {
    sessions.replaceMessages(
      'session-a',
      _heavyTimeline().map((entry) => entry.message).toList(),
    );
    final canonical = ModelProjectionBuilder(
      sessions: sessions,
      boundaries: boundaries,
    ).loadCanonicalTimeline('session-a');
    final outcome = await coordinator.runCompaction(
      request: requestFor(
        sessionId: 'session-a',
        timeline: [
          for (final entry in canonical.messages)
            IndexedConversationMessage(
              rowId: entry.rowId,
              message: entry.message,
            ),
        ],
        trigger: CompactionTrigger.manual,
      ),
      force: true,
    );
    expect(outcome?.status, CompactionStatus.completed);

    final observedAt = DateTime.utc(2026, 8, 29, 3, 0);

    // Unreserved call fails closed
    final unreserved = coordinator.recordPostBoundaryMissingUsage(
      compactionId: outcome!.compactionId,
      requestId: 'req-missing-provider',
      observedAt: observedAt,
      missingReason: 'no_provider_usage',
      routeSignature: _route(),
    );
    expect(unreserved, isFalse);

    // Reserve dispatch
    final reserved = coordinator.reservePostBoundaryDispatch(
      compactionId: outcome.compactionId,
      requestId: 'req-missing-provider',
      routeSignature: _route(),
      dispatchedAt: observedAt,
    );
    expect(reserved, isTrue);

    final ok = coordinator.recordPostBoundaryMissingUsage(
      compactionId: outcome.compactionId,
      requestId: 'req-missing-provider',
      observedAt: observedAt,
      missingReason: 'no_provider_usage',
      routeSignature: _route(),
    );
    expect(ok, isTrue);

    final record = boundaries.findById(outcome.compactionId);
    expect(record?.metrics?.providerConfirmedRequestTokensAfter, isNull);
    expect(record?.diagnostics?.postBoundary.status, 'missing');
    expect(record?.diagnostics?.postBoundary.missingReason, 'no_provider_usage');
    expect(record?.diagnostics?.postBoundary.targetOutcome, TargetOutcome.unknown);
  });

  test('exact post-boundary binding binds strictly to targeted compactionId and prevents unsafe opportunistic scan across multiple compactions', () async {
    final now = DateTime.utc(2026, 8, 29);
    sessions.saveSession(
      SessionState(
        sessionId: 'session-multi',
        model: 'gpt-4o',
        createdAt: now,
        updatedAt: now,
        lastUserMessageAt: now,
      ),
    );
    sessions.replaceMessages(
      'session-multi',
      _heavyTimeline().map((entry) => entry.message).toList(),
    );
    final canonical = ModelProjectionBuilder(
      sessions: sessions,
      boundaries: boundaries,
    ).loadCanonicalTimeline('session-multi');

    // Run first compaction (older)
    final outcome1 = await coordinator.runCompaction(
      request: requestFor(
        sessionId: 'session-multi',
        compactionId: 'cmp-multi-1',
        timeline: [
          for (final entry in canonical.messages)
            IndexedConversationMessage(
              rowId: entry.rowId,
              message: entry.message,
            ),
        ],
        trigger: CompactionTrigger.manual,
        contextWindowTokens: 100_000,
      ),
      force: true,
    );
    expect(outcome1?.status, CompactionStatus.completed);

    sessions.replaceMessages('session-multi', [
      ..._heavyTimeline().map((entry) => entry.message),
      Message(role: MessageRole.user, content: 'continuation 1: ${"x" * 2000}'),
      Message(role: MessageRole.assistant, content: 'continuation 2: ${"y" * 2000}'),
    ]);
    final canonical2 = ModelProjectionBuilder(
      sessions: sessions,
      boundaries: boundaries,
    ).loadCanonicalTimeline('session-multi');

    // Run second compaction (newer)
    final outcome2 = await coordinator.runCompaction(
      request: requestFor(
        sessionId: 'session-multi',
        compactionId: 'cmp-multi-2',
        timeline: [
          for (final entry in canonical2.messages)
            IndexedConversationMessage(
              rowId: entry.rowId,
              message: entry.message,
            ),
        ],
        trigger: CompactionTrigger.manual,
        contextWindowTokens: 100_000,
      ),
      force: true,
    );
    expect(outcome2?.status, CompactionStatus.completed);

    // Both compactions exist and have pending post-boundary status
    final initial1 = boundaries.findById(outcome1!.compactionId);
    final initial2 = boundaries.findById(outcome2!.compactionId);
    expect(initial1?.metrics?.providerConfirmedRequestTokensAfter, isNull);
    expect(initial2?.metrics?.providerConfirmedRequestTokensAfter, isNull);
    expect(initial1?.diagnostics?.postBoundary.status, 'pending');
    expect(initial2?.diagnostics?.postBoundary.status, 'pending');

    // Exact post-boundary call targeting outcome2 with 19182 provider-confirmed tokens
    final reserved = coordinator.reservePostBoundaryDispatch(
      compactionId: outcome2.compactionId,
      requestId: 'req-multi-continuation',
      routeSignature: _route(),
      dispatchedAt: DateTime.utc(2026, 8, 29, 3, 30),
    );
    expect(reserved, isTrue);

    final ok = coordinator.reconcilePostBoundaryUsage(
      compactionId: outcome2.compactionId,
      requestId: 'req-multi-continuation',
      observedAt: DateTime.utc(2026, 8, 29, 3, 30),
      inputTokens: 19_182,
      cachedTokens: 2_500,
      routeSignature: _route(),
    );
    expect(ok, isTrue);

    // outcome2 is confirmed with 19182
    final record2 = boundaries.findById(outcome2.compactionId);
    expect(record2?.metrics?.providerConfirmedRequestTokensAfter, 19_182);
    expect(record2?.diagnostics?.postBoundary.status, 'confirmed');
    expect(record2?.diagnostics?.postBoundary.requestId, 'req-multi-continuation');

    // outcome1 remains strictly pending — NOT opportunistically stolen by first-null route scan
    final record1 = boundaries.findById(outcome1.compactionId);
    expect(record1?.metrics?.providerConfirmedRequestTokensAfter, isNull);
    expect(record1?.diagnostics?.postBoundary.status, 'pending');
  });

  test('coordinator reserves dispatch and prevents subsequent steps from overwriting reservation', () async {
    final now = DateTime.utc(2026, 8, 29);
    sessions.saveSession(
      SessionState(
        sessionId: 'session-dispatch-reserve',
        model: 'gpt-4o',
        createdAt: now,
        updatedAt: now,
        lastUserMessageAt: now,
      ),
    );
    sessions.replaceMessages(
      'session-dispatch-reserve',
      [
        ..._heavyTimeline().map((entry) => entry.message),
      ],
    );
    final canonical = ModelProjectionBuilder(
      sessions: sessions,
      boundaries: boundaries,
    ).loadCanonicalTimeline('session-dispatch-reserve');
    final outcome = await coordinator.runCompaction(
      request: requestFor(
        sessionId: 'session-dispatch-reserve',
        compactionId: 'cmp-dispatch-reserve',
        timeline: [
          for (final entry in canonical.messages)
            IndexedConversationMessage(
              rowId: entry.rowId,
              message: entry.message,
            ),
        ],
        trigger: CompactionTrigger.auto,
        contextWindowTokens: 100_000,
      ),
      force: true,
    );
    expect(outcome?.status, CompactionStatus.completed);

    final reserved = coordinator.reservePostBoundaryDispatch(
      compactionId: outcome!.compactionId,
      requestId: 'turn-reserve:step-1',
      routeSignature: _route(),
      dispatchedAt: DateTime.utc(2026, 8, 29, 3, 1),
    );
    expect(reserved, isTrue);

    final boundaryRecord = boundaries.findById(outcome.compactionId);
    expect(boundaryRecord?.diagnostics?.postBoundary.status, 'reserved');
    expect(boundaryRecord?.diagnostics?.postBoundary.requestId, 'turn-reserve:step-1');

    // A second dispatch on step-2 is reserved (retaining the first reservation)
    final secondReserved = coordinator.reservePostBoundaryDispatch(
      compactionId: outcome.compactionId,
      requestId: 'turn-reserve:step-2',
      routeSignature: _route(),
      dispatchedAt: DateTime.utc(2026, 8, 29, 3, 2),
    );
    expect(secondReserved, isTrue);
    final boundaryRecordAfterSecond = boundaries.findById(outcome.compactionId);
    expect(boundaryRecordAfterSecond?.diagnostics?.postBoundary.requestId, 'turn-reserve:step-1');

    // Arriving usage for step-2 cannot overwrite reserved step-1
    final step2Reconcile = coordinator.reconcilePostBoundaryUsage(
      compactionId: outcome.compactionId,
      requestId: 'turn-reserve:step-2',
      observedAt: DateTime.utc(2026, 8, 29, 3, 3),
      inputTokens: 25_000,
      routeSignature: _route(),
    );
    expect(step2Reconcile, isFalse);

    // Arriving usage for step-1 successfully reconciles
    final step1Reconcile = coordinator.reconcilePostBoundaryUsage(
      compactionId: outcome.compactionId,
      requestId: 'turn-reserve:step-1',
      observedAt: DateTime.utc(2026, 8, 29, 3, 4),
      inputTokens: 12_500,
      routeSignature: _route(),
    );
    expect(step1Reconcile, isTrue);
    final confirmedRecord = boundaries.findById(outcome.compactionId);
    expect(confirmedRecord?.diagnostics?.postBoundary.status, 'confirmed');
    expect(confirmedRecord?.metrics?.providerConfirmedRequestTokensAfter, 12_500);
  });

  test('failed compaction run preserves attempt ledger and decision snapshot into session_compaction_operations', () async {
    final failingEngine = ContextCompactionEngine(
      summarizer: _ThrowingProviderSummarizer(),
    );
    final failingCoordinator = CompactionCoordinator(
      engine: failingEngine,
      boundaries: boundaries,
      activation: activation,
      projectionBuilder: ModelProjectionBuilder(
        sessions: sessions,
        boundaries: boundaries,
      ),
    );

    final now = DateTime.utc(2026, 8, 29);
    sessions.saveSession(
      SessionState(
        sessionId: 'session-fail-durability',
        model: 'gpt-4o',
        createdAt: now,
        updatedAt: now,
        lastUserMessageAt: now,
      ),
    );
    sessions.replaceMessages(
      'session-fail-durability',
      [
        ..._heavyTimeline().map((entry) => entry.message),
      ],
    );
    final canonical = ModelProjectionBuilder(
      sessions: sessions,
      boundaries: boundaries,
    ).loadCanonicalTimeline('session-fail-durability');
    final outcome = await failingCoordinator.runCompaction(
      request: requestFor(
        sessionId: 'session-fail-durability',
        compactionId: 'cmp-fail-durability-test',
        timeline: [
          for (final entry in canonical.messages)
            IndexedConversationMessage(
              rowId: entry.rowId,
              message: entry.message,
            ),
        ],
        trigger: CompactionTrigger.auto,
        contextWindowTokens: 100_000,
        providerProjection: [
          for (final entry in canonical.messages) entry.message,
        ],
      ),
      force: true,
    );
    expect(outcome?.status, CompactionStatus.failed);

    final record = boundaries.findById('cmp-fail-durability-test');
    expect(record, isNotNull);
    expect(record!.status, CompactionStatus.failed);
    expect(record.diagnostics, isNotNull);
    expect(record.diagnostics!.attempts, isNotEmpty);
    expect(record.diagnostics!.attempts.first.outcome, 'invalid_response');
    expect(record.diagnostics!.attempts.first.inputTokens, 1200);
    expect(record.diagnostics!.decisionSnapshot?['target_scope'], 'usable_budget');
    expect(record.diagnostics!.decisionSnapshot?['context_window'], 100_000);
  });
}
