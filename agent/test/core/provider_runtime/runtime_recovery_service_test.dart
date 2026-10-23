import 'package:test/test.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_protocol_constants.dart';
import 'package:sanad_agent/core/provider_runtime/provider_rate_limiter.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_failure_reason.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_notice.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_recovery_service.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/persisted_runtime_state_repository.dart';
import 'package:sanad_agent/evolution/models/session_execution_snapshot.dart';

void main() {
  late AgentStateDatabase state;
  late ProviderInstanceRepository repo;
  late ProviderInstanceService instanceService;
  late List<Map<String, dynamic>> emitted;
  late RuntimeRecoveryService recovery;

  setUp(() {
    state = AgentStateDatabase.inMemory();
    repo = ProviderInstanceRepository.fromDatabase(state.db);
    instanceService = ProviderInstanceService(repo);
    emitted = [];
    recovery = RuntimeRecoveryService(
      repo,
      ProviderRateLimiter(),
      noticeSink: emitted.add,
      autoFailoverEnabled: true,
    );
  });

  tearDown(() => state.dispose());

  /// Helper: create a ready instance with a model.
  String readyInstance({
    required String templateId,
    required String name,
    String model = 'gpt-4o',
    bool allowAutoFailover = true,
    int rpm = 0,
  }) {
    final inst = instanceService.create(
      templateId: templateId,
      displayName: name,
      authMethod: ProviderAuthMethod.apiKey,
      defaultModel: model,
      requestsPerMinute: rpm,
      allowAutoFailover: allowAutoFailover,
    );
    // Force-ready via repo so we don't need credentials/cache.
    repo.update(inst.copyWith(status: InstanceStatus.ready));
    return inst.id;
  }

  group('RuntimeRecoveryService — notice emission', () {
    test(
      'reportRateLimitWait emits a waiting notice with limit + resume_at',
      () {
        recovery.reportRateLimitWait(
          sessionId: 's1',
          providerInstanceId: 'p1',
          retryAfter: const Duration(seconds: 24),
          limit: 38,
        );
        expect(emitted, hasLength(1));
        final payload = emitted.single;
        expect(payload['status'], equals('waiting'));
        expect(payload['reason'], equals('rate_limit'));
        expect(payload['limit']['requests_per_minute'], equals(38));
        expect(payload['resume_at'], isNotNull);
        expect(payload['actions'], contains('stop'));
      },
    );

    test('reportFailure emits blocked notice for network error', () {
      final decision = recovery.reportFailure(
        sessionId: 's1',
        reason: RuntimeFailureReason.networkError,
        providerInstanceId: 'p1',
      );
      expect(decision.noticeStatus, equals(RuntimeNoticeStatus.blocked));
      expect(emitted, hasLength(1));
      expect(emitted.single['status'], equals('blocked'));
      expect(emitted.single['reason'], equals('network_error'));
    });

    test('reportFailure prepends stop for blocked auth notice', () {
      recovery.reportFailure(
        sessionId: 's1',
        reason: RuntimeFailureReason.auth,
        providerInstanceId: 'p1',
      );
      expect(emitted.single['actions'], contains('stop'));
    });

    test('reportFailure emits fatal notice for content policy', () {
      recovery.reportFailure(
        sessionId: 's1',
        reason: RuntimeFailureReason.contentPolicyBlocked,
      );
      expect(emitted.single['status'], equals('fatal'));
    });

    test(
      'a scheduled automatic retry is a waiting notice, never blocked',
      () {
        // `timeout` presents as blocked by default, but the runtime has already
        // scheduled attempt 1 of 1. `blocked` would tell every observer to give
        // up on a turn the daemon is about to continue (Task 141).
        recovery.reportFailure(
          sessionId: 's1',
          reason: RuntimeFailureReason.timeout,
          providerInstanceId: 'p1',
          retryAfter: const Duration(seconds: 2),
          automaticRetryScheduled: true,
          retryAttempt: 1,
          retryBudget: 1,
        );
        final payload = emitted.single;
        expect(payload['status'], equals('waiting'));
        expect(payload['reason'], equals('timeout'));
        expect(payload['retry_attempt'], equals(1));
        expect(payload['retry_budget'], equals(1));
        expect(payload['resume_at'], isNotNull);
        expect(payload['actions'], contains('stop'));
        expect(
          payload['actions'],
          isNot(contains('retry')),
          reason: 'a manual retry has nothing to resume: the attempt is '
              'already scheduled',
        );
      },
    );

    test('an exhausted retry budget is a blocked notice with no budget left', () {
      recovery.reportFailure(
        sessionId: 's1',
        reason: RuntimeFailureReason.timeout,
        providerInstanceId: 'p1',
        retryAttempt: 1,
        retryBudget: 1,
      );
      final payload = emitted.single;
      expect(payload['status'], equals('blocked'));
      expect(payload['retry_attempt'], equals(1));
      expect(payload['retry_budget'], equals(1));
      expect(payload['resume_at'], isNull);
    });

    test('clear emits a cleared notice and removes active state', () {
      recovery.reportRateLimitWait(
        sessionId: 's1',
        providerInstanceId: 'p1',
        retryAfter: const Duration(seconds: 5),
      );
      expect(recovery.hasActiveNotice('s1'), isTrue);
      recovery.clear('s1');
      expect(recovery.hasActiveNotice('s1'), isFalse);
      expect(emitted.last['status'], equals('cleared'));
    });

    test('emitResuming broadcasts a resuming notice', () {
      recovery.emitResuming(
        sessionId: 's1',
        reason: 'manual_retry',
        message: 'Retrying the last request.',
      );
      expect(emitted.single['status'], equals('resuming'));
      expect(emitted.single['reason'], equals('manual_retry'));
    });
  });

  group('RuntimeRecoveryService — durable execution transitions', () {
    void seedSession(String sessionId) {
      state.db.execute(
        '''
        INSERT INTO sessions (session_id, model, created_at, updated_at)
        VALUES (?, ?, ?, ?)
        ''',
        [sessionId, 'model-a', '2026-07-19', '2026-07-19'],
      );
    }

    test('a retry failure moves resuming work back to waiting', () {
      const sessionId = 's-resuming-wait';
      seedSession(sessionId);
      final persisted = PersistedRuntimeStateRepository.fromState(state);
      recovery.attachPersistedState(persisted);
      persisted.executionState.enqueueWorkItem(
        workItemId: 'work-resuming-wait',
        sessionId: sessionId,
        requestId: 'request-resuming-wait',
        state: SessionWorkState.resuming,
      );

      recovery.reportFailure(
        sessionId: sessionId,
        reason: RuntimeFailureReason.rateLimit,
        requestId: 'request-resuming-wait',
        providerInstanceId: 'provider-a',
        retryAfter: const Duration(seconds: 5),
      );

      expect(
        persisted.findActiveWorkItem(sessionId)?.state,
        SessionWorkState.waiting,
      );
      expect(
        persisted.executionSnapshots.getSnapshot(sessionId).state,
        SessionExecutionState.waiting,
      );
    });

    test('a scheduled automatic retry projects durable execution as waiting', () {
      const sessionId = 's-timeout-retrying';
      seedSession(sessionId);
      final persisted = PersistedRuntimeStateRepository.fromState(state);
      recovery.attachPersistedState(persisted);
      persisted.executionState.enqueueWorkItem(
        workItemId: 'work-timeout-retrying',
        sessionId: sessionId,
        requestId: 'request-timeout-retrying',
        state: SessionWorkState.running,
      );

      recovery.reportFailure(
        sessionId: sessionId,
        reason: RuntimeFailureReason.timeout,
        requestId: 'request-timeout-retrying',
        providerInstanceId: 'provider-a',
        retryAfter: const Duration(seconds: 2),
        automaticRetryScheduled: true,
        retryAttempt: 1,
        retryBudget: 1,
      );

      expect(
        persisted.findActiveWorkItem(sessionId)?.state,
        SessionWorkState.waiting,
      );
      expect(
        persisted.executionSnapshots.getSnapshot(sessionId).state,
        SessionExecutionState.waiting,
        reason:
            'a session show reader must see the retry in progress, not a stop',
      );
    });

    test('a blocking failure promotes waiting work to blocked', () {
      const sessionId = 's-waiting-blocked';
      seedSession(sessionId);
      final persisted = PersistedRuntimeStateRepository.fromState(state);
      recovery.attachPersistedState(persisted);
      persisted.executionState.enqueueWorkItem(
        workItemId: 'work-waiting-blocked',
        sessionId: sessionId,
        requestId: 'request-waiting-blocked',
        state: SessionWorkState.running,
      );
      persisted.transitionWorkItemState(
        workItemId: 'work-waiting-blocked',
        fromState: SessionWorkState.running,
        toState: SessionWorkState.waiting,
      );

      recovery.reportFailure(
        sessionId: sessionId,
        reason: RuntimeFailureReason.networkError,
        requestId: 'request-waiting-blocked',
        providerInstanceId: 'provider-a',
      );

      expect(
        persisted.findActiveWorkItem(sessionId)?.state,
        SessionWorkState.blocked,
      );
      expect(
        persisted.executionSnapshots.getSnapshot(sessionId).state,
        SessionExecutionState.blocked,
      );
    });

    test('a fatal notice projects durable execution as blocked', () {
      const sessionId = 's-running-fatal';
      seedSession(sessionId);
      final persisted = PersistedRuntimeStateRepository.fromState(state);
      recovery.attachPersistedState(persisted);
      persisted.executionState.enqueueWorkItem(
        workItemId: 'work-running-fatal',
        sessionId: sessionId,
        requestId: 'request-running-fatal',
        state: SessionWorkState.running,
      );

      recovery.reportFailure(
        sessionId: sessionId,
        reason: RuntimeFailureReason.contentPolicyBlocked,
        requestId: 'request-running-fatal',
        providerInstanceId: 'provider-a',
      );

      expect(
        persisted.findActiveWorkItem(sessionId)?.state,
        SessionWorkState.blocked,
      );
      expect(
        persisted.executionSnapshots.getSnapshot(sessionId).state,
        SessionExecutionState.blocked,
      );
      expect(
        recovery.activeNotice(sessionId)?.status,
        RuntimeNoticeStatus.fatal,
      );
    });
  });

  group('RuntimeRecoveryService — auto failover candidate selection', () {
    test('returns null when autoFailover disabled', () {
      recovery.autoFailoverEnabled = false;
      readyInstance(templateId: 'openai', name: 'OpenAI A', model: 'gpt-4o');
      final candidate = recovery.selectFailoverCandidate(
        failedInstanceId: 'nonexistent',
        requestedModelId: 'gpt-4o',
        excludedInstanceIds: const {},
      );
      expect(candidate, isNull);
    });

    test('prefers same template + same model', () {
      final a = readyInstance(templateId: 'openai', name: 'OpenAI A');
      final b = readyInstance(templateId: 'openai', name: 'OpenAI B');
      readyInstance(templateId: 'anthropic', name: 'Claude', model: 'gpt-4o');
      final candidate = recovery.selectFailoverCandidate(
        failedInstanceId: a,
        requestedModelId: 'gpt-4o',
        excludedInstanceIds: const {},
      );
      expect(candidate, isNotNull);
      expect(candidate!.id, equals(b));
      expect(candidate.templateId, equals('openai'));
    });

    test('falls back to any template with same model', () {
      final a = readyInstance(templateId: 'openai', name: 'OpenAI A');
      final other = readyInstance(
        templateId: 'anthropic',
        name: 'Claude',
        model: 'gpt-4o',
      );
      // No other openai instance with gpt-4o exists.
      final candidate = recovery.selectFailoverCandidate(
        failedInstanceId: a,
        requestedModelId: 'gpt-4o',
        excludedInstanceIds: const {},
      );
      expect(candidate, isNotNull);
      expect(candidate!.id, equals(other));
    });

    test('skips instances with allowAutoFailover=false', () {
      final a = readyInstance(templateId: 'openai', name: 'OpenAI A');
      readyInstance(
        templateId: 'openai',
        name: 'OpenAI Personal',
        model: 'gpt-4o',
        allowAutoFailover: false,
      );
      final candidate = recovery.selectFailoverCandidate(
        failedInstanceId: a,
        requestedModelId: 'gpt-4o',
        excludedInstanceIds: const {},
      );
      expect(candidate, isNull);
    });

    test('skips excluded (rate-limited/exhausted) instances', () {
      final a = readyInstance(templateId: 'openai', name: 'OpenAI A');
      final b = readyInstance(templateId: 'openai', name: 'OpenAI B');
      final candidate = recovery.selectFailoverCandidate(
        failedInstanceId: a,
        requestedModelId: 'gpt-4o',
        excludedInstanceIds: {b},
      );
      expect(candidate, isNull);
    });

    test('skips non-ready instances', () {
      final a = readyInstance(templateId: 'openai', name: 'OpenAI A');
      // Create a draft instance (not ready) with the same model.
      instanceService.create(
        templateId: 'openai',
        displayName: 'OpenAI Draft',
        authMethod: ProviderAuthMethod.apiKey,
        defaultModel: 'gpt-4o',
      );
      final candidate = recovery.selectFailoverCandidate(
        failedInstanceId: a,
        requestedModelId: 'gpt-4o',
        excludedInstanceIds: const {},
      );
      expect(candidate, isNull);
    });

    test('returns null when no model match exists', () {
      final a = readyInstance(templateId: 'openai', name: 'OpenAI A');
      readyInstance(
        templateId: 'openai',
        name: 'OpenAI B',
        model: 'gpt-4o-mini',
      );
      final candidate = recovery.selectFailoverCandidate(
        failedInstanceId: a,
        requestedModelId: 'gpt-4o',
        excludedInstanceIds: const {},
      );
      expect(candidate, isNull);
    });
  });

  group('RuntimeRecoveryService — abort + cancel token', () {
    test('cancel token exists before the first notice is emitted', () {
      final token = recovery.cancelToken('s1');
      expect(token, isA<Future<void>>());
    });

    test('abort makes the cancel token resolve', () async {
      recovery.reportRateLimitWait(
        sessionId: 's1',
        providerInstanceId: 'p1',
        retryAfter: const Duration(seconds: 5),
      );
      final token = recovery.cancelToken('s1');
      recovery.abort('s1');
      // The token should complete.
      expect(token, completes);
    });

    test('activeNotice returns the stored notice', () {
      recovery.reportRateLimitWait(
        sessionId: 's1',
        providerInstanceId: 'p1',
        retryAfter: const Duration(seconds: 5),
      );
      final notice = recovery.activeNotice('s1');
      expect(notice, isNotNull);
      expect(notice!.status, equals(RuntimeNoticeStatus.waiting));
    });

    test('waitForRetry returns false when abort cancels the wait', () async {
      final future = recovery.waitForRetry('s1', const Duration(seconds: 5));
      recovery.abort('s1');
      await expectLater(future, completion(isFalse));
    });
  });

  group('RuntimeRecoveryService — restoreActiveNotices', () {
    test(
      'restores waiting notices into active memory and keeps blocked notices durable-only',
      () {
        final persisted = PersistedRuntimeStateRepository(state.db);
        recovery.attachPersistedState(persisted);
        final futureResume = DateTime.now().add(const Duration(minutes: 3));
        persisted.upsertNotice(
          sessionId: 's-wait',
          requestId: 'req-wait',
          status: 'waiting',
          reason: 'rateLimit',
          title: 'Wait',
          message: 'waiting',
          providerInstanceId: 'prov-wait',
          resumeAt: futureResume.toUtc().toIso8601String(),
        );
        persisted.upsertNotice(
          sessionId: 's-block',
          requestId: 'req-block',
          status: 'blocked',
          reason: 'unknown',
          title: 'Blocked',
          message: 'blocked',
          providerInstanceId: 'prov-block',
        );

        recovery.restoreActiveNotices();

        expect(recovery.hasActiveNotice('s-wait'), isTrue);
        expect(
          recovery.activeNotice('s-wait')?.status,
          RuntimeNoticeStatus.waiting,
        );
        expect(recovery.hasActiveNotice('s-block'), isFalse);
        expect(recovery.cancelToken('s-wait'), isA<Future<void>>());
        expect(persisted.findNotice('s-block')?.status, equals('blocked'));
      },
    );

    test(
      'future resume_at restores provider cooldown and past resume_at becomes immediately eligible',
      () {
        final persisted = PersistedRuntimeStateRepository(state.db);
        final limiter = ProviderRateLimiter();
        recovery = RuntimeRecoveryService(
          repo,
          limiter,
          noticeSink: emitted.add,
          autoFailoverEnabled: true,
        );
        recovery.attachPersistedState(persisted);

        final futureResume = DateTime.now().add(const Duration(seconds: 30));
        final pastResume = DateTime.now().subtract(const Duration(seconds: 30));
        persisted.upsertNotice(
          sessionId: 's-future',
          requestId: 'req-future',
          status: 'waiting',
          reason: 'rateLimit',
          title: 'Future wait',
          message: 'wait',
          providerInstanceId: 'prov-future',
          resumeAt: futureResume.toUtc().toIso8601String(),
        );
        persisted.upsertNotice(
          sessionId: 's-past',
          requestId: 'req-past',
          status: 'waiting',
          reason: 'rateLimit',
          title: 'Past wait',
          message: 'wait',
          providerInstanceId: 'prov-past',
          resumeAt: pastResume.toUtc().toIso8601String(),
        );

        recovery.restoreActiveNotices();

        final futurePermit = limiter.tryAcquire('prov-future', 1);
        expect(futurePermit.granted, isFalse);
        expect(futurePermit.retryAfter, greaterThan(Duration.zero));

        final pastPermit = limiter.tryAcquire('prov-past', 1);
        expect(pastPermit.granted, isTrue);
      },
    );

    test(
      'restored future waiting notice triggers the auto-resume callback',
      () async {
        final persisted = PersistedRuntimeStateRepository(state.db);
        recovery.attachPersistedState(persisted);

        final resumed = <String>[];
        recovery.attachResumeHandler((notice) async {
          resumed.add(notice.sessionId);
        });

        final soon = DateTime.now().add(const Duration(milliseconds: 30));
        persisted.upsertNotice(
          sessionId: 's-auto-future',
          requestId: 'req-auto-future',
          status: 'waiting',
          reason: 'rateLimit',
          title: 'Wait',
          message: 'waiting',
          providerInstanceId: 'prov-auto-future',
          resumeAt: soon.toUtc().toIso8601String(),
        );

        recovery.restoreActiveNotices();
        await Future<void>.delayed(const Duration(milliseconds: 80));

        expect(resumed, equals(['s-auto-future']));
      },
    );

    test(
      'restored past waiting notice triggers the auto-resume callback once',
      () async {
        final persisted = PersistedRuntimeStateRepository(state.db);
        recovery.attachPersistedState(persisted);

        final resumed = <String>[];
        recovery.attachResumeHandler((notice) async {
          resumed.add(notice.sessionId);
        });

        final past = DateTime.now().subtract(const Duration(seconds: 1));
        persisted.upsertNotice(
          sessionId: 's-auto-past',
          requestId: 'req-auto-past',
          status: 'waiting',
          reason: 'rateLimit',
          title: 'Wait',
          message: 'waiting',
          providerInstanceId: 'prov-auto-past',
          resumeAt: past.toUtc().toIso8601String(),
        );

        recovery.restoreActiveNotices();
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(resumed, equals(['s-auto-past']));
      },
    );
  });
}
