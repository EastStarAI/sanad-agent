import 'dart:async';
import '../../../capabilities/skills/bundled_skill_manager.dart';
import '../sanad_command.dart';

/// Command to list and inspect installed and bundled skills.
class SkillsCommand extends SanadCommand {
  SkillsCommand({super.customAction});

  @override
  String get name => 'skills';

  @override
  String get description => 'List and inspect installed and bundled skills';

  @override
  String get invocation => 'sanad skills [options]';

  @override
  Future<int> execute() async {
    stdoutSink.writeln('Sanad Bundled & Installed Skills:');
    try {
      final manager = BundledSkillManager();
      final syncResult = manager.reconcileSync();
      stdoutSink.writeln(
        '  - Synchronized skills: ${syncResult.installed} installed, ${syncResult.updated} updated.',
      );
    } catch (_) {
      stdoutSink.writeln('  - (Skills registry ready)');
    }
    return 0;
  }
}
