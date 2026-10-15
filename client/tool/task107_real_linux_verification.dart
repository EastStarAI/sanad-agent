// Real Linux verification harness for Task 107 G5-R (UNTRACKED — do not commit).
//
// Runs the REAL StandaloneDaemonController against the REAL published
// sanad-agent binaries (v1.0.15 / v1.0.17) on an isolated SANAD_HOME,
// isolated LOCAL_GATEWAY_URL port, and an isolated systemd user unit instance
// (SANAD_SERVICE_INSTANCE). Only the health/gateway seams are injected, and
// only to bypass the FLUTTER_TEST short-circuit — both perform REAL HTTP.
//
// Required process env:
//   TASK107_ROOT            isolated SANAD_HOME parent (e.g. /tmp/sanad107-realtest/a)
//   TASK107_SCENARIO        A | B | C
//   SANAD_SERVICE_INSTANCE  systemd unit instance suffix (e.g. task107)
//   SANAD_HOME              same as $TASK107_ROOT/.sanad
// Dart-define:
//   --dart-define=LOCAL_GATEWAY_URL=http://127.0.0.1:<scenario port>
// Shell prep per scenario is documented in the task evidence.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:sanad_client/core/config/app_config.dart';
import 'package:sanad_client/features/devices/data/daemon/local_daemon_controller.dart';
import 'package:sanad_client/features/devices/data/daemon/standalone_daemon_controller.dart';
import 'package:sanad_client/infrastructure/local_gateway/local_gateway_http_client.dart';

const targetVersion = '1.0.17';

final scenario = Platform.environment['TASK107_SCENARIO'] ?? 'A';
final root = Platform.environment['TASK107_ROOT']!;
final sanadHome = p.join(root, '.sanad');
final sanadBin = p.join(sanadHome, 'bin', 'sanad');
final home = Platform.environment['HOME']!;
final userName = Platform.environment['USER'] ?? 'attia';
final instance = Platform.environment['SANAD_SERVICE_INSTANCE'] ?? 'task107';
final unitName = 'sanad-agent-$instance.service';
final unitPath = p.join(home, '.config', 'systemd', 'user', unitName);
final invocations = <String>[];

Future<ProcessResult> recordingRunner(String executable, List<String> arguments) async {
  invocations.add('${p.basename(executable)} ${arguments.join(' ')}');
  return Process.run(executable, arguments);
}

Future<Map<String, dynamic>?> realHealth() async {
  try {
    final headers = <String, String>{};
    final tokenFile = File(p.join(sanadHome, '.local_token'));
    if (tokenFile.existsSync()) {
      headers['x-sanad-local-token'] = tokenFile.readAsStringSync().trim();
    }
    final response = await http
        .get(Uri.parse('${AppConfig.localGatewayUrl}/health'), headers: headers)
        .timeout(const Duration(seconds: 3));
    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      if (data is Map<String, dynamic>) return data;
    }
    return null;
  } catch (_) {
    return null;
  }
}

Future<Map<String, dynamic>?> waitForHealth(String? expectedVersion, {Duration timeout = const Duration(seconds: 90)}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final health = await realHealth();
    if (health != null && (expectedVersion == null || health['version']?.toString() == expectedVersion)) {
      return health;
    }
    await Future<void>.delayed(const Duration(milliseconds: 700));
  }
  return null;
}

StandaloneDaemonController makeController() => StandaloneDaemonController(
      sanadHomePath: sanadHome,
      platformOverride: 'linux',
      environment: Platform.environment,
      processRunner: recordingRunner,
      healthProvider: realHealth,
      gatewayClient: const LocalGatewayHttpClient(),
    );

void assertNoPrivilegeEscalation() {
  final violations = invocations.where((inv) {
    if (inv.contains('sudo')) return true;
    if (inv.contains('enable-linger')) return true;
    if (inv.contains('rc-service')) return true;
    if (inv.contains('launchctl')) return true;
    // systemctl is allowed only in user mode (systemctl --user ...).
    if (inv.startsWith('systemctl') && !inv.split(' ').contains('--user')) return true;
    return false;
  }).toList();
  expect(violations, isEmpty, reason: 'PR #198 boundaries violated: $violations');
}

Future<void> assertLingerUnchanged() async {
  final linger = await Process.run('loginctl', ['show-user', userName, '-p', 'Linger']);
  expect(linger.stdout.toString().trim(), 'Linger=no', reason: 'linger must never be modified');
}

