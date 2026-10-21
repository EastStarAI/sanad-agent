import 'package:sanad_dev/sanad_dev_cli.dart' as sanad_dev;
import 'package:sanad_dev/src/runtime/ownership/runtime_ownership.dart'
    as runtime_ownership;
import 'package:test/test.dart';

import '../support/sanad_dev_test_fixtures.dart';

runtime_ownership.RuntimeLauncherRecord _record({
  required String sourceRoot,
  required String sanadHome,
  int agentPort = 58143,
}) => runtime_ownership.RuntimeLauncherRecord(
  launcherId: 'launcher-1',
  runtimeNonce: 'nonce-1',
  launcherPid: 999,
  launcherProcessIdentity: 'process-999',
  workspaceHash: '3e9ded8d',
  sourceRoot: sourceRoot,
  agentPort: agentPort,
  sanadHome: sanadHome,
  preferencesPrefix: 'sanad.557f5ac2.',
  clientPids: const [101],
  vmServicePorts: const [51244],
  status: 'running',
  updatedAt: DateTime.utc(2026, 10, 21),
);

void main() {
  final explicitHome = platformNeutralTestPath('/users/dev/.sanad-test-3');
  final otherSource = platformNeutralTestPath('/worktrees/test-home-3');

  test('explicit Home served by another worktree names that owner', () {
    final hint = sanad_dev.explicitHomeOwnerHint(
      explicitHome: explicitHome,
      runtime: testLinkedRuntime,
      homeRecords: [_record(sourceRoot: otherSource, sanadHome: explicitHome)],
    );

    expect(hint, isNotNull);
    expect(hint, contains(explicitHome));
    expect(hint, contains(otherSource));
    expect(hint, contains('58143'));
    expect(hint, contains('run this command from that worktree'));
  });

  test('no hint without an explicit absolute Home selector', () {
    for (final selector in [null, '', 'user']) {
      expect(
        sanad_dev.explicitHomeOwnerHint(
          explicitHome: selector,
          runtime: testLinkedRuntime,
          homeRecords: [
            _record(sourceRoot: otherSource, sanadHome: explicitHome),
          ],
        ),
        isNull,
      );
    }
  });

  test('no hint when the Home runtime belongs to the invoking worktree', () {
    expect(
      sanad_dev.explicitHomeOwnerHint(
        explicitHome: explicitHome,
        runtime: testLinkedRuntime,
        homeRecords: [
          _record(
            sourceRoot: testLinkedRuntime.repositoryRoot,
            sanadHome: explicitHome,
          ),
        ],
      ),
      isNull,
    );
  });

  test('records for a different Home never produce a hint', () {
    expect(
      sanad_dev.explicitHomeOwnerHint(
        explicitHome: explicitHome,
        runtime: testLinkedRuntime,
        homeRecords: [
          _record(
            sourceRoot: otherSource,
            sanadHome: platformNeutralTestPath('/users/dev/.sanad-test-2'),
          ),
        ],
      ),
      isNull,
    );
  });
}
