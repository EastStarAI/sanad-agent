import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sanad_dev/sanad_dev_cli.dart' as sanad_dev;
import 'package:test/test.dart';

void main() {
  group('applied baseline reconciles a revert', () {
    late Directory fixture;
    late Directory repository;

    Future<void> git(List<String> arguments) async {
      final result = await Process.run('git', [
        '-C',
        repository.path,
        ...arguments,
      ]);
      if (result.exitCode != 0) {
        throw StateError('git ${arguments.join(' ')} failed: ${result.stderr}');
      }
    }

    Future<String> head() async => (await Process.run('git', [
      '-C',
      repository.path,
      'rev-parse',
      'HEAD',
    ])).stdout.toString().trim();

    String fingerprint(String path) =>
        sanad_dev.sanadDevApplyPathFingerprint(repository.path, path);

    setUp(() async {
      fixture = await Directory.systemTemp.createTemp('sanad-apply-revert-');
      repository = Directory(p.join(fixture.path, 'repo'))
        ..createSync(recursive: true);
      Directory(
        p.join(repository.path, 'agent/lib'),
      ).createSync(recursive: true);
      await git(['init', '-q']);
      await git(['config', 'user.email', 'test@example.com']);
      await git(['config', 'user.name', 'Test']);
      await File(
        p.join(repository.path, 'agent/lib/constants.dart'),
      ).writeAsString('// committed constants\n');
      await git(['add', '.']);
      await git(['commit', '-q', '-m', 'first']);
    });

    tearDown(() async {
      if (fixture.existsSync()) await fixture.delete(recursive: true);
    });

    test('a revert to HEAD after an apply is reported again', () async {
      // The live-acceptance deviation: `apply` restarted the Agent for an
      // appended line, then `git checkout --` returned the file to HEAD. Git no
      // longer reports the path at all, so only the applied baseline can tell
      // that the running Agent still holds the appended code.
      const path = 'agent/lib/constants.dart';
      final tracked = File(p.join(repository.path, path));
      final start = await head();
      await tracked.writeAsString('// committed constants\n// appended\n');
      final first = await sanad_dev.inspectChangedPaths(
        repositoryRoot: repository.path,
        startCommit: start,
      );
      expect(first.paths, [path]);
      final applied = {path: fingerprint(path)};

      await tracked.writeAsString('// committed constants\n');
      final reverted = await sanad_dev.inspectChangedPaths(
        repositoryRoot: repository.path,
        startCommit: start,
        appliedFingerprints: applied,
      );

      expect(
        reverted.paths,
        [path],
        reason:
            'a file that returns to the start commit differs from what was '
            'applied, so the running Agent is stale',
      );
      expect(
        sanad_dev.decideSanadDevApply(changedPaths: reverted.paths).actions,
        [sanad_dev.SanadDevApplyAction.restartAgent],
      );

      // Recording the revert is what makes the following apply a no-op again.
      final settled = await sanad_dev.inspectChangedPaths(
        repositoryRoot: repository.path,
        startCommit: start,
        appliedFingerprints: {path: fingerprint(path)},
      );
      expect(settled.paths, isEmpty);
    });

    test('deleting an applied file is reported again', () async {
      const path = 'agent/lib/appended.dart';
      final untracked = File(p.join(repository.path, path));
      final start = await head();
      await untracked.writeAsString('// appended by an apply\n');
      final applied = {path: fingerprint(path)};

      untracked.deleteSync();
      final deleted = await sanad_dev.inspectChangedPaths(
        repositoryRoot: repository.path,
        startCommit: start,
        appliedFingerprints: applied,
      );

      expect(deleted.paths, [
        path,
      ], reason: 'an applied file that is gone now leaves the Agent stale');
      expect(
        sanad_dev.sanadDevApplyPathFingerprint(repository.path, path),
        sanad_dev.sanadDevApplyMissingPathFingerprint,
      );
      expect(
        sanad_dev.decideSanadDevApply(changedPaths: deleted.paths).actions,
        [sanad_dev.SanadDevApplyAction.restartAgent],
      );
    });

    test(
      'a tracked applied file whose deletion is committed is reported',
      () async {
        const path = 'agent/lib/constants.dart';
        final start = await head();
        final tracked = File(p.join(repository.path, path));
        await tracked.writeAsString('// committed constants\n// applied\n');
        final applied = {path: fingerprint(path)};

        await git(['rm', '-q', '-f', path]);
        await git(['commit', '-q', '-m', 'drop constants']);
        final deleted = await sanad_dev.inspectChangedPaths(
          repositoryRoot: repository.path,
          startCommit: start,
          appliedFingerprints: applied,
        );

        expect(deleted.paths, [path]);
      },
    );

    test(
      're-editing an applied file to new content is reported again',
      () async {
        const path = 'agent/lib/constants.dart';
        final tracked = File(p.join(repository.path, path));
        final start = await head();
        await tracked.writeAsString('// committed constants\n// first edit\n');
        final applied = {path: fingerprint(path)};

        await tracked.writeAsString('// committed constants\n// second edit\n');
        final reedited = await sanad_dev.inspectChangedPaths(
          repositoryRoot: repository.path,
          startCommit: start,
          appliedFingerprints: applied,
        );

        expect(reedited.paths, [path]);
        expect(
          sanad_dev.decideSanadDevApply(changedPaths: reedited.paths).actions,
          [sanad_dev.SanadDevApplyAction.restartAgent],
        );
      },
    );
  });
}
