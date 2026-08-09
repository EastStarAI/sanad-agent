import 'package:flutter_test/flutter_test.dart';
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
}
