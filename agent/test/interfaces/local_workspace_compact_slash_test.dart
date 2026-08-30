import 'dart:io';

import 'package:sanad_agent/capabilities/skills/skill_registry.dart';
import 'package:sanad_agent/interfaces/runtime/local_workspace_runtime_service.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late LocalWorkspaceRuntimeService service;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('slash-command-test');
    service = LocalWorkspaceRuntimeService(
      sanadHomePath: tempDir.path,
      currentWorkingDirectory: tempDir.path,
      skillRegistry: SkillRegistry(environment: {'SANAD_HOME': tempDir.path}),
    );
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  test('searchSlashCommands exposes only /compact runtime command by default', () async {
    final commands = await service.searchSlashCommands();
    expect(commands, hasLength(1));
    expect(commands.single['command'], 'compact');
    expect(commands.single['type'], 'runtime_command');
    expect(commands.single['source'], 'sanad-agent');
  });
}
