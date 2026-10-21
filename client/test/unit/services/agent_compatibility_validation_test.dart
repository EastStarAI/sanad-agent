import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sanad_client/features/devices/data/daemon/local_daemon_controller.dart';
import 'package:sanad_client/features/devices/data/daemon/standalone_daemon_controller.dart';
import 'package:sanad_client/features/devices/data/daemon/verified_agent_bootstrap_installer.dart';

import '../../helpers/fake_agent_cli.dart';

/// Task 107 G5 — a stopped agent is validated, replaced when outdated or
/// incompatible, registered, and started before the client uses it.
void main() {
  late Directory tempHome;
  late File executable;

  setUp(() {
    tempHome = Directory.systemTemp.createTempSync('sanad-compat-test-');
    executable = File(p.join(tempHome.path, 'bin', 'sanad'));
    executable.parent.createSync(recursive: true);
  });

  tearDown(() {
    if (tempHome.existsSync()) tempHome.deleteSync(recursive: true);
  });

  void registerLinuxService() {
    File(p.join(tempHome.path, '.config', 'systemd', 'user', 'sanad-agent.service')).createSync(recursive: true);
  }

  /// Mirrors the real installer: the previous executable is preserved as
  /// `.rollback` and the verified candidate takes its place.
  FakeBootstrapInstaller Function(String) replacingInstaller(
    FakeAgentCli cli, {
    AgentBootstrapStatus status = AgentBootstrapStatus.installed,
    String? message,
  }) {
    return (targetPath) => FakeBootstrapInstaller(
      targetPath: targetPath,
      onInstall: (target) {
        if (status != AgentBootstrapStatus.installed) return AgentBootstrapResult(status, message: message);
        final file = File(targetPath);
        if (file.existsSync()) file.renameSync('$targetPath.rollback');
        file.writeAsStringSync('agent $target');
        cli.version = target;
        return const AgentBootstrapResult(AgentBootstrapStatus.installed);
      },
    );
  }

  StandaloneDaemonController controllerFor(
    FakeAgentCli cli, {
    String platform = 'linux',
    VerifiedAgentBootstrapInstaller Function(String)? installer,
    Future<ProcessResult> Function(String, List<String>)? runner,
    Duration probeTimeout = StandaloneDaemonController.defaultExecutableProbeTimeout,
  }) {
    return StandaloneDaemonController(
      sanadHomePath: tempHome.path,
      environment: {'HOME': tempHome.path},
      platformOverride: platform,
      processRunner: runner ?? cli.run,
      healthProvider: cli.health,
      bootstrapInstallerFactory: installer ?? noBootstrapExpected,
      executableProbeTimeout: probeTimeout,
    );
  }

  bool usedInstallHelp(FakeAgentCli cli) => cli.calls.any(
    (call) => call.length >= 3 && call[0] == 'service' && call[1] == 'install' && call.contains('--help'),
  );

  group('ported G5 scenarios', () {
    test('1: old agent without --user-scope and no service is replaced, registered and started', () async {
      executable.writeAsStringSync('agent 1.0.15');
      final cli = FakeAgentCli('1.0.15');
      final installer = replacingInstaller(cli);
      final controller = controllerFor(cli, installer: installer);

      final result = await controller.updateDaemon(targetVersion: '1.0.17');

      expect(result.status, AgentLifecycleStatus.ready);
      expect(cli.version, '1.0.17');
      expect(cli.serviceInstalled, isTrue);
      expect(cli.started, isTrue);
      expect(
        cli.calls.where((call) => call.contains('--user-scope')).length,
        1,
        reason: 'the old binary must never be invoked with --user-scope',
      );
    });

    test('2: old stopped agent with a registered service is replaced and started', () async {
      registerLinuxService();
      executable.writeAsStringSync('agent 1.0.15');
      final cli = FakeAgentCli('1.0.15');
      final controller = controllerFor(cli, installer: replacingInstaller(cli));

      final result = await controller.updateDaemon(targetVersion: '1.0.17');

      expect(result.status, AgentLifecycleStatus.ready);
      expect(cli.version, '1.0.17');
      expect(cli.started, isTrue);
      expect(
        cli.calls.where((call) => call.length >= 2 && call[1] == 'install' && !call.contains('--help')),
        isEmpty,
        reason: 'an existing registration is reused on Linux',
      );
    });

    test('3: an old running agent is updated through its own /update path, not bootstrap', () async {
      // The daemon-owned HTTP update is outside this unit; the stopped-agent
      // lifecycle must not run while health answers.
      final cli = FakeAgentCli('1.0.17')..started = true;
      final controller = controllerFor(cli);

      final result = await controller.updateDaemon(targetVersion: '1.0.17');

      expect(result.status, AgentLifecycleStatus.upToDate);
      expect(cli.calls, isEmpty);
    });

    test('4: a compatible target-version agent with no service is not re-downloaded', () async {
      executable.writeAsStringSync('agent 1.0.17');
      final cli = FakeAgentCli('1.0.17');
      final controller = controllerFor(cli);

      final result = await controller.updateDaemon(targetVersion: '1.0.17');

      expect(result.status, AgentLifecycleStatus.ready);
      expect(cli.serviceInstalled, isTrue);
      expect(cli.started, isTrue);
    });

    test('5: a clean machine installs, registers and starts the agent', () async {
      final cli = FakeAgentCli('1.0.17');
      final installer = replacingInstaller(cli);
      final controller = controllerFor(cli, installer: installer);

      final result = await controller.updateDaemon(targetVersion: '1.0.17');

      expect(result.status, AgentLifecycleStatus.ready);
      expect(executable.readAsStringSync(), 'agent 1.0.17');
      expect(File('${executable.path}.rollback').existsSync(), isFalse);
      expect(cli.serviceInstalled, isTrue);
      expect(cli.started, isTrue);
    });

    test('6: trust and checksum failures keep the previous binary untouched', () async {
      executable.writeAsStringSync('agent 1.0.15');
      for (final status in [AgentBootstrapStatus.trustFailed, AgentBootstrapStatus.checksumFailed]) {
        final cli = FakeAgentCli('1.0.15');
        final controller = controllerFor(
          cli,
          installer: replacingInstaller(cli, status: status, message: 'stage=publisher_requirement'),
        );

        final result = await controller.updateDaemon(targetVersion: '1.0.17');

        expect(result.isSuccess, isFalse);
        expect(result.message, 'stage=publisher_requirement');
        expect(executable.readAsStringSync(), 'agent 1.0.15');
        expect(cli.started, isFalse);
        expect(cli.serviceInstalled, isFalse);
      }
    });

    test('7: a newer stopped agent is never downgraded', () async {
      executable.writeAsStringSync('agent 1.0.18');
      final cli = FakeAgentCli('1.0.18');
      final controller = controllerFor(cli);

      final result = await controller.updateDaemon(targetVersion: '1.0.17');

      expect(result.status, AgentLifecycleStatus.downgradeRejected);
      expect(executable.readAsStringSync(), 'agent 1.0.18');
    });

    test('8: a retry after a network failure succeeds', () async {
      executable.writeAsStringSync('agent 1.0.15');
      final cli = FakeAgentCli('1.0.15');
      var attempts = 0;
      final controller = controllerFor(
        cli,
        installer: (targetPath) => FakeBootstrapInstaller(
          targetPath: targetPath,
          onInstall: (target) {
            attempts++;
            if (attempts == 1) return const AgentBootstrapResult(AgentBootstrapStatus.networkFailed);
            return replacingInstaller(cli)(targetPath).onInstall(target);
          },
        ),
      );

      expect((await controller.updateDaemon(targetVersion: '1.0.17')).status, AgentLifecycleStatus.networkFailed);
      expect(executable.readAsStringSync(), 'agent 1.0.15');
      expect((await controller.updateDaemon(targetVersion: '1.0.17')).status, AgentLifecycleStatus.ready);
      expect(attempts, 2);
    });

    test('Ubuntu acceptance: v1.0.15 + unregistered service reaches ready on Run Sanad Locally without sudo', () async {
      executable.writeAsStringSync('agent 1.0.15');
      final cli = FakeAgentCli('1.0.15');
      final executables = <String>{};
      final controller = controllerFor(
        cli,
        installer: replacingInstaller(cli),
        runner: (command, arguments) {
          executables.add(command);
          return cli.run(command, arguments);
        },
      );

      final result = await controller.updateDaemon(targetVersion: '1.0.17');

      expect(result.status, AgentLifecycleStatus.ready);
      expect(executables, {executable.path}, reason: 'only the managed agent executable runs; never sudo');
      expect(cli.calls, anyElement(equals(['service', 'install', '--user-scope'])));
    });
  });

  group('review regressions', () {
    test('legacy v1.0.0-v1.0.6 binaries are never probed with service install --help', () async {
      for (final legacy in ['1.0.0', '1.0.4', '1.0.6']) {
        executable.writeAsStringSync('agent $legacy');
        File('${executable.path}.rollback').deleteSafely();
        final cli = FakeAgentCli(legacy);
        final controller = controllerFor(cli, installer: replacingInstaller(cli));

        final result = await controller.updateDaemon(targetVersion: '1.0.17');

        expect(result.status, AgentLifecycleStatus.ready, reason: legacy);
        expect(cli.realInstallFromHelpProbe, isFalse, reason: legacy);
        expect(usedInstallHelp(cli), isFalse, reason: legacy);
      }
    });

    test('registerService probes with read-only help and refuses an incompatible binary', () async {
      executable.writeAsStringSync('agent 1.0.4');
      final cli = FakeAgentCli('1.0.4');
      final controller = controllerFor(cli);

      final registration = await controller.registerService();

      expect(registration.succeeded, isFalse);
      expect(registration.diagnostic, ServiceRegistrationResult.incompatibleExecutableDiagnostic);
      expect(cli.realInstallFromHelpProbe, isFalse);
      expect(cli.serviceInstalled, isFalse);
      expect(cli.calls, [
        ['help', 'service', 'install'],
      ]);
    });

    test('a failed start after replacing a stopped agent restores the previous binary', () async {
      executable.writeAsStringSync('agent 1.0.15');
      final cli = FakeAgentCli('1.0.15');
      final controller = controllerFor(
        cli,
        installer: replacingInstaller(cli),
        runner: (command, arguments) async {
          if (arguments.length == 2 && arguments[1] == 'start') return ProcessResult(1, 1, '', 'failed');
          return cli.run(command, arguments);
        },
      );

      final result = await controller.updateDaemon(targetVersion: '1.0.17');

      expect(result.status, AgentLifecycleStatus.rollbackCompleted);
      expect(result.message, contains('The agent service could not be started.'));
      expect(executable.readAsStringSync(), 'agent 1.0.15');
      expect(File('${executable.path}.rollback').existsSync(), isFalse);
      expect(cli.stopped, isTrue, reason: 'the failed candidate is stopped before restore');
    });

    test('a fresh install that fails to start has nothing to roll back', () async {
      final cli = FakeAgentCli('1.0.17');
      final controller = controllerFor(
        cli,
        installer: replacingInstaller(cli),
        runner: (command, arguments) async {
          if (arguments.length == 2 && arguments[1] == 'start') return ProcessResult(1, 1, '', 'failed');
          return cli.run(command, arguments);
        },
      );

      final result = await controller.updateDaemon(targetVersion: '1.0.17');

      expect(result.status, AgentLifecycleStatus.startFailed);
      expect(executable.readAsStringSync(), 'agent 1.0.17');
    });

    test('a newer compatible stopped agent is started instead of left unusable', () async {
      executable.writeAsStringSync('agent 1.0.18');
      final cli = FakeAgentCli('1.0.18');
      final controller = controllerFor(cli);

      final result = await controller.updateDaemon(targetVersion: '1.0.17');

      expect(result.status, AgentLifecycleStatus.downgradeRejected);
      expect(cli.started, isTrue);
      expect(await controller.isDaemonRunning(), isTrue);
    });

    test('a missing Version line is unparseable, never a kernel version', () async {
      executable.writeAsStringSync('agent ?');
      final cli = FakeAgentCli('1.0.17', versionOutput: 'Sanad Agent\nPlatform: linux (6.8.0-45-generic)\n');
      final installer = replacingInstaller(cli);
      final controller = controllerFor(cli, installer: installer);

      expect(await controller.getInstalledExecutableVersion(), isNull);
      final result = await controller.updateDaemon(targetVersion: '1.0.17');
      expect(result.status, AgentLifecycleStatus.ready, reason: 'reinstalled, not rejected as a downgrade');
    });

    test('a prerelease agent is upgraded to the matching stable release', () async {
      executable.writeAsStringSync('agent 1.0.18-rc.1');
      final cli = FakeAgentCli('1.0.18-rc.1');
      final controller = controllerFor(cli, installer: replacingInstaller(cli));

      expect(await controller.getInstalledExecutableVersion(), '1.0.18-rc.1');
      final result = await controller.updateDaemon(targetVersion: '1.0.18');
      expect(result.status, AgentLifecycleStatus.ready);
      expect(executable.readAsStringSync(), 'agent 1.0.18');
    });

    test('a hung executable probe is bounded and treated as unknown', () async {
      executable.writeAsStringSync('agent hung');
      final cli = FakeAgentCli('1.0.17');
      final controller = controllerFor(
        cli,
        probeTimeout: const Duration(milliseconds: 50),
        runner: (_, _) => Completer<ProcessResult>().future,
      );

      expect(await controller.getInstalledExecutableVersion(), isNull);
      expect(await controller.validateServiceInstallCompatibility(), isFalse);
    });

    test('agent child processes are pinned to the managed Home and service instance', () {
      final controller = controllerFor(FakeAgentCli('1.0.17'));
      expect(controller.managedAgentEnvironment, {'SANAD_HOME': tempHome.path});

      final isolated = StandaloneDaemonController(
        sanadHomePath: tempHome.path,
        environment: {'HOME': tempHome.path, 'SANAD_SERVICE_INSTANCE': 'qa107'},
        platformOverride: 'linux',
      );
      expect(isolated.managedAgentEnvironment, {'SANAD_HOME': tempHome.path, 'SANAD_SERVICE_INSTANCE': 'qa107'});
    });

    test('option detection requires the exact flag', () async {
      executable.writeAsStringSync('agent');
      final controller = controllerFor(
        FakeAgentCli('1.0.17'),
        runner: (_, _) async => ProcessResult(1, 0, '    --user-scope-legacy   other\n', ''),
      );
      expect(await controller.validateServiceInstallCompatibility(), isFalse);
    });

    test('macOS and Windows register once without a capability probe', () async {
      for (final platform in ['macos', 'windows']) {
        final binary = File(p.join(tempHome.path, 'bin', platform == 'windows' ? 'sanad.exe' : 'sanad'))
          ..writeAsStringSync('agent 1.0.17');
        final cli = FakeAgentCli('1.0.17');
        final controller = controllerFor(cli, platform: platform);

        final result = await controller.updateDaemon(targetVersion: '1.0.17');

        expect(result.status, AgentLifecycleStatus.ready, reason: platform);
        expect(cli.calls.where((call) => call.first == 'help'), isEmpty, reason: platform);
        expect(cli.calls.where((call) => call.length > 1 && call[1] == 'install'), hasLength(1), reason: platform);
        binary.deleteSync();
      }
    });
  });

  test('parseAgentVersionOutput accepts only the Version line', () {
    expect(StandaloneDaemonController.parseAgentVersionOutput('Sanad Agent\nVersion: 1.0.17\n'), '1.0.17');
    expect(StandaloneDaemonController.parseAgentVersionOutput('Version: v1.0.18-rc.2'), '1.0.18-rc.2');
    expect(
      StandaloneDaemonController.parseAgentVersionOutput('Platform: macos (Version 15.1.1 (Build 24B91))'),
      isNull,
    );
    expect(StandaloneDaemonController.parseAgentVersionOutput('garbage 1.2.3'), isNull);
  });
}

extension on File {
  void deleteSafely() {
    if (existsSync()) deleteSync();
  }
}
