import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:sanad_client/features/devices/data/daemon/local_daemon_controller.dart';
import 'package:sanad_client/features/devices/data/daemon/standalone_daemon_controller.dart';
import 'package:sanad_client/features/devices/data/daemon/verified_agent_bootstrap_installer.dart';
import 'package:sanad_client/infrastructure/local_gateway/local_gateway_http_client.dart';

class FakeLocalGatewayHttpClient extends LocalGatewayHttpClient {
  final List<Uri> postedUris = <Uri>[];
  Object? Function(Uri uri)? onPost;

  @override
  Future<http.Response> post(Uri uri) async {
    postedUris.add(uri);
    final handler = onPost;
    if (handler != null) return handler(uri) as http.Response;
    return http.Response('{"status":"restart_required"}', 200);
  }
}

class FakeVerifiedAgentBootstrapInstaller extends VerifiedAgentBootstrapInstaller {
  final AgentBootstrapResult Function(String targetVersion)? onInstall;
  int installCallCount = 0;
  String? lastTargetVersion;

  FakeVerifiedAgentBootstrapInstaller({
    required super.targetPath,
    this.onInstall,
  });

  @override
  Future<AgentBootstrapResult> install({
    required String targetVersion,
    void Function(double progress)? onProgress,
  }) async {
    installCallCount++;
    lastTargetVersion = targetVersion;
    onProgress?.call(0.5);
    onProgress?.call(1.0);
    return onInstall?.call(targetVersion) ??
        const AgentBootstrapResult(AgentBootstrapStatus.installed);
  }
}

