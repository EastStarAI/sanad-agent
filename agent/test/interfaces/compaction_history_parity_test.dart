import 'dart:io';

import 'package:sanad_agent/core/auth/auth_manager.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/agent_runtime_service.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/sanad_home/sanad_home_bootstrap.dart';
import 'package:sanad_agent/engine/compaction/compaction.dart';
import 'package:sanad_agent/engine/runtime/compaction_coordinator.dart';
import 'package:sanad_agent/evolution/compaction/compaction_activation_service.dart';
import 'package:sanad_agent/evolution/compaction/compaction_boundary_change.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/compaction_boundary_repository.dart';
import 'package:sanad_agent/evolution/db/session_db.dart';
import 'package:sanad_agent/evolution/db/session_history_revision_repository.dart';
import 'package:sanad_agent/evolution/db/session_projection_revision_repository.dart';
import 'package:sanad_agent/evolution/models/session_state.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/handlers/session_query_handler.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/sanad_protocol_bridge.dart';
import 'package:sanad_agent/interfaces/models/gateway_event.dart';
import 'package:sanad_agent/interfaces/runtime/compaction_lifecycle_broadcaster.dart';
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

CompactionCandidate _candidate({required String id}) {
  const summary = CompactionInternalSummary(
    currentGoal: 'Ship compaction',
    remainingWork: 'Verify history parity',
  );
  return CompactionCandidate(
    compactionId: id,
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
      contextWindowTokens: 100_000,
      effectiveInputBudgetTokens: 95_000,
      autoThresholdTokens: 76_000,
      estimatedRequestTokensBefore: 80_000,
      estimatedRequestTokensAfter: 20_000,
      retainedTailTokens: 5_000,
    ),
    routeSignature: _route(),
  );
}

