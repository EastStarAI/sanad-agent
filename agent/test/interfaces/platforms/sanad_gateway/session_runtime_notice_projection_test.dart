import 'dart:io';

import 'package:get_it/get_it.dart';
import 'package:sanad_agent/cli/models/runtime_retry_state.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/persisted_runtime_state_repository.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/handlers/session_query_handler.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/sanad_protocol_bridge.dart';
import 'package:test/test.dart';

/// 2026-11-09: the Client rendered `OpenCodeGo rate limit reached … retrying
/// automatically in 30s (attempt 1 of 3)` for a session whose
/// `session show --json` reported `runtime_notice: null`, while the same
/// session was `waiting` on a scheduled attempt.
///
/// The projection dropped every durable notice that was not `blocked`, so only
/// the live in-memory recovery state could publish a scheduled wait. A turn that
/// was re-attached after a daemon restart has no such live state for the window
/// before it is hydrated, and that is exactly the window every observer reads.
///
/// These tests exercise the durable half of the projection: the row the daemon
/// persists, and the payload a reader derives from it.
void main() {
  late Directory tempDir;
  late AgentStateDatabase state;
  late SessionManager sessions;
  late PersistedRuntimeStateRepository persisted;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('sanad_notice_projection_');
    Directory('${tempDir.path}/memories').createSync(recursive: true);
    setSanadHomeOverride(tempDir.path);
    state = AgentStateDatabase.inMemory();
    GetIt.I.registerSingleton<AgentStateDatabase>(state);
    sessions = SessionManager();
    persisted = PersistedRuntimeStateRepository.fromState(state);
  });

  tearDown(() {
    GetIt.I.reset();
    SessionManager.resetForTesting();
    state.dispose();
    setSanadHomeOverride(null);
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// One history payload, as `session show --json` consumes it. The handler is
  /// built without an orchestrator on purpose: a composition that can answer a
  /// history query must project the durable notice it reads from SQLite.
  Map<String, dynamic> historyPayload(String sessionId) {
    final envelope =
        SessionQueryHandler(
          sessionManager: sessions,
          bridge: _EnvelopeBridge(),
          persistedState: persisted,
        ).buildHistoryEnvelope(
          CanonicalEvent(
            type: CanonicalEventTypes.getSessionHistory,
            sessionId: sessionId,
            payload: const {'request_id': 'history-tail'},
          ),
        );
    return Map<String, dynamic>.from(envelope['payload'] as Map);
  }

  /// The durable row a scheduled rate-limit retry writes: `waiting`, with the
  /// attempt counters, the resume deadline, and the structured cause.
  void persistScheduledRateLimitRetry(
    String sessionId, {
    String status = 'waiting',
    int attempt = 1,
    int budget = 3,
    String reason = 'upstreamRateLimit',
  }) {
    persisted.upsertNotice(
      sessionId: sessionId,
      requestId: 'req-turn-1',
      runId: 'run-1',
      status: status,
      reason: reason,
      severity: 'warning',
      title: 'OpenCodeGo Rate limit reached',
      message:
          'Too many requests to OpenCodeGo. Wait or switch provider. '
          'Retrying automatically in 30s (attempt $attempt of $budget).',
      providerInstanceId: 'provider-opencode-go',
      providerDisplayName: 'OpenCodeGo',
      retryAfterMs: 30000,
      resumeAt: DateTime.now().toUtc().add(const Duration(seconds: 30))
          .toIso8601String(),
      retryAttempt: attempt,
      retryBudget: budget,
      actions: const ['stop', 'changeProvider'],
    );
  }

  /// The durable owner the projection reads next to the notice: a work item in
  /// the state the notice describes, so the session is not read as `idle`.
  void holdWorkItem(
    String sessionId, {
    required SessionWorkState state,
    String requestId = 'req-turn-1',
  }) {
    persisted.executionState.enqueueWorkItem(
      workItemId: 'wi-$sessionId',
      sessionId: sessionId,
      requestId: requestId,
      providerInstanceId: 'provider-opencode-go',
      modelId: 'grok-code-fast-1',
      state: state,
    );
  }

  test('a persisted scheduled retry is projected, not dropped', () {
    final sessionId = sessions.createSession('model').sessionId;
    holdWorkItem(sessionId, state: SessionWorkState.waiting);
    persistScheduledRateLimitRetry(sessionId);

    final payload = historyPayload(sessionId);
    final notice = payload['runtime_notice'];

    expect(
      notice,
      isA<Map>(),
      reason:
          'the durable `waiting` notice is the only recovery state a re-attached '
          'turn has before it is hydrated; dropping it makes the session look '
          'stopped to `session show`, `session retry`, and every supervisor',
    );
    final map = Map<String, dynamic>.from(notice as Map);
    expect(map['status'], 'waiting');
    expect(map['reason'], 'upstream_rate_limit');
    expect(
      map['retry_attempt'],
      1,
      reason: 'the attempt counters must survive the durable round trip',
    );
    expect(map['retry_budget'], 3);
    expect(map['resume_at'], isNotNull);
    expect(
      (map['actions'] as List).toSet(),
      containsAll(<String>{'stop', 'retry', 'changeProvider'}),
      reason: 'a scheduled wait can be shortened by a manual retry',
    );
  });

  test('the projected notice derives a retrying classification', () {
    final sessionId = sessions.createSession('model').sessionId;
    holdWorkItem(sessionId, state: SessionWorkState.waiting);
    persistScheduledRateLimitRetry(sessionId);

    final payload = historyPayload(sessionId);
    final retry = RuntimeRetryState.fromProjection(payload);

    expect(payload['execution_snapshot'], isA<Map>());
    expect(retry.executionState, 'waiting');

    expect(retry.isAutoRetrying, isTrue);
    expect(retry.isTrulyBlocked, isFalse);
    expect(retry.attempt, 1);
    expect(retry.budget, 3);
    expect(retry.reason, 'upstream_rate_limit');
    expect(retry.retryLabel, 'retrying (1/3)');
    expect(retry.retryAfterMs, greaterThan(0));
  });

  test('a parked turn stays blocked with its own actions', () {
    final sessionId = sessions.createSession('model').sessionId;
    holdWorkItem(sessionId, state: SessionWorkState.blocked);
    persistScheduledRateLimitRetry(
      sessionId,
      status: 'blocked',
      attempt: 3,
      budget: 3,
    );

    final payload = historyPayload(sessionId);
    final notice = Map<String, dynamic>.from(payload['runtime_notice'] as Map);
    expect(notice['status'], 'blocked');
    expect(notice['retry_attempt'], 3);
    expect(notice['retry_budget'], 3);

    final retry = RuntimeRetryState.fromProjection(payload);
    expect(retry.isAutoRetrying, isFalse);
    expect(retry.isTrulyBlocked, isTrue);
  });

  test('a cleared row is never projected', () {
    final sessionId = sessions.createSession('model').sessionId;
    persistScheduledRateLimitRetry(sessionId, status: 'cleared');

    expect(historyPayload(sessionId)['runtime_notice'], isNull);
  });
}

/// Minimal bridge: returns the event envelope unchanged so the test reads the
/// same payload the local transport sends.
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
