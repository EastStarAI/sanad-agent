import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sanad_dev/sanad_dev_cli.dart' as sanad_dev;
import 'package:sanad_dev/src/infrastructure/compiled_cli_cache.dart';
import 'package:sanad_dev/src/infrastructure/runtime_context.dart'
    as runtime_context;
import 'package:test/test.dart';

void main() {
  late Directory fixture;
  late runtime_context.SanadDevRuntime runtime;
  late List<String> lines;
  late List<String> errors;
  late List<CompiledCliComponent> ensured;
  late List<List<String>> runs;
  late List<int> exitCodes;

  Future<void> invoke(
    List<String> arguments, {
    bool artifactRebuilt = false,
    int childExitCode = 0,
  }) async {
    await sanad_dev.handleCompiledCliCommand(
      arguments,
      sanadHomePath: '/isolated/home',
      printMessage: lines.add,
      printError: errors.add,
      ensureArtifact: (component, {force = false, log}) async {
        ensured.add(component);
        return CompiledCliArtifact(
          component: component,
          executablePath: p.join('/cache', component.name),
          fingerprint: 'fingerprint',
          cacheKey: 'abcdef123456',
          rebuilt: artifactRebuilt,
          buildDuration: artifactRebuilt
              ? const Duration(milliseconds: 12400)
              : null,
        );
      },
      runArtifact: (executable, arguments) async {
        runs.add([executable, ...arguments]);
        return childExitCode;
      },
      setExitCode: exitCodes.add,
    );
  }

  setUp(() async {
    fixture = await Directory.systemTemp.createTemp('sanad-cli-command-');
    runtime = runtime_context.SanadDevRuntime(
      workspaceRoot: fixture.path,
      repositoryRoot: p.join(fixture.path, 'repo'),
      worktreeId: 'feat-x-12345678',
      isLinkedWorktree: true,
      usesPrimaryResources: false,
      agentPort: 58092,
      vmServicePort: 51092,
      sanadHome: '/isolated/home',
      runtimeDirectory: p.join(fixture.path, 'runtime'),
      branch: 'feat/x',
    );
    Directory(runtime.repositoryRoot).createSync(recursive: true);
    lines = [];
    errors = [];
    ensured = [];
    runs = [];
    exitCodes = [];
  });

  tearDown(() async {
    if (fixture.existsSync()) await fixture.delete(recursive: true);
  });

  group('compiled CLI command', () {
    test('path prints the cached artifact and its build result', () async {
      // The handler discovers the caller runtime; point it at the fixture.
      final previous = Platform.environment['SANAD_DEV_CALLER_DIR'];
      try {
        await invoke(const ['path', 'agent'], artifactRebuilt: true);

        expect(ensured, [CompiledCliComponent.agent]);
        expect(lines.single, contains('/cache/agent'));
        expect(lines.single, contains('sha=abcdef123456'));
        expect(lines.single, contains('built in 12.4s'));
        expect(runs, isEmpty);
      } finally {
        if (previous != null) {
          // The process environment cannot be mutated in tests; nothing to do.
        }
      }
    });

    test('forwards arguments after -- to the cached artifact', () async {
      await invoke(const ['agent', '--', '--version']);

      expect(runs.single, ['/cache/agent', '--version']);
      expect(errors, isEmpty);
      expect(exitCodes, isEmpty);
    });

    test('forwards every argument when no separator is given', () async {
      await invoke(const ['client', 'session', 'list']);

      expect(ensured, [CompiledCliComponent.client]);
      expect(runs.single, ['/cache/client', 'session', 'list']);
    });

    test('returns the child exit status', () async {
      await invoke(const ['agent', '--', 'session', 'stop'], childExitCode: 3);

      expect(exitCodes, [3]);
    });

    test('rejects an unknown or missing component', () async {
      await invoke(const ['path']);
      expect(errors.single, contains('Usage: sanad-dev cli'));
      expect(exitCodes, [64]);

      errors.clear();
      exitCodes.clear();
      await invoke(const ['server', '--', 'list']);
      expect(errors.single, contains('Usage: sanad-dev cli'));
      expect(exitCodes, [64]);
      expect(ensured, isEmpty);
    });

    test('requires arguments for the run form', () async {
      await invoke(const ['agent']);

      expect(errors.single, contains('Nothing to run'));
      expect(runs, isEmpty);
      expect(exitCodes, [64]);
    });
  });

  group('cache read lock', () {
    test('is released as soon as the binary has started', () async {
      // A long `sanad-dev cli agent -- …` session must not block a rebuild for
      // its whole lifetime, so the shared lock covers only the launch.
      final cache = CompiledCliCache(
        workspaceRoot: fixture.path,
        repositoryRoot: runtime.repositoryRoot,
      );
      const component = CompiledCliComponent.agent;
      final cacheKey = await cache.resolveCacheKey();
      final lockFile = File(
        p.join(
          cache.cacheRoot,
          cacheKey,
          compiledCliLockFileName(component),
        ),
      )..createSync(recursive: true);
      final releaseChild = p.join(fixture.path, 'release-child');
      var childExited = false;

      final run = sanad_dev
          .runCompiledCliArtifactUnderCacheLock(
            cache,
            component,
            '/bin/sh',
            [
              '-c',
              'while [ ! -f "\$1" ]; do sleep 1; done',
              'sh',
              releaseChild,
            ],
          )
          .whenComplete(() => childExited = true);

      // Let the child start before a second caller tries the same lock.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(childExited, isFalse, reason: 'the child is still running');

      await cache
          .withReadLock(component, () async {})
          .timeout(
            const Duration(seconds: 3),
            onTimeout: () => fail(
              'the cache lock was still held by the running child',
            ),
          );

      expect(
        childExited,
        isFalse,
        reason: 'a rebuild must be able to run while the child is alive',
      );
      File(releaseChild).writeAsStringSync('go');
      expect(await run, 0);
      expect(lockFile.existsSync(), isTrue);
    }, timeout: const Timeout(Duration(seconds: 30)));
  });
}
