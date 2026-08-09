import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../../../scripts/sanad_dev.dart' as sanad_dev;
import '../../../../scripts/sanad_dev/client_launch_profile.dart';
import '../../../../scripts/sanad_dev/runtime_switch.dart';

void main() {
  test('switch manifest round-trips and is port scoped', () async {
    final root = await Directory.systemTemp.createTemp('sanad-switch-target');
    addTearDown(() => root.delete(recursive: true));
    await File(
      '${root.path}/agent/bin/sanad_agent.dart',
    ).create(recursive: true);
    await File('${root.path}/client/pubspec.yaml').create(recursive: true);
    final home = await Directory.systemTemp.createTemp('sanad-switch-home');
    addTearDown(() => home.delete(recursive: true));
    final path = runtimeSwitchManifestPath(home.path, 58091);
    final request = RuntimeSwitchRequest(
      id: 'request-1',
      agentPort: 58091,
      targetRepositoryRoot: root.path,
      targetWorkspaceHash: 'abcd1234',
      targetWorktreeName: 'feature-a',
      targetBranch: 'feature/a',
      targetIsLinkedWorktree: true,
      requestedAt: DateTime.utc(2026, 7, 28),
      launcherId: 'launcher-1',
      runtimeNonce: 'nonce-1',
      requesterSessionId: 'session-1',
      requesterToolCallId: 'tool-1',
    );

    await writeRuntimeSwitchRequest(path, request);
    final restored = await readRuntimeSwitchRequest(path);

    expect(path, endsWith('runtime-switch-58091.json'));
    expect(restored?.targetRepositoryRoot, root.path);
    expect(restored?.requesterToolCallId, 'tool-1');
    expect(restored?.status, 'requested');
  });

  test('switch target must contain both agent and client source roots', () {
    final request = RuntimeSwitchRequest(
      id: 'request-1',
      agentPort: 58091,
      targetRepositoryRoot: Directory.systemTemp.path,
      targetWorkspaceHash: 'abcd1234',
      targetWorktreeName: 'feature-a',
      targetBranch: 'feature/a',
      targetIsLinkedWorktree: true,
      requestedAt: DateTime.utc(2026, 7, 28),
      launcherId: 'launcher-1',
      runtimeNonce: 'nonce-1',
    );

    expect(
      () => validateRuntimeSwitchTarget(request),
      throwsA(isA<FormatException>()),
    );
  });

  test('fromJson does not validate target root if status is not requested', () async {
    final home = await Directory.systemTemp.createTemp('sanad-switch-home');
    addTearDown(() => home.delete(recursive: true));
    final path = runtimeSwitchManifestPath(home.path, 58091);

    final request = RuntimeSwitchRequest(
      id: 'request-2',
      agentPort: 58091,
      targetRepositoryRoot: '/nonexistent/path/to/repo',
      targetWorkspaceHash: 'abcd1234',
      targetWorktreeName: 'feature-a',
      targetBranch: 'feature/a',
      targetIsLinkedWorktree: true,
      requestedAt: DateTime.utc(2026, 7, 28),
      launcherId: 'launcher-1',
      runtimeNonce: 'nonce-1',
      status: 'complete',
    );

    await writeRuntimeSwitchRequest(path, request);

    final restored = await readRuntimeSwitchRequest(path);
    expect(restored?.targetRepositoryRoot, '/nonexistent/path/to/repo');
    expect(restored?.status, 'complete');
  });

  test('invalid manifest warning is emitted once per file revision', () async {
    final home = await Directory.systemTemp.createTemp('sanad-switch-home');
    addTearDown(() => home.delete(recursive: true));
    final path = runtimeSwitchManifestPath(home.path, 58091);
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString('{"version":1}');
    final gate = RuntimeSwitchManifestWarningGate();
    const error = FormatException('Unsupported runtime switch manifest version.');

    expect(await gate.shouldReport(path, error), isTrue);
    expect(await gate.shouldReport(path, error), isFalse);

    await Future<void>.delayed(const Duration(milliseconds: 5));
    await file.writeAsString('{"version":100}');
    expect(await gate.shouldReport(path, error), isTrue);
    expect(await gate.shouldReport(path, error), isFalse);

    gate.reset();
    expect(await gate.shouldReport(path, error), isTrue);
  });

  test(
    'switched client preserves state profile and replaces worktree markers',
    () {
      final profile = extractClientLaunchProfile(const [
        'flutter',
        'run',
        '-d',
        'macos',
        '--dart-define-from-file=config/dev.json',
        '--dart-define=LOCAL_GATEWAY_URL=http://127.0.0.1:58091',
        '--dart-define=SANAD_HOME=/tmp/shared-home',
        '--dart-define=SANAD_SHARED_PREFERENCES_PREFIX=sanad.shared.',
        '--dart-define=SANAD_DEV_WORKTREE_NAME=old-tree',
        '--dart-define=SANAD_DEV_WORKTREE_BRANCH=old-branch',
        '--dart-define=SANAD_DEV_WORKSPACE_HASH=oldhash',
        '--dart-define=SANAD_DEV_LAUNCHER_ID=launcher-1',
        '--dart-define=SANAD_DEV_RUNTIME_NONCE=nonce-1',
        '-t',
        'lib/driver_main.dart',
      ]);

      final arguments = buildSwitchedClientRunArguments(
        currentProfile: profile,
        targetWorktreeName: 'new-tree',
        targetBranch: 'feature/new',
        targetWorkspaceHash: 'newhash',
        targetIsLinkedWorktree: true,
        vmServicePort: 51123,
        deviceId: 'macos',
      );

      expect(arguments, contains('--dart-define=SANAD_HOME=/tmp/shared-home'));
      expect(
        arguments,
        contains('--dart-define=LOCAL_GATEWAY_URL=http://127.0.0.1:58091'),
      );
      expect(
        arguments,
        contains('--dart-define=SANAD_DEV_WORKTREE_NAME=new-tree'),
      );
      expect(
        arguments,
        contains('--dart-define=SANAD_DEV_WORKTREE_BRANCH=feature/new'),
      );
      expect(
        arguments,
        contains('--dart-define=SANAD_DEV_WORKSPACE_HASH=newhash'),
      );
      expect(
        arguments,
        contains('--dart-define=SANAD_DEV_LAUNCHER_ID=launcher-1'),
      );
      expect(
        arguments,
        contains('--dart-define=SANAD_DEV_RUNTIME_NONCE=nonce-1'),
      );
      expect(
        arguments,
        isNot(contains('--dart-define=SANAD_DEV_WORKSPACE_HASH=oldhash')),
      );
      expect(
        arguments,
        isNot(contains('--dart-define=SANAD_DEV_WORKTREE_NAME=old-tree')),
      );
      expect(arguments, contains('--host-vmservice-port=51123'));
      expect(arguments, containsAll(['-t', 'lib/driver_main.dart']));
    },
  );

  test('switched client group preserves every device and VM port', () {
    final profiles = [
      extractClientLaunchProfile(const [
        'flutter',
        'run',
        '-d',
        'macos',
        '--dart-define=LOCAL_GATEWAY_URL=http://127.0.0.1:58091',
        '--dart-define=SANAD_HOME=/tmp/shared-home',
      ]),
      extractClientLaunchProfile(const [
        'flutter',
        'run',
        '-d',
        'iphone-simulator-id',
        '--dart-define=LOCAL_GATEWAY_URL=http://127.0.0.1:58091',
        '--dart-define=SANAD_HOME=/tmp/shared-home',
      ]),
    ];

    final groups = buildSwitchedClientGroupArguments(
      profiles: profiles,
      vmServicePorts: const [51123, 51124],
      deviceIds: const ['macos', 'iphone-simulator-id'],
      targetWorktreeName: 'new-tree',
      targetBranch: 'feature/new',
      targetIsLinkedWorktree: true,
    );

    expect(groups, hasLength(2));
    expect(groups[0], containsAll(['-d', 'macos', '--host-vmservice-port=51123']));
    expect(
      groups[1],
      containsAll([
        '-d',
        'iphone-simulator-id',
        '--host-vmservice-port=51124',
      ]),
    );
    for (final arguments in groups) {
      expect(
        arguments,
        contains('--dart-define=SANAD_DEV_WORKTREE_NAME=new-tree'),
      );
    }
  });

  test(
    'replacement waits for previous process and VM resources to disappear',
    () async {
      var processChecks = 0;
      var vmChecks = 0;

      final unavailable = await sanad_dev.waitForClientResourcesUnavailable(
        clientPidsByVmPort: const {51123: 101},
        timeout: const Duration(seconds: 1),
        pollInterval: Duration.zero,
        processRunning: (_) async => processChecks++ == 0,
        vmServiceAvailable: (_) async => vmChecks++ == 0,
      );

      expect(unavailable, isTrue);
      expect(processChecks, 3);
      expect(vmChecks, 2);
    },
  );

  test(
    'managed PID selection rejects a stale source on the retained VM port',
    () {
      sanad_dev.ClientInstance client({
        required int pid,
        required String path,
        required String workspaceHash,
      }) {
        return sanad_dev.ClientInstance(
          51123,
          'token',
          path,
          'macos',
          pid: pid,
          launchProfile: extractClientLaunchProfile([
            '--dart-define=LOCAL_GATEWAY_URL=http://127.0.0.1:58091',
            '--dart-define=SANAD_DEV_LAUNCHER_ID=launcher-1',
            '--dart-define=SANAD_DEV_RUNTIME_NONCE=nonce-1',
            '--dart-define=SANAD_DEV_WORKSPACE_HASH=$workspaceHash',
          ]),
        );
      }

      final stale = client(
        pid: 101,
        path: '/source/client',
        workspaceHash: 'old',
      );
      expect(
        sanad_dev.exactManagedClientPids(
          discoveredClients: [stale],
          expectedVmServicePorts: const {51123},
          launcherId: 'launcher-1',
          runtimeNonce: 'nonce-1',
          workspaceHash: 'target',
        ),
        isNull,
      );

      final target = client(
        pid: 202,
        path: '/target/client',
        workspaceHash: 'target',
      );
      expect(
        sanad_dev.exactManagedClientPids(
          discoveredClients: [stale, target],
          expectedVmServicePorts: const {51123},
          launcherId: 'launcher-1',
          runtimeNonce: 'nonce-1',
          workspaceHash: 'target',
        ),
        [202],
      );
    },
  );

  test('process tree orders descendants after their owning parent', () {
    const listing = '''
      100 1
      110 100
      120 100
      111 110
      999 1
    ''';

    final ordered = orderUnixProcessTree(listing, 100);

    expect(ordered, [100, 110, 111, 120]);
    expect(ordered.reversed, [120, 111, 110, 100]);
  });

  test('switching to primary removes linked-worktree markers', () {
    final profile = extractClientLaunchProfile(const [
      '--dart-define=SANAD_DEV_WORKTREE_NAME=old-tree',
      '--dart-define=SANAD_DEV_WORKTREE_BRANCH=old-branch',
      '--dart-define=SANAD_HOME=/tmp/shared-home',
    ]);

    final arguments = buildSwitchedClientRunArguments(
      currentProfile: profile,
      targetWorktreeName: 'sanad-agent',
      targetBranch: 'main',
      targetIsLinkedWorktree: false,
      vmServicePort: 51123,
      deviceId: 'macos',
    );

    expect(
      arguments.where((argument) => argument.contains('SANAD_DEV_WORKTREE_')),
      isEmpty,
    );
  });

  test(
    'copyWith records terminal handoff status without changing identity',
    () {
      final request = RuntimeSwitchRequest(
        id: 'request-1',
        agentPort: 58091,
        targetRepositoryRoot: Directory.systemTemp.path,
        targetWorkspaceHash: 'abcd1234',
        targetWorktreeName: 'feature-a',
        targetBranch: 'feature/a',
        targetIsLinkedWorktree: true,
        requestedAt: DateTime.utc(2026, 7, 28),
        launcherId: 'launcher-1',
        runtimeNonce: 'nonce-1',
      );

      final completed = request.copyWith(status: 'complete', message: 'done');
      expect(completed.id, request.id);
      expect(completed.status, 'complete');
      expect(completed.message, 'done');
    },
  );
}
