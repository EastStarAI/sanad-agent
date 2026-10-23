import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sanad_dev/src/infrastructure/runtime_home_fixture.dart';
import 'package:test/test.dart';

/// Restore staging is per Home, and a failed rollback must never take the
/// surviving backups with it. Both are properties of the real restore path, so
/// every case here runs against real Homes and real fixture bytes.
void main() {
  late Directory fixture;
  late Directory workspace;
  late Directory home;

  Future<void> writeHomeFile(String relative, String contents) async {
    final file = File(p.join(home.path, relative));
    await file.parent.create(recursive: true);
    await file.writeAsString(contents);
  }

  setUp(() async {
    fixture = await Directory.systemTemp.createTemp('sanad-home-staging-');
    workspace = Directory(p.join(fixture.path, 'worktree'))
      ..createSync(recursive: true);
    home = Directory(p.join(fixture.path, 'home'))..createSync(recursive: true);
    await writeHomeFile('state.db', 'database-v1');
    await writeHomeFile('config.yaml', 'model: test');
    await writeHomeFile('memories/notes.md', '# memory');
    await writeHomeFile('skills/custom/SKILL.md', '# skill');
    await writeHomeFile('workspaces/registry.json', '{}');
  });

  tearDown(() async {
    if (fixture.existsSync()) await fixture.delete(recursive: true);
  });

  test('two Homes under one parent never share a staging directory', () async {
    // Two worktree Homes live side by side under `~/.sanad/dev/homes`, so a
    // fixed staging name let crash recovery in one worktree move the other
    // Home's backed-up `state.db` into its own Home.
    final parent = Directory(p.join(fixture.path, 'homes'))
      ..createSync(recursive: true);
    final homeA = Directory(p.join(parent.path, 'feat-a'))
      ..createSync(recursive: true);
    final homeB = Directory(p.join(parent.path, 'feat-b'))
      ..createSync(recursive: true);
    for (final (directory, contents) in [
      (homeA, 'db-a'),
      (homeB, 'db-b'),
    ]) {
      await File(p.join(directory.path, 'state.db')).writeAsString(contents);
      await File(
        p.join(directory.path, 'config.yaml'),
      ).writeAsString('model: ${p.basename(directory.path)}');
    }
    final workspaceA = Directory(p.join(fixture.path, 'wt-a'))
      ..createSync(recursive: true);
    final workspaceB = Directory(p.join(fixture.path, 'wt-b'))
      ..createSync(recursive: true);
    await saveHomeFixture(
      workspaceRoot: workspaceA.path,
      homePath: homeA.path,
      name: 'clean',
    );
    await saveHomeFixture(
      workspaceRoot: workspaceB.path,
      homePath: homeB.path,
      name: 'clean',
    );

    final stagingA = sanadDevFixtureStagingPath(homeA.path);
    final stagingB = sanadDevFixtureStagingPath(homeB.path);
    final canonicalParent = parent.resolveSymbolicLinksSync();
    expect(stagingA, isNot(stagingB));
    expect(p.dirname(stagingA), canonicalParent);
    expect(p.dirname(stagingB), canonicalParent);

    // Crash Home A after it displaced its database.
    final backupA = Directory(p.join(stagingA, 'backup'))
      ..createSync(recursive: true);
    await File(
      p.join(homeA.path, 'state.db'),
    ).rename(p.join(backupA.path, 'state.db'));

    await restoreHomeFixture(
      workspaceRoot: workspaceB.path,
      homePath: homeB.path,
      name: 'clean',
    );

    expect(
      File(p.join(stagingA, 'backup', 'state.db')).readAsStringSync(),
      'db-a',
      reason: "restoring Home B must not delete Home A's in-flight backup",
    );
    expect(
      File(p.join(homeB.path, 'state.db')).readAsStringSync(),
      'db-b',
      reason: "Home B must never receive Home A's database",
    );
    expect(Directory(stagingB).existsSync(), isFalse);

    // Home A recovers its own staging on its own next run.
    await restoreHomeFixture(
      workspaceRoot: workspaceA.path,
      homePath: homeA.path,
      name: 'clean',
    );

    expect(File(p.join(homeA.path, 'state.db')).readAsStringSync(), 'db-a');
    expect(Directory(stagingA).existsSync(), isFalse);
  });

  test('two restores of one Home are serialized and never adopt staging', () async {
    // A second `reset --fixture` for the same Home (two agent sessions, or a
    // retried script) used to enter recovery while the first restore held
    // displaced originals in its staging directory: it renamed them back over the
    // files the first restore had just placed and then deleted the staging
    // directory, destroying the only rollback copy.
    await saveHomeFixture(
      workspaceRoot: workspace.path,
      homePath: home.path,
      name: 'clean',
    );
    await writeHomeFile('state.db', 'database-v2');
    await writeHomeFile('config.yaml', 'model: diverged');
    final staging = sanadDevFixtureStagingPath(home.path);
    final lockPath = sanadDevFixtureRestoreLockPath(home.path);
    expect(
      p.dirname(lockPath),
      p.dirname(staging),
      reason: 'the restore lock is per Home and sits beside its staging',
    );
    expect(
      p.isWithin(home.path, lockPath),
      isFalse,
      reason: 'the restore lock is never written inside the Home',
    );

    final firstDisplaced = Completer<void>();
    final releaseFirstSwap = Completer<void>();
    var secondCompleted = false;
    var firstPlacedWhileSecondWaited = false;

    final first = restoreHomeFixture(
      workspaceRoot: workspace.path,
      homePath: home.path,
      name: 'clean',
      abortSwapAfterDisplacing: (group) async {
        // Pause right after the database family was displaced, so the first
        // restore is inside its swap with a live staging directory and the only
        // copy of the Home's database in `backup/`.
        if (group != 'state.db') return false;
        firstDisplaced.complete();
        await releaseFirstSwap.future;
        firstPlacedWhileSecondWaited = true;
        return false;
      },
    );
    final second = () async {
      await firstDisplaced.future;
      await restoreHomeFixture(
        workspaceRoot: workspace.path,
        homePath: home.path,
        name: 'clean',
      );
      secondCompleted = true;
    }();

    await firstDisplaced.future;
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(
      secondCompleted,
      isFalse,
      reason: 'a second restore must wait for the first to release this Home',
    );
    expect(
      File(p.join(staging, 'backup', 'state.db')).readAsStringSync(),
      'database-v2',
      reason: 'recovery must never adopt an in-flight staging directory',
    );

    releaseFirstSwap.complete();
    final firstReport = await first;
    await second;

    expect(firstPlacedWhileSecondWaited, isTrue);
    expect(secondCompleted, isTrue);
    expect(firstReport.restoredFiles, greaterThan(0));
    expect(File(p.join(home.path, 'state.db')).readAsStringSync(), 'database-v1');
    expect(File(p.join(home.path, 'config.yaml')).readAsStringSync(), 'model: test');
    expect(
      Directory(staging).existsSync(),
      isFalse,
      reason: 'a completed restore leaves no staging behind',
    );
  });

  test('refuses a staging directory that records another Home', () async {
    await saveHomeFixture(
      workspaceRoot: workspace.path,
      homePath: home.path,
      name: 'clean',
    );
    final staging = Directory(sanadDevFixtureStagingPath(home.path))
      ..createSync(recursive: true);
    Directory(p.join(staging.path, 'backup')).createSync(recursive: true);
    File(
      p.join(staging.path, 'staging-home'),
    ).writeAsStringSync('${p.join(home.path, 'someone-else')}\n');

    await expectLater(
      restoreHomeFixture(
        workspaceRoot: workspace.path,
        homePath: home.path,
        name: 'clean',
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('belongs to the Home'),
        ),
      ),
    );
    expect(
      Directory(staging.path).listSync(recursive: true).isNotEmpty,
      isTrue,
      reason: 'a foreign staging directory is never deleted either',
    );
  });

  test('a failed rollback keeps the backups and prints their path', () async {
    if (Platform.isWindows) return;
    await saveHomeFixture(
      workspaceRoot: workspace.path,
      homePath: home.path,
      name: 'clean',
    );
    await writeHomeFile('state.db', 'database-v2');
    final staging = sanadDevFixtureStagingPath(home.path);

    Object? failure;
    try {
      await restoreHomeFixture(
        workspaceRoot: workspace.path,
        homePath: home.path,
        name: 'clean',
        abortSwapAfterDisplacing: (group) {
          // Make the Home unwritable so the rollback cannot put the displaced
          // original back: the failure must be reported, not hidden.
          Process.runSync('chmod', ['500', home.path]);
          return true;
        },
      );
    } on Object catch (error) {
      failure = error;
    } finally {
      Process.runSync('chmod', ['700', home.path]);
    }

    expect(failure, isA<StateError>());
    final message = (failure as StateError).message;
    expect(message, contains('could not be rolled back'));
    expect(
      message,
      contains(staging),
      reason: 'the operator must be told where the originals are',
    );
    expect(message, contains(home.path));
    expect(
      Directory(staging).existsSync(),
      isTrue,
      reason: 'a failed rollback must never delete the backups',
    );
    expect(
      File(p.join(staging, 'backup', 'state.db')).readAsStringSync(),
      'database-v2',
      reason: 'the displaced original survives the failed rollback',
    );
    expect(File(p.join(home.path, 'state.db')).existsSync(), isFalse);
  });

  test('the allowlist and database family ignore host casing', () {
    for (final path in const [
      'State.DB',
      'STATE.DB-WAL',
      'state.DB-SHM',
      'Config.YAML',
      'MEMORIES/Notes.md',
    ]) {
      expect(
        isFixtureCapturedPath(path),
        isTrue,
        reason: '$path is a captured path on a case-insensitive disk',
      );
    }
    for (final path in const [
      '.ENV',
      '.LOCAL_TOKEN',
      'LOGS/Agent.LOG',
      'SKILLS/Vault.key',
      'WORKSPACES/Private.PEM',
    ]) {
      expect(
        isFixtureCapturedPath(path),
        isFalse,
        reason: '$path must never be captured, whatever its casing',
      );
    }
    expect(isFixtureDatabaseFamilyPath('State.DB'), isTrue);
    expect(isFixtureDatabaseFamilyPath('STATE.DB-wal'), isTrue);
    expect(isFixtureDatabaseFamilyPath('state.db.backup'), isFalse);
  });
}
