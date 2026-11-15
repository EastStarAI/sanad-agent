import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/sanad_home/runtime_ownership.dart';
import 'package:sanad_agent/core/sanad_home/sanad_home_bootstrap.dart';
import 'package:test/test.dart';

/// Failure deadline for the spawned helper to report that it holds the lock.
///
/// The readiness line is the contract, so this only bounds the wait. It matches
/// the sibling `runtime_ownership_test.dart`: 3× the 36 s worst-case Dart
/// spawn-and-compile cost measured on the slowest release lane
/// (`macos-15-intel`), because a fixed 10 s budget sat below a single spawn
/// there and failed this case twice on that lane.
const _helperReadyBudget = Duration(seconds: 120);

/// Failure deadline for the helper to exit after it is told to release.
const _helperExitBudget = Duration(seconds: 120);

/// Stays above the helper spawn plus both deadlines above so a stalled helper
/// reports its own assertion instead of a test-runner timeout.
const _ownershipTestTimeout = Timeout(Duration(minutes: 5));

void main() {
  late Directory home;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('sanad-runtime-holder-');
    setSanadHomeOverride(home.path);
    setSanadStateHomeOverride(home.path);
    await SanadHomeBootstrap.prepareAll();
  });

  tearDown(() async {
    setSanadHomeOverride(null);
    setSanadStateHomeOverride(null);
    if (await home.exists()) {
      await home.delete(recursive: true);
    }
  });

  File holderFile() =>
      File(p.join(home.path, SanadRuntimeOwnership.holderRelativePath));

  Future<Directory> packageRoot() async {
    final packageLibrary = await Isolate.resolvePackageUri(
      Uri.parse('package:sanad_agent/core/constants.dart'),
    );
    if (packageLibrary == null) {
      fail('Could not resolve the sanad_agent package root.');
    }
    return File.fromUri(packageLibrary).parent.parent.parent;
  }

  group('lock holder record', () {
    test('names the owning process as soon as the lock is taken', () async {
      final lease = await SanadRuntimeOwnership.acquire();
      addTearDown(lease.release);

      final holder = SanadRuntimeOwnership.readHolder();
      expect(holder, isNotNull);
      expect(holder!.pid, pid);
      expect(holder.isAlive, isTrue);
      // The identity is whatever the launcher injected; a deliberate manual run
      // records empty strings instead.
      expect(
        holder.launcherId,
        Platform.environment['SANAD_DEV_LAUNCHER_ID']?.trim() ?? '',
      );
      expect(
        holder.runtimeNonce,
        Platform.environment['SANAD_DEV_RUNTIME_NONCE']?.trim() ?? '',
      );

      final file = holderFile();
      expect(file.existsSync(), isTrue);
      // The record is owner-only and carries correlation evidence only.
      if (!Platform.isWindows) {
        expect(file.statSync().mode & 0x1ff, 0x180);
      }
      final decoded =
          jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      expect(decoded.keys, isNot(contains('token')));
      expect(decoded.keys, isNot(contains('credential')));
    });

    test('a competing process is refused and the holder is named', () async {
      final root = await packageRoot();
      final helperPath = root.uri
          .resolve('test/core/sanad_home/runtime_lock_holder.dart')
          .toFilePath();
      final holder = await Process.start(
        Platform.resolvedExecutable,
        [helperPath, home.path],
        workingDirectory: root.path,
        environment: <String, String>{
          ...Platform.environment,
          'SANAD_HOME': home.path,
          'SANAD_STATE_HOME': home.path,
          'SANAD_DEV_LAUNCHER_ID': 'launcher-holder-test',
          'SANAD_DEV_RUNTIME_NONCE': 'nonce-holder-test',
        },
      );
      final helperStderr = StringBuffer();
      final stderrSubscription = holder.stderr
          .transform(utf8.decoder)
          .listen(helperStderr.write);

      // Says how the child ended, or that it outlived its own exit deadline.
      // It only explains a readiness failure, so it never replaces it.
      Future<String> exitReport() async {
        try {
          return 'exit ${await holder.exitCode.timeout(_helperExitBudget)}';
        } on TimeoutException {
          return 'still running ${_helperExitBudget.inSeconds} s after the '
              'readiness failure';
        }
      }

      try {
        late final String ready;
        try {
          ready = await holder.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .first
              .timeout(_helperReadyBudget);
        } on StateError {
          // stdout closed before the readiness line: the helper died instead.
          fail(
            'Runtime lock helper closed its stdout before readiness '
            '(pid ${holder.pid}, ${await exitReport()}): '
            '${helperStderr.toString().trim()}',
          );
        } on TimeoutException {
          // Alive but silent. Terminate it so the failure owns no process, and
          // report the phase, the pid, and whatever it wrote to stderr: the
          // old bare `TimeoutException` said none of that.
          holder.kill();
          fail(
            'Runtime lock helper did not report readiness within '
            '${_helperReadyBudget.inSeconds} s '
            '(pid ${holder.pid}, ${await exitReport()}): '
            '${helperStderr.toString().trim()}',
          );
        }
        expect(ready, 'locked');

        final recorded = SanadRuntimeOwnership.readHolder();
        expect(recorded, isNotNull);
        expect(recorded!.pid, holder.pid);
        expect(recorded.launcherId, 'launcher-holder-test');
        expect(recorded.runtimeNonce, 'nonce-holder-test');
        expect(recorded.isAlive, isTrue);

        late SanadRuntimeOwnershipConflict conflict;
        try {
          await SanadRuntimeOwnership.acquire(
            timeout: const Duration(milliseconds: 50),
          );
          fail('A second owner must be refused.');
        } on SanadRuntimeOwnershipConflict catch (error) {
          conflict = error;
        }
        expect(conflict.holder?.pid, holder.pid);
        expect(conflict.holderStale, isFalse);
        expect(conflict.message, contains('pid ${holder.pid}'));
        expect(conflict.message, contains('launcher-holder-test'));
        expect(conflict.message, contains('nonce-holder-test'));

        holder.stdin.writeln('release');
        await holder.stdin.flush();
        expect(await holder.exitCode.timeout(_helperExitBudget), 0);
      } finally {
        holder.kill();
        await stderrSubscription.cancel();
      }
    }, timeout: _ownershipTestTimeout);

    test('an unreadable or absent record never blocks acquisition', () async {
      holderFile().writeAsStringSync('not json');
      final lease = await SanadRuntimeOwnership.acquire();
      addTearDown(lease.release);
      // The lock is the authority; the record is replaced on acquisition.
      expect(SanadRuntimeOwnership.readHolder()?.pid, pid);
    });
  });

  group('conflict wording', () {
    test('a stale recorded holder is reported as stale', () {
      final conflict = SanadRuntimeOwnershipConflict(
        holder: SanadRuntimeOwnershipHolder(
          pid: 4194304,
          launcherId: 'launcher-gone',
          runtimeNonce: 'nonce-gone',
          acquiredAt: DateTime.utc(2026, 11, 7, 5, 35),
        ),
        holderStale: true,
      );
      expect(conflict.message, contains('pid 4194304'));
      expect(conflict.message, contains('no longer running'));
      expect(conflict.toString(), conflict.message);
    });

    test('an absent record says the holder cannot be named', () {
      const conflict = SanadRuntimeOwnershipConflict();
      expect(conflict.message, contains('cannot be named'));
    });
  });
}
