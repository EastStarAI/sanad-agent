import 'dart:io';

import 'package:get_it/get_it.dart';
import 'package:sanad_agent/cli/models/runtime_retry_state.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/core/provider_runtime/provider_protocol_constants.dart';
import 'package:sanad_agent/core/provider_runtime/provider_rate_limiter.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_failure_reason.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_notice.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_recovery_exception.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_recovery_service.dart';
import 'package:sanad_agent/engine/adapters/llm_http_exception.dart';
import 'package:sanad_agent/engine/adapters/provider_history_projection_exception.dart';
import 'package:sanad_agent/engine/runtime/runner_recovery_coordinator.dart';
import 'package:sanad_agent/engine/runtime/turn_route_state.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/persisted_runtime_state_repository.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/handlers/session_query_handler.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/sanad_protocol_bridge.dart';
import 'package:test/fake.dart';
import 'package:test/test.dart';

/// Only the members the projection-rejection branch may read are implemented;
/// any failover, retry, route or profile hook throws from [Fake], so reaching
/// one fails the test.
class _TurnRoute extends Fake implements TurnRouteState {
  @override
  String? get turnRequestId => 'turn-1';
}

class _Host extends Fake implements RunnerRecoveryHost {
  @override
  final TurnRouteState turnRoute = _TurnRoute();

  @override
  String get sessionId => 'session-1';

  @override
  String? get authoritativeRunId => 'run-1';
}

/// A host that behaves like the runner on the automatic-retry path: the retry
/// wake keeps durable ownership, and nothing else is touched by the decision
/// under test.
class _RetryHost extends _Host {
  @override
  bool claimOwnedAutomaticRetry() => true;
}

/// A host whose session is a real persisted session, so the chain test can read
/// the durable projection for the turn it just failed.
class _ChainHost extends _RetryHost {
  @override
  final String sessionId;

  _ChainHost(this.sessionId);
}

/// Minimal bridge: returns the event envelope unchanged so the chain test reads
/// exactly the payload the local transport sends.
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

