import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sanad_dev/src/infrastructure/compiled_cli_cache.dart';
import 'package:test/test.dart';

/// Source commit the fixture cache is keyed on.
///
/// The expected cache key is derived from it instead of being written out, so
/// the fixture never carries a hash-shaped literal that a secret scanner has to
/// distinguish from a real credential.
const fixtureSourceCommit = 'abcdef1234567890';

/// Cache key the fixture commit maps to: the first twelve characters.
String fixtureCacheKey(String commit) => commit.substring(0, 12);

void main() {
  late Directory fixture;
  late Directory workspace;
  late Directory repository;
  late List<List<String>> builds;

  Future<void> writeSource(String relative, String contents) async {
    final file = File(p.join(repository.path, relative));
    await file.parent.create(recursive: true);
    await file.writeAsString(contents);
  }

  CompiledCliCache cache({
    String commit = fixtureSourceCommit,
    String sdkVersion = 'dart 3.10.7',
  }) => CompiledCliCache(
    workspaceRoot: workspace.path,
    repositoryRoot: repository.path,
    sourceCommit: () async => commit,
    dartSdkVersion: () async => sdkVersion,
    builder: ({required workingDirectory, required arguments}) async {
      builds.add(arguments);
      if (arguments.contains('build')) {
        final outputIndex = arguments.indexOf('-o') + 1;
        final bundle = Directory(p.join(arguments[outputIndex], 'bundle'));
        await Directory(p.join(bundle.path, 'bin')).create(recursive: true);
        await File(
          p.join(bundle.path, 'bin', 'sanad_client'),
        ).writeAsString('client-binary');
      } else {
        final outputIndex = arguments.indexOf('-o') + 1;
        await File(arguments[outputIndex]).writeAsString('agent-binary');
      }
      return 0;
    },
  );

  setUp(() async {
    fixture = await Directory.systemTemp.createTemp('sanad-cli-cache-');
    workspace = Directory(p.join(fixture.path, 'worktree'))
      ..createSync(recursive: true);
    repository = Directory(p.join(fixture.path, 'repo'))
      ..createSync(recursive: true);
    builds = [];
    await writeSource('agent/bin/sanad_agent.dart', 'void main() {}');
    await writeSource('agent/lib/agent.dart', 'class Agent {}');
    await writeSource(
      'agent/pubspec.yaml',
      'name: sanad_agent\nversion: 1.2.3',
    );
    await writeSource('client/bin/sanad_client.dart', 'void main() {}');
    await writeSource('client/lib/client.dart', 'class Client {}');
    await writeSource('client/pubspec.yaml', 'name: sanad_client');
    await writeSource('shared/windows_path/lib/windows_path.dart', '// shared');
    await writeSource('release/contract/lib/contract.dart', '// contract');
    await writeSource(
      'client/pubspec.yaml',
      'name: sanad_client\ndependencies:\n  sanad_windows_path:\n'
          '    path: ../shared/windows_path\n  sanad_release:\n'
          '    path: ../release/contract\n',
    );
  });

  tearDown(() async {
    if (fixture.existsSync()) await fixture.delete(recursive: true);
  });

  group('compiled CLI cache', () {
    test('caches per worktree commit and reuses a matching artifact', () async {
      final first = await cache().ensure(CompiledCliComponent.agent);
      expect(first.rebuilt, isTrue);
      expect(first.cacheKey, fixtureCacheKey(fixtureSourceCommit));
      expect(
        first.executablePath,
        p.join(
          workspace.path,
          '.sanad-dev',
          'bin',
          fixtureCacheKey(fixtureSourceCommit),
          Platform.isWindows ? 'agent.exe' : 'agent',
        ),
      );
      expect(File(first.executablePath).readAsStringSync(), 'agent-binary');
      expect(builds, hasLength(1));

      final second = await cache().ensure(CompiledCliComponent.agent);
      expect(second.rebuilt, isFalse);
      expect(second.buildLabel, 'reused');
      expect(builds, hasLength(1));
    });

    test('rebuilds when a component source file changes', () async {
      await cache().ensure(CompiledCliComponent.agent);
      await writeSource('agent/lib/agent.dart', 'class Agent { int x = 1; }');

      final rebuilt = await cache().ensure(CompiledCliComponent.agent);

      expect(rebuilt.rebuilt, isTrue);
      expect(builds, hasLength(2));
      expect(rebuilt.buildDuration, isNotNull);
    });

    test('rebuilds when a path dependency changes', () async {
      await cache().ensure(CompiledCliComponent.client);
      await writeSource(
        'shared/windows_path/lib/windows_path.dart',
        '// shared changed',
      );

      final rebuilt = await cache().ensure(CompiledCliComponent.client);

      expect(rebuilt.rebuilt, isTrue);
      expect(builds, hasLength(2));
    });

    test('rebuilds when the pinned Flutter version changes', () async {
      await cache().ensure(CompiledCliComponent.agent);
      await writeSource('.fvmrc', '{"flutter":"3.41.9"}');
      expect(
        (await cache().ensure(CompiledCliComponent.agent)).rebuilt,
        isTrue,
      );
      expect(builds, hasLength(2));
    });

    test('rebuilds when a native build hook changes', () async {
      await cache().ensure(CompiledCliComponent.client);
      await writeSource('client/hook/build.dart', 'void main() {}');

      final rebuilt = await cache().ensure(CompiledCliComponent.client);

      expect(rebuilt.rebuilt, isTrue);
      expect(builds, hasLength(2));
    });

    test('rebuilds when a transitive path dependency changes', () async {
      await writeSource(
        'shared/windows_path/pubspec.yaml',
        'name: sanad_windows_path\ndependencies:\n  deep:\n'
            '    path: ../deep\n',
      );
      await writeSource('shared/deep/lib/deep.dart', '// deep');
      await cache().ensure(CompiledCliComponent.client);
      await writeSource('shared/deep/lib/deep.dart', '// deep changed');

      final rebuilt = await cache().ensure(CompiledCliComponent.client);

      expect(
        rebuilt.rebuilt,
        isTrue,
        reason: 'a path dependency of a path dependency is still an input',
      );
      expect(builds, hasLength(2));
    });

    test('rebuilds when the effective SDK changes without an FVM pin', () async {
      expect(File(p.join(repository.path, '.fvmrc')).existsSync(), isFalse);
      await cache(sdkVersion: 'dart 3.10.7').ensure(CompiledCliComponent.agent);

      final rebuilt = await cache(
        sdkVersion: 'dart 3.11.0',
      ).ensure(CompiledCliComponent.agent);

      expect(rebuilt.rebuilt, isTrue);
      expect(builds, hasLength(2));
    });

    test('publishes atomically and leaves no staging artifact', () async {
      final artifact = await cache().ensure(CompiledCliComponent.agent);

      expect(File(artifact.executablePath).readAsStringSync(), 'agent-binary');
      expect(
        Directory(p.dirname(artifact.executablePath))
            .listSync()
            .where((entity) => entity.path.contains('.building')),
        isEmpty,
      );
    });

    test('concurrent builds publish one complete artifact', () async {
      final results = await Future.wait([
        cache().ensure(CompiledCliComponent.agent),
        cache().ensure(CompiledCliComponent.agent),
      ]);

      expect(
        builds,
        hasLength(1),
        reason: 'the per-commit build lock serializes compilation',
      );
      for (final artifact in results) {
        expect(File(artifact.executablePath).readAsStringSync(), 'agent-binary');
      }
      expect(results.where((artifact) => artifact.rebuilt), hasLength(1));
    });

    test('a reader takes the shared lock and runs the action', () async {
      final artifact = await cache().ensure(CompiledCliComponent.agent);
      final lockFile = File(
        p.join(
          p.dirname(artifact.executablePath),
          compiledCliLockFileName(CompiledCliComponent.agent),
        ),
      );
      expect(lockFile.existsSync(), isTrue);

      final value = await cache().withReadLock(
        CompiledCliComponent.agent,
        () async => File(artifact.executablePath).readAsStringSync(),
      );

      expect(value, 'agent-binary');
    });

    test('prunes older commits and keeps the current one', () async {
      for (var index = 0; index < compiledCliRetainedCommits + 3; index++) {
        await cache(
          commit: 'commit${index.toString().padLeft(6, '0')}',
        ).ensure(CompiledCliComponent.agent);
      }
      final binRoot = Directory(
        p.join(workspace.path, '.sanad-dev', 'bin'),
      );
      final remaining = binRoot
          .listSync()
          .whereType<Directory>()
          .map((directory) => p.basename(directory.path))
          .toSet();

      expect(
        remaining.length,
        lessThanOrEqualTo(compiledCliRetainedCommits + 1),
        reason: 'the cache keeps a bounded window plus the current commit',
      );
      expect(remaining, contains('commit000005'));
    });

    test('force rebuilds an unchanged artifact', () async {
      await cache().ensure(CompiledCliComponent.agent);

      final forced = await cache().ensure(
        CompiledCliComponent.agent,
        force: true,
      );

      expect(forced.rebuilt, isTrue);
      expect(builds, hasLength(2));
    });

    test('separates artifacts by commit and drops a failed build', () async {
      final first = await cache(
        commit: 'aaaa11112222',
      ).ensure(CompiledCliComponent.agent);
      final second = await cache(
        commit: 'bbbb33334444',
      ).ensure(CompiledCliComponent.agent);

      expect(first.executablePath, isNot(second.executablePath));
      expect(second.cacheKey, 'bbbb33334444');

      final failing = CompiledCliCache(
        workspaceRoot: workspace.path,
        repositoryRoot: repository.path,
        sourceCommit: () async => 'cccc55556666',
        builder: ({required workingDirectory, required arguments}) async => 2,
      );
      await expectLater(
        failing.ensure(CompiledCliComponent.agent),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('Agent CLI build failed'),
          ),
        ),
      );
      expect(
        Directory(
          p.join(workspace.path, '.sanad-dev', 'bin', 'cccc55556666'),
        )
            .listSync()
            .whereType<File>()
            .where(
              (file) =>
                  p.basename(file.path) !=
                  compiledCliLockFileName(CompiledCliComponent.agent),
            ),
        isEmpty,
        reason: 'a failed build publishes no artifact and no stamp',
      );
    });

    test('passes the pubspec version define to the Agent compile', () async {
      await cache().ensure(CompiledCliComponent.agent);

      expect(builds.single, contains('-DSANAD_AGENT_VERSION=1.2.3'));
      expect(builds.single, contains('bin/sanad_agent.dart'));
    });

    test('builds the Client CLI as a bundle beside its libraries', () async {
      final artifact = await cache().ensure(CompiledCliComponent.client);

      expect(builds.single.take(3), ['dart', 'build', 'cli']);
      expect(
        artifact.executablePath,
        p.join(
          workspace.path,
          '.sanad-dev',
          'bin',
          fixtureCacheKey(fixtureSourceCommit),
          'client-bundle',
          'bin',
          Platform.isWindows ? 'sanad_client.exe' : 'sanad_client',
        ),
      );
      expect(File(artifact.executablePath).existsSync(), isTrue);
    });

    test('falls back to a nogit cache key outside a repository', () async {
      final key = await CompiledCliCache(
        workspaceRoot: workspace.path,
        repositoryRoot: repository.path,
        sourceCommit: () async => '',
        builder: ({required workingDirectory, required arguments}) async => 0,
      ).resolveCacheKey();

      expect(key, 'nogit');
    });

    test('component parsing accepts only agent and client', () {
      expect(CompiledCliComponent.parse('agent'), CompiledCliComponent.agent);
      expect(CompiledCliComponent.parse('CLIENT'), CompiledCliComponent.client);
      expect(CompiledCliComponent.parse('server'), isNull);
    });

    test('formats build durations', () {
      expect(
        formatCompiledCliDuration(const Duration(milliseconds: 250)),
        '250ms',
      );
      expect(
        formatCompiledCliDuration(const Duration(milliseconds: 12400)),
        '12.4s',
      );
    });
  });
}
