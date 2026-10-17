import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sanad_agent/cli/runner/sanad_command_runner.dart';
import 'package:sanad_agent/interfaces/runtime/local_workspace_runtime_service.dart';
import 'package:test/test.dart';

import '../support/isolated_sanad_test_home.dart';

/// The skills commands share the global `--workspace` option: passing an
/// existing directory selects the workspace skills root, and omitting it keeps
/// the Sanad Home scope.
void main() {
  useIsolatedSanadTestHome();

  late Directory temp;
  late Directory home;
  late Directory workspace;
  late Directory source;
  late StringBuffer stdoutBuffer;
  late StringBuffer stderrBuffer;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('skills-workspace-');
    home = Directory(p.join(temp.path, 'home'));
    workspace = Directory(p.join(temp.path, 'ws'))..createSync(recursive: true);
    source = Directory(p.join(temp.path, 'src'));
    final skill = Directory(p.join(source.path, 'skills', 'alpha'))
      ..createSync(recursive: true);
    File(p.join(skill.path, 'SKILL.md')).writeAsStringSync(
      '---\n'
      'name: alpha\n'
      'description: Demo skill. Use when verifying the workspace scope.\n'
      '---\n\n# alpha\n',
    );
    stdoutBuffer = StringBuffer();
    stderrBuffer = StringBuffer();
  });

  tearDown(() => temp.deleteSync(recursive: true));

  Future<int> run(List<String> args) => SanadCommandRunner(
    stdoutSink: stdoutBuffer,
    stderrSink: stderrBuffer,
  ).run(args);

  List<String> addArgs() => [
    'skills',
    'add',
    source.path,
    '--skill',
    'alpha',
    '--home',
    home.path,
  ];

  test('--workspace installs into that workspace', () async {
    final code = await run([...addArgs(), '--workspace', workspace.path]);

    expect(code, 0);
    expect(
      File(p.join(workspace.path, '.sanad', 'skills', 'alpha', 'SKILL.md'))
          .existsSync(),
      isTrue,
    );
    expect(Directory(p.join(home.path, 'skills')).existsSync(), isFalse);
    expect(stdoutBuffer.toString(), contains('(workspace)'));
  });

  test('omitting --workspace installs into the Sanad Home', () async {
    final code = await run(addArgs());

    expect(code, 0);
    expect(
      File(p.join(home.path, 'skills', 'alpha', 'SKILL.md')).existsSync(),
      isTrue,
    );
    expect(
      Directory(p.join(workspace.path, '.sanad', 'skills')).existsSync(),
      isFalse,
    );
    expect(stdoutBuffer.toString(), contains('(user)'));
  });

  test('an unknown workspace name is refused before anything is written', () async {
    final code = await run([...addArgs(), '--workspace', 'no-such-workspace']);

    expect(code, 64);
    expect(stderrBuffer.toString(), contains('No workspace matched'));
    expect(Directory(p.join(home.path, 'skills')).existsSync(), isFalse);
  });

  test('a registered workspace name resolves to its path', () async {
    await LocalWorkspaceRuntimeService().createWorkspace(
      name: 'demo-workspace',
      path: workspace.path,
    );

    final code = await run([...addArgs(), '--workspace', 'demo-workspace']);

    expect(code, 0);
    expect(
      File(p.join(workspace.path, '.sanad', 'skills', 'alpha', 'SKILL.md'))
          .existsSync(),
      isTrue,
    );
    expect(stdoutBuffer.toString(), contains('(workspace)'));
  });

  test('the removed --project flag is rejected', () async {
    final code = await run([...addArgs(), '--project']);

    expect(code, isNot(0));
  });
}
