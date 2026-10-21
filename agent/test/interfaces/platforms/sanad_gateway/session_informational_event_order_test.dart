import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/core/models/llm_finish_reason.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/models/tool_call.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/message_history_identity.dart';
import 'package:sanad_agent/evolution/db/runtime/session_route_mutation_coordinator.dart';
import 'package:sanad_agent/evolution/db/runtime/session_route_transition_repository.dart';
import 'package:sanad_agent/evolution/db/runtime/session_work_item_repository.dart';
import 'package:sanad_agent/evolution/models/session_route_transition.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/handlers/session_query_handler.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/sanad_protocol_bridge.dart';
import 'package:test/test.dart';

/// Task 78: informational events (`session.forked`, auto-failover
/// `session_route_transition`) keep the causal position they had live, on
/// every history page, exactly once.
void main() {
  late AgentStateDatabase state;
  late SessionManager sessions;
  late SessionRouteTransitionRepository transitions;

  setUp(() async {
    await getIt.reset();
    SessionManager.resetForTesting();
    state = AgentStateDatabase.inMemory();
    getIt.registerSingleton<AgentStateDatabase>(state);
    sessions = SessionManager();
    transitions = SessionRouteTransitionRepository(state);
  });

  tearDown(() async {
    SessionManager.resetForTesting();
    await getIt.reset();
  });

  Map<String, dynamic> historyPayload(
    String sessionId, {
    int? limit,
    String? cursor,
  }) {
    final envelope =
        SessionQueryHandler(
          sessionManager: sessions,
          bridge: _EnvelopeBridge(),
          routeTransitions: transitions,
        ).buildHistoryEnvelope(
          CanonicalEvent(
            type: CanonicalEventTypes.getSessionHistory,
            sessionId: sessionId,
            payload: {
              'request_id': 'history-${cursor ?? 'tail'}',
              'limit': ?limit,
              'cursor': ?cursor,
            },
          ),
        );
    return Map<String, dynamic>.from(envelope['payload'] as Map);
  }

  List<Map<String, dynamic>> rows(Map<String, dynamic> payload) =>
      (payload['messages'] as List)
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .toList();

  /// Compact `type:content` labels so order assertions read like a timeline.
  List<String> labels(List<Map<String, dynamic>> history) => [
    for (final row in history)
      switch (row['type']) {
        CanonicalEventTypes.sessionForked => 'fork',
        'session_route_transition' => 'route:${row['route_revision']}',
        'tool_use' => 'tool_use',
        'tool_result' => 'tool_result',
        _ => '${row['type']}:${row['content']}',
      },
  ];

  Message user(String text, String messageId, String turnId, {String? req}) =>
      Message(
        role: MessageRole.user,
        content: text,
        metadata: {
          'message_id': messageId,
          'turn_id': turnId,
          'request_id': ?req,
          'input_kind': MessageHistoryIdentity.rootTurn,
        },
      );

  Message answer(String text, String messageId, String turnId) => Message(
    role: MessageRole.assistant,
    content: text,
    finishReason: LLMFinishReason.stop,
    metadata: {'message_id': messageId, 'turn_id': turnId},
  );

  /// Parent with [turns] completed turns, forked at the last final answer;
  /// the child then continues with [childTurns] new turns.
  String forkedChild({int turns = 1, int childTurns = 0}) {
    final parent = sessions.createSession('model').sessionId;
    sessions.saveSessionHistory(parent, [
      for (var t = 1; t <= turns; t++) ...[
        user('parent q$t', 'p-u$t', 'p-t$t', req: 'p-req-$t'),
        answer('parent a$t', 'p-a$t', 'p-t$t'),
      ],
    ]);
    final commit = sessions.commitFork(
      sourceSessionId: parent,
      requestId: 'fork-req',
      targetMessageId: 'p-a$turns',
      targetTurnId: 'p-t$turns',
    );
    final child = commit.child!.sessionId;
    if (childTurns > 0) {
      sessions.saveSessionHistory(child, [
        ...sessions.getMessages(child),
        for (var t = 1; t <= childTurns; t++) ...[
          user('child q$t', 'c-u$t', 'c-t$t', req: 'c-req-$t'),
          answer('child a$t', 'c-a$t', 'c-t$t'),
        ],
      ]);
    }
    return child;
  }

  group('session.forked causal anchor', () {
    test('a continued child keeps the marker right after the copied '
        'prefix, before the post-fork turns', () {
      final child = forkedChild(turns: 1, childTurns: 2);

      expect(labels(rows(historyPayload(child))), [
        'user_message:parent q1',
        'final_answer:parent a1',
        'fork',
        'user_message:child q1',
        'final_answer:child a1',
        'user_message:child q2',
        'final_answer:child a2',
      ]);
    });

    test('a page without the copied prefix end carries no marker', () {
      final child = forkedChild(turns: 1, childTurns: 3);

      // Tail page of 4 rows: child q2 .. child a3, all post-fork.
      final tail = historyPayload(child, limit: 4);
      expect(
        labels(rows(tail)).where((label) => label == 'fork'),
        isEmpty,
      );
    });

    test('paging back shows the marker exactly once, on the page that '
        'holds the copied prefix end, even at a page edge', () {
      final child = forkedChild(turns: 2, childTurns: 2);
      // Active rows: p q1, p a1, p q2, p a2 | c q1, c a1, c q2, c a2.
      // limit 4 splits exactly at the fork boundary.
      final tail = historyPayload(child, limit: 4);
      final older = historyPayload(
        child,
        limit: 4,
        cursor: tail['next_cursor'] as String,
      );

      expect(labels(rows(tail)), [
        'user_message:child q1',
        'final_answer:child a1',
        'user_message:child q2',
        'final_answer:child a2',
      ]);
      expect(labels(rows(older)), [
        'user_message:parent q1',
        'final_answer:parent a1',
        'user_message:parent q2',
        'final_answer:parent a2',
        'fork',
      ]);
    });

    test('a fresh child still ends with the marker', () {
      final child = forkedChild(turns: 1);

      expect(labels(rows(historyPayload(child))).last, 'fork');
    });
  });

  group('legacy auto-failover transition (no durable anchor)', () {
    String toolTurnSession({String requestId = 'req-1'}) {
      final sessionId = sessions.createSession('model-a').sessionId;
      sessions.saveSessionHistory(sessionId, [
        user('search it', 'm-user', 't1', req: requestId),
        Message(
          role: MessageRole.assistant,
          toolCalls: [
            ToolCall(id: 'call-1', name: 'search', arguments: const {}),
          ],
          metadata: const {'message_id': 'm-call', 'turn_id': 't1'},
        ),
        Message(
          role: MessageRole.tool,
          toolCallId: 'call-1',
          content: 'found',
          metadata: const {
            'message_id': 'm-result',
            'turn_id': 't1',
            'terminal_at': '2026-10-21T10:00:10.000Z',
          },
        ),
        answer('done', 'm-final', 't1'),
      ]);
      return sessionId;
    }

    SessionRouteTransition legacy(
      String sessionId, {
      int revision = 2,
      String? requestId = 'req-1',
      SessionRouteSource source = SessionRouteSource.autoFailover,
      String createdAt = '2026-10-21T10:00:20.000Z',
    }) => SessionRouteTransition(
      sessionId: sessionId,
      routeRevision: revision,
      eventId: 'evt-$revision',
      source: source,
      previousProviderInstanceId: 'provider-a',
      providerInstanceId: 'provider-b',
      model: 'model-a',
      reason: 'rate_limit',
      requestId: requestId,
      createdAt: DateTime.parse(createdAt),
    );

    test('is placed after the tool results that finished before it, '
        'not right after the user row', () {
      final sessionId = toolTurnSession();
      transitions.insert(legacy(sessionId));

      expect(labels(rows(historyPayload(sessionId))), [
        'user_message:search it',
        'tool_use',
        'tool_result',
        'route:2',
        'final_answer:done',
      ]);
    });

    test('appears on the older page that holds its request, once', () {
      final sessionId = toolTurnSession();
      sessions.saveSessionHistory(sessionId, [
        ...sessions.getMessages(sessionId),
        for (var t = 2; t <= 4; t++) ...[
          user('q$t', 'm-u$t', 't$t', req: 'req-$t'),
          answer('a$t', 'm-a$t', 't$t'),
        ],
      ]);
      transitions.insert(legacy(sessionId));

      final tail = historyPayload(sessionId, limit: 6);
      final older = historyPayload(
        sessionId,
        limit: 6,
        cursor: tail['next_cursor'] as String,
      );
      final all = [...labels(rows(older)), ...labels(rows(tail))];

      expect(all.where((label) => label == 'route:2'), hasLength(1));
      expect(labels(rows(older)), contains('route:2'));
      expect(labels(rows(tail)), isNot(contains('route:2')));
    });

    test('a legacy notice keeps one occurrence and the single-page order '
        'at every page size, even when its tool results sit on a newer '
        'page than its request', () {
      final sessionId = toolTurnSession();
      sessions.saveSessionHistory(sessionId, [
        ...sessions.getMessages(sessionId),
        user('q2', 'm-u2', 't2', req: 'req-2'),
        answer('a2', 'm-a2', 't2'),
      ]);
      transitions.insert(legacy(sessionId));

      List<String> merged(int limit) {
        final pages = <List<String>>[];
        String? cursor;
        do {
          final page = historyPayload(sessionId, limit: limit, cursor: cursor);
          pages.insert(0, labels(rows(page)));
          cursor = page['has_more'] == true
              ? page['next_cursor'] as String?
              : null;
        } while (cursor != null);
        return [for (final page in pages) ...page];
      }

      const expected = [
        'user_message:search it',
        'tool_use',
        'tool_result',
        'route:2',
        'final_answer:done',
        'user_message:q2',
        'final_answer:a2',
      ];
      for (final limit in [1, 2, 3, 100]) {
        expect(merged(limit), expected, reason: 'page size $limit');
      }
    });

    test('an anchored notice follows its anchor row, not the turn timing', () {
      final sessionId = toolTurnSession();
      // Anchored on the tool-call row: the failover hit the step before the
      // tool result. Timing alone would put it after the result.
      transitions.insert(_anchored(legacy(sessionId), 'm-call'));

      expect(labels(rows(historyPayload(sessionId))), [
        'user_message:search it',
        'tool_use',
        'route:2',
        'tool_result',
        'final_answer:done',
      ]);
    });

    test('two failovers at one anchor keep revision order', () {
      final sessionId = toolTurnSession();
      transitions.insert(_anchored(legacy(sessionId), 'm-result'));
      transitions.insert(
        _anchored(
          legacy(
            sessionId,
            revision: 3,
            createdAt: '2026-10-21T10:00:21.000Z',
          ),
          'm-result',
        ),
      );

      expect(labels(rows(historyPayload(sessionId))), [
        'user_message:search it',
        'tool_use',
        'tool_result',
        'route:2',
        'route:3',
        'final_answer:done',
      ]);
    });

    test('an anchored notice appears once, on the older page holding its '
        'anchor', () {
      final sessionId = toolTurnSession();
      sessions.saveSessionHistory(sessionId, [
        ...sessions.getMessages(sessionId),
        for (var t = 2; t <= 4; t++) ...[
          user('q$t', 'm-u$t', 't$t', req: 'req-$t'),
          answer('a$t', 'm-a$t', 't$t'),
        ],
      ]);
      transitions.insert(_anchored(legacy(sessionId), 'm-result'));

      final tail = historyPayload(sessionId, limit: 6);
      final older = historyPayload(
        sessionId,
        limit: 6,
        cursor: tail['next_cursor'] as String,
      );

      expect(labels(rows(tail)), isNot(contains('route:2')));
      expect(labels(rows(older)), [
        'user_message:search it',
        'tool_use',
        'tool_result',
        'route:2',
        'final_answer:done',
      ]);
    });

    test('the anchor round-trips through the route coordinator', () {
      final sessionId = toolTurnSession();
      final coordinator = SessionRouteMutationCoordinator(
        state: state,
        workItems: SessionWorkItemRepository(state),
        transitions: transitions,
        providerInstances: ProviderInstanceRepository.fromDatabase(state.db),
      );
      coordinator.mutate(
        sessionId: sessionId,
        providerInstanceId: 'provider-b',
        model: 'model-b',
        source: SessionRouteSource.autoFailover,
        requestId: 'req-1',
        anchorMessageId: sessions.latestActiveMessageId(sessionId),
      );

      expect(
        transitions.findForSession(sessionId).single.anchorMessageId,
        'm-final',
      );
    });

    test('user and recovery route changes stay out of history, matching '
        'the live timeline which renders only automatic failover', () {
      final sessionId = toolTurnSession();
      transitions.insert(legacy(sessionId, source: SessionRouteSource.user));
      transitions.insert(
        legacy(sessionId, revision: 3, source: SessionRouteSource.recovery),
      );

      expect(
        labels(rows(historyPayload(sessionId))),
        isNot(anyElement(startsWith('route:'))),
      );
    });
  });
}

SessionRouteTransition _anchored(SessionRouteTransition t, String anchor) =>
    SessionRouteTransition(
      sessionId: t.sessionId,
      routeRevision: t.routeRevision,
      eventId: t.eventId,
      source: t.source,
      previousProviderInstanceId: t.previousProviderInstanceId,
      providerInstanceId: t.providerInstanceId,
      model: t.model,
      reason: t.reason,
      requestId: t.requestId,
      anchorMessageId: anchor,
      createdAt: t.createdAt,
    );

class _EnvelopeBridge extends SanadProtocolBridge {
  @override
  Map<String, dynamic> buildAgentEventEnvelope(CanonicalEvent canonicalEvent) {
    return {
      'event': canonicalEvent.type,
      'payload': canonicalEvent.payload,
      'session_id': canonicalEvent.sessionId,
    };
  }
}
