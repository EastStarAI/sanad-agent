import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/core/provider_runtime/provider_protocol_constants.dart';
import 'package:sanad_agent/core/provider_runtime/provider_rate_limiter.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_failure_reason.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_notice.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_recovery_exception.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_recovery_service.dart';
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
}