void main() {
  late AgentStateDatabase state;
  late SessionDB sessions;
  late SessionManager sessionManager;
  late CompactionBoundaryRepository boundaries;
  late SanadProtocolBridge bridge;
  late Directory sanadHome;

  setUp(() async {
    sanadHome = Directory.systemTemp.createTempSync('compaction_history_');
    setSanadHomeOverride(sanadHome.path);
    await SanadHomeBootstrap.identity().prepare();
    getIt.allowReassignment = true;
    state = AgentStateDatabase.inMemory();
    getIt.registerSingleton<AgentStateDatabase>(state);
    getIt.registerSingleton<AuthManager>(AuthManager());
    SessionManager.resetForTesting();
    sessions = SessionDB.fromState(state);
    sessionManager = SessionManager();
    boundaries = CompactionBoundaryRepository(
      state,
      SessionHistoryRevisionRepository(state),
    );
    bridge = SanadProtocolBridge();
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
    sessions.replaceMessages('session-1', [
      Message(role: MessageRole.user, content: 'one'),
      Message(role: MessageRole.assistant, content: 'two'),
      Message(role: MessageRole.user, content: 'three'),
    ]);
  });

  tearDown(() async {
    SessionManager.resetForTesting();
    if (getIt.isRegistered<AuthManager>()) {
      getIt.unregister<AuthManager>();
    }
    if (getIt.isRegistered<AgentStateDatabase>()) {
      getIt.unregister<AgentStateDatabase>();
    }
    sessions.dispose();
    state.dispose();
    setSanadHomeOverride(null);
    sanadHome.deleteSync(recursive: true);
  });

  test('session history includes durable compaction lifecycle rows', () {
    final startedAt = DateTime.utc(2026, 8, 29, 2);
    boundaries.tryClaim(
      compactionId: 'cmp-history',
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
    CompactionActivationService(
      boundaries: boundaries,
      projectionRevisions: SessionProjectionRevisionRepository(state),
      changes: CompactionBoundaryChangeNotifier(),
    ).activateCandidate(
      candidate: _candidate(id: 'cmp-history'),
      startedAt: startedAt,
      completedAt: startedAt.add(const Duration(seconds: 2)),
    );
    final durableOperation = boundaries
        .listCompletedForSession('session-1')
        .single;
    expect(durableOperation.retainedTailEndFingerprint, isNotNull);
    expect(durableOperation.retainedTailEndOccurrence, 1);
    sessions.replaceMessages('session-1', [
      Message(role: MessageRole.user, content: 'one'),
      Message(role: MessageRole.assistant, content: 'two'),
      Message(role: MessageRole.user, content: 'three'),
      Message(
        role: MessageRole.assistant,
        content: 'response produced after compaction',
      ),
    ]);

    final handler = SessionQueryHandler(
      sessionManager: sessionManager,
      bridge: bridge,
      compactionBoundaries: boundaries,
    );
    final tailEnvelope = handler.buildHistoryEnvelope(
      CanonicalEvent(
        type: CanonicalEventTypes.getSessionHistory,
        sessionId: 'session-1',
        payload: {
          'request_id': 'history-tail',
          'session_id': 'session-1',
          'limit': 1,
        },
      ),
    );
    final tailPayload = tailEnvelope['payload'] as Map<String, dynamic>;
    final olderEnvelope = handler.buildHistoryEnvelope(
      CanonicalEvent(
        type: CanonicalEventTypes.getSessionHistory,
        sessionId: 'session-1',
        payload: {
          'request_id': 'history-older',
          'session_id': 'session-1',
          'limit': 1,
          'cursor': tailPayload['next_cursor'],
        },
      ),
    );
    final olderPayload = olderEnvelope['payload'] as Map<String, dynamic>;
    final messages = [
      ...(olderPayload['messages'] as List),
      ...(tailPayload['messages'] as List),
    ];
    final compactionRows = messages
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .where(
          (row) =>
              row['type'] == CanonicalEventTypes.contextCompactionCompleted,
        )
        .toList();

    expect(compactionRows, hasLength(1));
    expect(tailPayload, contains('execution_snapshot'));
    expect(olderPayload, isNot(contains('execution_snapshot')));
    expect(compactionRows.first['compaction_id'], 'cmp-history');
    expect(compactionRows.first['trigger'], 'manual');
    expect(compactionRows.first['status'], 'completed');
    expect(compactionRows.first.containsKey('internal_summary_json'), isFalse);
    expect(compactionRows.first['estimated_request_tokens_before'], 80_000);
    expect(compactionRows.first['effective_input_budget_tokens'], 95_000);
    expect(compactionRows.first['auto_threshold_tokens'], 76_000);

    final liveResponses = <GatewayResponse>[];
    CompactionLifecycleBroadcaster(liveResponses.add).handle(
      CompactionLifecycleEvent(
        compactionId: 'cmp-history',
        sessionId: 'session-1',
        trigger: CompactionTrigger.manual,
        status: CompactionStatus.completed,
        metrics: _candidate(id: 'cmp-history').metrics,
        startedAt: startedAt,
        completedAt: startedAt.add(const Duration(seconds: 2)),
      ),
    );
    expect(
      compactionRows.first['event_id'],
      liveResponses.single.eventId,
      reason: 'reload must preserve the live completed transition identity',
    );
    final compactionIndex = messages.indexWhere(
      (row) => row is Map && row['compaction_id'] == 'cmp-history',
    );
    final postCompactionResponseIndex = messages.indexWhere(
      (row) =>
          row is Map && row['content'] == 'response produced after compaction',
    );
    expect(
      compactionIndex,
      lessThan(postCompactionResponseIndex),
      reason: 'history must keep compaction before the response it enabled',
    );

    sessions.replaceMessages('session-1', [
      Message(role: MessageRole.user, content: 'one'),
      Message(role: MessageRole.assistant, content: 'two'),
      Message(
        role: MessageRole.tool,
        content: 'recovery row inserted before the durable anchor',
      ),
      Message(role: MessageRole.user, content: 'three'),
      Message(
        role: MessageRole.assistant,
        content: 'response produced after compaction',
      ),
    ]);
    final rewrittenEnvelope = handler.buildHistoryEnvelope(
      CanonicalEvent(
        type: CanonicalEventTypes.getSessionHistory,
        sessionId: 'session-1',
        payload: {'request_id': 'history-rewritten', 'session_id': 'session-1'},
      ),
    );
    final rewrittenMessages =
        (rewrittenEnvelope['payload'] as Map<String, dynamic>)['messages']
            as List;
    final recoveryIndex = rewrittenMessages.indexWhere(
      (row) =>
          row is Map &&
          row['content'] == 'recovery row inserted before the durable anchor',
    );
    final relocatedCompactionIndex = rewrittenMessages.indexWhere(
      (row) => row is Map && row['compaction_id'] == 'cmp-history',
    );
    final rewrittenResponseIndex = rewrittenMessages.indexWhere(
      (row) =>
          row is Map && row['content'] == 'response produced after compaction',
    );
    expect(recoveryIndex, lessThan(relocatedCompactionIndex));
    expect(relocatedCompactionIndex, lessThan(rewrittenResponseIndex));
  });
}
