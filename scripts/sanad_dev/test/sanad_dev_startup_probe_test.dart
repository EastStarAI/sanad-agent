import 'package:test/test.dart';

import 'package:sanad_dev/startup_probe.dart';

void main() {
  test('Agent startup allows a bounded cold-start window', () {
    expect(sanadDevAgentStartupTimeout, const Duration(minutes: 3));
    expect(
      sanadDevComponentControlTimeout,
      greaterThan(sanadDevAgentStartupTimeout),
    );
  });

  test('Client startup allows a five-minute cold-build window', () {
    expect(sanadDevClientStartupTimeout, const Duration(minutes: 5));
    expect(
      sanadDevClientStartupTimeout,
      greaterThan(const Duration(seconds: 90)),
    );
    expect(
      sanadDevComponentControlTimeout,
      greaterThan(sanadDevClientStartupTimeout),
    );
  });

  test(
    'Agent health matches the inherited launcher lease across Git roots',
    () {
      expect(
        matchesSanadDevAgentHealth(
          const {
            'status': 'ok',
            'workspace_hash': 'public-submodule-hash',
            'dev_launcher_id': 'launcher-1',
            'dev_runtime_nonce': 'nonce-1',
          },
          launcherId: 'launcher-1',
          runtimeNonce: 'nonce-1',
        ),
        isTrue,
      );
    },
  );

  test('Agent health rejects a stale or incomplete launcher lease', () {
    const health = {
      'status': 'ok',
      'dev_launcher_id': 'launcher-1',
      'dev_runtime_nonce': 'nonce-1',
    };

    expect(
      matchesSanadDevAgentHealth(
        health,
        launcherId: 'launcher-stale',
        runtimeNonce: 'nonce-1',
      ),
      isFalse,
    );
    expect(
      matchesSanadDevAgentHealth(
        health,
        launcherId: 'launcher-1',
        runtimeNonce: 'nonce-stale',
      ),
      isFalse,
    );
    expect(
      matchesSanadDevAgentHealth(
        const {'status': 'ok'},
        launcherId: 'launcher-1',
        runtimeNonce: 'nonce-1',
      ),
      isFalse,
    );
  });

  test('startup timeout follows elapsed time instead of probe speed', () async {
    var now = DateTime.utc(2026);
    var attempts = 0;

    final ready = await waitForSanadDevStartupProbe(
      probe: () async {
        attempts++;
        return false;
      },
      timeout: const Duration(seconds: 1),
      pollInterval: const Duration(milliseconds: 250),
      clock: () => now,
      delay: (duration) async => now = now.add(duration),
    );

    expect(ready, isFalse);
    expect(attempts, 5);
  });

  test('startup polling returns as soon as the probe is ready', () async {
    var attempts = 0;

    final ready = await waitForSanadDevStartupProbe(
      probe: () async => ++attempts == 3,
      pollInterval: Duration.zero,
    );

    expect(ready, isTrue);
    expect(attempts, 3);
  });
}
