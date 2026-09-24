import 'dart:io';

import 'package:test/test.dart';

import 'package:sanad_dev/sanad_dev_cli.dart' as sanad_dev;
import 'package:sanad_dev/src/runtime/ownership/runtime_ownership.dart'
    as runtime_ownership;
import '../../support/sanad_dev_caller_env.dart';

/// Recovery-matrix coverage for the no-components stale-lease cell:
/// `handleRuntimeDoctor(fix: true)` must remove a stale record only when no
/// live launcher, Agent, or Client remains. Discovery is injected so the test
/// is deterministic even on a host that has a live runtime outside its scope.
void main() {
  test(
    'doctor --fix removes a stale record when no live surface remains',
    () async {
      final home = await Directory.systemTemp.createTemp(
        'sanad-doctor-nocomp-',
      );
      addTearDown(() => home.delete(recursive: true));
      final runtime = await resolveHandlerRuntime(sanadHomeOverride: home.path);
      final record = runtime_ownership.RuntimeLauncherRecord(
        launcherId: 'launcher-nocomp',
        runtimeNonce: 'nonce-nocomp',
        launcherPid: 999500,
        launcherProcessIdentity: 'gone-process',
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

      await sanad_dev.handleRuntimeDoctor(
        fix: true,
        sanadHomePath: home.path,
        processRunning: (_) async => false,
        discoverAgents: ({sanadHomeOverride}) async => const [],
        discoverClients: () async => const [],
      );

      expect(await recordFile.exists(), isFalse);
    },
  );

  test(
    'doctor --fix preserves a stale record while any live surface remains',
    () async {
      final home = await Directory.systemTemp.createTemp('sanad-doctor-live-');
      addTearDown(() => home.delete(recursive: true));
      final runtime = await resolveHandlerRuntime(sanadHomeOverride: home.path);
      final record = runtime_ownership.RuntimeLauncherRecord(
        launcherId: 'launcher-live',
        runtimeNonce: 'nonce-live',
        launcherPid: 999501,
        launcherProcessIdentity: 'gone-process',
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

      await sanad_dev.handleRuntimeDoctor(
        fix: true,
        sanadHomePath: home.path,
        processRunning: (_) async => record.launcherPid == 999501,
        discoverAgents: ({sanadHomeOverride}) async => const [],
        discoverClients: () async => const [],
      );

      expect(await recordFile.exists(), isTrue);
    },
  );
}
