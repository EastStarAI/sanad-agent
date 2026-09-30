import 'dart:io';

import 'package:test/test.dart';

import 'package:sanad_dev/sanad_dev_cli.dart' as sanad_dev;
import 'package:sanad_dev/src/infrastructure/client_launch_profile.dart'
    as launch_profile;
import 'package:sanad_dev/src/runtime/ownership/runtime_ownership.dart'
    as runtime_ownership;
import '../../support/sanad_dev_caller_env.dart';

void main() {
  group('orphaned runtime stop process ownership safety', () {
    test(
      'force stop terminates launcher only when process identity matches lease',
      () async {
        final home = await Directory.systemTemp.createTemp(
          'sanad-stop-launcher-id-',
        );
        addTearDown(() => home.delete(recursive: true));
        final runtime = await resolveHandlerRuntime(
          sanadHomeOverride: home.path,
        );
        final record = runtime_ownership.RuntimeLauncherRecord(
          launcherId: 'test-launcher',
          runtimeNonce: 'test-nonce',
          launcherPid: 999111,
          launcherProcessIdentity: 'exact-launcher-identity',
          workspaceHash: runtime.worktreeId.split('-').last,
          sourceRoot: runtime.repositoryRoot,
          agentPort: runtime.agentPort,
          sanadHome: home.path,
          preferencesPrefix: '',
          clientPids: const [],
          vmServicePorts: const [],
          status: 'running',
          updatedAt: DateTime.now().toUtc(),
        );
        await runtime_ownership.writeRuntimeLauncherRecord(record);
        final recordFile = File(
          runtime_ownership.runtimeLauncherRecordPath(
            home.path,
            runtime.agentPort,
          ),
        );
        expect(await recordFile.exists(), isTrue);

        final terminatedPids = <int>[];
        await sanad_dev.handleRuntimeStop(
          force: true,
          sanadHomePath: home.path,
          processRunning: (pid) async => pid == 999111,
          processIdentity: (pid) async =>
              pid == 999111 ? 'exact-launcher-identity' : null,
          terminateProcess: (pid) async => terminatedPids.add(pid),
          discoverAgents: ({sanadHomeOverride}) async => const [],
          discoverClients: () async => const [],
        );

        expect(terminatedPids, contains(999111));
      },
    );

    test(
      'force stop refuses to terminate launcher when process identity changed (recycled PID)',
      () async {
        final home = await Directory.systemTemp.createTemp(
          'sanad-stop-launcher-skip-',
        );
        addTearDown(() => home.delete(recursive: true));
        final runtime = await resolveHandlerRuntime(
          sanadHomeOverride: home.path,
        );
        final record = runtime_ownership.RuntimeLauncherRecord(
          launcherId: 'test-launcher',
          runtimeNonce: 'test-nonce',
          launcherPid: 999222,
          launcherProcessIdentity: 'expected-identity',
          workspaceHash: runtime.worktreeId.split('-').last,
          sourceRoot: runtime.repositoryRoot,
          agentPort: runtime.agentPort,
          sanadHome: home.path,
          preferencesPrefix: '',
          clientPids: const [],
          vmServicePorts: const [],
          status: 'running',
          updatedAt: DateTime.now().toUtc(),
        );
        await runtime_ownership.writeRuntimeLauncherRecord(record);

        final terminatedPids = <int>[];
        await sanad_dev.handleRuntimeStop(
          force: true,
          sanadHomePath: home.path,
          processRunning: (pid) async => pid == 999222,
          processIdentity: (pid) async =>
              pid == 999222 ? 'foreign-notepad-identity' : null,
          terminateProcess: (pid) async => terminatedPids.add(pid),
          discoverAgents: ({sanadHomeOverride}) async => const [],
          discoverClients: () async => const [],
        );

        expect(terminatedPids, isNot(contains(999222)));
      },
    );

    test(
      'force stop terminates client PID from lease only when process identity proves runtime ownership',
      () async {
        final home = await Directory.systemTemp.createTemp(
          'sanad-stop-client-proof-',
        );
        addTearDown(() => home.delete(recursive: true));
        final runtime = await resolveHandlerRuntime(
          sanadHomeOverride: home.path,
        );
        final record = runtime_ownership.RuntimeLauncherRecord(
          launcherId: 'launcher-xyz',
          runtimeNonce: 'nonce-xyz',
          launcherPid: 999333,
          launcherProcessIdentity: 'launcher-id',
          workspaceHash: runtime.worktreeId.split('-').last,
          sourceRoot: runtime.repositoryRoot,
          agentPort: runtime.agentPort,
          sanadHome: home.path,
          preferencesPrefix: '',
          clientPids: const [8881, 8882, 8883, 8884],
          vmServicePorts: const [],
          status: 'running',
          updatedAt: DateTime.now().toUtc(),
        );
        await runtime_ownership.writeRuntimeLauncherRecord(record);

        final terminatedPids = <int>[];
        await sanad_dev.handleRuntimeStop(
          force: true,
          sanadHomePath: home.path,
          processRunning: (pid) async => true,
          processIdentity: (pid) async {
            if (pid == 999333) return 'launcher-id';
            if (pid == 8881) {
              return 'flutter run --dart-define=SANAD_DEV_LAUNCHER_ID=launcher-xyz --dart-define=SANAD_DEV_RUNTIME_NONCE=nonce-xyz';
            }
            if (pid == 8882) {
              return 'C:\\Windows\\System32\\svchost.exe -k netsvcs';
            }
            if (pid == 8883) {
              return 'flutter run --dart-define=LOCAL_GATEWAY_URL=http://localhost:${runtime.agentPort}';
            }
            if (pid == 8884) {
              return 'flutter run --dart-define=SANAD_DEV_LAUNCHER_ID=launcher-xyz';
            }
            return null;
          },
          terminateProcess: (pid) async => terminatedPids.add(pid),
          discoverAgents: ({sanadHomeOverride}) async => const [],
          discoverClients: () async => const [],
        );

        expect(terminatedPids, contains(999333));
        expect(terminatedPids, contains(8881));
        expect(terminatedPids, isNot(contains(8882)));
        expect(terminatedPids, isNot(contains(8883)));
        expect(terminatedPids, isNot(contains(8884)));
      },
    );
  });

  group('target orphan Client-only cleanup', () {
    const clientPort = 58099;
    final clientProfileArgs = [
      'flutter',
      'run',
      '--dart-define=LOCAL_GATEWAY_URL=http://127.0.0.1:$clientPort',
      '--dart-define=SANAD_DEV_LAUNCHER_ID=launcher-cleanup',
      '--dart-define=SANAD_DEV_RUNTIME_NONCE=nonce-cleanup',
    ];

    test('cleans an exact stale Client-only orphan and its lease', () async {
      final home = await Directory.systemTemp.createTemp(
        'sanad-cleanup-client-',
      );
      addTearDown(() => home.delete(recursive: true));
      final runtime = await resolveHandlerRuntime(sanadHomeOverride: home.path);
      final clientDir =
          '${runtime.repositoryRoot}${Platform.pathSeparator}client';
      final client = sanad_dev.ClientInstance(
        51099,
        'token',
        clientDir,
        'windows',
        pid: 7001,
        launchProfile: launch_profile.extractClientLaunchProfile([
          ...clientProfileArgs,
          '--dart-define=SANAD_HOME=${home.path}',
        ]),
      );
      final record = runtime_ownership.RuntimeLauncherRecord(
        launcherId: 'launcher-cleanup',
        runtimeNonce: 'nonce-cleanup',
        launcherPid: 999600,
        launcherProcessIdentity: 'dead-launcher',
        workspaceHash: runtime.worktreeId.split('-').last,
        sourceRoot: runtime.repositoryRoot,
        agentPort: clientPort,
        sanadHome: home.path,
        preferencesPrefix: '',
        clientPids: const [7001],
        vmServicePorts: const [51099],
        status: 'running',
        updatedAt: DateTime.now().toUtc(),
      );
      await runtime_ownership.writeRuntimeLauncherRecord(record);
      final recordFile = File(
        runtime_ownership.runtimeLauncherRecordPath(home.path, clientPort),
      );
      expect(await recordFile.exists(), isTrue);

      final terminatedPids = <int>[];
      await sanad_dev.handleTargetOrphanCleanup(
        sanadHomePath: home.path,
        processRunning: (_) async => false,
        terminateProcess: (pid, signal) {
          terminatedPids.add(pid);
          return true;
        },
        discoverAgents: ({sanadHomeOverride}) async => const [],
        discoverClients: () async => [client],
      );

      expect(terminatedPids, contains(7001));
      expect(await recordFile.exists(), isFalse);
    });

    test('refuses cleanup while the target Agent stays live', () async {
      final home = await Directory.systemTemp.createTemp(
        'sanad-cleanup-refuse-',
      );
      addTearDown(() => home.delete(recursive: true));
      final runtime = await resolveHandlerRuntime(sanadHomeOverride: home.path);
      final clientDir =
          '${runtime.repositoryRoot}${Platform.pathSeparator}client';
      final client = sanad_dev.ClientInstance(
        51099,
        'token',
        clientDir,
        'windows',
        pid: 7002,
        launchProfile: launch_profile.extractClientLaunchProfile([
          ...clientProfileArgs,
          '--dart-define=SANAD_HOME=${home.path}',
        ]),
      );
      final record = runtime_ownership.RuntimeLauncherRecord(
        launcherId: 'launcher-cleanup',
        runtimeNonce: 'nonce-cleanup',
        launcherPid: 999600,
        launcherProcessIdentity: 'dead-launcher',
        workspaceHash: '',
        sourceRoot: runtime.repositoryRoot,
        agentPort: clientPort,
        sanadHome: home.path,
        preferencesPrefix: '',
        clientPids: const [7002],
        vmServicePorts: const [51099],
        status: 'running',
        updatedAt: DateTime.now().toUtc(),
      );
      await runtime_ownership.writeRuntimeLauncherRecord(record);
      final recordFile = File(
        runtime_ownership.runtimeLauncherRecordPath(home.path, clientPort),
      );

      final terminatedPids = <int>[];
      await sanad_dev.handleTargetOrphanCleanup(
        sanadHomePath: home.path,
        processRunning: (_) async => false,
        terminateProcess: (pid, signal) {
          terminatedPids.add(pid);
          return true;
        },
        discoverAgents: ({sanadHomeOverride}) async => [
          sanad_dev.AgentInstance(clientPort, 'foreign-workspace', 'worktree'),
        ],
        discoverClients: () async => [client],
      );

      expect(terminatedPids, isEmpty);
      expect(await recordFile.exists(), isTrue);
    });
  });
}
