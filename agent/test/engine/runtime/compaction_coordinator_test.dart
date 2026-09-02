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
  late CompactionCoordinator coordinator;
  late List<CompactionLifecycleEvent> lifecycle;

  CompactionEngineRequest requestFor({
    required String sessionId,
    required List<IndexedConversationMessage> timeline,
    CompactionTrigger trigger = CompactionTrigger.auto,
    int contextWindowTokens = 3_000,
    int targetRequestTokens = 2_000,
  }) {
    final revision = revisions.read(sessionId)!;
    return CompactionEngineRequest(
      compactionId: 'cmp-coordinator',
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
    final activation = CompactionActivationService(
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
    expect(persisted?.failureDetailJson, contains('sourceRevisionStale'));
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
}
