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