/// Task 110 port guard (Task 116): RunnerRecoveryCoordinator presents a
/// provider-history projection rejection as one blocked local invalid request
/// and never fails over, retries, or touches the route or capability profile,
/// even when a ready failover candidate exists.
void main() {
  late AgentStateDatabase state;
  late RuntimeRecoveryService recovery;

  setUp(() {
    state = AgentStateDatabase.inMemory();
    final repository = ProviderInstanceRepository.fromDatabase(state.db);
    final now = DateTime.utc(2026, 10, 21);
    for (final id in ['provider-1', 'provider-2']) {
      repository.createInstance(
        ProviderInstance(
          id: id,
          templateId: 'openai',
          displayName: id,
          protocol: ProviderProtocol.openaiCompatible,
          authMethod: ProviderAuthMethod.apiKey,
          defaultModel: 'gpt-4o',
          status: InstanceStatus.ready,
          createdAt: now,
          updatedAt: now,
        ),
      );
    }
    recovery = RuntimeRecoveryService(
      repository,
      ProviderRateLimiter(),
      autoFailoverEnabled: true,
    );
    getIt.registerSingleton<RuntimeRecoveryService>(recovery);
  });

  tearDown(() {
    getIt.reset();
    state.dispose();
  });

  test('projection rejection is blocked with no failover or retry', () async {
    final coordinator = RunnerRecoveryCoordinator(_Host());
    final failed = <String>{};

    await expectLater(
      coordinator.handleRuntimeFailure(
        ProviderHistoryProjectionException(
          route: 'provider-1/gpt-4o',
          reasonCode: ProviderHistoryProjectionException.unpairedToolCall,
          affectedCount: 1,
        ),
        providerInstanceId: 'provider-1',
        modelId: 'gpt-4o',
        attempt: 0,
        streamStarted: false,
        failedProviderInstanceIds: failed,
      ),
      throwsA(
        isA<RuntimeRecoveryRequired>().having(
          (error) => error.reason,
          'reason',
          RuntimeFailureReason.invalidRequest,
        ),
      ),
    );

    expect(failed, isEmpty, reason: 'no failover candidate was considered');
    final notice = recovery.activeNotice('session-1');
    expect(notice, isNotNull);
    expect(notice!.status, RuntimeNoticeStatus.blocked);
    expect(notice.title, 'Conversation history not supported by this model');
  });

  group('automatic retry classification', () {
    /// The provider failure the coordinator classifies. `retry-after: 0` keeps
    /// the automatic wait at its jitter floor so the retry path is exercised
    /// without sleeping for the reason's fallback delay.
    LlmHttpException httpFailure(int statusCode, String body) =>
        LlmHttpException(
          statusCode: statusCode,
          body: body,
          headers: const {'retry-after': '0'},
          operation: 'chat.completions',
        );

    test(
      'a retryable timeout with budget left is published as waiting, not blocked',
      () async {
        final coordinator = RunnerRecoveryCoordinator(_RetryHost());

        final handled = await coordinator.handleRuntimeFailure(
          httpFailure(504, 'gateway timeout'),
          providerInstanceId: 'provider-1',
          modelId: 'gpt-4o',
          attempt: 0,
          streamStarted: false,
          failedProviderInstanceIds: <String>{},
        );

        expect(handled, isTrue, reason: 'the turn continues on the same route');
        final notice = recovery.activeNotice('session-1');
        expect(notice, isNotNull);
        // The retry completed, so the recovery state is the transient resume…
        expect(notice!.status, RuntimeNoticeStatus.resuming);
        // …and the attempt it just spent is published, not inferred from prose.
        expect(notice.reason, RuntimeFailureReason.unknown);
      },
    );

    test(
      'the notice during the automatic wait is waiting with the attempt counters',
      () async {
        final coordinator = RunnerRecoveryCoordinator(_RetryHost());
        final notices = <RuntimeNotice>[];
        recovery.attachNoticeSink((payload) {
          notices.add(
            RuntimeNotice(
              sessionId: payload['session_id'] as String,
              status: RuntimeNoticeStatus.values.byName(
                payload['status'] as String,
              ),
              reason: RuntimeFailureReason.values.byName(
                payload['reason'] as String,
              ),
              title: payload['title'] as String,
              message: payload['message'] as String,
              retryAttempt: payload['retry_attempt'] as int?,
              retryBudget: payload['retry_budget'] as int?,
              createdAt: DateTime.now(),
              updatedAt: DateTime.now(),
            ),
          );
        });

        await coordinator.handleRuntimeFailure(
          httpFailure(504, 'gateway timeout'),
          providerInstanceId: 'provider-1',
          modelId: 'gpt-4o',
          attempt: 0,
          streamStarted: false,
          failedProviderInstanceIds: <String>{},
        );

        final waiting = notices.firstWhere(
          (notice) => notice.status == RuntimeNoticeStatus.waiting,
        );
        expect(waiting.retryAttempt, 1);
        expect(waiting.retryBudget, 1);
        expect(
          waiting.isAutomaticRetryPending,
          isTrue,
          reason:
              'attempt 1 of 1 is scheduled, so the turn must not read as stopped',
        );
        expect(waiting.message, contains('Retrying automatically'));
      },
    );

    test('an exhausted retry budget is blocked with no budget left', () async {
      final coordinator = RunnerRecoveryCoordinator(_RetryHost());

      await expectLater(
        coordinator.handleRuntimeFailure(
          httpFailure(504, 'gateway timeout'),
          providerInstanceId: 'provider-1',
          modelId: 'gpt-4o',
          // The timeout budget is 1, so this call is the second failure.
          attempt: 1,
          streamStarted: false,
          failedProviderInstanceIds: <String>{},
        ),
        throwsA(isA<RuntimeRecoveryRequired>()),
      );

      final notice = recovery.activeNotice('session-1');
      expect(notice, isNotNull);
      expect(notice!.status, RuntimeNoticeStatus.blocked);
      expect(notice.isAutomaticRetryPending, isFalse);
      expect(notice.awaitsIntervention, isTrue);
      expect(notice.retryAttempt, 1);
      expect(notice.retryBudget, 1);
      expect(notice.hasRetryBudgetLeft, isFalse);
      expect(notice.message, contains('gave up after 1 attempt'));
    });

    test('a non-retryable failure is blocked immediately', () async {
      final coordinator = RunnerRecoveryCoordinator(_RetryHost());

      await expectLater(
        coordinator.handleRuntimeFailure(
          httpFailure(401, 'Invalid API key'),
          providerInstanceId: 'provider-1',
          modelId: 'gpt-4o',
          attempt: 0,
          streamStarted: false,
          failedProviderInstanceIds: <String>{},
        ),
        throwsA(isA<RuntimeRecoveryRequired>()),
      );

      final notice = recovery.activeNotice('session-1');
      expect(notice, isNotNull);
      expect(notice!.status, RuntimeNoticeStatus.blocked);
      expect(notice.reason, RuntimeFailureReason.auth);
      expect(notice.isAutomaticRetryPending, isFalse);
      expect(notice.awaitsIntervention, isTrue);
      expect(
        notice.retryBudget,
        isNull,
        reason: 'a failure that is never retried publishes no budget',
      );
    });

    /// 2026-11-09: a provider 429 produced a live Client banner
    /// (`retrying automatically in 30s (attempt 1 of 3)`) while
    /// `sanad session show --json` reported `runtime_notice: null`. The chain
    /// below is the defect in one flow: the fake provider response the
    /// coordinator classifies, the durable row it writes, the history
    /// projection a re-attached reader sees, and the classification both
    /// `session show` and `session retry` derive from it. No network is used
    /// and no retry is slept through: `retry-after: 0` keeps the wait at its
    /// jitter floor.
    test('a provider 429 reaches session show as a scheduled rate-limit '
        'retry', () async {
      final persisted = PersistedRuntimeStateRepository.fromState(state);
      // The reported turn had no failover route it was allowed to take, so the
      // daemon's only option was the scheduled retry on the same provider. That
      // is what makes this the same-route path rather than an auto-failover.
      final providers = ProviderInstanceRepository.fromDatabase(state.db);
      final spare = providers.findById('provider-2');
      expect(spare, isNotNull);
      providers.update(spare!.copyWith(allowAutoFailover: false));

      final tempHome = Directory.systemTemp.createTempSync('sanad_429_chain_');
      setSanadHomeOverride(tempHome.path);
      GetIt.I.registerSingleton<AgentStateDatabase>(state);
      SessionManager.resetForTesting();
      final sessions = SessionManager();
      addTearDown(() {
        SessionManager.resetForTesting();
        if (GetIt.I.isRegistered<AgentStateDatabase>()) {
          GetIt.I.unregister<AgentStateDatabase>();
        }
        setSanadHomeOverride(null);
        tempHome.deleteSync(recursive: true);
      });
      final sessionId = sessions.createSession('gpt-4o').sessionId;

      // The durable owner the daemon holds for the turn it is about to fail: a
      // work item in the waiting state, so the projection is not read as an
      // ended turn while the retry is scheduled.
      persisted.executionState.enqueueWorkItem(
        workItemId: 'wi-$sessionId',
        sessionId: sessionId,
        requestId: 'turn-1',
        providerInstanceId: 'provider-1',
        modelId: 'gpt-4o',
        state: SessionWorkState.waiting,
      );

      /// The history projection `session show --json` reads for this session.
      Map<String, dynamic> historyProjection() {
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

      recovery.attachPersistedState(persisted);
      final noticePayloads = <Map<String, dynamic>>[];
      final persistedAtPublish = <Map<String, dynamic>>[];
      // The projection a reader gets at the exact moment the daemon publishes
      // the scheduled wait — the instant the live Client rendered
      // `retrying automatically in 30s (attempt 1 of 3)` while `session show`
      // reported `runtime_notice: null`.
      Map<String, dynamic>? projectionAtWait;
      recovery.attachNoticeSink((payload) {
        noticePayloads.add(Map<String, dynamic>.from(payload));
        // `_emit` mirrors the notice before it publishes, so the row read here
        // is the durable state a reader sees at the same instant.
        final row = persisted.findNotice(sessionId);
        persistedAtPublish.add(<String, dynamic>{
          'status': row?.status,
          'reason': row?.reason,
          'retry_attempt': row?.retryAttempt,
          'retry_budget': row?.retryBudget,
          'has_resume_at': row?.resumeAt != null,
        });
        if (payload['status'] == 'waiting' && projectionAtWait == null) {
          projectionAtWait = historyProjection();
        }
      });

      // The 429 OpenCodeGo returned for the reported turn: a capacity rejection
      // the classifier reads as an upstream rate limit, whose automatic budget
      // is 3.
      await RunnerRecoveryCoordinator(_ChainHost(sessionId)).handleRuntimeFailure(
        httpFailure(
          429,
          'Too many requests to the upstream provider. Rate limit reached.',
        ),
        providerInstanceId: 'provider-1',
        modelId: 'gpt-4o',
        attempt: 0,
        streamStarted: false,
        failedProviderInstanceIds: <String>{},
      );

      final waiting = noticePayloads.firstWhere(
        (payload) => payload['status'] == 'waiting',
      );
      expect(waiting['reason'], 'upstream_rate_limit');
      expect(waiting['retry_attempt'], 1);
      expect(waiting['retry_budget'], 3);
      expect(waiting['resume_at'], isNotNull);

      final rowWhileWaiting =
          persistedAtPublish[noticePayloads.indexOf(waiting)];
      expect(rowWhileWaiting['status'], 'waiting');
      expect(
        rowWhileWaiting['retry_attempt'],
        1,
        reason: 'a restart must not lose the attempt the daemon published',
      );
      expect(rowWhileWaiting['retry_budget'], 3);
      expect(rowWhileWaiting['has_resume_at'], isTrue);

      // What `session show --json` answered while the daemon waited: the notice
      // the live broadcast had, with the counters, and the classification both
      // `session show` and `session retry` derive from it.
      final atWait = projectionAtWait;
      expect(atWait, isNotNull, reason: 'the projection is read at the wait');
      final notice = Map<String, dynamic>.from(
        atWait!['runtime_notice'] as Map,
      );
      expect(notice['status'], 'waiting');
      expect(notice['reason'], 'upstream_rate_limit');
      expect(notice['retry_attempt'], 1);
      expect(notice['retry_budget'], 3);
      expect(
        (notice['actions'] as List),
        containsAll(<String>['stop', 'retry', 'changeProvider']),
      );

      final retry = RuntimeRetryState.fromProjection(atWait);
      expect(retry.executionState, 'waiting');
      expect(retry.isAutoRetrying, isTrue);
      expect(retry.retryLabel, 'retrying (1/3)');
      expect(retry.reason, 'upstream_rate_limit');

      // A reader that arrives after the retry started still sees a recovery in
      // progress rather than a stopped turn.
      final after = persisted.findNotice(sessionId);
      expect(after, isNotNull);
      expect(
        RuntimeRetryState.fromProjection(historyProjection()).isAutoRetrying,
        isTrue,
        reason: 'a retry in flight is never reported as a stopped turn',
      );
    });
  });

  group('automaticRetryNote', () {
    late RunnerRecoveryCoordinator coordinator;

    setUp(() => coordinator = RunnerRecoveryCoordinator(_Host()));

    test('states that the automatic budget gave up', () {
      final note = coordinator.automaticRetryNote(
        attempt: 1,
        budget: 1,
        streamStarted: false,
      );
      expect(note, contains('gave up after 1 attempt'));
      expect(note, contains('retry manually'));

      expect(
        coordinator.automaticRetryNote(
          attempt: 3,
          budget: 3,
          streamStarted: false,
        ),
        contains('gave up after 3 attempts'),
      );
    });

    test('states that streaming output blocked the automatic retry', () {
      expect(
        coordinator.automaticRetryNote(
          attempt: 0,
          budget: 1,
          streamStarted: true,
        ),
        contains('already started streaming'),
      );
    });

    test('stays silent for a retry that is still available or never eligible',
        () {
      expect(
        coordinator.automaticRetryNote(
          attempt: 0,
          budget: 1,
          streamStarted: false,
        ),
        isEmpty,
        reason: 'a retry is still scheduled, so nothing is exhausted yet',
      );
      expect(
        coordinator.automaticRetryNote(
          attempt: 0,
          budget: 0,
          streamStarted: false,
        ),
        isEmpty,
        reason: 'a failure that is never retried needs no explanation',
      );
    });
  });
}