Future<String> installedBinaryVersion() async {
  final result = await Process.run(sanadBin, ['--version']);
  expect(result.exitCode, 0, reason: 'sanad --version failed: ${result.stderr}');
  return result.stdout.toString();
}

void main() {
  test(
    'REAL $scenario: task 107 G5-R scenario $scenario on Ubuntu ${Platform.operatingSystemVersion}',
    () async {
      expect(File(sanadBin).existsSync(), isTrue, reason: 'prepared binary missing at $sanadBin');
      addTearDown(() async {
        if (Platform.environment['TASK107_KEEP'] == '1') return;
        Process.run('systemctl', ['--user', 'stop', unitName]).ignore();
        Process.run('systemctl', ['--user', 'disable', unitName]).ignore();
        final file = File(unitPath);
        if (file.existsSync()) file.deleteSync();
        Process.run('systemctl', ['--user', 'daemon-reload']).ignore();
      });

      final controller = makeController();

      switch (scenario) {
        case 'A':
          // Stopped v1.0.15 + unregistered service → auto-update, register, start.
          expect(await realHealth(), isNull, reason: 'no daemon should be running yet');
          expect(File(unitPath).existsSync(), isFalse, reason: 'service must start unregistered');

          final result = await controller.updateDaemon(targetVersion: targetVersion);

          expect(result.status, AgentLifecycleStatus.ready, reason: result.message);
          expect(await installedBinaryVersion(), contains(targetVersion));
          expect(File(unitPath).existsSync(), isTrue, reason: 'systemd user unit must be registered');
          final active = await Process.run('systemctl', ['--user', 'is-active', unitName]);
          expect(active.stdout.toString().trim(), 'active');
          expect((await waitForHealth(targetVersion))?['version'], targetVersion);
          expect(File('/etc/systemd/system/$unitName').existsSync(), isFalse, reason: 'must never install a system service');
          await assertLingerUnchanged();
          assertNoPrivilegeEscalation();
          break;

        case 'B':
          // Running v1.0.15 daemon (registered service started by shell prep)
          // → update must be ACTUALLY executed and health must report 1.0.17.
          expect((await waitForHealth('1.0.15'))?['version'], '1.0.15', reason: 'prep must leave a running v1.0.15 daemon');

          final result = await controller.updateDaemon(targetVersion: targetVersion);

          expect(result.status, AgentLifecycleStatus.ready, reason: result.message);
          expect((await waitForHealth(targetVersion))?['version'], targetVersion, reason: 'update was not actually executed');
          expect(await installedBinaryVersion(), contains(targetVersion));
          final active = await Process.run('systemctl', ['--user', 'is-active', unitName]);
          expect(active.stdout.toString().trim(), 'active');
          await assertLingerUnchanged();
          assertNoPrivilegeEscalation();
          break;

        case 'C':
          // Running v1.0.17 daemon (started manually) at target version with an
          // unregistered service → must register the service without restarting
          // the healthy daemon (R2 fix).
          final manualPid = int.parse(
            Platform.environment['TASK107_MANUAL_PID']?.trim().isNotEmpty == true
                ? Platform.environment['TASK107_MANUAL_PID']!.trim()
                : File(p.join(root, 'manual-daemon.pid')).readAsStringSync().trim(),
          );
          final alive = await Process.run('kill', ['-0', '$manualPid']);
          expect(alive.exitCode, 0, reason: 'manual daemon must be alive');
          expect((await waitForHealth(targetVersion))?['version'], targetVersion);
          expect(File(unitPath).existsSync(), isFalse, reason: 'scenario prep must ensure the service is unregistered');
          expect(controller.isServiceInstalled(), isFalse);

          final result = await controller.updateDaemon(targetVersion: targetVersion);

          expect(result.status, AgentLifecycleStatus.upToDate, reason: result.message);
          expect(File(unitPath).existsSync(), isTrue, reason: 'R2: service must be registered instead of a plain upToDate');
          final stillAlive = await Process.run('kill', ['-0', '$manualPid']);
          expect(stillAlive.exitCode, 0, reason: 'the healthy daemon must not be restarted');
          expect((await waitForHealth(targetVersion))?['version'], targetVersion);
          await assertLingerUnchanged();
          assertNoPrivilegeEscalation();
          // Manual daemon cleanup (not systemd-managed in this scenario).
          Process.run('kill', ['$manualPid']).ignore();
          break;

        default:
          fail('unknown TASK107_SCENARIO: $scenario');
      }
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
