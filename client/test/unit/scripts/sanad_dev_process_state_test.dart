import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../../../scripts/sanad_dev.dart' as sanad_dev;
import '../../../../scripts/sanad_dev/client_launch_profile.dart' as launch_profile;
import '../../../../scripts/sanad_dev/runtime_component_control.dart' as component_control;
import '../../../../scripts/sanad_dev/runtime_context.dart' as runtime_context;
import '../../../../scripts/sanad_dev/runtime_ownership.dart' as runtime_ownership;

void main() {
  const workspaceHash = '2b962b17';
  const clientDirectory = '/repo/client';
  const linkedRuntime = runtime_context.SanadDevRuntime(
    workspaceRoot: '/repo',
    repositoryRoot: '/repo',
    worktreeId: 'task-$workspaceHash',
    isLinkedWorktree: true,
    usesPrimaryResources: false,
    agentPort: 58092,
    vmServicePort: 51092,
    sanadHome: '/isolated/home',
    runtimeDirectory: '/isolated/runtime',
    branch: 'codex/task',
  );

  test('gateway discovery includes homes recorded by sibling runtimes', () async {
    final temp = await Directory.systemTemp.createTemp(
      'sanad-candidate-homes-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final siblingHome = '${temp.path}${Platform.pathSeparator}sibling-home';
    final runtimeRoot = '${temp.path}${Platform.pathSeparator}runtimes';
    final current = runtime_context.SanadDevRuntime(
      workspaceRoot: '/repo/current',
      repositoryRoot: '/repo/current',
      worktreeId: 'current',
      isLinkedWorktree: true,
      usesPrimaryResources: false,
      agentPort: 58092,
      vmServicePort: 51092,
      sanadHome: '${temp.path}${Platform.pathSeparator}current-home',
      runtimeDirectory: '$runtimeRoot${Platform.pathSeparator}current',
      branch: 'codex/current',
    );
    final sibling = runtime_context.SanadDevRuntime(
      workspaceRoot: '/repo/sibling',
      repositoryRoot: '/repo/sibling',
      worktreeId: 'sibling',
      isLinkedWorktree: true,
      usesPrimaryResources: false,
      agentPort: 58093,
      vmServicePort: 51093,
      sanadHome: siblingHome,
      runtimeDirectory: '$runtimeRoot${Platform.pathSeparator}sibling',
      branch: 'codex/sibling',
    );
    await runtime_context.writeRuntimeRecord(sibling, sibling.toJson());

    final homes = await sanad_dev.discoverLocalGatewayCandidateHomes(current);

    expect(homes, contains(current.sanadHome));
    expect(homes, contains(siblingHome));
  });
  const primaryRuntime = runtime_context.SanadDevRuntime(
    workspaceRoot: '/primary',
    repositoryRoot: '/primary',
    worktreeId: 'main-aabbccdd',
    isLinkedWorktree: false,
    usesPrimaryResources: true,
    agentPort: 58085,
    vmServicePort: 51001,
    sanadHome: '/users/developer/.sanad',
    runtimeDirectory: '/users/developer/.sanad/dev/runtimes/main',
    branch: 'main',
  );

  launch_profile.ClientLaunchProfile ownedProfile({
    int gatewayPort = 58092,
    String preferencesPrefix = '',
    bool includeHash = true,
    String sanadHome = '/isolated/home',
  }) {
    return launch_profile.extractClientLaunchProfile([
      'flutter',
      'run',
      '--dart-define-from-file=config/dev.json',
      '--dart-define=LOCAL_GATEWAY_URL=http://127.0.0.1:$gatewayPort',
      '--dart-define=SANAD_HOME=$sanadHome',
      '--dart-define=SANAD_SHARED_PREFERENCES_PREFIX=${preferencesPrefix.isEmpty ? runtime_context.deriveSanadDevPreferencesPrefix(sanadHome) : preferencesPrefix}',
      '--dart-define=SANAD_DEV_WORKTREE_NAME=repo',
      '--dart-define=SANAD_DEV_WORKTREE_BRANCH=codex/task',
      '--dart-define=SANAD_DEV_LAUNCHER_ID=launcher-1',
      '--dart-define=SANAD_DEV_RUNTIME_NONCE=nonce-1',
      if (includeHash) '--dart-define=SANAD_DEV_WORKSPACE_HASH=$workspaceHash',
    ]);
  }

  test('normal selection ignores inherited requester port semantics', () {
    final workspaceAgent = sanad_dev.AgentInstance(
      58092,
      workspaceHash,
      'worktree',
    );
    final primaryAgent = sanad_dev.AgentInstance(58085, 'aabbccdd', 'default');

    final state = sanad_dev.selectRuntimeProcessState(
      activeAgents: [primaryAgent, workspaceAgent],
      activeClients: const [],
      runtime: linkedRuntime,
    );

    expect(state.agent, same(workspaceAgent));
  });

  test('Agent-only runtime keeps its discovered Sanad Home', () {
    const userHome = '/users/developer/.sanad';
    final state = sanad_dev.RuntimeProcessState(
      agent: sanad_dev.AgentInstance(
        58092,
        workspaceHash,
        'default',
        sanadHome: userHome,
      ),
      ownedClients: const [],
      crossOwnedClients: const [],
      ambiguousClients: const [],
    );

    expect(
      sanad_dev.resolveActiveSanadHome(linkedRuntime, state),
      userHome,
    );
  });

  test('explicit diagnostic port remains an explicit selector', () {
    final workspaceAgent = sanad_dev.AgentInstance(
      58092,
      workspaceHash,
      'worktree',
    );
    final primaryAgent = sanad_dev.AgentInstance(58085, 'aabbccdd', 'default');

    final state = sanad_dev.selectRuntimeProcessState(
      activeAgents: [workspaceAgent, primaryAgent],
      activeClients: const [],
      runtime: linkedRuntime,
      requestedAgentPort: 58085,
    );

    expect(state.agent, same(primaryAgent));
  });

  test('source match connected to another workspace is cross-owned', () {
    final client = sanad_dev.ClientInstance(
      51084,
      'token',
      clientDirectory,
      'macos',
      pid: 12926,
      launchProfile: ownedProfile(gatewayPort: 58085),
    );
    final state = sanad_dev.selectRuntimeProcessState(
      activeAgents: [sanad_dev.AgentInstance(58085, 'aabbccdd', 'default')],
      activeClients: [client],
      runtime: linkedRuntime,
      pathMatches: (first, second) => first == second,
    );

    expect(state.agent, isNull);
    expect(state.crossOwnedClients, [client]);
    expect(state.mutationAllowed, isFalse);
    expect(sanad_dev.runtimeStatusLabel(state), contains('stop refused'));
    expect(sanad_dev.crossOwnedRunMessage(), isNot(contains('sanad-dev stop')));
  });

  test('missing or contradictory launch identity fails closed', () {
    final agent = sanad_dev.AgentInstance(58092, workspaceHash, 'worktree');
    final missing = sanad_dev.ClientInstance(
      51084,
      'token',
      clientDirectory,
      'macos',
      pid: 101,
    );
    final contradictory = sanad_dev.ClientInstance(
      51085,
      'token',
      clientDirectory,
      'macos',
      pid: 102,
      launchProfile: ownedProfile(preferencesPrefix: 'sanad.wrong.'),
    );

    final state = sanad_dev.selectRuntimeProcessState(
      activeAgents: [agent],
      activeClients: [missing, contradictory],
      runtime: linkedRuntime,
      pathMatches: (first, second) => first == second,
    );

    expect(state.ownedClients, isEmpty);
    expect(state.ambiguousClients, [missing, contradictory]);
    expect(state.mutationAllowed, isFalse);
  });

  test('device selector is exact and fails closed on duplicate devices', () {
    final first = sanad_dev.ClientInstance(
      51084,
      'token',
      clientDirectory,
      'macos',
    );
    final second = sanad_dev.ClientInstance(
      51085,
      'token',
      clientDirectory,
      'macos',
    );

    expect(
      sanad_dev.selectClientByDevice(clients: [first, second], deviceId: 'windows').kind,
      sanad_dev.ClientSelectionKind.missing,
    );
    expect(
      sanad_dev.selectClientByDevice(clients: [first, second], deviceId: 'macos').kind,
      sanad_dev.ClientSelectionKind.ambiguous,
    );
    expect(
      sanad_dev
          .selectClientByDevice(
            clients: [first, second],
            deviceId: 'macos',
            vmServicePort: 51085,
          )
          .selected,
      same(second),
    );
  });

  test('managed launch profile remains owned while Agent is paused', () {
    final client = sanad_dev.ClientInstance(
      51084,
      'token',
      clientDirectory,
      'macos',
      pid: 101,
      launchProfile: ownedProfile(),
    );

    final state = sanad_dev.selectRuntimeProcessState(
      activeAgents: const [],
      activeClients: [client],
      runtime: linkedRuntime,
      pathMatches: (first, second) => first == second,
    );

    expect(state.agent, isNull);
    expect(state.ownedClients, [client]);
    expect(sanad_dev.runtimeStatusLabel(state), 'running (client only)');
  });

  test(
    'stop invokes only injected fakes for a completely owned group',
    () async {
      final agent = sanad_dev.AgentInstance(58092, workspaceHash, 'worktree');
      final owned = sanad_dev.ClientInstance(
        51084,
        'token',
        clientDirectory,
        'macos',
        pid: 101,
        launchProfile: ownedProfile(),
      );
      final state = sanad_dev.selectRuntimeProcessState(
        activeAgents: [agent],
        activeClients: [owned],
        runtime: linkedRuntime,
        pathMatches: (first, second) => first == second,
      );
      final requestedLauncherPids = <int>[];
      final record = runtime_ownership.RuntimeLauncherRecord(
        launcherId: 'launcher-1',
        runtimeNonce: 'nonce-1',
        launcherPid: 999,
        launcherProcessIdentity: 'process-999',
        workspaceHash: workspaceHash,
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

  test('timed-out component request removes only its pending manifest', () async {
    final home = await Directory.systemTemp.createTemp(
      'sanad-component-timeout-',
    );
    addTearDown(() => home.delete(recursive: true));
    final record = runtime_ownership.RuntimeLauncherRecord(
      launcherId: 'launcher-timeout',
      runtimeNonce: 'nonce-timeout',
      launcherPid: 999,
      launcherProcessIdentity: 'process-999',
      workspaceHash: workspaceHash,
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
  });

  test('stop refuses before invoking any fake for blocked ownership', () async {
    final blocked = sanad_dev.ClientInstance(
      51084,
      'token',
      clientDirectory,
      'macos',
      pid: 101,
      launchProfile: ownedProfile(gatewayPort: 58085),
    );
    final state = sanad_dev.selectRuntimeProcessState(
      activeAgents: [sanad_dev.AgentInstance(58085, 'aabbccdd', 'default')],
      activeClients: [blocked],
      runtime: linkedRuntime,
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

  test(
    'standalone clone fails closed while another primary owner is active',
    () {
      final conflict = sanad_dev.primaryResourceOwnershipConflict(
        primaryRuntime,
        [sanad_dev.AgentInstance(58085, 'different', 'default')],
      );
      expect(conflict, contains('owned by another Git workspace'));
      expect(conflict, contains('absolute --home'));
      expect(
        sanad_dev.primaryResourceOwnershipConflict(primaryRuntime, [
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
          primaryRuntime,
          const [],
          activeClients: [foreignPrimaryClient],
        ),
        isNotNull,
      );
    },
  );

  test('inactive linked worktree selects no primary runtime', () {
    final state = sanad_dev.selectRuntimeProcessState(
      activeAgents: [sanad_dev.AgentInstance(58085, 'aabbccdd', 'default')],
      activeClients: const [],
      runtime: linkedRuntime,
    );

    expect(state.agent, isNull);
    expect(state.relevantClients, isEmpty);
    expect(
      sanad_dev.noActiveRuntimeMessage(linkedRuntime),
      'No active sanad-dev runtime found for task-$workspaceHash.',
    );
  });

  test('live exact launcher lease classifies a runtime as managed', () async {
    final home = await Directory.systemTemp.createTemp('sanad-managed-home');
    addTearDown(() => home.delete(recursive: true));
    final runtime = runtime_context.SanadDevRuntime(
      workspaceRoot: '/repo',
      repositoryRoot: '/repo',
      worktreeId: 'task-$workspaceHash',
      isLinkedWorktree: true,
      usesPrimaryResources: false,
      agentPort: 58092,
      vmServicePort: 51084,
      sanadHome: home.path,
      runtimeDirectory: '${home.path}/runtime',
      branch: 'codex/task',
    );
    final agent = sanad_dev.AgentInstance(
      58092,
      workspaceHash,
      'worktree',
      launcherId: 'launcher-1',
      runtimeNonce: 'nonce-1',
    );
    final client = sanad_dev.ClientInstance(
      51084,
      'token',
      clientDirectory,
      'macos',
      pid: 101,
      launchProfile: ownedProfile(sanadHome: home.path),
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
        workspaceHash: workspaceHash,
        sourceRoot: '/repo',
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

    expect(assessment.classification, runtime_ownership.RuntimeOwnershipClass.managed);
  });

  test(
    'managed lease remains authoritative beside an unmanaged Client',
    () async {
      final home = await Directory.systemTemp.createTemp(
        'sanad-managed-with-manual-',
      );
      addTearDown(() => home.delete(recursive: true));
      final runtime = runtime_context.SanadDevRuntime(
        workspaceRoot: '/repo',
        repositoryRoot: '/repo',
        worktreeId: 'task-$workspaceHash',
        isLinkedWorktree: true,
        usesPrimaryResources: false,
        agentPort: 58092,
        vmServicePort: 51084,
        sanadHome: home.path,
        runtimeDirectory: '${home.path}/runtime',
        branch: 'codex/task',
      );
      final managed = sanad_dev.ClientInstance(
        51084,
        'token',
        clientDirectory,
        'macos',
        pid: 101,
        launchProfile: ownedProfile(sanadHome: home.path),
      );
      final unmanaged = sanad_dev.ClientInstance(
        51085,
        'token',
        clientDirectory,
        'macos',
        pid: 102,
      );
      final state = sanad_dev.selectRuntimeProcessState(
        activeAgents: [
          sanad_dev.AgentInstance(
            58092,
            workspaceHash,
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
          workspaceHash: workspaceHash,
          sourceRoot: '/repo',
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

  test('multiple matching agents are ambiguous and never mutable', () {
    final state = sanad_dev.selectRuntimeProcessState(
      activeAgents: [
        sanad_dev.AgentInstance(58092, workspaceHash, 'worktree'),
        sanad_dev.AgentInstance(58093, workspaceHash, 'worktree'),
      ],
      activeClients: const [],
      runtime: linkedRuntime,
    );

    expect(state.agent, isNull);
    expect(state.agentAmbiguous, isTrue);
    expect(state.mutationAllowed, isFalse);
    expect(sanad_dev.runtimeStatusLabel(state), contains('ambiguous'));
  });

  test('managed Client logs derive the Agent journal port from launch identity', () {
    final client = sanad_dev.ClientInstance(
      51330,
      'token',
      clientDirectory,
      'macos',
      launchProfile: ownedProfile(gatewayPort: 58092),
    );

    expect(
      sanad_dev.resolveManagedClientJournalAgentPort(
        fallbackAgentPort: 58123,
        client: client,
      ),
      58092,
    );
    expect(
      sanad_dev.resolveManagedClientJournalAgentPort(
        fallbackAgentPort: 58123,
        explicitAgentPort: 58085,
        client: client,
      ),
      58085,
    );
  });

  test('source-switch status is explicitly historical', () {
    expect(
      sanad_dev.runtimeSourceSwitchLabel('complete'),
      'Last source switch: complete',
    );
  });
}
