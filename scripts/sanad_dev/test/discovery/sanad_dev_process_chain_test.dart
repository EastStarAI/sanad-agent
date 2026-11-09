import 'package:test/test.dart';

import 'package:sanad_dev/sanad_dev_cli.dart' as sanad_dev;

/// Process-lineage coverage for the reclaim kill tier.
///
/// A reclaim may signal a process only when the whole Agent lineage is proven
/// from the parent map, so these tests pin the boundary conditions: a readable
/// non-Agent ancestor ends the lineage, an unreadable one refuses it, and the
/// walk is bounded.
void main() {
  group('process parent map', () {
    test('parses a pid/ppid table and ignores other lines', () {
      final parents = sanad_dev.parseProcessParentMap(
        '    1     0\n'
        '  2288     1\n'
        ' 42383  2288\n'
        '\n'
        'header noise\n',
      );
      expect(parents, {1: 0, 2288: 1, 42383: 2288});
    });

    test('lists descendants without the root', () {
      final descendants = sanad_dev.processDescendants(
        rootPid: 10,
        parentByPid: {11: 10, 12: 11, 13: 10, 20: 1, 1: 0},
      );
      expect(descendants, {11, 12, 13});
    });
  });

  group('agent daemon lineage', () {
    test('orders a three-hop chain outermost first', () {
      final chain = sanad_dev.agentDaemonChainCandidates(
        daemonPid: 42383,
        parentByPid: {1: 0, 2276: 1, 2288: 2276, 42383: 2288},
      );
      expect(chain, [2276, 2288, 42383]);
    });

    test('stops at pid 1 and at the hop limit', () {
      expect(
        sanad_dev.agentDaemonChainCandidates(
          daemonPid: 40,
          parentByPid: {40: 1},
        ),
        [40],
      );
      expect(
        sanad_dev.agentDaemonChainCandidates(
          daemonPid: 40,
          parentByPid: {40: 41, 41: 42, 42: 43, 43: 44, 44: 45},
          maxHops: 2,
        ),
        [42, 41, 40],
      );
    });

    test('breaks a cycle instead of looping', () {
      expect(
        sanad_dev.agentDaemonChainCandidates(
          daemonPid: 5,
          parentByPid: {5: 6, 6: 5},
        ),
        [6, 5],
      );
    });

    test('recognizes only Agent runtime commands', () {
      expect(
        sanad_dev.isAgentRuntimeCommand(
          'dartvm bin/sanad_agent.dart daemon --child-process',
        ),
        isTrue,
      );
      expect(
        sanad_dev.isAgentRuntimeCommand(
          'fvm dart run bin/sanad_agent.dart daemon',
        ),
        isTrue,
      );
      expect(sanad_dev.isAgentRuntimeCommand('flutter run -d macos'), isFalse);
      expect(sanad_dev.isAgentRuntimeCommand('-zsh'), isFalse);
      expect(sanad_dev.isAgentRuntimeCommand(null), isFalse);
    });

    Future<List<int>> prove(
      Map<int, int> parents,
      Map<int, String?> identities,
    ) => sanad_dev.proveAgentDaemonChain(
      daemonPid: 42383,
      parentByPid: parents,
      processIdentity: (pid) async => identities[pid],
    );

    test(
      'proves the whole chain when every command is an Agent runtime',
      () async {
        final chain = await prove(
          {1: 0, 2276: 1, 2288: 2276, 42383: 2288},
          {
            2276: 'fvm dart run bin/sanad_agent.dart daemon',
            2288: 'dartvm bin/sanad_agent.dart daemon',
            42383: 'dartvm bin/sanad_agent.dart daemon --child-process',
          },
        );
        expect(chain, [2276, 2288, 42383]);
      },
    );

    test('refuses the chain when an ancestor cannot be read', () async {
      final chain = await prove(
        {1: 0, 2276: 1, 2288: 2276, 42383: 2288},
        {
          2288: 'dartvm bin/sanad_agent.dart daemon',
          42383: 'dartvm bin/sanad_agent.dart daemon --child-process',
        },
      );
      expect(chain, isEmpty);
    });

    test('stops at a readable non-Agent ancestor', () async {
      final chain = await prove(
        {1: 0, 900: 1, 2288: 900, 42383: 2288},
        {
          900: '-zsh',
          2288: 'dartvm bin/sanad_agent.dart daemon',
          42383: 'dartvm bin/sanad_agent.dart daemon --child-process',
        },
      );
      expect(chain, [2288, 42383]);
    });

    test('refuses when the daemon itself is not an Agent runtime', () async {
      final chain = await prove(
        {1: 0, 42383: 1},
        {42383: '/usr/bin/python3 -m http.server'},
      );
      expect(chain, isEmpty);
    });
  });
}
