import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sanad_agent/core/sanad_home/supervisor_launcher_lease.dart';
import 'package:test/test.dart';

void main() {
  late Directory home;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('sanad-supervisor-lease-');
  });

  tearDown(() async {
    if (await home.exists()) {
      await home.delete(recursive: true);
    }
  });

  File writeLease({
    int agentPort = 58085,
    String launcherId = 'launcher-a',
    String runtimeNonce = 'nonce-a',
    int launcherPid = 4242,
    int version = sanadDevLauncherLeaseVersion,
  }) {
    final directory = Directory(p.join(home.path, 'dev'));
    if (!directory.existsSync()) directory.createSync(recursive: true);
    final file = File(
      p.join(directory.path, 'runtime-launcher-$agentPort.json'),
    );
    file.writeAsStringSync(
      jsonEncode({
        'version': version,
        'launcher_id': launcherId,
        'runtime_nonce': runtimeNonce,
        'launcher_pid': launcherPid,
        'agent_port': agentPort,
      }),
    );
    return file;
  }

  Future<SupervisorLauncherVerdict> verify({
    Map<String, String> environment = const {},
    bool launcherAlive = true,
  }) => verifySupervisorLauncher(
    environment: environment,
    sanadHome: home.path,
    launcherRunning: (pid) async => launcherAlive,
  );

  test('an unmanaged launch keeps today’s behaviour', () async {
    // A deliberate `fvm dart run … daemon` carries no launcher identity and is
    // not tied to any lease.
    final verdict = await verify(
      environment: const {'LOCAL_GATEWAY_PORT': '58085'},
    );
    expect(verdict.kind, SupervisorLauncherVerdictKind.unmanaged);
    expect(verdict.isDenied, isFalse);
    expect(verdict.isManaged, isFalse);
  });

  test('the launcher that still holds the lease may respawn', () async {
    writeLease();
    final verdict = await verify(
      environment: const {
        'SANAD_DEV_LAUNCHER_ID': 'launcher-a',
        'SANAD_DEV_RUNTIME_NONCE': 'nonce-a',
        'LOCAL_GATEWAY_PORT': '58085',
      },
    );
    expect(verdict.kind, SupervisorLauncherVerdictKind.allowed);
    expect(verdict.isDenied, isFalse);
  });

  test('a missing lease denies the respawn', () async {
    final verdict = await verify(
      environment: const {
        'SANAD_DEV_LAUNCHER_ID': 'launcher-a',
        'SANAD_DEV_RUNTIME_NONCE': 'nonce-a',
      },
    );
    expect(verdict.isDenied, isTrue);
    expect(verdict.reason, contains('no launcher lease exists'));
  });

  test('a lease that names another launcher denies the respawn', () async {
    writeLease(launcherId: 'launcher-b', runtimeNonce: 'nonce-b');
    final verdict = await verify(
      environment: const {
        'SANAD_DEV_LAUNCHER_ID': 'launcher-a',
        'SANAD_DEV_RUNTIME_NONCE': 'nonce-a',
      },
    );
    expect(verdict.isDenied, isTrue);
    expect(
      verdict.reason,
      contains(
        'no launcher lease names launcher '
        'launcher-a',
      ),
    );
    expect(verdict.reason, contains('58085'));
  });

  test('a nonce mismatch denies the respawn and names both nonces', () async {
    writeLease(runtimeNonce: 'nonce-b');
    final verdict = await verify(
      environment: const {
        'SANAD_DEV_LAUNCHER_ID': 'launcher-a',
        'SANAD_DEV_RUNTIME_NONCE': 'nonce-a',
        'LOCAL_GATEWAY_PORT': '58085',
      },
    );
    expect(verdict.isDenied, isTrue);
    expect(verdict.reason, contains('nonce-b'));
    expect(verdict.reason, contains('nonce-a'));
  });

  test('a launcher that is gone denies the respawn', () async {
    writeLease();
    final verdict = await verify(
      environment: const {
        'SANAD_DEV_LAUNCHER_ID': 'launcher-a',
        'SANAD_DEV_RUNTIME_NONCE': 'nonce-a',
      },
      launcherAlive: false,
    );
    expect(verdict.isDenied, isTrue);
    expect(verdict.reason, contains('pid 4242'));
    expect(verdict.reason, contains('not running'));
  });

  test('a launcher id without a nonce is denied', () async {
    writeLease();
    final verdict = await verify(
      environment: const {'SANAD_DEV_LAUNCHER_ID': 'launcher-a'},
    );
    expect(verdict.isDenied, isTrue);
    expect(verdict.reason, contains('no runtime nonce'));
  });

  test('the lease is found when the preferred port names another file', () async {
    // The port environment variable is a hint, not the identity: a runtime that
    // moved port must still be able to prove ownership of its own lease.
    writeLease(agentPort: 58085);
    final verdict = await verify(
      environment: const {
        'SANAD_DEV_LAUNCHER_ID': 'launcher-a',
        'SANAD_DEV_RUNTIME_NONCE': 'nonce-a',
        'LOCAL_GATEWAY_PORT': '58086',
      },
    );
    expect(verdict.kind, SupervisorLauncherVerdictKind.allowed);
  });

  test('an unreadable or future-schema lease is ignored', () async {
    final file = writeLease();
    file.writeAsStringSync('{not json');
    expect(
      (await verify(
        environment: const {
          'SANAD_DEV_LAUNCHER_ID': 'launcher-a',
          'SANAD_DEV_RUNTIME_NONCE': 'nonce-a',
        },
      )).isDenied,
      isTrue,
    );

    writeLease(version: sanadDevLauncherLeaseVersion + 1);
    expect(
      (await verify(
        environment: const {
          'SANAD_DEV_LAUNCHER_ID': 'launcher-a',
          'SANAD_DEV_RUNTIME_NONCE': 'nonce-a',
        },
      )).isDenied,
      isTrue,
    );
  });
}
