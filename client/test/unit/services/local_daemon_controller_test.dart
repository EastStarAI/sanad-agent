import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:sanad_client/features/devices/data/daemon/local_daemon_controller.dart';
import 'package:sanad_client/features/devices/data/daemon/source_daemon_controller.dart';
import 'package:sanad_client/features/devices/data/daemon/standalone_daemon_controller.dart';

class TestStandaloneDaemonController extends StandaloneDaemonController {
  bool runningState = false;
  Map<String, dynamic>? healthState;
  String? versionState;
  bool isServiceInstalledState = false;
  bool startDaemonResult = true;
  bool stopDaemonResult = true;
  bool installResult = true;

  int isDaemonRunningCount = 0;
  int getDaemonHealthCount = 0;
  int getDaemonVersionCount = 0;
  int startDaemonCount = 0;
  int stopDaemonCount = 0;
  int installCount = 0;

  TestStandaloneDaemonController();

  @override
  Future<bool> isDaemonRunning() async {
    isDaemonRunningCount++;
    return runningState;
  }

  @override
  Future<Map<String, dynamic>?> getDaemonHealth() async {
    getDaemonHealthCount++;
    return healthState;
  }

  @override
  Future<String?> getDaemonVersion() async {
    getDaemonVersionCount++;
    return versionState;
  }

  @override
  Future<bool> startDaemon() async {
    startDaemonCount++;
    return startDaemonResult;
  }

  @override
  Future<bool> stopDaemon() async {
    stopDaemonCount++;
    return stopDaemonResult;
  }

  @override
  bool isServiceInstalled() {
    return isServiceInstalledState;
  }

  @override
  Future<bool> install() async {
    installCount++;
    return installResult;
  }
}

class TestSourceDaemonController extends SourceDaemonController {
  bool runningState = false;
  Map<String, dynamic>? healthState;
  String? versionState;
  bool startDaemonResult = true;
  bool stopDaemonResult = true;

  int isDaemonRunningCount = 0;
  int getDaemonHealthCount = 0;
  int getDaemonVersionCount = 0;
  int startDaemonCount = 0;
  int stopDaemonCount = 0;

  TestSourceDaemonController();

  @override
  Future<bool> isDaemonRunning() async {
    isDaemonRunningCount++;
    return runningState;
  }

  @override
  Future<Map<String, dynamic>?> getDaemonHealth() async {
    getDaemonHealthCount++;
    return healthState;
  }

  @override
  Future<String?> getDaemonVersion() async {
    getDaemonVersionCount++;
    return versionState;
  }

  @override
  Future<bool> startDaemon() async {
    startDaemonCount++;
    return startDaemonResult;
  }

  @override
  Future<bool> stopDaemon() async {
    stopDaemonCount++;
    return stopDaemonResult;
  }
}

