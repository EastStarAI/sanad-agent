import 'package:test/test.dart';

import 'package:sanad_dev/sanad_dev_cli.dart' as sanad_dev;
import '../support/sanad_dev_test_fixtures.dart';

void main() {
  test('normal selection ignores inherited requester port semantics', () {
    final workspaceAgent = sanad_dev.AgentInstance(
      58092,
      testWorkspaceHash,
      'worktree',
    );
    final primaryAgent = sanad_dev.AgentInstance(58085, 'aabbccdd', 'default');

    final state = sanad_dev.selectRuntimeProcessState(
      activeAgents: [primaryAgent, workspaceAgent],
      activeClients: const [],
      runtime: testLinkedRuntime,
    );

    expect(state.agent, same(workspaceAgent));
  });

  test(
    'nested public source uses port and launcher lease across Git-root hashes',
    () {
      final nestedAgent = sanad_dev.AgentInstance(
        58092,
        'public-submodule-hash',
        'worktree',
        launcherId: 'launcher-1',
        runtimeNonce: 'nonce-1',
        sanadHome: testLinkedRuntime.sanadHome,
      );
      final client = sanad_dev.ClientInstance(
        51092,
        'token',
        testClientDirectory,
        'macos',
        pid: 42,
        launchProfile: testOwnedProfile(),
      );

      final state = sanad_dev.selectRuntimeProcessState(
        activeAgents: [nestedAgent],
        activeClients: [client],
        runtime: testLinkedRuntime,
      );

      expect(state.agent, same(nestedAgent));
      expect(state.ownedClients, [client]);
      expect(state.crossOwnedClients, isEmpty);
    },
  );

  test('Agent-only runtime keeps its discovered Sanad Home', () {
    const userHome = '/users/developer/.sanad';
    final state = sanad_dev.RuntimeProcessState(
      agent: sanad_dev.AgentInstance(
        58092,
        testWorkspaceHash,
        'default',
        sanadHome: userHome,
      ),
      ownedClients: const [],
      crossOwnedClients: const [],
      ambiguousClients: const [],
    );

    expect(
      sanad_dev.resolveActiveSanadHome(testLinkedRuntime, state),
      userHome,
    );
  });

  test('explicit diagnostic port remains an explicit selector', () {
    final workspaceAgent = sanad_dev.AgentInstance(
      58092,
      testWorkspaceHash,
      'worktree',
    );
    final primaryAgent = sanad_dev.AgentInstance(58085, 'aabbccdd', 'default');

    final state = sanad_dev.selectRuntimeProcessState(
      activeAgents: [workspaceAgent, primaryAgent],
      activeClients: const [],
      runtime: testLinkedRuntime,
      requestedAgentPort: 58085,
    );

    expect(state.agent, same(primaryAgent));
  });

  test('device selector is exact and fails closed on duplicate devices', () {
    final first = sanad_dev.ClientInstance(
      51084,
      'token',
      testClientDirectory,
      'macos',
    );
    final second = sanad_dev.ClientInstance(
      51085,
      'token',
      testClientDirectory,
      'macos',
    );

    expect(
      sanad_dev
          .selectClientByDevice(clients: [first, second], deviceId: 'windows')
          .kind,
      sanad_dev.ClientSelectionKind.missing,
    );
    expect(
      sanad_dev
          .selectClientByDevice(clients: [first, second], deviceId: 'macos')
          .kind,
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

  test('inactive linked worktree selects no primary runtime', () {
    final state = sanad_dev.selectRuntimeProcessState(
      activeAgents: [sanad_dev.AgentInstance(58085, 'aabbccdd', 'default')],
      activeClients: const [],
      runtime: testLinkedRuntime,
    );

    expect(state.agent, isNull);
    expect(state.relevantClients, isEmpty);
    expect(
      sanad_dev.noActiveRuntimeMessage(testLinkedRuntime),
      'No active sanad-dev runtime found for task-$testWorkspaceHash.',
    );
  });

  test('multiple matching agents are ambiguous and never mutable', () {
    final state = sanad_dev.selectRuntimeProcessState(
      activeAgents: [
        sanad_dev.AgentInstance(58092, testWorkspaceHash, 'worktree'),
        sanad_dev.AgentInstance(58093, testWorkspaceHash, 'worktree'),
      ],
      activeClients: const [],
      runtime: testLinkedRuntime,
    );

    expect(state.agent, isNull);
    expect(state.agentAmbiguous, isTrue);
    expect(state.mutationAllowed, isFalse);
    expect(sanad_dev.runtimeStatusLabel(state), contains('ambiguous'));
  });
}
