import 'package:logging/logging.dart';
import 'package:sanad_agent/core/agent_runtime_service.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/models/tool_call.dart';
import 'package:sanad_agent/engine/compaction/compaction.dart';
import 'package:sanad_agent/evolution/compaction/compaction_summary_projection.dart';
import 'package:sanad_agent/evolution/compaction/model_projection_builder.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/compaction_boundary_repository.dart';
import 'package:sanad_agent/evolution/db/session_db.dart';
import 'package:sanad_agent/evolution/db/session_history_revision_repository.dart';
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

void main() {
  late AgentStateDatabase state;
  late SessionDB sessions;
  late CompactionBoundaryRepository boundaries;
  late ModelProjectionBuilder builder;

  setUp(() {
    ModelProjectionBuilder.resetLoggedInvalidations();
    state = AgentStateDatabase.inMemory();
    sessions = SessionDB.fromState(state);
    boundaries = CompactionBoundaryRepository(
      state,
      SessionHistoryRevisionRepository(state),
    );
    builder = ModelProjectionBuilder(
      sessions: sessions,
      boundaries: boundaries,
    );
    final now = DateTime.utc(2026, 8, 29);
    sessions.saveSession(
      SessionState(
        sessionId: 'session-1',
        model: 'gpt-4o',
        createdAt: now,
        updatedAt: now,
        lastUserMessageAt: now,
      ),
    );
  });

  tearDown(() {
    sessions.dispose();
    state.dispose();
  });

  test('without boundary projection returns full canonical history', () {
    sessions.replaceMessages('session-1', [
      Message(role: MessageRole.user, content: 'hello'),
      Message(role: MessageRole.assistant, content: 'hi'),
    ]);

    final projection = builder.buildForSession('session-1');
    expect(projection.usesCompactionBoundary, isFalse);
    expect(projection.conversationMessages, hasLength(2));
    expect(projection.conversationMessages.first.content, 'hello');
  });

  test(
    'with boundary projection returns summary user message tail and post rows',
    () {
      final canonical = [
        Message(role: MessageRole.user, content: 'old-1'),
        Message(role: MessageRole.user, content: 'old-2'),
        Message(role: MessageRole.assistant, content: 'tail-1'),
        Message(role: MessageRole.user, content: 'tail-2'),
        Message(role: MessageRole.user, content: 'after-boundary'),
      ];
      sessions.replaceMessages('session-1', canonical);

      final startedAt = DateTime.utc(2026, 8, 29, 1);
      boundaries.tryClaim(
        compactionId: 'cmp-1',
        sessionId: 'session-1',
        trigger: CompactionTrigger.auto,
        sourceRange: CompactionMessageRange(
          start: const CompactionMessageIdentity(1),
          end: const CompactionMessageIdentity(2),
        ),
        retainedTailRange: CompactionMessageRange(
          start: const CompactionMessageIdentity(3),
          end: const CompactionMessageIdentity(4),
        ),
        routeSignature: _route(),
        startedAt: startedAt,
      );
      const summary = CompactionInternalSummary(
        currentGoal: 'Finish feature',
        remainingWork: 'Run tests',
      );
      boundaries.completeStarted(
        candidate: CompactionCandidate(
          compactionId: 'cmp-1',
          sessionId: 'session-1',
          trigger: CompactionTrigger.auto,
          sourceRevision: const CompactionHistoryRevision(1),
          sourceRange: CompactionMessageRange(
            start: const CompactionMessageIdentity(1),
            end: const CompactionMessageIdentity(2),
          ),
          retainedTailRange: CompactionMessageRange(
            start: const CompactionMessageIdentity(3),
            end: const CompactionMessageIdentity(4),
          ),
          internalSummary: summary,
          continuityResult: CompactionContinuityResult.fromSummary(summary),
          metrics: CompactionMetrics(
            contextWindowTokens: 100_000,
            estimatedRequestTokensBefore: 80_000,
            estimatedRequestTokensAfter: 20_000,
            retainedTailTokens: 5_000,
          ),
          routeSignature: _route(),
        ),
        startedAt: startedAt,
        completedAt: DateTime.utc(2026, 8, 29, 2),
      );

      final projection = builder.buildForSession('session-1');
      expect(projection.usesCompactionBoundary, isTrue);
      expect(projection.conversationMessages, hasLength(4));
      expect(projection.conversationMessages.first.role, MessageRole.user);
      expect(
        projection
            .conversationMessages
            .first
            .metadata?[CompactionSummaryProjection.projectionMetadataKey],
        isTrue,
      );
      expect(
        projection.conversationMessages.first.content,
        contains('Finish feature'),
      );
      expect(
        projection.conversationMessages.any(
          (m) => m.content == 'after-boundary',
        ),
        isTrue,
      );
      expect(
        projection.conversationMessages.any(
          (m) => m.role == MessageRole.system,
        ),
        isFalse,
      );

      final rowIdsBefore = builder
          .loadCanonicalTimeline('session-1')
          .messages
          .map((entry) => entry.rowId)
          .toList();
      sessions.replaceMessages('session-1', [
        ...canonical,
        Message(role: MessageRole.user, content: 'new turn'),
      ]);
      final timelineAfter = builder.loadCanonicalTimeline('session-1');
      expect(
        timelineAfter.messages
            .take(rowIdsBefore.length)
            .map((entry) => entry.rowId),
        rowIdsBefore,
      );
      final projectionAfter = builder.buildForSession('session-1');
      expect(projectionAfter.activeBoundary?.compactionId, 'cmp-1');
      expect(projectionAfter.conversationMessages.last.content, 'new turn');

      sessions.replaceMessages('session-1', [
        canonical[0],
        canonical[1],
        canonical[2],
        Message(role: MessageRole.user, content: 'tail-2 recovered'),
        canonical[4],
        Message(role: MessageRole.user, content: 'new turn'),
      ]);
      final rewrittenProjection = builder.buildForSession('session-1');
      expect(rewrittenProjection.activeBoundary?.compactionId, 'cmp-1');
      expect(
        rewrittenProjection.conversationMessages.map(
          (message) => message.content,
        ),
        containsAllInOrder([
          'tail-1',
          'tail-2 recovered',
          'after-boundary',
          'new turn',
        ]),
      );
    },
  );

  test('projection walks session rows instead of numeric ids across gaps', () {
    sessions.replaceMessages('session-1', [
      Message(role: MessageRole.user, content: 'old-1'),
      Message(role: MessageRole.user, content: 'old-2'),
      Message(role: MessageRole.assistant, content: 'tail-1'),
      Message(role: MessageRole.user, content: 'tail-2'),
      Message(role: MessageRole.user, content: 'after'),
    ]);
    sessions.replaceMessages('session-1', [
      Message(role: MessageRole.user, content: 'old-1'),
      Message(role: MessageRole.user, content: 'old-2 edited'),
      Message(role: MessageRole.assistant, content: 'tail-1 edited'),
      Message(role: MessageRole.user, content: 'tail-2 edited'),
      Message(role: MessageRole.user, content: 'after edited'),
    ]);
    final timeline = builder.loadCanonicalTimeline('session-1').messages;
    expect(timeline.map((entry) => entry.rowId), [1, 6, 7, 8, 9]);
    final source = CompactionMessageRange(
      start: CompactionMessageIdentity(timeline[0].rowId),
      end: CompactionMessageIdentity(timeline[1].rowId),
    );
    final tail = CompactionMessageRange(
      start: CompactionMessageIdentity(timeline[2].rowId),
      end: CompactionMessageIdentity(timeline[3].rowId),
    );
    final startedAt = DateTime.utc(2026, 8, 29, 1);
    final claim = boundaries.tryClaim(
      compactionId: 'cmp-gapped-projection',
      sessionId: 'session-1',
      trigger: CompactionTrigger.auto,
      sourceRange: source,
      retainedTailRange: tail,
      routeSignature: _route(),
      startedAt: startedAt,
    );
    const summary = CompactionInternalSummary(
      currentGoal: 'Project gapped rows',
      remainingWork: 'Continue',
    );
    final completed = boundaries.completeStarted(
      candidate: CompactionCandidate(
        compactionId: 'cmp-gapped-projection',
        sessionId: 'session-1',
        trigger: CompactionTrigger.auto,
        sourceRevision: claim.record!.sourceHistoryRevision,
        sourceRange: source,
        retainedTailRange: tail,
        internalSummary: summary,
        continuityResult: CompactionContinuityResult.fromSummary(summary),
        metrics: CompactionMetrics(
          contextWindowTokens: 400_000,
          estimatedRequestTokensBefore: 320_000,
          estimatedRequestTokensAfter: 40_000,
          retainedTailTokens: 10_000,
        ),
        routeSignature: _route(),
      ),
      startedAt: startedAt,
      completedAt: DateTime.utc(2026, 8, 29, 2),
    );
    expect(completed.outcome, CompactionTerminalOutcome.completed);

    final projection = builder.buildForSession('session-1');
    expect(
      projection.conversationMessages.map((message) => message.content),
      containsAllInOrder(['tail-1 edited', 'tail-2 edited', 'after edited']),
    );
  });

  test('reload builds identical projection from storage only', () {
    sessions.replaceMessages('session-1', [
      Message(role: MessageRole.user, content: 'one'),
      Message(role: MessageRole.assistant, content: 'two'),
      Message(role: MessageRole.user, content: 'three'),
    ]);
    final startedAt = DateTime.utc(2026, 8, 29);
    boundaries.tryClaim(
      compactionId: 'cmp-reload',
      sessionId: 'session-1',
      trigger: CompactionTrigger.manual,
      sourceRange: CompactionMessageRange(
        start: const CompactionMessageIdentity(1),
        end: const CompactionMessageIdentity(1),
      ),
      retainedTailRange: CompactionMessageRange(
        start: const CompactionMessageIdentity(2),
        end: const CompactionMessageIdentity(3),
      ),
      routeSignature: _route(),
      startedAt: startedAt,
    );
    const summary = CompactionInternalSummary(
      currentGoal: 'Goal',
      remainingWork: 'Next',
    );
    boundaries.completeStarted(
      candidate: CompactionCandidate(
        compactionId: 'cmp-reload',
        sessionId: 'session-1',
        trigger: CompactionTrigger.manual,
        sourceRevision: const CompactionHistoryRevision(1),
        sourceRange: CompactionMessageRange(
          start: const CompactionMessageIdentity(1),
          end: const CompactionMessageIdentity(1),
        ),
        retainedTailRange: CompactionMessageRange(
          start: const CompactionMessageIdentity(2),
          end: const CompactionMessageIdentity(3),
        ),
        internalSummary: summary,
        continuityResult: CompactionContinuityResult.fromSummary(summary),
        metrics: CompactionMetrics(
          contextWindowTokens: 10_000,
          estimatedRequestTokensBefore: 8_000,
          estimatedRequestTokensAfter: 2_000,
          retainedTailTokens: 500,
        ),
        routeSignature: _route(),
      ),
      startedAt: startedAt,
      completedAt: DateTime.utc(2026, 8, 29, 1),
    );

    final first = builder.buildForSession('session-1');
    final second = ModelProjectionBuilder(
      sessions: SessionDB.fromState(state),
      boundaries: CompactionBoundaryRepository(
        state,
        SessionHistoryRevisionRepository(state),
      ),
    ).buildForSession('session-1');

    expect(
      second.conversationMessages.length,
      first.conversationMessages.length,
    );
    expect(
      second.conversationMessages.last.content,
      first.conversationMessages.last.content,
    );
  });

  test('rewritten retained-tail end projects the replacement suffix', () {
    sessions.replaceMessages('session-1', [
      Message(role: MessageRole.user, content: 'one'),
      Message(role: MessageRole.user, content: 'two'),
    ]);
    state.db.execute(
      '''
      INSERT INTO session_compaction_operations (
        compaction_id, session_id, trigger, status,
        source_history_revision,
        source_start_message_id, source_end_message_id,
        tail_start_message_id, tail_end_message_id,
        provider_instance_id, model_id, template_id, protocol,
        normalized_base_url, config_revision, credential_revision,
        context_window_tokens, estimated_request_tokens_before,
        estimated_request_tokens_after, retained_tail_tokens,
        internal_summary_json, started_at, completed_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ''',
      [
        'cmp-bad',
        'session-1',
        CompactionTrigger.auto.wireValue,
        CompactionStatus.completed.wireValue,
        1,
        1,
        1,
        2,
        4,
        'provider-1',
        'gpt-4o',
        'openai',
        'openai_compatible',
        'https://api.example.com/v1',
        1,
        1,
        10_000,
        8_000,
        2_000,
        500,
        '{"currentGoal":"Goal","remainingWork":"Next"}',
        DateTime.utc(2026, 8, 29).toIso8601String(),
        DateTime.utc(2026, 8, 29, 1).toIso8601String(),
      ],
    );

    final projection = builder.buildForSession('session-1');
    expect(projection.usesCompactionBoundary, isTrue);
    expect(
      projection.conversationMessages.map((message) => message.content),
      containsAllInOrder(['two']),
    );
  });

  test('preserves tool call and tool result pairs inside retained tail', () {
    sessions.replaceMessages('session-1', [
      Message(role: MessageRole.user, content: 'run tool'),
      Message(
        role: MessageRole.assistant,
        content: '',
        toolCalls: [
          ToolCall(
            id: 'tool-1',
            name: 'read_file',
            arguments: {'path': 'a.txt'},
          ),
        ],
      ),
      Message(
        role: MessageRole.tool,
        content: 'file contents',
        toolCallId: 'tool-1',
      ),
      Message(role: MessageRole.user, content: 'thanks'),
    ]);

    final startedAt = DateTime.utc(2026, 8, 29);
    boundaries.tryClaim(
      compactionId: 'cmp-tool',
      sessionId: 'session-1',
      trigger: CompactionTrigger.auto,
      sourceRange: CompactionMessageRange(
        start: const CompactionMessageIdentity(1),
        end: const CompactionMessageIdentity(1),
      ),
      retainedTailRange: CompactionMessageRange(
        start: const CompactionMessageIdentity(2),
        end: const CompactionMessageIdentity(4),
      ),
      routeSignature: _route(),
      startedAt: startedAt,
    );
    const summary = CompactionInternalSummary(
      currentGoal: 'Use tool output',
      remainingWork: 'Respond',
    );
    boundaries.completeStarted(
      candidate: CompactionCandidate(
        compactionId: 'cmp-tool',
        sessionId: 'session-1',
        trigger: CompactionTrigger.auto,
        sourceRevision: const CompactionHistoryRevision(1),
        sourceRange: CompactionMessageRange(
          start: const CompactionMessageIdentity(1),
          end: const CompactionMessageIdentity(1),
        ),
        retainedTailRange: CompactionMessageRange(
          start: const CompactionMessageIdentity(2),
          end: const CompactionMessageIdentity(4),
        ),
        internalSummary: summary,
        continuityResult: CompactionContinuityResult.fromSummary(summary),
        metrics: CompactionMetrics(
          contextWindowTokens: 10_000,
          estimatedRequestTokensBefore: 8_000,
          estimatedRequestTokensAfter: 2_000,
          retainedTailTokens: 500,
        ),
        routeSignature: _route(),
      ),
      startedAt: startedAt,
      completedAt: DateTime.utc(2026, 8, 29, 1),
    );

    final projection = builder.buildForSession('session-1');
    final toolResult = projection.conversationMessages.where(
      (message) => message.role == MessageRole.tool,
    );
    expect(toolResult, hasLength(1));
    expect(toolResult.first.toolCallId, 'tool-1');
  });

  test('rejects boundary whose tail starts inside a tool batch', () {
    sessions.replaceMessages('session-1', [
      Message(role: MessageRole.user, content: 'run tools'),
      Message(
        role: MessageRole.assistant,
        toolCalls: [
          ToolCall(id: 'tool-1', name: 'read_file', arguments: const {}),
          ToolCall(id: 'tool-2', name: 'search', arguments: const {}),
          ToolCall(id: 'tool-3', name: 'write_file', arguments: const {}),
        ],
      ),
      for (final id in const ['tool-1', 'tool-2', 'tool-3'])
        Message(role: MessageRole.tool, content: id, toolCallId: id),
      Message(role: MessageRole.user, content: 'continue'),
    ]);

    final startedAt = DateTime.utc(2026, 8, 30);
    final source = CompactionMessageRange(
      start: const CompactionMessageIdentity(1),
      end: const CompactionMessageIdentity(2),
    );
    final tail = CompactionMessageRange(
      start: const CompactionMessageIdentity(3),
      end: const CompactionMessageIdentity(6),
    );
    boundaries.tryClaim(
      compactionId: 'cmp-orphaned-tool-results',
      sessionId: 'session-1',
      trigger: CompactionTrigger.auto,
      sourceRange: source,
      retainedTailRange: tail,
      routeSignature: _route(),
      startedAt: startedAt,
    );
    const summary = CompactionInternalSummary(
      currentGoal: 'Continue safely',
      remainingWork: 'Send the next request',
    );
    boundaries.completeStarted(
      candidate: CompactionCandidate(
        compactionId: 'cmp-orphaned-tool-results',
        sessionId: 'session-1',
        trigger: CompactionTrigger.auto,
        sourceRevision: const CompactionHistoryRevision(1),
        sourceRange: source,
        retainedTailRange: tail,
        internalSummary: summary,
        continuityResult: CompactionContinuityResult.fromSummary(summary),
        metrics: CompactionMetrics(
          contextWindowTokens: 10_000,
          estimatedRequestTokensBefore: 8_000,
          estimatedRequestTokensAfter: 2_000,
          retainedTailTokens: 500,
        ),
        routeSignature: _route(),
      ),
      startedAt: startedAt,
      completedAt: startedAt.add(const Duration(seconds: 1)),
    );

    final projection = builder.buildForSession('session-1');

    expect(projection.usesCompactionBoundary, isFalse);
    expect(projection.conversationMessages, hasLength(6));
    expect(
      projection.conversationMessages.where(
        (message) => message.role == MessageRole.tool,
      ),
      hasLength(3),
    );
  });

  test('uses newest eligible boundary and keeps single summary anchor', () {
    sessions.replaceMessages('session-1', [
      Message(role: MessageRole.user, content: 'm1'),
      Message(role: MessageRole.user, content: 'm2'),
      Message(role: MessageRole.user, content: 'm3'),
      Message(role: MessageRole.user, content: 'm4'),
    ]);

    Future<void> completeBoundary({
      required String id,
      required CompactionMessageRange source,
      required CompactionMessageRange tail,
      required String goal,
      required DateTime completedAt,
    }) async {
      final startedAt = completedAt.subtract(const Duration(minutes: 1));
      boundaries.tryClaim(
        compactionId: id,
        sessionId: 'session-1',
        trigger: CompactionTrigger.auto,
        sourceRange: source,
        retainedTailRange: tail,
        routeSignature: _route(),
        startedAt: startedAt,
      );
      final summary = CompactionInternalSummary(
        currentGoal: goal,
        remainingWork: 'Next',
      );
      boundaries.completeStarted(
        candidate: CompactionCandidate(
          compactionId: id,
          sessionId: 'session-1',
          trigger: CompactionTrigger.auto,
          sourceRevision: const CompactionHistoryRevision(1),
          sourceRange: source,
          retainedTailRange: tail,
          internalSummary: summary,
          continuityResult: CompactionContinuityResult.fromSummary(summary),
          metrics: CompactionMetrics(
            contextWindowTokens: 10_000,
            estimatedRequestTokensBefore: 8_000,
            estimatedRequestTokensAfter: 2_000,
            retainedTailTokens: 500,
          ),
          routeSignature: _route(),
        ),
        startedAt: startedAt,
        completedAt: completedAt,
      );
    }

    completeBoundary(
      id: 'cmp-old',
      source: CompactionMessageRange(
        start: const CompactionMessageIdentity(1),
        end: const CompactionMessageIdentity(1),
      ),
      tail: CompactionMessageRange(
        start: const CompactionMessageIdentity(2),
        end: const CompactionMessageIdentity(2),
      ),
      goal: 'Old goal',
      completedAt: DateTime.utc(2026, 8, 29, 1),
    );
    completeBoundary(
      id: 'cmp-new',
      source: CompactionMessageRange(
        start: const CompactionMessageIdentity(1),
        end: const CompactionMessageIdentity(2),
      ),
      tail: CompactionMessageRange(
        start: const CompactionMessageIdentity(3),
        end: const CompactionMessageIdentity(4),
      ),
      goal: 'New goal',
      completedAt: DateTime.utc(2026, 8, 29, 2),
    );

    final projection = builder.buildForSession('session-1');
    expect(projection.activeBoundary?.compactionId, 'cmp-new');
    expect(projection.conversationMessages.first.content, contains('New goal'));
    expect(
      projection.conversationMessages.first.content,
      isNot(contains('Old goal')),
    );
    expect(
      projection.conversationMessages.where(
        (message) =>
            message.metadata?[CompactionSummaryProjection
                .projectionMetadataKey] ==
            true,
      ),
      hasLength(1),
    );
  });

  test('metadata-only history updates preserve the active boundary', () {
    final canonical = [
      Message(role: MessageRole.user, content: 'old-1'),
      Message(role: MessageRole.user, content: 'old-2'),
      Message(role: MessageRole.assistant, content: 'tail-1'),
      Message(role: MessageRole.user, content: 'tail-2'),
    ];
    sessions.replaceMessages('session-1', canonical);
    final originalIds = builder
        .loadCanonicalTimeline('session-1')
        .messages
        .map((entry) => entry.rowId)
        .toList(growable: false);
    final startedAt = DateTime.utc(2026, 8, 31);
    final sourceRange = CompactionMessageRange(
      start: CompactionMessageIdentity(originalIds[0]),
      end: CompactionMessageIdentity(originalIds[1]),
    );
    final tailRange = CompactionMessageRange(
      start: CompactionMessageIdentity(originalIds[2]),
      end: CompactionMessageIdentity(originalIds[3]),
    );
    boundaries.tryClaim(
      compactionId: 'cmp-metadata-stable',
      sessionId: 'session-1',
      trigger: CompactionTrigger.auto,
      sourceRange: sourceRange,
      retainedTailRange: tailRange,
      routeSignature: _route(),
      startedAt: startedAt,
    );
    const summary = CompactionInternalSummary(
      currentGoal: 'Keep the active boundary',
      remainingWork: 'Continue from the retained tail',
    );
    boundaries.completeStarted(
      candidate: CompactionCandidate(
        compactionId: 'cmp-metadata-stable',
        sessionId: 'session-1',
        trigger: CompactionTrigger.auto,
        sourceRevision: const CompactionHistoryRevision(1),
        sourceRange: sourceRange,
        retainedTailRange: tailRange,
        internalSummary: summary,
        continuityResult: CompactionContinuityResult.fromSummary(summary),
        metrics: CompactionMetrics(
          contextWindowTokens: 400_000,
          estimatedRequestTokensBefore: 320_000,
          estimatedRequestTokensAfter: 40_000,
          retainedTailTokens: 10_000,
        ),
        routeSignature: _route(),
      ),
      startedAt: startedAt,
      completedAt: startedAt.add(const Duration(seconds: 1)),
    );

    sessions.replaceMessages('session-1', [
      canonical[0].copyWith(metadata: const {'request_id': 'request-1'}),
      canonical[1],
      canonical[2],
      canonical[3],
    ]);

    expect(
      builder
          .loadCanonicalTimeline('session-1')
          .messages
          .map((entry) => entry.rowId),
      originalIds,
    );
    final projection = builder.buildForSession('session-1');
    expect(projection.activeBoundary?.compactionId, 'cmp-metadata-stable');
    expect(projection.conversationMessages.first.content, contains('Keep'));
  });

  test('semantic history updates still invalidate the old boundary', () {
    final canonical = [
      Message(role: MessageRole.user, content: 'old-1'),
      Message(role: MessageRole.user, content: 'old-2'),
      Message(role: MessageRole.assistant, content: 'tail-1'),
      Message(role: MessageRole.user, content: 'tail-2'),
    ];
    sessions.replaceMessages('session-1', canonical);
    final ids = builder
        .loadCanonicalTimeline('session-1')
        .messages
        .map((entry) => entry.rowId)
        .toList(growable: false);
    final startedAt = DateTime.utc(2026, 8, 31);
    final sourceRange = CompactionMessageRange(
      start: CompactionMessageIdentity(ids[0]),
      end: CompactionMessageIdentity(ids[1]),
    );
    final tailRange = CompactionMessageRange(
      start: CompactionMessageIdentity(ids[2]),
      end: CompactionMessageIdentity(ids[3]),
    );
    boundaries.tryClaim(
      compactionId: 'cmp-semantic-change',
      sessionId: 'session-1',
      trigger: CompactionTrigger.auto,
      sourceRange: sourceRange,
      retainedTailRange: tailRange,
      routeSignature: _route(),
      startedAt: startedAt,
    );
    const summary = CompactionInternalSummary(
      currentGoal: 'Old summarized goal',
      remainingWork: 'Old remaining work',
    );
    boundaries.completeStarted(
      candidate: CompactionCandidate(
        compactionId: 'cmp-semantic-change',
        sessionId: 'session-1',
        trigger: CompactionTrigger.auto,
        sourceRevision: const CompactionHistoryRevision(1),
        sourceRange: sourceRange,
        retainedTailRange: tailRange,
        internalSummary: summary,
        continuityResult: CompactionContinuityResult.fromSummary(summary),
        metrics: CompactionMetrics(
          contextWindowTokens: 400_000,
          estimatedRequestTokensBefore: 320_000,
          estimatedRequestTokensAfter: 40_000,
          retainedTailTokens: 10_000,
        ),
        routeSignature: _route(),
      ),
      startedAt: startedAt,
      completedAt: startedAt.add(const Duration(seconds: 1)),
    );

    sessions.replaceMessages('session-1', [
      Message(role: MessageRole.user, content: 'edited-old-1'),
      canonical[1],
      canonical[2],
      canonical[3],
    ]);

    final projection = builder.buildForSession('session-1');
    expect(projection.usesCompactionBoundary, isFalse);
    expect(projection.conversationMessages.first.content, 'edited-old-1');
  });

  test('canonical timeline query returns full history independently', () {
    sessions.replaceMessages('session-1', [
      Message(role: MessageRole.user, content: 'one'),
      Message(role: MessageRole.assistant, content: 'two'),
    ]);

    final timeline = builder.loadCanonicalTimeline('session-1');
    expect(timeline.messages, hasLength(2));
    expect(timeline.messages.first.rowId, 1);
    expect(timeline.messages.last.rowId, 2);
  });

  test('history rewrite inside source range supersedes boundary without lockout', () {
    final canonical = [
      Message(role: MessageRole.user, content: 'root-prompt'),
      Message(role: MessageRole.assistant, content: 'assistant-1'),
      Message(role: MessageRole.user, content: 'user-2'),
      Message(role: MessageRole.assistant, content: 'assistant-2'),
      Message(role: MessageRole.user, content: 'user-3'),
      Message(role: MessageRole.assistant, content: 'assistant-3'),
    ];
    sessions.replaceMessages('session-1', canonical);
    final initialTimeline = builder.loadCanonicalTimeline('session-1').messages;
    expect(initialTimeline, hasLength(6));
    final sourceRange = CompactionMessageRange(
      start: CompactionMessageIdentity(initialTimeline[0].rowId),
      end: CompactionMessageIdentity(initialTimeline[3].rowId),
    );
    final tailRange = CompactionMessageRange(
      start: CompactionMessageIdentity(initialTimeline[4].rowId),
      end: CompactionMessageIdentity(initialTimeline[5].rowId),
    );
    final startedAt = DateTime.utc(2026, 8, 31);
    final claim = boundaries.tryClaim(
      compactionId: 'cmp-lockout',
      sessionId: 'session-1',
      trigger: CompactionTrigger.manual,
      sourceRange: sourceRange,
      retainedTailRange: tailRange,
      routeSignature: _route(),
      startedAt: startedAt,
    );
    const summary = CompactionInternalSummary(
      currentGoal: 'Compacted goal',
      remainingWork: 'Remaining work',
    );
    boundaries.completeStarted(
      candidate: CompactionCandidate(
        compactionId: 'cmp-lockout',
        sessionId: 'session-1',
        trigger: CompactionTrigger.manual,
        sourceRevision: claim.record!.sourceHistoryRevision,
        sourceRange: sourceRange,
        retainedTailRange: tailRange,
        internalSummary: summary,
        continuityResult: CompactionContinuityResult.fromSummary(summary),
        metrics: CompactionMetrics(
          contextWindowTokens: 400_000,
          estimatedRequestTokensBefore: 320_000,
          estimatedRequestTokensAfter: 40_000,
          retainedTailTokens: 10_000,
        ),
        routeSignature: _route(),
      ),
      startedAt: startedAt,
      completedAt: startedAt.add(const Duration(seconds: 1)),
    );

    final initialProj = builder.buildForSession('session-1');
    expect(initialProj.usesCompactionBoundary, isTrue);

    // Realistic rewrite starting at index 1: root-prompt unchanged, subsequent rows replaced.
    sessions.replaceMessages('session-1', [
      canonical[0],
      canonical[1].copyWith(content: 'assistant-1 pruned/edited'),
      canonical[2],
      canonical[3],
      canonical[4],
      canonical[5],
      Message(role: MessageRole.user, content: 'new-turn-after-rewrite'),
    ]);

    final projection = builder.buildForSession('session-1');
    expect(projection.usesCompactionBoundary, isFalse);
    expect(projection.conversationMessages.first.content, 'root-prompt');
    expect(projection.conversationMessages.last.content, 'new-turn-after-rewrite');

    // Completed boundary row remains intact in the database for audit.
    final completedBoundaries = boundaries.listCompletedForSession('session-1');
    expect(completedBoundaries, hasLength(1));
    expect(completedBoundaries.first.compactionId, 'cmp-lockout');
  });

  test('superseded boundary projects next eligible older boundary if present', () {
    final canonical = [
      Message(role: MessageRole.user, content: 'm1'),
      Message(role: MessageRole.assistant, content: 'm2'),
      Message(role: MessageRole.user, content: 'm3'),
      Message(role: MessageRole.assistant, content: 'm4'),
      Message(role: MessageRole.user, content: 'm5'),
      Message(role: MessageRole.assistant, content: 'm6'),
      Message(role: MessageRole.user, content: 'm7'),
      Message(role: MessageRole.assistant, content: 'm8'),
    ];
    sessions.replaceMessages('session-1', canonical);
    final initialIds = builder
        .loadCanonicalTimeline('session-1')
        .messages
        .map((entry) => entry.rowId)
        .toList();
    expect(initialIds, [1, 2, 3, 4, 5, 6, 7, 8]);

    // Boundary 1 (older): source 1..2, tail 3..4 at rev 1
    final claim1 = boundaries.tryClaim(
      compactionId: 'cmp-older',
      sessionId: 'session-1',
      trigger: CompactionTrigger.auto,
      sourceRange: CompactionMessageRange(
        start: const CompactionMessageIdentity(1),
        end: const CompactionMessageIdentity(2),
      ),
      retainedTailRange: CompactionMessageRange(
        start: const CompactionMessageIdentity(3),
        end: const CompactionMessageIdentity(4),
      ),
      routeSignature: _route(),
      startedAt: DateTime.utc(2026, 8, 31, 1),
    );
    const summary1 = CompactionInternalSummary(
      currentGoal: 'Older goal',
      remainingWork: 'Older work',
    );
    boundaries.completeStarted(
      candidate: CompactionCandidate(
        compactionId: 'cmp-older',
        sessionId: 'session-1',
        trigger: CompactionTrigger.auto,
        sourceRevision: claim1.record!.sourceHistoryRevision,
        sourceRange: CompactionMessageRange(
          start: const CompactionMessageIdentity(1),
          end: const CompactionMessageIdentity(2),
        ),
        retainedTailRange: CompactionMessageRange(
          start: const CompactionMessageIdentity(3),
          end: const CompactionMessageIdentity(4),
        ),
        internalSummary: summary1,
        continuityResult: CompactionContinuityResult.fromSummary(summary1),
        metrics: CompactionMetrics(
          contextWindowTokens: 400_000,
          estimatedRequestTokensBefore: 300_000,
          estimatedRequestTokensAfter: 30_000,
          retainedTailTokens: 5_000,
        ),
        routeSignature: _route(),
      ),
      startedAt: DateTime.utc(2026, 8, 31, 1),
      completedAt: DateTime.utc(2026, 8, 31, 1, 30),
    );

    // Boundary 2 (newer): source 1..6, tail 7..8 at rev 1
    final claim2 = boundaries.tryClaim(
      compactionId: 'cmp-newer',
      sessionId: 'session-1',
      trigger: CompactionTrigger.auto,
      sourceRange: CompactionMessageRange(
        start: const CompactionMessageIdentity(1),
        end: const CompactionMessageIdentity(6),
      ),
      retainedTailRange: CompactionMessageRange(
        start: const CompactionMessageIdentity(7),
        end: const CompactionMessageIdentity(8),
      ),
      routeSignature: _route(),
      startedAt: DateTime.utc(2026, 8, 31, 2),
    );
    const summary2 = CompactionInternalSummary(
      currentGoal: 'Newer goal',
      remainingWork: 'Newer work',
    );
    boundaries.completeStarted(
      candidate: CompactionCandidate(
        compactionId: 'cmp-newer',
        sessionId: 'session-1',
        trigger: CompactionTrigger.auto,
        sourceRevision: claim2.record!.sourceHistoryRevision,
        sourceRange: CompactionMessageRange(
          start: const CompactionMessageIdentity(1),
          end: const CompactionMessageIdentity(6),
        ),
        retainedTailRange: CompactionMessageRange(
          start: const CompactionMessageIdentity(7),
          end: const CompactionMessageIdentity(8),
        ),
        internalSummary: summary2,
        continuityResult: CompactionContinuityResult.fromSummary(summary2),
        metrics: CompactionMetrics(
          contextWindowTokens: 400_000,
          estimatedRequestTokensBefore: 350_000,
          estimatedRequestTokensAfter: 35_000,
          retainedTailTokens: 5_000,
        ),
        routeSignature: _route(),
      ),
      startedAt: DateTime.utc(2026, 8, 31, 2),
      completedAt: DateTime.utc(2026, 8, 31, 2, 30),
    );

    // Before rewrite, newer boundary is active
    final projBefore = builder.buildForSession('session-1');
    expect(projBefore.activeBoundary?.compactionId, 'cmp-newer');
    expect(projBefore.conversationMessages.first.content, contains('Newer goal'));

    // Rewrite modifying messages starting at index 4 (m5 onwards)
    // Rows 1..4 remain unchanged with their original identities (1, 2, 3, 4).
    // cmp-newer (source 1..6) has source end 6 missing => superseded by rev 2 bump.
    // cmp-older (source 1..2, tail 3..4) has all endpoints present => eligible!
    sessions.replaceMessages('session-1', [
      canonical[0],
      canonical[1],
      canonical[2],
      canonical[3],
      canonical[4].copyWith(content: 'm5 edited'),
      canonical[5],
      canonical[6],
      canonical[7],
    ]);

    final projAfter = builder.buildForSession('session-1');
    expect(projAfter.usesCompactionBoundary, isTrue);
    expect(projAfter.activeBoundary?.compactionId, 'cmp-older');
    expect(
      projAfter.conversationMessages.map((m) => m.content).toList(),
      [
        contains('Older goal'),
        'm3',
        'm4',
        'm5 edited',
        'm6',
        'm7',
        'm8',
      ],
    );
  });

  test('impossible row ordering (missing source start) marks boundary ineligible without throwing', () {
    final canonical = [
      Message(role: MessageRole.user, content: 'user-1'),
      Message(role: MessageRole.assistant, content: 'assistant-1'),
      Message(role: MessageRole.user, content: 'user-2'),
      Message(role: MessageRole.assistant, content: 'assistant-2'),
    ];
    sessions.replaceMessages('session-1', canonical);
    final ids = builder
        .loadCanonicalTimeline('session-1')
        .messages
        .map((entry) => entry.rowId)
        .toList();

    final startedAt = DateTime.utc(2026, 8, 31);
    final claim = boundaries.tryClaim(
      compactionId: 'cmp-impossible-order',
      sessionId: 'session-1',
      trigger: CompactionTrigger.manual,
      sourceRange: CompactionMessageRange(
        start: CompactionMessageIdentity(ids[0]),
        end: CompactionMessageIdentity(ids[1]),
      ),
      retainedTailRange: CompactionMessageRange(
        start: CompactionMessageIdentity(ids[2]),
        end: CompactionMessageIdentity(ids[3]),
      ),
      routeSignature: _route(),
      startedAt: startedAt,
    );
    const summary = CompactionInternalSummary(
      currentGoal: 'Goal',
      remainingWork: 'Work',
    );
    boundaries.completeStarted(
      candidate: CompactionCandidate(
        compactionId: 'cmp-impossible-order',
        sessionId: 'session-1',
        trigger: CompactionTrigger.manual,
        sourceRevision: claim.record!.sourceHistoryRevision,
        sourceRange: CompactionMessageRange(
          start: CompactionMessageIdentity(ids[0]),
          end: CompactionMessageIdentity(ids[1]),
        ),
        retainedTailRange: CompactionMessageRange(
          start: CompactionMessageIdentity(ids[2]),
          end: CompactionMessageIdentity(ids[3]),
        ),
        internalSummary: summary,
        continuityResult: CompactionContinuityResult.fromSummary(summary),
        metrics: CompactionMetrics(
          contextWindowTokens: 400_000,
          estimatedRequestTokensBefore: 320_000,
          estimatedRequestTokensAfter: 40_000,
          retainedTailTokens: 10_000,
        ),
        routeSignature: _route(),
      ),
      startedAt: startedAt,
      completedAt: startedAt.add(const Duration(seconds: 1)),
    );

    // Simulate an impossible ordering (source start missing, source end present).
    state.db.execute(
      'DELETE FROM messages WHERE session_id = ? AND id = ?',
      ['session-1', ids[0]],
    );

    // Must NOT throw on the hot path for anchor states; falls back to full canonical history.
    final projection = builder.buildForSession('session-1');
    expect(projection.usesCompactionBoundary, isFalse);
    expect(
      projection.conversationMessages.map((m) => m.content),
      containsAllInOrder(['assistant-1', 'user-2', 'assistant-2']),
    );
  });

  test('missing retained-tail start falls back to full canonical history instead of throwing', () async {
    final canonical = [
      Message(role: MessageRole.user, content: 'u1'),
      Message(role: MessageRole.assistant, content: 'a1'),
      Message(role: MessageRole.user, content: 'u2'),
      Message(role: MessageRole.assistant, content: 'a2'),
    ];
    sessions.replaceMessages('session-1', canonical);
    final ids = builder
        .loadCanonicalTimeline('session-1')
        .messages
        .map((entry) => entry.rowId)
        .toList();

    final startedAt = DateTime.utc(2026, 8, 31);
    final claim = boundaries.tryClaim(
      compactionId: 'cmp-tail-gone',
      sessionId: 'session-1',
      trigger: CompactionTrigger.manual,
      sourceRange: CompactionMessageRange(
        start: CompactionMessageIdentity(ids[0]),
        end: CompactionMessageIdentity(ids[1]),
      ),
      retainedTailRange: CompactionMessageRange(
        start: CompactionMessageIdentity(ids[2]),
        end: CompactionMessageIdentity(ids[3]),
      ),
      routeSignature: _route(),
      startedAt: startedAt,
    );
    const summary = CompactionInternalSummary(
      currentGoal: 'Goal',
      remainingWork: 'Work',
    );
    boundaries.completeStarted(
      candidate: CompactionCandidate(
        compactionId: 'cmp-tail-gone',
        sessionId: 'session-1',
        trigger: CompactionTrigger.manual,
        sourceRevision: claim.record!.sourceHistoryRevision,
        sourceRange: CompactionMessageRange(
          start: CompactionMessageIdentity(ids[0]),
          end: CompactionMessageIdentity(ids[1]),
        ),
        retainedTailRange: CompactionMessageRange(
          start: CompactionMessageIdentity(ids[2]),
          end: CompactionMessageIdentity(ids[3]),
        ),
        internalSummary: summary,
        continuityResult: CompactionContinuityResult.fromSummary(summary),
        metrics: CompactionMetrics(
          contextWindowTokens: 400_000,
          estimatedRequestTokensBefore: 320_000,
          estimatedRequestTokensAfter: 40_000,
          retainedTailTokens: 10_000,
        ),
        routeSignature: _route(),
      ),
      startedAt: startedAt,
      completedAt: startedAt.add(const Duration(seconds: 1)),
    );

    // Both tail rows removed: source intact, tail start and end gone.
    state.db.execute(
      'DELETE FROM messages WHERE session_id = ? AND id >= ?',
      ['session-1', ids[2]],
    );

    final logRecords = <String>[];
    final sub = Logger('ModelProjectionBuilder').onRecord.listen(
      (rec) => logRecords.add(rec.message),
    );
    final projection = builder.buildForSession('session-1');
    await sub.cancel();

    expect(projection.usesCompactionBoundary, isFalse);
    expect(
      projection.conversationMessages.map((m) => m.content).toList(),
      ['u1', 'a1'],
    );
    expect(logRecords, [
      'Compaction boundary invalidated: compaction_id=cmp-tail-gone, '
          'reason=tail_start_missing',
    ]);
  });

  test('every invalidated completed boundary emits one bounded sanitized log line (R2)', () {
    final canonical = [
      Message(role: MessageRole.user, content: 'private user message'),
      Message(role: MessageRole.assistant, content: 'private assistant message'),
      Message(role: MessageRole.user, content: 'tail user'),
      Message(role: MessageRole.assistant, content: 'tail assistant'),
    ];
    sessions.replaceMessages('session-1', canonical);
    final ids = builder
        .loadCanonicalTimeline('session-1')
        .messages
        .map((entry) => entry.rowId)
        .toList();

    final startedAt = DateTime.utc(2026, 8, 31);
    final claim = boundaries.tryClaim(
      compactionId: 'cmp-log-test',
      sessionId: 'session-1',
      trigger: CompactionTrigger.manual,
      sourceRange: CompactionMessageRange(
        start: CompactionMessageIdentity(ids[0]),
        end: CompactionMessageIdentity(ids[1]),
      ),
      retainedTailRange: CompactionMessageRange(
        start: CompactionMessageIdentity(ids[2]),
        end: CompactionMessageIdentity(ids[3]),
      ),
      routeSignature: _route(),
      startedAt: startedAt,
    );
    const summary = CompactionInternalSummary(
      currentGoal: 'Sanitized Goal',
      remainingWork: 'Sanitized Work',
    );
    boundaries.completeStarted(
      candidate: CompactionCandidate(
        compactionId: 'cmp-log-test',
        sessionId: 'session-1',
        trigger: CompactionTrigger.manual,
        sourceRevision: claim.record!.sourceHistoryRevision,
        sourceRange: CompactionMessageRange(
          start: CompactionMessageIdentity(ids[0]),
          end: CompactionMessageIdentity(ids[1]),
        ),
        retainedTailRange: CompactionMessageRange(
          start: CompactionMessageIdentity(ids[2]),
          end: CompactionMessageIdentity(ids[3]),
        ),
        internalSummary: summary,
        continuityResult: CompactionContinuityResult.fromSummary(summary),
        metrics: CompactionMetrics(
          contextWindowTokens: 400_000,
          estimatedRequestTokensBefore: 320_000,
          estimatedRequestTokensAfter: 40_000,
          retainedTailTokens: 10_000,
        ),
        routeSignature: _route(),
      ),
      startedAt: startedAt,
      completedAt: startedAt.add(const Duration(seconds: 1)),
    );

    // Rewrite starting at index 1 so source start (ids[0]) exists but source end (ids[1]) is removed.
    sessions.replaceMessages('session-1', [
      canonical[0],
      canonical[1].copyWith(content: 'edited message'),
      canonical[2],
      canonical[3],
    ]);

    final logRecords = <String>[];
    final sub = Logger('ModelProjectionBuilder').onRecord.listen((rec) {
      logRecords.add(rec.message);
    });

    final projection = builder.buildForSession('session-1');
    sub.cancel();

    expect(projection.usesCompactionBoundary, isFalse);
    expect(logRecords, hasLength(1));
    expect(
      logRecords.first,
      'Compaction boundary invalidated: compaction_id=cmp-log-test, reason=source_end_missing',
    );
    // Verified sanitized: no user message content in the log line.
    expect(logRecords.first, isNot(contains('private user message')));
    expect(logRecords.first, isNot(contains('edited message')));
  });

  test('repeated buildForSession calls emit each invalidation at most once per process (compactionId, reason)', () {
    final canonical = [
      Message(role: MessageRole.user, content: 'user message'),
      Message(role: MessageRole.assistant, content: 'assistant message'),
      Message(role: MessageRole.user, content: 'tail user'),
      Message(role: MessageRole.assistant, content: 'tail assistant'),
    ];
    sessions.replaceMessages('session-1', canonical);
    final ids = builder
        .loadCanonicalTimeline('session-1')
        .messages
        .map((entry) => entry.rowId)
        .toList();

    final startedAt = DateTime.utc(2026, 8, 31);
    final claim = boundaries.tryClaim(
      compactionId: 'cmp-dedup-test',
      sessionId: 'session-1',
      trigger: CompactionTrigger.manual,
      sourceRange: CompactionMessageRange(
        start: CompactionMessageIdentity(ids[0]),
        end: CompactionMessageIdentity(ids[1]),
      ),
      retainedTailRange: CompactionMessageRange(
        start: CompactionMessageIdentity(ids[2]),
        end: CompactionMessageIdentity(ids[3]),
      ),
      routeSignature: _route(),
      startedAt: startedAt,
    );
    const summary = CompactionInternalSummary(
      currentGoal: 'Goal',
      remainingWork: 'Work',
    );
    boundaries.completeStarted(
      candidate: CompactionCandidate(
        compactionId: 'cmp-dedup-test',
        sessionId: 'session-1',
        trigger: CompactionTrigger.manual,
        sourceRevision: claim.record!.sourceHistoryRevision,
        sourceRange: CompactionMessageRange(
          start: CompactionMessageIdentity(ids[0]),
          end: CompactionMessageIdentity(ids[1]),
        ),
        retainedTailRange: CompactionMessageRange(
          start: CompactionMessageIdentity(ids[2]),
          end: CompactionMessageIdentity(ids[3]),
        ),
        internalSummary: summary,
        continuityResult: CompactionContinuityResult.fromSummary(summary),
        metrics: CompactionMetrics(
          contextWindowTokens: 400_000,
          estimatedRequestTokensBefore: 320_000,
          estimatedRequestTokensAfter: 40_000,
          retainedTailTokens: 10_000,
        ),
        routeSignature: _route(),
      ),
      startedAt: startedAt,
      completedAt: startedAt.add(const Duration(seconds: 1)),
    );

    // Rewrite starting at index 1 so source start exists but source end is removed.
    sessions.replaceMessages('session-1', [
      canonical[0],
      canonical[1].copyWith(content: 'edited message'),
      canonical[2],
      canonical[3],
    ]);

    final logRecords = <String>[];
    final sub = Logger('ModelProjectionBuilder').onRecord.listen((rec) {
      logRecords.add(rec.message);
    });

    // Simulate 4 calls to buildForSession during a single turn/request
    builder.buildForSession('session-1');
    builder.buildForSession('session-1');
    builder.buildForSession('session-1');
    builder.buildForSession('session-1');
    sub.cancel();

    expect(
      logRecords,
      hasLength(1),
      reason: 'Repeated calls must emit at most once per process per (compactionId, reason)',
    );
    expect(
      logRecords.single,
      'Compaction boundary invalidated: compaction_id=cmp-dedup-test, reason=source_end_missing',
    );
  });

  test('every canonical row removal via replaceMessages bumps history_revision (R7)', () {
    final historyRepo = SessionHistoryRevisionRepository(state);
    expect(historyRepo.read('session-1')?.value, 0);

    // Initial 5 messages: bumps revision to 1.
    sessions.replaceMessages('session-1', [
      Message(role: MessageRole.user, content: 'm1'),
      Message(role: MessageRole.assistant, content: 'm2'),
      Message(role: MessageRole.user, content: 'm3'),
      Message(role: MessageRole.assistant, content: 'm4'),
      Message(role: MessageRole.user, content: 'm5'),
    ]);
    expect(historyRepo.read('session-1')?.value, 1);

    // Row removal (shortening list removes tail rows id >= existing[3]): bumps revision to 2.
    sessions.replaceMessages('session-1', [
      Message(role: MessageRole.user, content: 'm1'),
      Message(role: MessageRole.assistant, content: 'm2'),
      Message(role: MessageRole.user, content: 'm3'),
    ]);
    expect(historyRepo.read('session-1')?.value, 2);

    // Mid-history rewrite (message 2 edited, deletes rows id >= existing[1] and reinserts): bumps revision to 3.
    sessions.replaceMessages('session-1', [
      Message(role: MessageRole.user, content: 'm1'),
      Message(role: MessageRole.assistant, content: 'm2 edited'),
      Message(role: MessageRole.user, content: 'm3'),
    ]);
    expect(historyRepo.read('session-1')?.value, 3);

    // Unconditional bump: even an identical replacement without changes bumps revision to 4.
    sessions.replaceMessages('session-1', [
      Message(role: MessageRole.user, content: 'm1'),
      Message(role: MessageRole.assistant, content: 'm2 edited'),
      Message(role: MessageRole.user, content: 'm3'),
    ]);
    expect(historyRepo.read('session-1')?.value, 4);
  });

  test('recovers session matching production lockout shape without database edits', () {
    // Exact shape from coordinator intake:
    // Session has history revision 1373.
    // Completed boundary at revision 945:
    // source: 29575340..29576050
    // tail: 29576051..29576299
    // Active rows: 29575340, 29579131, 29579132
    state.db.execute(
      '''
      UPDATE sessions
      SET history_revision = 1373
      WHERE session_id = 'session-1'
      ''',
    );
    state.db.execute(
      '''
      INSERT INTO messages (
        id, session_id, data, history_status
      ) VALUES
        (29575340, 'session-1', '{"role":"user","content":"Root prompt"}', 'active'),
        (29579131, 'session-1', '{"role":"assistant","content":"Rewritten response"}', 'active'),
        (29579132, 'session-1', '{"role":"user","content":"Next user turn"}', 'active')
      ''',
    );
    state.db.execute(
      '''
      INSERT INTO session_compaction_operations (
        compaction_id, session_id, trigger, status,
        source_history_revision,
        source_start_message_id, source_end_message_id,
        tail_start_message_id, tail_end_message_id,
        provider_instance_id, model_id, template_id, protocol,
        normalized_base_url, config_revision, credential_revision,
        context_window_tokens, estimated_request_tokens_before,
        estimated_request_tokens_after, retained_tail_tokens,
        internal_summary_json, started_at, completed_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ''',
      [
        'cmp-prod-lockout',
        'session-1',
        CompactionTrigger.manual.wireValue,
        CompactionStatus.completed.wireValue,
        945,
        29575340,
        29576050,
        29576051,
        29576299,
        'provider-1',
        'gpt-4o',
        'openai',
        'openai_compatible',
        'https://api.example.com/v1',
        1,
        1,
        258_000,
        220_000,
        25_000,
        5_000,
        '{"currentGoal":"Production goal","remainingWork":"Production work"}',
        '2026-10-20T10:00:00Z',
        '2026-10-20T10:01:00Z',
      ],
    );

    // On next load, projection must succeed without throwing and project full canonical history.
    final projection = builder.buildForSession('session-1');
    expect(projection.usesCompactionBoundary, isFalse);
    expect(projection.conversationMessages, hasLength(3));
    expect(projection.conversationMessages[0].content, 'Root prompt');
    expect(projection.conversationMessages[1].content, 'Rewritten response');
    expect(projection.conversationMessages[2].content, 'Next user turn');

    // The boundary row remains untouched in the DB for audit.
    final auditRows = boundaries.listCompletedForSession('session-1');
    expect(auditRows, hasLength(1));
    expect(auditRows.first.compactionId, 'cmp-prod-lockout');
    expect(auditRows.first.sourceHistoryRevision.value, 945);
  });
}
