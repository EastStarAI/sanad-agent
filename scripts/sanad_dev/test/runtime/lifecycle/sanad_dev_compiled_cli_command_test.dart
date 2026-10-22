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
    exitCode = 0;
  });

  tearDown(() async {
    if (fixture.existsSync()) await fixture.delete(recursive: true);
    exitCode = 0;
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
      expect(exitCode, 0);
    });

    test('forwards every argument when no separator is given', () async {
      await invoke(const ['client', 'session', 'list']);

      expect(ensured, [CompiledCliComponent.client]);
      expect(runs.single, ['/cache/client', 'session', 'list']);
    });

    test('returns the child exit status', () async {
      await invoke(const ['agent', '--', 'session', 'stop'], childExitCode: 3);

      expect(exitCode, 3);
    });

    test('rejects an unknown or missing component', () async {
      await invoke(const ['path']);
      expect(errors.single, contains('Usage: sanad-dev cli'));
      expect(exitCode, 64);

      errors.clear();
      exitCode = 0;
      await invoke(const ['server', '--', 'list']);
      expect(errors.single, contains('Usage: sanad-dev cli'));
      expect(exitCode, 64);
      expect(ensured, isEmpty);
    });

    test('requires arguments for the run form', () async {
      await invoke(const ['agent']);

      expect(errors.single, contains('Nothing to run'));
      expect(runs, isEmpty);
      expect(exitCode, 64);
    });
  });
}
