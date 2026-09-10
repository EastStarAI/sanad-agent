import 'dart:io';

import 'package:test/test.dart';

import 'package:sanad_dev/runtime_ownership.dart';

void main() {
  RuntimeLauncherRecord record(String home) => RuntimeLauncherRecord(
    launcherId: 'launcher-1',
    runtimeNonce: 'nonce-1',
    launcherPid: 901,
    launcherProcessIdentity: 'started-at-and-command',
    workspaceHash: 'abcdef12',
    sourceRoot: '/repo',
    agentPort: 58091,
    sanadHome: home,
    preferencesPrefix: 'sanad.test.',
    clientPids: const [902],
    vmServicePorts: const [51091],
    status: 'running',
    updatedAt: DateTime.utc(2026, 7, 29),
  );

  test(
    'launcher record and stop request are atomic and identity scoped',
    () async {
      final home = await Directory.systemTemp.createTemp('sanad-launcher-home');
      addTearDown(() => home.delete(recursive: true));
      final expected = record(home.path);

      await writeRuntimeLauncherRecord(expected);
      final restored = await readRuntimeLauncherRecord(home.path, 58091);
      expect(restored?.launcherId, 'launcher-1');
      expect(restored?.runtimeNonce, 'nonce-1');

      await writeRuntimeLauncherStopRequest(expected);
      expect(await consumeRuntimeLauncherStopRequest(expected), isTrue);
      expect(await consumeRuntimeLauncherStopRequest(expected), isFalse);
    },
  );

  test(
    'valid managed lease requires exact process, client, and nonce identity',
    () {
      final expected = record('/tmp/sanad-home');
      expect(
        validateManagedRuntimeRecord(
          record: expected,
          agentPort: 58091,
          sanadHome: '/tmp/sanad-home',
          workspaceHash: 'abcdef12',
          launcherRunning: true,
          launcherProcessIdentity: 'started-at-and-command',
          clientDefines: const [
            {
              'SANAD_DEV_LAUNCHER_ID': 'launcher-1',
              'SANAD_DEV_RUNTIME_NONCE': 'nonce-1',
              'LOCAL_GATEWAY_URL': 'http://127.0.0.1:58091',
              'SANAD_HOME': '/tmp/sanad-home',
              'SANAD_SHARED_PREFERENCES_PREFIX': 'sanad.test.',
            },
          ],
          clientPids: const [902],
          vmServicePorts: const [51091],
        ),
        isNull,
      );
    },
  );

  test('managed Agent-only lease permits an empty client set', () {
    final base = record('/tmp/sanad-home');
    final agentOnly = RuntimeLauncherRecord(
      launcherId: base.launcherId,
      runtimeNonce: base.runtimeNonce,
      launcherPid: base.launcherPid,
      launcherProcessIdentity: base.launcherProcessIdentity,
      workspaceHash: base.workspaceHash,
      sourceRoot: base.sourceRoot,
      agentPort: base.agentPort,
      sanadHome: base.sanadHome,
      preferencesPrefix: base.preferencesPrefix,
      clientPids: const [],
      vmServicePorts: const [],
      status: 'running',
      updatedAt: base.updatedAt,
    );

    expect(
      validateManagedRuntimeRecord(
        record: agentOnly,
        agentPort: 58091,
        sanadHome: '/tmp/sanad-home',
        workspaceHash: 'abcdef12',
        launcherRunning: true,
        launcherProcessIdentity: 'started-at-and-command',
        clientDefines: const [],
        clientPids: const [],
        vmServicePorts: const [],
      ),
      isNull,
    );
  });

  test('stale, PID-reused, and nonce-mismatched leases fail closed', () {
    final expected = record('/tmp/sanad-home');

    String? validate({
      bool running = true,
      String identity = 'started-at-and-command',
      String nonce = 'nonce-1',
    }) => validateManagedRuntimeRecord(
      record: expected,
      agentPort: 58091,
      sanadHome: '/tmp/sanad-home',
      workspaceHash: 'abcdef12',
      launcherRunning: running,
      launcherProcessIdentity: identity,
      clientDefines: [
        {
          'SANAD_DEV_LAUNCHER_ID': 'launcher-1',
          'SANAD_DEV_RUNTIME_NONCE': nonce,
          'LOCAL_GATEWAY_URL': 'http://127.0.0.1:58091',
          'SANAD_HOME': '/tmp/sanad-home',
          'SANAD_SHARED_PREFERENCES_PREFIX': 'sanad.test.',
        },
      ],
      clientPids: const [902],
      vmServicePorts: const [51091],
    );

    expect(validate(running: false), contains('stale'));
    expect(validate(identity: 'reused-pid'), contains('PID was reused'));
    expect(validate(nonce: 'wrong'), contains('nonce'));
  });
}
