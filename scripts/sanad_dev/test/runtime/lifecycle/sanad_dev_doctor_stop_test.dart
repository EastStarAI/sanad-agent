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

  group('stale Agent-only recovery', () {
    runtime_ownership.RuntimeLauncherRecord record({
      String status = 'agent-only',
      List<int> clientPids = const [],
      List<int> vmServicePorts = const [],
      String workspaceHash = testWorkspaceHash,
      String sourceRoot = '/repo',
      int agentPort = 58092,
      String sanadHome = '/isolated/home',
      String launcherId = 'launcher-stale',
      String runtimeNonce = 'nonce-stale',
    }) => runtime_ownership.RuntimeLauncherRecord(
      launcherId: launcherId,
      runtimeNonce: runtimeNonce,
      launcherPid: 999,
      launcherProcessIdentity: 'process-999',
      workspaceHash: workspaceHash,
      sourceRoot: sourceRoot,
      agentPort: agentPort,
      sanadHome: sanadHome,
      preferencesPrefix: 'sanad.test.',
      clientPids: clientPids,
      vmServicePorts: vmServicePorts,
      status: status,
      updatedAt: DateTime.utc(2026, 9, 20),
    );

    sanad_dev.AgentInstance agent({
      int port = 58092,
      String workspaceHash = testWorkspaceHash,
      String launcherId = 'launcher-stale',
      String runtimeNonce = 'nonce-stale',
      String? sanadHome = '/isolated/home',
    }) => sanad_dev.AgentInstance(
      port,
      workspaceHash,
      'worktree',
      launcherId: launcherId,
      runtimeNonce: runtimeNonce,
      sanadHome: sanadHome,
    );

    sanad_dev.RuntimeProcessState state({
      sanad_dev.AgentInstance? liveAgent,
      List<sanad_dev.ClientInstance> clients = const [],
      List<sanad_dev.ClientInstance> crossOwnedClients = const [],
      bool agentAmbiguous = false,
    }) => sanad_dev.RuntimeProcessState(
      agent: liveAgent ?? agent(),
      ownedClients: clients,
      crossOwnedClients: crossOwnedClients,
      ambiguousClients: const [],
      agentAmbiguous: agentAmbiguous,
    );

    test('live-surface matching includes launcher identity and nonce', () {
      final lease = record();
      expect(
        sanad_dev.agentMatchesLauncherRecord(
          agent(port: 59999, launcherId: 'launcher-stale', runtimeNonce: 'x'),
          lease,
        ),
        isTrue,
      );
      expect(
        sanad_dev.agentMatchesLauncherRecord(
          agent(port: 59999, launcherId: 'x', runtimeNonce: 'nonce-stale'),
          lease,
        ),
        isTrue,
      );

      final client = sanad_dev.ClientInstance(
        51999,
        'token',
        testClientDirectory,
        'windows',
        launchProfile: testOwnedProfile(gatewayPort: 59998),
      );
      expect(
        sanad_dev.clientMatchesLauncherRecord(
          client,
          record(agentPort: 59999, launcherId: 'launcher-1', runtimeNonce: 'x'),
        ),
        isTrue,
      );
      expect(
        sanad_dev.clientMatchesLauncherRecord(
          client,
          record(agentPort: 59999, launcherId: 'x', runtimeNonce: 'nonce-1'),
        ),
        isTrue,
      );
      expect(
        sanad_dev.clientMatchesLauncherRecord(
          client,
          record(agentPort: 59999, launcherId: 'x', runtimeNonce: 'y'),
        ),
        isFalse,
      );
    });

    test('admits only the exact stale Agent-only identity', () {
      expect(
        sanad_dev.staleAgentRecoveryBlocker(
          runtime: testLinkedRuntime,
          state: state(),
          record: record(),
          activeHome: '/isolated/home',
          launcherLive: false,
        ),
        isNull,
      );
      expect(
        sanad_dev.staleAgentRecoveryBlocker(
          runtime: testLinkedRuntime,
          state: state(),
          record: record(status: 'running', clientPids: [101]),
          activeHome: '/isolated/home',
          launcherLive: false,
        ),
        contains('exact Agent-only'),
      );
      expect(
        sanad_dev.staleAgentRecoveryBlocker(
          runtime: testLinkedRuntime,
          state: state(liveAgent: agent(runtimeNonce: 'foreign')),
          record: record(),
          activeHome: '/isolated/home',
          launcherLive: false,
        ),
        contains('identity or nonce'),
      );
      expect(
        sanad_dev.staleAgentRecoveryBlocker(
          runtime: testLinkedRuntime,
          state: state(
            clients: [
              sanad_dev.ClientInstance(
                51084,
                'token',
                testClientDirectory,
                'windows',
                pid: 101,
                launchProfile: testOwnedProfile(),
              ),
            ],
          ),
          record: record(),
          activeHome: '/isolated/home',
          launcherLive: false,
        ),
        contains('live Clients'),
      );
      expect(
        sanad_dev.staleAgentRecoveryBlocker(
          runtime: testLinkedRuntime,
          state: state(),
          record: record(),
          activeHome: '/isolated/home',
          launcherLive: true,
        ),
        contains('still live'),
      );
    });

    test('rejects every mismatched ownership dimension', () {
      final foreignClient = sanad_dev.ClientInstance(
        51084,
        'token',
        testClientDirectory,
        'windows',
        pid: 101,
        launchProfile: testOwnedProfile(),
      );
      final cases =
          <
            ({
              String name,
              sanad_dev.RuntimeProcessState processState,
              runtime_ownership.RuntimeLauncherRecord lease,
              String activeHome,
            })
          >[
            (
              name: 'Agent port',
              processState: state(liveAgent: agent(port: 58093)),
              lease: record(),
              activeHome: '/isolated/home',
            ),
            (
              name: 'workspace',
              processState: state(liveAgent: agent(workspaceHash: 'foreign')),
              lease: record(),
              activeHome: '/isolated/home',
            ),
            (
              name: 'source',
              processState: state(),
              lease: record(sourceRoot: '/foreign'),
              activeHome: '/isolated/home',
            ),
            (
              name: 'active Home',
              processState: state(),
              lease: record(),
              activeHome: '/foreign/home',
            ),
            (
              name: 'Agent Home',
              processState: state(liveAgent: agent(sanadHome: null)),
              lease: record(),
              activeHome: '/isolated/home',
            ),
            (
              name: 'launcher id',
              processState: state(liveAgent: agent(launcherId: 'foreign')),
              lease: record(),
              activeHome: '/isolated/home',
            ),
            (
              name: 'ambiguous Agent',
              processState: state(agentAmbiguous: true),
              lease: record(),
              activeHome: '/isolated/home',
            ),
            (
              name: 'cross-owned Client',
              processState: state(crossOwnedClients: [foreignClient]),
              lease: record(),
              activeHome: '/isolated/home',
            ),
          ];

      for (final testCase in cases) {
        expect(
          sanad_dev.staleAgentRecoveryBlocker(
            runtime: testLinkedRuntime,
            state: testCase.processState,
            record: testCase.lease,
            activeHome: testCase.activeHome,
            launcherLive: false,
          ),
          isNotNull,
          reason: testCase.name,
        );
      }
    });

    test('doctor recommends recovery only for admitted Agent-only orphan', () {
      final orphaned = sanad_dev.RuntimeOwnershipAssessment(
        classification: runtime_ownership.RuntimeOwnershipClass.orphaned,
        state: state(),
      );
      expect(
        sanad_dev.doctorNextAction(
          ownership: orphaned,
          state: state(),
          staleAgentRecoveryAvailable: true,
          staleRecordRemovalAvailable: false,
        ),
        contains('doctor --fix'),
      );
      expect(
        sanad_dev.doctorNextAction(
          ownership: orphaned,
          state: state(),
          staleAgentRecoveryAvailable: false,
          staleRecordRemovalAvailable: false,
        ),
        isNot(contains('cleanup-target-orphans')),
      );

      final clientOnly = sanad_dev.RuntimeProcessState(
        agent: null,
        ownedClients: const [],
        crossOwnedClients: const [],
        ambiguousClients: const [],
        agentAmbiguous: false,
      );
      expect(
        sanad_dev.doctorNextAction(
          ownership: sanad_dev.RuntimeOwnershipAssessment(
            classification: runtime_ownership.RuntimeOwnershipClass.stopped,
            state: clientOnly,
          ),
          state: clientOnly,
          staleAgentRecoveryAvailable: false,
          staleRecordRemovalAvailable: true,
        ),
        contains('doctor --fix'),
      );
      expect(
        sanad_dev.doctorNextAction(
          ownership: sanad_dev.RuntimeOwnershipAssessment(
            classification: runtime_ownership.RuntimeOwnershipClass.orphaned,
            state: clientOnly,
          ),
          state: clientOnly,
          staleAgentRecoveryAvailable: false,
          staleRecordRemovalAvailable: false,
        ),
        contains('cleanup-target-orphans'),
      );
    });

    test(
      'deletes the lease only after controlled drain and rediscovery',
      () async {
        final events = <String>[];
        final error = await sanad_dev.recoverStaleAgentLease(
          runtime: testLinkedRuntime,
          state: state(),
          record: record(),
          activeHome: '/isolated/home',
          launcherLive: false,
          requestPermanentRestart: () async {
            events.add('request');
            return true;
          },
          waitForAgentExit: () async {
            events.add('wait');
            return true;
          },
          launcherIsRunning: () async {
            events.add('launcher');
            return false;
          },
          discoverAgents: () async {
            events.add('agents');
            return const [];
          },
          discoverClients: () async {
            events.add('clients');
            return const [];
          },
          deleteRecord: () async => events.add('delete'),
        );

        expect(error, isNull);
        expect(events, [
          'request',
          'wait',
          'launcher',
          'agents',
          'clients',
          'delete',
        ]);
      },
    );

    test('preserves the lease when drain or post-check fails', () async {
      var deleted = false;
      final rejected = await sanad_dev.recoverStaleAgentLease(
        runtime: testLinkedRuntime,
        state: state(),
        record: record(),
        activeHome: '/isolated/home',
        launcherLive: false,
        requestPermanentRestart: () async => false,
        waitForAgentExit: () async => true,
        launcherIsRunning: () async => false,
        discoverAgents: () async => const [],
        discoverClients: () async => const [],
        deleteRecord: () async => deleted = true,
      );
      expect(rejected, contains('rejected'));
      expect(deleted, isFalse);

      final stillLive = await sanad_dev.recoverStaleAgentLease(
        runtime: testLinkedRuntime,
        state: state(),
        record: record(),
        activeHome: '/isolated/home',
        launcherLive: false,
        requestPermanentRestart: () async => true,
        waitForAgentExit: () async => true,
        launcherIsRunning: () async => false,
        discoverAgents: () async => [agent()],
        discoverClients: () async => const [],
        deleteRecord: () async => deleted = true,
      );
      expect(stillLive, contains('still live'));
      expect(deleted, isFalse);
    });
  });
}
