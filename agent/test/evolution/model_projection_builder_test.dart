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
}
