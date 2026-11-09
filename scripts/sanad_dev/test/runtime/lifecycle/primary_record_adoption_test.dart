import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:sanad_dev/sanad_dev_cli.dart' as sanad_dev;
import 'package:sanad_dev/src/infrastructure/runtime_context.dart'
    as runtime_context;

/// The primary checkout used to name its record directory after the checked-out
/// branch, so detaching HEAD renamed the namespace mid-session and left the
/// previous record looking unclaimed. The id is path-derived now, and these
/// tests pin the one-time adoption of an already-written record.
void main() {
  group('primary runtime record adoption', () {
    late Directory root;
    late String workspace;

    setUp(() {
      root = Directory.systemTemp.createTempSync('sanad-primary-adoption-');
      workspace = p.join(root.path, 'repo');
      Directory(workspace).createSync(recursive: true);
    });

    tearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    String hash() => runtime_context.worktreeHashSuffix(workspace);

    String runtimesRoot() => p.join(root.path, '.sanad', 'dev', 'runtimes');

    runtime_context.SanadDevRuntime runtime({bool linked = false}) {
      final id = linked ? 'feat-x-${hash()}' : 'primary-${hash()}';
      return runtime_context.SanadDevRuntime(
        workspaceRoot: workspace,
        repositoryRoot: workspace,
        worktreeId: id,
        isLinkedWorktree: linked,
        usesPrimaryResources: !linked,
        agentPort: 58085,
        vmServicePort: 51111,
        sanadHome: p.join(root.path, '.sanad'),
        runtimeDirectory: p.join(runtimesRoot(), id),
        branch: 'main',
      );
    }

    Directory recordDirectory(String name) =>
        Directory(p.join(runtimesRoot(), name))..createSync(recursive: true);

    void writeLocator(Directory directory, {String? workspaceHash}) {
      File(p.join(directory.path, 'startup-attempt.json')).writeAsStringSync(
        jsonEncode({
          'version': 1,
          'attempt_id': 'attempt-1',
          'workspace_hash': workspaceHash ?? hash(),
          'agent_port': 58085,
          'resolved_home': p.join(root.path, '.sanad'),
        }),
      );
    }

    test('adopts a branch-derived record without losing its files', () async {
      final legacy = recordDirectory('sanad-agent-${hash()}');
      writeLocator(legacy);
      File(p.join(legacy.path, 'apply-baseline.json')).writeAsStringSync('{}');
      File(
        p.join(legacy.path, 'runtime.json'),
      ).writeAsStringSync(jsonEncode({'agent_pid': 4242, 'agent_port': 58085}));

      await sanad_dev.adoptLegacyPrimaryRuntimeRecord(runtime());

      final canonical = Directory(p.join(runtimesRoot(), 'primary-${hash()}'));
      expect(canonical.existsSync(), isTrue);
      expect(legacy.existsSync(), isFalse);
      expect(
        File(p.join(canonical.path, 'apply-baseline.json')).existsSync(),
        isTrue,
        reason: 'the apply baseline travels with the directory',
      );
      expect(
        File(p.join(canonical.path, 'startup-attempt.json')).existsSync(),
        isTrue,
      );
    });

    test('keeps an existing canonical directory and never merges', () async {
      final legacy = recordDirectory('main-${hash()}');
      writeLocator(legacy);
      final canonical = recordDirectory('primary-${hash()}');
      writeLocator(canonical, workspaceHash: null);
      File(p.join(canonical.path, 'runtime.json')).writeAsStringSync('{}');

      await sanad_dev.adoptLegacyPrimaryRuntimeRecord(runtime());

      expect(legacy.existsSync(), isTrue);
      expect(File(p.join(canonical.path, 'runtime.json')).existsSync(), isTrue);
    });

    test('is idempotent', () async {
      final legacy = recordDirectory('main-${hash()}');
      writeLocator(legacy);

      await sanad_dev.adoptLegacyPrimaryRuntimeRecord(runtime());
      await sanad_dev.adoptLegacyPrimaryRuntimeRecord(runtime());

      final canonical = Directory(p.join(runtimesRoot(), 'primary-${hash()}'));
      expect(canonical.existsSync(), isTrue);
      expect(canonical.listSync().map((entity) => p.basename(entity.path)), [
        'startup-attempt.json',
      ]);
    });

    test('still adopts a record written without a locator', () async {
      final legacy = recordDirectory('sanad-agent-${hash()}');

      await sanad_dev.adoptLegacyPrimaryRuntimeRecord(runtime());

      expect(legacy.existsSync(), isFalse);
      expect(
        Directory(p.join(runtimesRoot(), 'primary-${hash()}')).existsSync(),
        isTrue,
      );
    });

    test('never adopts a record that names another workspace', () async {
      final foreign = recordDirectory('other-${hash()}');
      writeLocator(foreign, workspaceHash: 'deadbeef');

      await sanad_dev.adoptLegacyPrimaryRuntimeRecord(runtime());

      expect(foreign.existsSync(), isTrue);
      expect(
        Directory(p.join(runtimesRoot(), 'primary-${hash()}')).existsSync(),
        isFalse,
      );
    });

    test('leaves a linked worktree record untouched', () async {
      final linked = recordDirectory('feat-x-${hash()}');
      writeLocator(linked);

      await sanad_dev.adoptLegacyPrimaryRuntimeRecord(runtime(linked: true));

      expect(linked.existsSync(), isTrue);
    });

    test('resolving a legacy record is read-only and readable', () async {
      final legacy = recordDirectory('main-${hash()}');
      writeLocator(legacy);
      File(p.join(legacy.path, 'runtime.json')).writeAsStringSync(
        jsonEncode({
          'agent_pid': 4242,
          'client_pid': 4343,
          'agent_port': 58085,
          'vm_service_port': 51111,
        }),
      );

      final first = await runtime_context.legacyRuntimeRecordDirectory(
        runtime(),
      );
      final second = await runtime_context.legacyRuntimeRecordDirectory(
        runtime(),
      );

      expect(first, legacy.path);
      expect(second, legacy.path);
      expect(
        legacy.existsSync(),
        isTrue,
        reason: 'observation commands never rename a record',
      );
      final record = await runtime_context.readRuntimeRecord(
        runtime(),
        directory: first,
      );
      expect(record?.agentPid, 4242);
      expect(record?.clientPid, 4343);
      expect(record?.vmServicePort, 51111);
    });
  });
}
