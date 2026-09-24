import 'dart:io';

import 'package:test/test.dart';

import 'package:sanad_dev/sanad_dev_cli.dart' as sanad_dev;
import 'package:sanad_dev/src/infrastructure/client_launch_profile.dart'
    as launch_profile;
import 'package:sanad_dev/src/infrastructure/runtime_context.dart'
    as runtime_context;
import 'package:sanad_dev/src/runtime/ownership/runtime_ownership.dart'
    as runtime_ownership;
import '../../support/sanad_dev_test_fixtures.dart';

void main() {
  test('source match connected to another workspace is cross-owned', () {
    final client = sanad_dev.ClientInstance(
      51084,
      'token',
      testClientDirectory,
      'macos',
      pid: 12926,
      launchProfile: testOwnedProfile(gatewayPort: 58085),
    );
    final state = sanad_dev.selectRuntimeProcessState(
      activeAgents: [sanad_dev.AgentInstance(58085, 'aabbccdd', 'default')],
      activeClients: [client],
      runtime: testLinkedRuntime,
      pathMatches: (first, second) => first == second,
    );

    expect(state.agent, isNull);
    expect(state.crossOwnedClients, [client]);
    expect(state.mutationAllowed, isFalse);
    expect(sanad_dev.runtimeStatusLabel(state), contains('stop refused'));
    expect(sanad_dev.crossOwnedRunMessage(), isNot(contains('sanad-dev stop')));
  });

  test('missing or contradictory launch identity fails closed', () {
    final agent = sanad_dev.AgentInstance(58092, testWorkspaceHash, 'worktree');
    final missing = sanad_dev.ClientInstance(
      51084,
      'token',
      testClientDirectory,
      'macos',
      pid: 101,
    );
    final contradictory = sanad_dev.ClientInstance(
      51085,
      'token',
      testClientDirectory,
      'macos',
      pid: 102,
      launchProfile: testOwnedProfile(preferencesPrefix: 'sanad.wrong.'),
    );

    final state = sanad_dev.selectRuntimeProcessState(
      activeAgents: [agent],
      activeClients: [missing, contradictory],
      runtime: testLinkedRuntime,
      pathMatches: (first, second) => first == second,
    );

    expect(state.ownedClients, isEmpty);
    expect(state.ambiguousClients, [missing, contradictory]);
    expect(state.mutationAllowed, isFalse);
  });

  test('managed launch profile remains owned while Agent is paused', () {
    final client = sanad_dev.ClientInstance(
      51084,
      'token',
      testClientDirectory,
      'macos',
      pid: 101,
      launchProfile: testOwnedProfile(),
    );

    final state = sanad_dev.selectRuntimeProcessState(
      activeAgents: const [],
      activeClients: [client],
      runtime: testLinkedRuntime,
      pathMatches: (first, second) => first == second,
    );

    expect(state.agent, isNull);
    expect(state.ownedClients, [client]);
    expect(sanad_dev.runtimeStatusLabel(state), 'running (client only)');
  });

  test(
    'standalone clone fails closed while another primary owner is active',
    () {
      final conflict = sanad_dev.primaryResourceOwnershipConflict(
        testPrimaryRuntime,
        [sanad_dev.AgentInstance(58085, 'different', 'default')],
      );
      expect(conflict, contains('owned by another Git workspace'));
      expect(conflict, contains('absolute --home'));
      expect(
        sanad_dev.primaryResourceOwnershipConflict(testPrimaryRuntime, [
          sanad_dev.AgentInstance(58085, 'aabbccdd', 'default'),
        ]),
        isNull,
      );
      final foreignPrimaryClient = sanad_dev.ClientInstance(
        51002,
        'token',
        '/other/clone/client',
        'macos',
        launchProfile: launch_profile.extractClientLaunchProfile(const [
          'flutter',
          'run',
          '--dart-define=SANAD_HOME=/users/developer/.sanad',
        ]),
      );
      expect(
        sanad_dev.primaryResourceOwnershipConflict(
          testPrimaryRuntime,
          const [],
          activeClients: [foreignPrimaryClient],
        ),
        isNotNull,
      );
    },
  );

  test(
    'exact launcher lease stays managed across nested Git-root hashes',
    () async {
      final home = await Directory.systemTemp.createTemp('sanad-managed-home');
      addTearDown(() => home.delete(recursive: true));
      final runtime = createTestRuntime(
        vmServicePort: 51084,
        sanadHome: home.path,
        runtimeDirectory: '${home.path}${Platform.pathSeparator}runtime',
        platformNeutral: true,
      );
      final agent = sanad_dev.AgentInstance(
        58092,
        'public-submodule-hash',
        'worktree',
        launcherId: 'launcher-1',
        runtimeNonce: 'nonce-1',
      );
      final client = sanad_dev.ClientInstance(
        51084,
        'token',
        testClientDirectory,
        'macos',
        pid: 101,
        launchProfile: testOwnedProfile(sanadHome: home.path),
      );
      final state = sanad_dev.selectRuntimeProcessState(
        activeAgents: [agent],
        activeClients: [client],
        runtime: runtime,
        pathMatches: (first, second) => first == second,
      );
      await runtime_ownership.writeRuntimeLauncherRecord(
        runtime_ownership.RuntimeLauncherRecord(
          launcherId: 'launcher-1',
          runtimeNonce: 'nonce-1',
          launcherPid: 999,
          launcherProcessIdentity: 'process-999',
          workspaceHash: testWorkspaceHash,
          sourceRoot: runtime.repositoryRoot,
          agentPort: 58092,
          sanadHome: home.path,
          preferencesPrefix: runtime_context.deriveSanadDevPreferencesPrefix(
            home.path,
          ),
          clientPids: const [101],
          vmServicePorts: const [51084],
          status: 'running',
          updatedAt: DateTime.utc(2026, 7, 29),
        ),
      );

      final assessment = await sanad_dev.assessRuntimeOwnership(
        runtime: runtime,
        state: state,
        processRunning: (_) async => true,
        processIdentity: (_) async => 'process-999',
      );

      expect(
        assessment.classification,
        runtime_ownership.RuntimeOwnershipClass.managed,
      );
    },
  );

  test(
    'managed lease remains authoritative beside an unmanaged Client',
    () async {
      final home = await Directory.systemTemp.createTemp(
        'sanad-managed-with-manual-',
      );
      addTearDown(() => home.delete(recursive: true));
      final runtime = createTestRuntime(
        vmServicePort: 51084,
        sanadHome: home.path,
        runtimeDirectory: '${home.path}${Platform.pathSeparator}runtime',
        platformNeutral: true,
      );
      final managed = sanad_dev.ClientInstance(
        51084,
        'token',
        testClientDirectory,
        'macos',
        pid: 101,
        launchProfile: testOwnedProfile(sanadHome: home.path),
      );
      final unmanaged = sanad_dev.ClientInstance(
        51085,
        'token',
        testClientDirectory,
        'macos',
        pid: 102,
      );
      final state = sanad_dev.selectRuntimeProcessState(
        activeAgents: [
          sanad_dev.AgentInstance(
            58092,
            testWorkspaceHash,
            'worktree',
            launcherId: 'launcher-1',
            runtimeNonce: 'nonce-1',
          ),
        ],
        activeClients: [managed, unmanaged],
        runtime: runtime,
        pathMatches: (first, second) => first == second,
      );
      expect(state.mutationAllowed, isFalse);
      await runtime_ownership.writeRuntimeLauncherRecord(
        runtime_ownership.RuntimeLauncherRecord(
          launcherId: 'launcher-1',
          runtimeNonce: 'nonce-1',
          launcherPid: 999,
          launcherProcessIdentity: 'process-999',
          workspaceHash: testWorkspaceHash,
          sourceRoot: runtime.repositoryRoot,
          agentPort: 58092,
          sanadHome: home.path,
          preferencesPrefix: runtime_context.deriveSanadDevPreferencesPrefix(
            home.path,
          ),
          clientPids: const [101],
          vmServicePorts: const [51084],
          status: 'running',
          updatedAt: DateTime.utc(2026, 8, 2),
        ),
      );

      final assessment = await sanad_dev.assessRuntimeOwnership(
        runtime: runtime,
        state: state,
        processRunning: (_) async => true,
        processIdentity: (_) async => 'process-999',
      );

      expect(
        assessment.classification,
        runtime_ownership.RuntimeOwnershipClass.managed,
      );
      expect(assessment.state.ownedClients, [managed]);
      expect(assessment.state.blockedClients, isEmpty);
    },
  );

  test('source-switch status is explicitly historical', () {
    expect(
      sanad_dev.runtimeSourceSwitchLabel('complete'),
      'Last source switch: complete',
    );
  });
}