void main() {
  group('G5 — Agent Compatibility Validation and Auto-Pairing', () {
    late Directory tempHome;
    late Directory binDir;
    late File sanadExecutable;

    setUp(() {
      tempHome = Directory.systemTemp.createTempSync('sanad-compat-test-');
      binDir = Directory(p.join(tempHome.path, 'bin'))..createSync(recursive: true);
      sanadExecutable = File(p.join(binDir.path, 'sanad'));
    });

    tearDown(() {
      try {
        if (tempHome.existsSync()) tempHome.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('Scenario 1: Old agent without CLI arguments with unregistered service updates via bootstrap', () async {
      sanadExecutable.createSync();
      var versionOnDisk = '1.0.15';
      var serviceRegistered = false;
      var daemonStarted = false;
      var bootstrapCalled = 0;

      final controller = StandaloneDaemonController(
        sanadHomePath: tempHome.path,
        platformOverride: 'linux',
        bootstrapInstallerFactory: (targetPath) => FakeVerifiedAgentBootstrapInstaller(
          targetPath: targetPath,
          onInstall: (target) {
            bootstrapCalled++;
            versionOnDisk = target;
            return const AgentBootstrapResult(AgentBootstrapStatus.installed);
          },
        ),
        healthProvider: () async {
          if (!daemonStarted) return null;
          return {'status': 'ok', 'version': versionOnDisk};
        },
        processRunner: (executable, arguments) async {
          if (arguments.contains('--version')) {
            return ProcessResult(0, 0, 'Version: $versionOnDisk', '');
          }
          if (arguments.contains('--help')) {
            // v1.0.15 lacks --user-scope in help; v1.0.17 has it
            final hasUserScope = versionOnDisk != '1.0.15';
            final helpText = hasUserScope
                ? 'Usage: sanad service install\n  --user-scope  Install user service'
                : 'Usage: sanad service install';
            return ProcessResult(0, 0, helpText, '');
          }
          if (arguments.contains('install')) {
            if (arguments.contains('--user-scope') && versionOnDisk == '1.0.15') {
              return ProcessResult(1, 1, '', 'Could not find an option named "--user-scope".');
            }
            serviceRegistered = true;
            return ProcessResult(0, 0, 'Service installed', '');
          }
          if (arguments.contains('start')) {
            daemonStarted = true;
            return ProcessResult(0, 0, 'Service started', '');
          }
          return ProcessResult(0, 0, '', '');
        },
      );

      final result = await controller.updateDaemon(targetVersion: '1.0.17');

      expect(result.status, AgentLifecycleStatus.ready);
      expect(bootstrapCalled, 1);
      expect(serviceRegistered, isTrue);
      expect(daemonStarted, isTrue);
    });

    test('Scenario 2: Old agent stopped with registered service updates via bootstrap', () async {
      sanadExecutable.createSync();
      // Create service file to simulate registered service
      final serviceDir = Directory(p.join(tempHome.path, '.config', 'systemd', 'user'))..createSync(recursive: true);
      File(p.join(serviceDir.path, 'sanad-agent.service')).createSync();

      var versionOnDisk = '1.0.15';
      var daemonStarted = false;
      var bootstrapCalled = 0;

      final controller = StandaloneDaemonController(
        sanadHomePath: tempHome.path,
        platformOverride: 'linux',
        environment: {'HOME': tempHome.path},
        bootstrapInstallerFactory: (targetPath) => FakeVerifiedAgentBootstrapInstaller(
          targetPath: targetPath,
          onInstall: (target) {
            bootstrapCalled++;
            versionOnDisk = target;
            return const AgentBootstrapResult(AgentBootstrapStatus.installed);
          },
        ),
        healthProvider: () async {
          if (!daemonStarted) return null;
          return {'status': 'ok', 'version': versionOnDisk};
        },
        processRunner: (executable, arguments) async {
          if (arguments.contains('--version')) {
            return ProcessResult(0, 0, 'Version: $versionOnDisk', '');
          }
          if (arguments.contains('--help')) {
            return ProcessResult(0, 0, '--user-scope', '');
          }
          if (arguments.contains('start')) {
            daemonStarted = true;
            return ProcessResult(0, 0, 'Service started', '');
          }
          if (arguments.contains('install')) {
            return ProcessResult(0, 0, 'Service installed', '');
          }
          return ProcessResult(0, 0, '', '');
        },
      );

      expect(controller.isServiceInstalled(), isTrue);

      final result = await controller.updateDaemon(targetVersion: '1.0.17');

      expect(result.status, AgentLifecycleStatus.ready);
      expect(bootstrapCalled, 1);
      expect(daemonStarted, isTrue);
    });

    test('Scenario 3: Old agent already running executes update to newer target version', () async {
      // Daemon is actually running v1.0.15 while the client requires 1.0.17.
      // The update must be ACTUALLY executed (gateway POST /update observed),
      // not short-circuited, and the lifecycle must end ready on 1.0.17.
      final fakeGateway = FakeLocalGatewayHttpClient();
      var runningVersion = '1.0.15';
      var restartRequested = false;
      fakeGateway.onPost = (uri) {
        restartRequested = true;
        return http.Response('{"status":"restart_required"}', 200);
      };

      // Simulate a registered service so the final registration check is a no-op.
      final serviceDir = Directory(p.join(tempHome.path, '.config', 'systemd', 'user'))..createSync(recursive: true);
      File(p.join(serviceDir.path, 'sanad-agent.service')).createSync();

      final controller = StandaloneDaemonController(
        sanadHomePath: tempHome.path,
        platformOverride: 'linux',
        environment: {'HOME': tempHome.path},
        gatewayClient: fakeGateway,
        healthProvider: () async {
          if (restartRequested) runningVersion = '1.0.17';
          return {'status': 'ok', 'version': runningVersion};
        },
      );

      final result = await controller.updateDaemon(targetVersion: '1.0.17');

      expect(result.status, AgentLifecycleStatus.ready);
      expect(fakeGateway.postedUris, hasLength(1), reason: 'Update must be executed exactly once');
      final updateUri = fakeGateway.postedUris.single;
      expect(updateUri.path, contains('/update'));
      expect(updateUri.queryParameters['target_version'], '1.0.17');
    });

    test('Scenario 4: Compatible agent with unregistered service skips re-download', () async {
      sanadExecutable.createSync();
      var serviceRegistered = false;
      var daemonStarted = false;
      var bootstrapCalled = 0;

      final controller = StandaloneDaemonController(
        sanadHomePath: tempHome.path,
        platformOverride: 'linux',
        bootstrapInstallerFactory: (targetPath) => FakeVerifiedAgentBootstrapInstaller(
          targetPath: targetPath,
          onInstall: (_) {
            bootstrapCalled++;
            return const AgentBootstrapResult(AgentBootstrapStatus.installed);
          },
        ),
        healthProvider: () async {
          if (!daemonStarted) return null;
          return {'status': 'ok', 'version': '1.0.17'};
        },
        processRunner: (executable, arguments) async {
          if (arguments.contains('--version')) {
            return ProcessResult(0, 0, 'Version: 1.0.17', '');
          }
          if (arguments.contains('--help')) {
            return ProcessResult(0, 0, 'Usage: sanad service install\n  --user-scope', '');
          }
          if (arguments.contains('install')) {
            serviceRegistered = true;
            return ProcessResult(0, 0, 'Service installed', '');
          }
          if (arguments.contains('start')) {
            daemonStarted = true;
            return ProcessResult(0, 0, 'Service started', '');
          }
          return ProcessResult(0, 0, '', '');
        },
      );

      final result = await controller.updateDaemon(targetVersion: '1.0.17');

      expect(result.status, AgentLifecycleStatus.ready);
      expect(bootstrapCalled, 0, reason: 'Compatible binary must not be re-downloaded');
      expect(serviceRegistered, isTrue);
      expect(daemonStarted, isTrue);
    });

    test('Scenario 5: Agent not present performs clean initial install', () async {
      expect(sanadExecutable.existsSync(), isFalse);
      var bootstrapCalled = 0;
      var serviceRegistered = false;
      var daemonStarted = false;

      final controller = StandaloneDaemonController(
        sanadHomePath: tempHome.path,
        platformOverride: 'linux',
        bootstrapInstallerFactory: (targetPath) => FakeVerifiedAgentBootstrapInstaller(
          targetPath: targetPath,
          onInstall: (target) {
            bootstrapCalled++;
            sanadExecutable.createSync();
            return const AgentBootstrapResult(AgentBootstrapStatus.installed);
          },
        ),
        healthProvider: () async {
          if (!daemonStarted) return null;
          return {'status': 'ok', 'version': '1.0.17'};
        },
        processRunner: (executable, arguments) async {
          if (arguments.contains('--help')) {
            return ProcessResult(0, 0, '--user-scope', '');
          }
          if (arguments.contains('install')) {
            serviceRegistered = true;
            return ProcessResult(0, 0, 'Service installed', '');
          }
          if (arguments.contains('start')) {
            daemonStarted = true;
            return ProcessResult(0, 0, 'Service started', '');
          }
          return ProcessResult(0, 0, '', '');
        },
      );

      final result = await controller.updateDaemon(targetVersion: '1.0.17');

      expect(result.status, AgentLifecycleStatus.ready);
      expect(bootstrapCalled, 1);
      expect(serviceRegistered, isTrue);
      expect(daemonStarted, isTrue);
    });

    test('Scenario 6: Agent update fails with trust or checksum failure safely', () async {
      sanadExecutable.createSync();

      final trustFailController = StandaloneDaemonController(
        sanadHomePath: tempHome.path,
        platformOverride: 'linux',
        bootstrapInstallerFactory: (targetPath) => FakeVerifiedAgentBootstrapInstaller(
          targetPath: targetPath,
          onInstall: (_) => const AgentBootstrapResult(
            AgentBootstrapStatus.trustFailed,
            message: 'Developer ID verification failed.',
          ),
        ),
        processRunner: (executable, arguments) async {
          if (arguments.contains('--version')) {
            return ProcessResult(0, 0, 'Version: 1.0.15', '');
          }
          return ProcessResult(0, 0, '', '');
        },
      );

      final trustResult = await trustFailController.updateDaemon(targetVersion: '1.0.17');
      expect(trustResult.status, AgentLifecycleStatus.trustFailed);
      expect(trustResult.message, contains('Developer ID'));

      final checksumFailController = StandaloneDaemonController(
        sanadHomePath: tempHome.path,
        platformOverride: 'linux',
        bootstrapInstallerFactory: (targetPath) => FakeVerifiedAgentBootstrapInstaller(
          targetPath: targetPath,
          onInstall: (_) => const AgentBootstrapResult(
            AgentBootstrapStatus.checksumFailed,
            message: 'SHA-256 digest mismatch.',
          ),
        ),
        processRunner: (executable, arguments) async {
          if (arguments.contains('--version')) {
            return ProcessResult(0, 0, 'Version: 1.0.15', '');
          }
          return ProcessResult(0, 0, '', '');
        },
      );

      final checksumResult = await checksumFailController.updateDaemon(targetVersion: '1.0.17');
      expect(checksumResult.status, AgentLifecycleStatus.checksumFailed);
      expect(checksumResult.message, contains('SHA-256'));
    });

    test('Scenario 7: Newer installed agent rejects accidental downgrade', () async {
      sanadExecutable.createSync();
      var bootstrapCalled = 0;

      final controller = StandaloneDaemonController(
        sanadHomePath: tempHome.path,
        platformOverride: 'linux',
        bootstrapInstallerFactory: (targetPath) => FakeVerifiedAgentBootstrapInstaller(
          targetPath: targetPath,
          onInstall: (_) {
            bootstrapCalled++;
            return const AgentBootstrapResult(AgentBootstrapStatus.installed);
          },
        ),
        processRunner: (executable, arguments) async {
          if (arguments.contains('--version')) {
            return ProcessResult(0, 0, 'Sanad Agent\nVersion: 1.0.18\nPlatform: linux', '');
          }
          return ProcessResult(0, 0, '', '');
        },
      );

      final result = await controller.updateDaemon(targetVersion: '1.0.17');

      expect(result.status, AgentLifecycleStatus.downgradeRejected);
      expect(bootstrapCalled, 0, reason: 'Newer agent must never be downgraded');
    });

    test('Scenario 8: Retry after previous failure succeeds cleanly', () async {
      sanadExecutable.createSync();
      var installAttempts = 0;
      var daemonStarted = false;

      final controller = StandaloneDaemonController(
        sanadHomePath: tempHome.path,
        platformOverride: 'linux',
        bootstrapInstallerFactory: (targetPath) => FakeVerifiedAgentBootstrapInstaller(
          targetPath: targetPath,
          onInstall: (_) {
            installAttempts++;
            if (installAttempts == 1) {
              return const AgentBootstrapResult(
                AgentBootstrapStatus.networkFailed,
                message: 'Connection timed out.',
              );
            }
            return const AgentBootstrapResult(AgentBootstrapStatus.installed);
          },
        ),
        healthProvider: () async {
          if (!daemonStarted) return null;
          return {'status': 'ok', 'version': '1.0.17'};
        },
        processRunner: (executable, arguments) async {
          if (arguments.contains('--version')) {
            return ProcessResult(0, 0, 'Version: 1.0.15', '');
          }
          if (arguments.contains('--help')) {
            return ProcessResult(0, 0, '  --user-scope  user service', '');
          }
          if (arguments.contains('install')) {
            return ProcessResult(0, 0, 'Service installed', '');
          }
          if (arguments.contains('start')) {
            daemonStarted = true;
            return ProcessResult(0, 0, 'Service started', '');
          }
          return ProcessResult(0, 0, '', '');
        },
      );

      // Attempt 1 fails
      final failResult = await controller.updateDaemon(targetVersion: '1.0.17');
      expect(failResult.status, AgentLifecycleStatus.networkFailed);

      // Attempt 2 succeeds
      final successResult = await controller.updateDaemon(targetVersion: '1.0.17');
      expect(successResult.status, AgentLifecycleStatus.ready);
      expect(installAttempts, 2);
      expect(daemonStarted, isTrue);
    });

    test('Scenario 9: Running agent at target version with unregistered service registers service instead of plain upToDate', () async {
      sanadExecutable.createSync();
      var serviceRegistered = false;
      var daemonStartInvoked = false;
      final installInvocations = <List<String>>[];

      final controller = StandaloneDaemonController(
        sanadHomePath: tempHome.path,
        platformOverride: 'linux',
        environment: {'HOME': tempHome.path},
        // Daemon is healthy and already at the target version, but no service
        // file exists under HOME/.config/systemd/user/.
        healthProvider: () async => {'status': 'ok', 'version': '1.0.17'},
        processRunner: (executable, arguments) async {
          if (arguments.contains('--help')) {
            return ProcessResult(0, 0, 'Usage: sanad service install\n  --user-scope', '');
          }
          if (arguments.contains('install')) {
            installInvocations.add(arguments);
            serviceRegistered = true;
            return ProcessResult(0, 0, 'Service installed', '');
          }
          if (arguments.contains('start')) {
            daemonStartInvoked = true;
            return ProcessResult(0, 0, 'Service started', '');
          }
          return ProcessResult(0, 0, '', '');
        },
      );

      expect(controller.isServiceInstalled(), isFalse);

      final result = await controller.updateDaemon(targetVersion: '1.0.17');

      expect(result.status, AgentLifecycleStatus.upToDate);
      expect(serviceRegistered, isTrue, reason: 'Unregistered service must be registered even when the running daemon is up to date');
      expect(installInvocations, hasLength(1));
      expect(installInvocations.single, ['service', 'install', '--user-scope']);
      expect(daemonStartInvoked, isFalse, reason: 'A healthy running daemon must not be restarted');
    });

    test('Scenario 10: Service registration failure at target version surfaces serviceRegistrationFailed', () async {
      sanadExecutable.createSync();

      final controller = StandaloneDaemonController(
        sanadHomePath: tempHome.path,
        platformOverride: 'linux',
        environment: {'HOME': tempHome.path},
        healthProvider: () async => {'status': 'ok', 'version': '1.0.17'},
        processRunner: (executable, arguments) async {
          if (arguments.contains('--help')) {
            return ProcessResult(0, 0, '--user-scope', '');
          }
          if (arguments.contains('install')) {
            return ProcessResult(1, 1, '', 'Service operation failed: systemd user bus unavailable.');
          }
          return ProcessResult(0, 0, '', '');
        },
      );

      final result = await controller.updateDaemon(targetVersion: '1.0.17');

      expect(result.status, AgentLifecycleStatus.serviceRegistrationFailed);
      expect(result.isSuccess, isFalse);
    });

    group('G5-R — PR #198 service-registration regression boundaries', () {
      test('Linux service install arguments are exactly user-scoped (no system scope)', () {
        const controller = StandaloneDaemonController(platformOverride: 'linux');
        expect(controller.serviceInstallArguments, ['service', 'install', '--user-scope']);
        expect(controller.serviceInstallArguments, isNot(contains('--system')));
        expect(controller.serviceInstallArguments, isNot(contains('--user')));
      });

      test('Registration diagnostics never leak privilege-escalation instructions', () {
        // sudo / loginctl / systemctl hints must be sanitized away (null diagnostic).
        expect(
          StandaloneDaemonController.sanitizeServiceRegistrationOutput(
            stderr: 'sudo: a password is required',
          ),
          isNull,
        );
        expect(
          StandaloneDaemonController.sanitizeServiceRegistrationOutput(
            stderr: 'Service operation failed: loginctl enable-linger attia',
          ),
          isNull,
        );
        expect(
          StandaloneDaemonController.sanitizeServiceRegistrationOutput(
            stderr: 'Service operation failed: systemctl enable sanad-agent.service',
          ),
          isNull,
        );
        // Safe diagnostics remain available to the user.
        expect(
          StandaloneDaemonController.sanitizeServiceRegistrationOutput(
            stderr: 'Service operation failed: systemd user bus unavailable.',
          ),
          'systemd user bus unavailable.',
        );
        const failure = ServiceRegistrationResult(succeeded: false);
        expect(failure.failureMessage, ServiceRegistrationResult.defaultFailureMessage);
      });

      test('Registration failure keeps the previous agent and returns bounded generic message', () async {
        sanadExecutable.createSync();
        final result = await StandaloneDaemonController(
          sanadHomePath: tempHome.path,
          platformOverride: 'linux',
          processRunner: (executable, arguments) async {
            if (arguments.contains('--help')) {
              return ProcessResult(0, 0, '--user-scope', '');
            }
            return ProcessResult(1, 1, '', 'sudo loginctl enable-linger failed with password prompt');
          },
        ).registerService();

        expect(result.succeeded, isFalse);
        expect(result.diagnostic, isNull, reason: 'Privilege-escalation output must not reach the UI');
        expect(result.failureMessage, ServiceRegistrationResult.defaultFailureMessage);
        expect(sanadExecutable.existsSync(), isTrue, reason: 'The installed agent binary must be preserved');
      });
    });

    test('Ubuntu Acceptance Test: v1.0.15 agent with unregistered service auto-updates on Run Sanad Locally', () async {
      sanadExecutable.createSync();
      var versionOnDisk = '1.0.15';
      var serviceRegistered = false;
      var daemonStarted = false;
      var usedPrivilegeEscalation = false;

      final controller = StandaloneDaemonController(
        sanadHomePath: tempHome.path,
        platformOverride: 'linux',
        bootstrapInstallerFactory: (targetPath) => FakeVerifiedAgentBootstrapInstaller(
          targetPath: targetPath,
          onInstall: (target) {
            versionOnDisk = target;
            return const AgentBootstrapResult(AgentBootstrapStatus.installed);
          },
        ),
        healthProvider: () async {
          if (!daemonStarted) return null;
          return {'status': 'ok', 'version': versionOnDisk};
        },
        processRunner: (executable, arguments) async {
          // PR #198 boundary: no sudo, no loginctl/linger changes, no system
          // service managers may ever be spawned by the client registration flow.
          const escalationTools = ['sudo', 'systemctl', 'launchctl', 'loginctl', 'rc-service'];
          final invoked = [p.basename(executable), ...arguments.map((a) => a.toLowerCase())];
          if (invoked.any((part) => escalationTools.contains(part))) {
            usedPrivilegeEscalation = true;
          }
          if (arguments.contains('--version')) {
            return ProcessResult(0, 0, 'Version: $versionOnDisk', '');
          }
          if (arguments.contains('--help')) {
            final hasUserScope = versionOnDisk != '1.0.15';
            return ProcessResult(
              0,
              0,
              hasUserScope ? '  --user-scope  Install user service' : 'No user-scope',
              '',
            );
          }
          if (arguments.contains('install')) {
            if (arguments.contains('--user-scope') && versionOnDisk == '1.0.15') {
              return ProcessResult(1, 1, '', 'Could not find an option named "--user-scope".');
            }
            serviceRegistered = true;
            return ProcessResult(0, 0, 'Service installed successfully', '');
          }
          if (arguments.contains('start')) {
            daemonStarted = true;
            return ProcessResult(0, 0, 'Service started', '');
          }
          return ProcessResult(0, 0, '', '');
        },
      );

      // Simulated "Run Sanad Locally" user action
      final lifecycleResult = await controller.updateDaemon(targetVersion: '1.0.17');

      expect(lifecycleResult.isSuccess, isTrue);
      expect(lifecycleResult.status, AgentLifecycleStatus.ready);
      expect(versionOnDisk, '1.0.17');
      expect(serviceRegistered, isTrue);
      expect(daemonStarted, isTrue);
      expect(usedPrivilegeEscalation, isFalse, reason: 'Must not use sudo, loginctl, systemctl, launchctl, or rc-service');
    });

    test('registerService rejects incompatible binary before invoking with unknown flags', () async {
      sanadExecutable.createSync();
      var installAttempted = false;

      final controller = StandaloneDaemonController(
        sanadHomePath: tempHome.path,
        platformOverride: 'linux',
        processRunner: (executable, arguments) async {
          if (arguments.contains('--help')) {
            // Lacks --user-scope
            return ProcessResult(0, 0, 'Usage: sanad service install [arguments]', '');
          }
          if (arguments.contains('install')) {
            installAttempted = true;
            return ProcessResult(1, 1, '', 'Could not find an option named "--user-scope".');
          }
          return ProcessResult(0, 0, '', '');
        },
      );

      final result = await controller.registerService();

      expect(result.succeeded, isFalse);
      expect(result.diagnostic, contains('incompatible with required service options'));
      expect(installAttempted, isFalse, reason: 'Must not execute binary with unsupported options');
    });

    test('macOS and Windows skip --user-scope capability validation and succeed cleanly', () async {
      sanadExecutable.createSync();
      var macServiceInstalled = false;
      var winServiceInstalled = false;

      final macController = StandaloneDaemonController(
        sanadHomePath: tempHome.path,
        platformOverride: 'macos',
        processRunner: (executable, arguments) async {
          if (arguments.contains('install')) {
            expect(arguments, isNot(contains('--user-scope')));
            macServiceInstalled = true;
            return ProcessResult(0, 0, 'Installed', '');
          }
          return ProcessResult(0, 0, '', '');
        },
      );

      final macResult = await macController.registerService();
      expect(macResult.succeeded, isTrue);
      expect(macServiceInstalled, isTrue);

      File(p.join(binDir.path, 'sanad.exe')).createSync();
      final winController = StandaloneDaemonController(
        sanadHomePath: tempHome.path,
        platformOverride: 'windows',
        processRunner: (executable, arguments) async {
          if (arguments.contains('install')) {
            expect(arguments, isNot(contains('--user-scope')));
            winServiceInstalled = true;
            return ProcessResult(0, 0, 'Installed', '');
          }
          return ProcessResult(0, 0, '', '');
        },
      );

      final winResult = await winController.registerService();
      expect(winResult.succeeded, isTrue);
      expect(winServiceInstalled, isTrue);
    });
  });
}
