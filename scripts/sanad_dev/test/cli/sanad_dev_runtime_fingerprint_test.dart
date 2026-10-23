import 'dart:io';

import 'package:test/test.dart';

import '../support/sanad_dev_bootstrap_fixture.dart';

/// Proves that the wrapper's runtime-CLI freshness check never misses a change
/// and never rebuilds for unchanged content.
void main() {
  late SanadBootstrapFixture bootstrap;
  late Directory fixture;
  late File calls;

  setUp(() async {
    bootstrap = await SanadBootstrapFixture.create();
    fixture = bootstrap.root;
    calls = bootstrap.calls;
  });

  tearDown(() => bootstrap.dispose());

  Future<ProcessResult> runBootstrap(
    List<String> arguments, {
    Map<String, String> environment = const {},
  }) => bootstrap.run(arguments, environment: environment);

  group('runtime CLI fingerprint', () {
    late File source;

    String sourcePath(String name) =>
        '${fixture.path}${Platform.pathSeparator}scripts'
        '${Platform.pathSeparator}sanad_dev${Platform.pathSeparator}lib'
        '${Platform.pathSeparator}$name';

    Future<ProcessResult> git(List<String> arguments) => Process.run('git', [
      '-c',
      'user.name=fixture',
      '-c',
      'user.email=fixture@example.test',
      '-c',
      'commit.gpgsign=false',
      ...arguments,
    ], workingDirectory: fixture.path);

    Future<void> commitAll(String message) async {
      final added = await git(['add', '--all']);
      expect(added.exitCode, 0, reason: '${added.stderr}');
      final committed = await git([
        'commit',
        '--quiet',
        '--no-verify',
        '--message',
        message,
      ]);
      expect(committed.exitCode, 0, reason: '${committed.stderr}');
    }

    Future<String> headSha() async {
      final result = await git(['rev-parse', 'HEAD']);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      return result.stdout.toString().trim();
    }

    /// Names of the prepared runtime artifacts, newest last.
    Future<List<String>> artifactNames() async {
      final directory = Directory(
        '${fixture.path}${Platform.pathSeparator}.dart_tool'
        '${Platform.pathSeparator}sanad-dev',
      );
      if (!await directory.exists()) return const [];
      final names = await directory
          .list()
          .where(
            (entity) =>
                entity is File &&
                entity.path
                    .split(Platform.pathSeparator)
                    .last
                    .startsWith('sanad-dev-runtime-'),
          )
          .map((entity) => entity.path.split(Platform.pathSeparator).last)
          .toList();
      names.sort();
      return names;
    }

    /// The artifact the wrapper recorded as current in `runtime-cli.stamp`.
    Future<String> activeArtifactName() async {
      final stamp = await File(
        '${fixture.path}${Platform.pathSeparator}.dart_tool'
        '${Platform.pathSeparator}sanad-dev'
        '${Platform.pathSeparator}runtime-cli.stamp',
      ).readAsString();
      return 'sanad-dev-runtime-${stamp.trim()}';
    }

    /// Runs one runtime command and reports whether the CLI was recompiled.
    ///
    /// `status` is a runtime command: it never bootstraps implicitly, it reports
    /// staleness and keeps using the last prepared CLI. `setup` is the entry
    /// point that rebuilds a stale prepared runtime.
    Future<({bool compiled, bool stale, String? error})> runRuntimeCommand({
      String command = 'status',
    }) async {
      await calls.writeAsString('');
      final result = await runBootstrap([command]);
      final stale = '${result.stderr}'.contains('Project runtime is stale');
      if (result.exitCode != 0) {
        return (
          compiled: false,
          stale: stale,
          error: '${result.stdout}\n${result.stderr}',
        );
      }
      final invocations = result.exitCode == 0
          ? await calls.readAsLines()
          : const <String>[];
      return (
        compiled: invocations.any((line) => line.contains('dart compile')),
        stale: stale,
        error: null,
      );
    }

    setUp(() async {
      source = File(sourcePath('sanad_dev_cli.dart'));
      await File(
        '${fixture.path}${Platform.pathSeparator}.gitignore',
      ).writeAsString('.dart_tool/\nfake-bin/\nuser-bin/\ncalls.log\n');
      final initialized = await git(['init', '--quiet']);
      expect(initialized.exitCode, 0, reason: '${initialized.stderr}');
      await commitAll('fixture head');
    });

    test('a clean tree reuses the prepared runtime on every run', () async {
      expect((await runBootstrap(const ['setup'])).exitCode, 0);
      final prepared = await artifactNames();
      expect(prepared, hasLength(1));

      for (var run = 0; run < 3; run++) {
        final outcome = await runRuntimeCommand();
        expect(outcome.error, isNull);
        expect(
          outcome.compiled,
          isFalse,
          reason: 'a clean watched tree must not recompile',
        );
      }
      expect(await artifactNames(), prepared);
    });

    test(
      'a tracked edit rebuilds on setup and reverting reuses the artifact',
      () async {
        expect((await runBootstrap(const ['setup'])).exitCode, 0);
        final prepared = await artifactNames();
        expect(prepared, hasLength(1));

        await source.writeAsString('void main() { print(1); }');
        final staleStatus = await runRuntimeCommand();
        expect(staleStatus.error, isNull);
        expect(
          staleStatus.stale,
          isTrue,
          reason: 'a runtime command reports staleness instead of rebuilding',
        );
        expect(
          staleStatus.compiled,
          isFalse,
          reason: 'a runtime command never bootstraps implicitly',
        );
        expect(await artifactNames(), prepared);

        final edited = await runRuntimeCommand(command: 'setup');
        expect(edited.compiled, isTrue, reason: 'a tracked edit is a rebuild');
        final rebuilt = await artifactNames();
        expect(rebuilt, hasLength(2));
        expect(
          await activeArtifactName(),
          isNot(prepared.single),
          reason: 'the edited content must become the active artifact',
        );

        final reverted = await git(['checkout', '--', 'scripts/sanad_dev']);
        expect(reverted.exitCode, 0, reason: '${reverted.stderr}');
        final restored = await runRuntimeCommand(command: 'setup');
        expect(restored.error, isNull);
        expect(
          restored.compiled,
          isFalse,
          reason: 'restored content must resolve to the prepared artifact',
        );
        expect(await artifactNames(), rebuilt);
        expect(await activeArtifactName(), prepared.single);
      },
    );

    test('an untracked new source is a rebuild, its removal is not', () async {
      expect((await runBootstrap(const ['setup'])).exitCode, 0);
      final prepared = await artifactNames();
      expect(prepared, hasLength(1));
      final added = File(sourcePath('extra_untracked.dart'));

      await added.writeAsString('class Extra {}\n');
      final staleStatus = await runRuntimeCommand();
      expect(staleStatus.error, isNull);
      expect(
        staleStatus.stale,
        isTrue,
        reason: 'an untracked source makes the prepared runtime stale',
      );
      expect(staleStatus.compiled, isFalse);
      final withExtra = await runRuntimeCommand(command: 'setup');
      expect(
        withExtra.compiled,
        isTrue,
        reason: 'an untracked source file changes the compiled inputs',
      );
      final afterExtra = await artifactNames();
      expect(afterExtra, hasLength(2));

      await added.delete();
      final withoutExtra = await runRuntimeCommand(command: 'setup');
      expect(withoutExtra.error, isNull);
      expect(withoutExtra.compiled, isFalse);
      expect(await artifactNames(), afterExtra);
      expect(prepared.single, await activeArtifactName());
    });

    test('a deletion and a branch switch are rebuilds', () async {
      final added = File(sourcePath('extra_tracked.dart'));
      await added.writeAsString('class Tracked {}\n');
      await commitAll('add tracked source');
      final preparedHead = await headSha();
      expect((await runBootstrap(const ['setup'])).exitCode, 0);
      final prepared = await artifactNames();
      expect(prepared, hasLength(1));

      // A branch that drops the file is a different compiled input set.
      final branched = await git(['checkout', '--quiet', '-b', 'other']);
      expect(branched.exitCode, 0, reason: '${branched.stderr}');
      final removed = await git([
        'rm',
        '--quiet',
        'scripts/sanad_dev/lib/extra_tracked.dart',
      ]);
      expect(removed.exitCode, 0, reason: '${removed.stderr}');
      await commitAll('drop tracked source');

      final afterDeletion = await runRuntimeCommand(command: 'setup');
      expect(
        afterDeletion.compiled,
        isTrue,
        reason: 'a deletion changes the compiled inputs',
      );
      final afterDeletionArtifacts = await artifactNames();
      expect(afterDeletionArtifacts, hasLength(2));

      final back = await git(['checkout', '--quiet', preparedHead]);
      expect(back.exitCode, 0, reason: '${back.stderr}');
      final afterBranchReturn = await runRuntimeCommand(command: 'setup');
      expect(afterBranchReturn.error, isNull);
      expect(
        afterBranchReturn.compiled,
        isFalse,
        reason: 'returning to the prepared content reuses its artifact',
      );
      expect(await artifactNames(), afterDeletionArtifacts);
      expect(prepared, contains(await activeArtifactName()));
    });
  });
}
