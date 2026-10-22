import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sanad_dev/src/infrastructure/compiled_cli_cache.dart';
import 'package:test/test.dart';

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

  CompiledCliCache cache({String commit = 'abcdef1234567890'}) =>
      CompiledCliCache(
        workspaceRoot: workspace.path,
        repositoryRoot: repository.path,
        sourceCommit: () async => commit,
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
      expect(first.cacheKey, 'abcdef123456');
      expect(
        first.executablePath,
        p.join(
          workspace.path,
          '.sanad-dev',
          'bin',
          'abcdef123456',
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
        ).listSync().whereType<File>(),
        isEmpty,
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
          'abcdef123456',
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