void main() {
  group('StandaloneDaemonController Tests', () {
    late TestStandaloneDaemonController controller;

    setUp(() {
      controller = TestStandaloneDaemonController();
    });

    test('resolves explicit and runtime Sanad Home before user fallback', () {
      const explicit = StandaloneDaemonController(
        sanadHomePath: r'C:\isolated\explicit-home',
        environment: {
          'SANAD_HOME': r'C:\isolated\runtime-home',
          'USERPROFILE': r'C:\Users\fallback',
        },
      );
      const runtime = StandaloneDaemonController(
        environment: {
          'SANAD_HOME': r'C:\isolated\runtime-home',
          'USERPROFILE': r'C:\Users\fallback',
        },
      );

      expect(explicit.getSanadHome(), r'C:\isolated\explicit-home');
      expect(runtime.getSanadHome(), r'C:\isolated\runtime-home');
    });

    test('delegates status checks and lifecycle methods correctly', () async {
      controller.runningState = true;
      controller.healthState = {'status': 'ok'};
      controller.versionState = '1.0.0';
      controller.isServiceInstalledState = true;

      expect(await controller.isDaemonRunning(), isTrue);
      expect(await controller.getDaemonHealth(), containsPair('status', 'ok'));
      expect(await controller.getDaemonVersion(), '1.0.0');
      expect(controller.isServiceInstalled(), isTrue);
      expect(controller.shouldAutoStart, isTrue);

      expect(controller.isDaemonRunningCount, 1);
      expect(controller.getDaemonHealthCount, 1);
      expect(controller.getDaemonVersionCount, 1);
    });

    test('restartDaemon starts the service when it is not running', () async {
      controller.runningState = false;
      controller.startDaemonResult = true;

      final result = await controller.restartDaemon();

      expect(result, isTrue);
      expect(controller.stopDaemonCount, 0);
      expect(controller.startDaemonCount, 1);
    });

    test('install delegates correctly', () async {
      controller.installResult = true;
      final result = await controller.install();
      expect(result, isTrue);
      expect(controller.installCount, 1);
    });
  });

  group('SourceDaemonController Tests', () {
    late TestSourceDaemonController controller;

    setUp(() {
      controller = TestSourceDaemonController();
    });

    test('delegates status checks correctly', () async {
      controller.runningState = true;
      controller.healthState = {'status': 'ok'};
      controller.versionState = '1.0.0';

      expect(await controller.isDaemonRunning(), isTrue);
      expect(await controller.getDaemonHealth(), containsPair('status', 'ok'));
      expect(await controller.getDaemonVersion(), '1.0.0');

      expect(controller.isDaemonRunningCount, 1);
      expect(controller.getDaemonHealthCount, 1);
      expect(controller.getDaemonVersionCount, 1);
    });

    test('isServiceInstalled always returns true for source development mode', () {
      expect(controller.isServiceInstalled(), isTrue);
    });

    test('shouldAutoStart always returns false for source development mode', () {
      expect(controller.shouldAutoStart, isFalse);
    });

    test('install is no-op and returns true', () async {
      final result = await controller.install();
      expect(result, isTrue);
    });
  });

  group('StandaloneDaemonController Linux and Diagnostic Tests', () {
    late Directory tempHome;

    setUp(() {
      tempHome = Directory.systemTemp.createTempSync('sanad-daemon-ctrl-test-');
    });

    tearDown(() {
      try {
        if (tempHome.existsSync()) tempHome.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('serviceInstallArguments includes --user-scope on Linux and omits it on macOS/Windows', () {
      final linuxController = StandaloneDaemonController(
        sanadHomePath: tempHome.path,
        platformOverride: 'linux',
      );
      final macController = StandaloneDaemonController(
        sanadHomePath: tempHome.path,
        platformOverride: 'macos',
      );
      final winController = StandaloneDaemonController(
        sanadHomePath: tempHome.path,
        platformOverride: 'windows',
      );

      expect(linuxController.serviceInstallArguments, ['service', 'install', '--user-scope']);
      expect(macController.serviceInstallArguments, ['service', 'install']);
      expect(winController.serviceInstallArguments, ['service', 'install']);
    });

    test('sanitizeServiceRegistrationOutput cleans ANSI and control sequences', () {
      const rawWithAnsi =
          '\x1B[31mService operation failed: The systemd user service manager is unavailable.\x1B[0m\x07';
      final sanitized = StandaloneDaemonController.sanitizeServiceRegistrationOutput(
        stderr: rawWithAnsi,
      );

      expect(sanitized, 'The systemd user service manager is unavailable.');
    });

    test('sanitizeServiceRegistrationOutput extracts concise failure line', () {
      const multiLine = '''
Service operation failed: Failed to connect to bus
Sanad Agent Service Status:
  State: ManagerUnavailable
''';
      final sanitized = StandaloneDaemonController.sanitizeServiceRegistrationOutput(
        stderr: multiLine,
      );

      expect(sanitized, 'Failed to connect to bus');
    });

    test('sanitizeServiceRegistrationOutput rejects unsuitable output', () {
      expect(
        StandaloneDaemonController.sanitizeServiceRegistrationOutput(
          stderr: 'Unhandled exception:\n#0 main (file:///sanad/bin/service.dart)',
        ),
        isNull,
      );
      expect(
        StandaloneDaemonController.sanitizeServiceRegistrationOutput(
          stderr: 'Error: invalid token Bearer abcdef12345',
        ),
        isNull,
      );
      expect(
        StandaloneDaemonController.sanitizeServiceRegistrationOutput(
          stderr: 'sudo -- install -m 0644 unit /etc/systemd/system',
        ),
        isNull,
      );
      expect(
        StandaloneDaemonController.sanitizeServiceRegistrationOutput(
          stderr: '{"error": "internal failure"}',
        ),
        isNull,
      );
      expect(
        StandaloneDaemonController.sanitizeServiceRegistrationOutput(
          stderr: '   ',
          stdout: '',
        ),
        isNull,
      );
    });

    test('sanitizeServiceRegistrationOutput bounds output length', () {
      final veryLong = 'Service operation failed: ${'A' * 200}';
      final sanitized = StandaloneDaemonController.sanitizeServiceRegistrationOutput(
        stderr: veryLong,
      );

      expect(sanitized, isNotNull);
      expect(sanitized!.length, lessThanOrEqualTo(120));
    });

    test('updateDaemon propagates safe sanitized failure message to AgentLifecycleResult', () async {
      final binDir = Directory(p.join(tempHome.path, 'bin'))..createSync(recursive: true);
      File(p.join(binDir.path, 'sanad')).createSync();

      final controller = StandaloneDaemonController(
        sanadHomePath: tempHome.path,
        platformOverride: 'linux',
        processRunner: (executable, arguments) async => ProcessResult(
          1,
          1,
          '',
          'Service operation failed: The systemd user service manager is unavailable.',
        ),
      );

      final result = await controller.updateDaemon(targetVersion: '1.0.0');

      expect(result.status, AgentLifecycleStatus.serviceRegistrationFailed);
      expect(
        result.message,
        'The agent was downloaded but its background service could not be registered: The systemd user service manager is unavailable.',
      );
      expect(
        result.actionableMessage,
        'The agent was downloaded but its background service could not be registered: The systemd user service manager is unavailable.',
      );
    });

    test('updateDaemon falls back to generic message when registration output is empty or unsuitable', () async {
      final binDir = Directory(p.join(tempHome.path, 'bin'))..createSync(recursive: true);
      File(p.join(binDir.path, 'sanad')).createSync();

      final emptyController = StandaloneDaemonController(
        sanadHomePath: tempHome.path,
        platformOverride: 'linux',
        processRunner: (executable, arguments) async => ProcessResult(1, 1, '', ''),
      );

      final emptyResult = await emptyController.updateDaemon(targetVersion: '1.0.0');

      expect(emptyResult.status, AgentLifecycleStatus.serviceRegistrationFailed);
      expect(
        emptyResult.message,
        'The agent was downloaded but its background service could not be registered.',
      );
      expect(
        emptyResult.actionableMessage,
        'The agent was downloaded but its background service could not be registered.',
      );

      final unsuitableController = StandaloneDaemonController(
        sanadHomePath: tempHome.path,
        platformOverride: 'linux',
        processRunner: (executable, arguments) async => ProcessResult(
          1,
          1,
          '',
          'Unhandled exception:\n#0 main',
        ),
      );

      final unsuitableResult = await unsuitableController.updateDaemon(targetVersion: '1.0.0');

      expect(unsuitableResult.status, AgentLifecycleStatus.serviceRegistrationFailed);
      expect(
        unsuitableResult.message,
        'The agent was downloaded but its background service could not be registered.',
      );
      expect(
        unsuitableResult.actionableMessage,
        'The agent was downloaded but its background service could not be registered.',
      );
    });

    test('registerService does not log raw stdout or stderr and logs only non-sensitive metadata', () async {
      final binDir = Directory(p.join(tempHome.path, 'bin'))..createSync(recursive: true);
      File(p.join(binDir.path, 'sanad')).createSync();

      final capturedRecords = <LogRecord>[];
      final subscription = Logger('StandaloneDaemonController').onRecord.listen((record) {
        capturedRecords.add(record);
      });

      try {
        final controller = StandaloneDaemonController(
          sanadHomePath: tempHome.path,
          platformOverride: 'linux',
          processRunner: (executable, arguments) async => ProcessResult(
            1,
            1,
            'RAW_STDOUT_TOKEN_SECRET_123',
            'RAW_STDERR_PASSWORD_SECRET_456\nService operation failed: user bus is unavailable',
          ),
        );

        final result = await controller.registerService();
        expect(result.succeeded, isFalse);
        expect(result.diagnostic, 'user bus is unavailable');

        expect(capturedRecords, isNotEmpty);
        for (final record in capturedRecords) {
          expect(record.message, isNot(contains('RAW_STDOUT_TOKEN_SECRET_123')));
          expect(record.message, isNot(contains('RAW_STDERR_PASSWORD_SECRET_456')));
        }

        final failureLogs = capturedRecords.where((r) => r.level >= Level.WARNING).toList();
        expect(failureLogs, isNotEmpty);
        expect(failureLogs.first.message, contains('exitCode=1'));
        expect(failureLogs.first.message, contains('hasDiagnostic=true'));
      } finally {
        await subscription.cancel();
      }
    });

    test('StandaloneDaemonController source does not log raw stdout or stderr', () {
      final sourceFile = File('lib/features/devices/data/daemon/standalone_daemon_controller.dart');
      expect(sourceFile.existsSync(), isTrue);
      final source = sourceFile.readAsStringSync();

      expect(source, isNot(contains(r'${result.stdout}')));
      expect(source, isNot(contains(r'${result.stderr}')));
      expect(source, isNot(contains('Service install stdout')));
      expect(source, isNot(contains('Service install stderr')));
    });
  });
}
