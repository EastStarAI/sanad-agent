import 'dart:io';

import 'package:test/test.dart';

import 'package:sanad_dev/sanad_dev_cli.dart' as sanad_dev;
import 'package:sanad_dev/src/infrastructure/runtime_component_control.dart'
    as component_control;
import 'package:sanad_dev/src/infrastructure/runtime_context.dart'
    as runtime_context;
import 'package:sanad_dev/src/runtime/ownership/runtime_ownership.dart'
    as runtime_ownership;
import '../../support/sanad_dev_test_fixtures.dart';

void main() {
  test(
    'stop invokes only injected fakes for a completely owned group',
    () async {
      final agent = sanad_dev.AgentInstance(
        58092,
        testWorkspaceHash,
        'worktree',
      );
      final owned = sanad_dev.ClientInstance(
        51084,
        'token',
        testClientDirectory,
        'macos',
        pid: 101,
        launchProfile: testOwnedProfile(),
      );
      final state = sanad_dev.selectRuntimeProcessState(
        activeAgents: [agent],
        activeClients: [owned],
        runtime: testLinkedRuntime,
        pathMatches: (first, second) => first == second,
      );
      final requestedLauncherPids = <int>[];
      final record = runtime_ownership.RuntimeLauncherRecord(
        launcherId: 'launcher-1',
        runtimeNonce: 'nonce-1',
        launcherPid: 999,
        launcherProcessIdentity: 'process-999',
        workspaceHash: testWorkspaceHash,
        sourceRoot: '/repo',
        agentPort: 58092,
        sanadHome: '/isolated/home',
        preferencesPrefix: runtime_context.deriveSanadDevPreferencesPrefix(
          '/isolated/home',
        ),
        clientPids: const [101],
        vmServicePorts: const [51084],
        status: 'running',
        updatedAt: DateTime.utc(2026, 7, 29),
      );
      final stopped = await sanad_dev.stopManagedRuntimeLauncher(
        sanad_dev.RuntimeOwnershipAssessment(
          classification: runtime_ownership.RuntimeOwnershipClass.managed,
          state: state,
          record: record,
        ),
        requestStop: (record) async {
          requestedLauncherPids.add(record.launcherPid);
        },
        processRunning: (_) async => false,
      );

      expect(stopped, isTrue);
      expect(requestedLauncherPids, [999]);
    },
  );

  test(
    'timed-out component request removes only its pending manifest',
    () async {
      final home = await Directory.systemTemp.createTemp(
        'sanad-component-timeout-',
      );
      addTearDown(() => home.delete(recursive: true));
      final record = runtime_ownership.RuntimeLauncherRecord(
        launcherId: 'launcher-timeout',
        runtimeNonce: 'nonce-timeout',
        launcherPid: 999,
        launcherProcessIdentity: 'process-999',
        workspaceHash: testWorkspaceHash,
        sourceRoot: '/repo',
        agentPort: 58094,
        sanadHome: home.path,
        preferencesPrefix: 'sanad.timeout.',
        clientPids: const [],
        vmServicePorts: const [],
        status: 'agent-only',
        updatedAt: DateTime.utc(2026, 7, 30),
      );

      final succeeded = await sanad_dev.requestManagedComponentAction(
        record,
        action: component_control.RuntimeComponentAction.stop,
        target: component_control.RuntimeComponentTarget.agent,
        timeout: const Duration(milliseconds: 20),
      );

      expect(succeeded, isFalse);
      expect(
        File(
          component_control.runtimeComponentControlPath(home.path, 58094),
        ).existsSync(),
        isFalse,
      );
    },
  );

  test('doctor removes stale lease only when every live surface is absent', () {
    expect(
      sanad_dev.canRemoveStaleLauncherRecord(
        launcherLive: false,
        endpointLive: false,
        clientLive: false,
      ),
      isTrue,
    );
    for (final evidence in const [
      (true, false, false),
      (false, true, false),
      (false, false, true),
    ]) {
      expect(
        sanad_dev.canRemoveStaleLauncherRecord(
          launcherLive: evidence.$1,
          endpointLive: evidence.$2,
          clientLive: evidence.$3,
        ),
        isFalse,
      );
    }
  });

  test('stop refuses before invoking any fake for blocked ownership', () async {
    final blocked = sanad_dev.ClientInstance(
      51084,
      'token',
      testClientDirectory,
      'macos',
      pid: 101,
      launchProfile: testOwnedProfile(gatewayPort: 58085),
    );
    final state = sanad_dev.selectRuntimeProcessState(
      activeAgents: [sanad_dev.AgentInstance(58085, 'aabbccdd', 'default')],
      activeClients: [blocked],
      runtime: testLinkedRuntime,
      pathMatches: (first, second) => first == second,
    );
    var calls = 0;

    final stopped = await sanad_dev.stopManagedRuntimeLauncher(
      sanad_dev.RuntimeOwnershipAssessment(
        classification: runtime_ownership.RuntimeOwnershipClass.crossOwned,
        state: state,
      ),
      requestStop: (_) async {
        calls++;
      },
      processRunning: (_) async {
        calls++;
        return false;
      },
    );

    expect(stopped, isFalse);
    expect(calls, 0);
  });
}
