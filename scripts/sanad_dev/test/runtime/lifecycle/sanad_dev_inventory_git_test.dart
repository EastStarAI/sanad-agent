import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:sanad_dev/sanad_dev_cli.dart' as sanad_dev;
import 'package:sanad_dev/src/infrastructure/path_equivalence.dart'
    as path_equivalence;
import 'package:sanad_dev/src/infrastructure/runtime_context.dart'
    as runtime_context;

/// Real-Git coverage for the `git worktree list --porcelain` reader.
///
/// The seam tests in `sanad_dev_inventory_test.dart` use fake Git output; this
/// suite proves the parser, the primary-checkout resolution, and the worktree
/// hash agree with what Git actually prints from a primary checkout and a linked
/// worktree. It creates a throwaway repository under the system temp directory
/// and never touches a port, a Home, or the developer's checkout.
void main() {
  group('sanad-dev inventory git reader', () {
    late Directory root;
    late String repoPath;
    late String linkedPath;
    late String detachedPath;

    ProcessResult git(List<String> args, {String? directory}) => Process.runSync(
      'git',
      ['-C', directory ?? repoPath, ...args],
      environment: const {'GIT_CONFIG_NOSYSTEM': '1', 'LC_ALL': 'C'},
    );

    void gitOk(List<String> args, {String? directory}) {
      final result = git(args, directory: directory);
      if (result.exitCode != 0) {
        fail('git ${args.join(' ')} failed: ${result.stderr}');
      }
    }

    String gitText(List<String> args, {String? directory}) =>
        git(args, directory: directory).stdout.toString().trim();

    setUpAll(() {
      root = Directory.systemTemp.createTempSync('sanad-inventory-git-');
      repoPath = p.join(root.path, 'repo');
      linkedPath = p.join(root.path, 'linked');
      detachedPath = p.join(root.path, 'detached');
      Directory(repoPath).createSync(recursive: true);
      gitOk(['init', '-b', 'main']);
      File(p.join(repoPath, 'README.md')).writeAsStringSync('fixture\n');
      gitOk(['add', 'README.md']);
      gitOk([
        '-c',
        'user.email=inventory@example.invalid',
        '-c',
        'user.name=Inventory Fixture',
        '-c',
        'commit.gpgsign=false',
        'commit',
        '-m',
        'fixture',
      ]);
      gitOk(['worktree', 'add', '-b', 'feat/fixture', linkedPath]);
      gitOk(['worktree', 'add', '--detach', detachedPath, 'HEAD']);
      gitOk([
        'worktree',
        'lock',
        '--reason',
        'held by another session',
        linkedPath,
      ]);
    });

    tearDownAll(() {
      try {
        if (root.existsSync()) root.deleteSync(recursive: true);
      } on FileSystemException {
        // Windows may retain read-only Git index files; the OS temp dir is
        // disposable.
      }
    });

    test('parses real porcelain output for primary, linked and detached',
        () async {
      final result = await sanad_dev.runSanadDevGit(repoPath, [
        'worktree',
        'list',
        '--porcelain',
      ]);
      expect(result.exitCode, 0);
      final entries = sanad_dev.parseWorktreeListPorcelain(
        result.stdout.toString(),
      );

      expect(entries, hasLength(3));
      // Git lists the main worktree first, then the remaining worktrees in its
      // own path order, so every other entry is looked up by path.
      final primary = entries.first;
      expect(path_equivalence.equivalentPaths(primary.path, repoPath), isTrue);
      expect(primary.branch, 'main');
      expect(primary.detached, isFalse);
      expect(primary.locked, isFalse);
      expect(primary.head, gitText(['rev-parse', 'HEAD']));

      final linked = entries.singleWhere(
        (entry) => path_equivalence.equivalentPaths(entry.path, linkedPath),
      );
      expect(linked.branch, 'feat/fixture');
      expect(linked.locked, isTrue);
      expect(linked.lockReason, 'held by another session');
      expect(linked.head, primary.head);

      final detached = entries.singleWhere(
        (entry) => path_equivalence.equivalentPaths(entry.path, detachedPath),
      );
      expect(detached.detached, isTrue);
      expect(detached.branch, isNull);
      expect(detached.head, primary.head);
      expect(detached.locked, isFalse);
    });

    test('resolves the primary checkout from real Git common directories',
        () async {
      // From the primary checkout Git prints a path relative to the worktree.
      final relative = await sanad_dev.readInventoryGitText(
        sanad_dev.runSanadDevGit,
        repoPath,
        ['rev-parse', '--git-common-dir'],
      );
      expect(relative, isNotNull);
      expect(
        path_equivalence.equivalentPaths(
          sanad_dev.resolveInventoryMainCheckout(
            commonDirectory: relative,
            callerToplevel: repoPath,
          ),
          repoPath,
        ),
        isTrue,
      );

      // From a linked worktree Git prints an absolute common directory.
      final absolute = await sanad_dev.readInventoryGitText(
        sanad_dev.runSanadDevGit,
        linkedPath,
        ['rev-parse', '--git-common-dir'],
      );
      expect(p.isAbsolute(absolute!), isTrue);
      expect(
        path_equivalence.equivalentPaths(
          sanad_dev.resolveInventoryMainCheckout(
            commonDirectory: absolute,
            callerToplevel: linkedPath,
          ),
          repoPath,
        ),
        isTrue,
      );
    });

    test('derives distinct worktree ids whose suffix is the workspace hash', () {
      final primaryId = runtime_context.deriveWorktreeId(repoPath, 'main');
      final linkedId = runtime_context.deriveWorktreeId(linkedPath, 'feat/fixture');

      expect(primaryId, startsWith('main-'));
      expect(linkedId, startsWith('feat-fixture-'));
      expect(primaryId, isNot(linkedId));
      expect(primaryId, endsWith(runtime_context.worktreeHashSuffix(repoPath)));
      expect(linkedId, endsWith(runtime_context.worktreeHashSuffix(linkedPath)));
    });
  });
}
