import 'skill_registry.dart';

class SkillLoadService {
  static const sourcePrefix = 'Skill source: ';

  final Map<String, String>? _environment;
  final SkillRegistry? _registry;

  const SkillLoadService({
    Map<String, String>? environment,
    SkillRegistry? registry,
  }) : _environment = environment,
       _registry = registry;

  Future<String> load({required String skill, String? workspacePath}) async {
    final resolved =
        await (_registry ?? SkillRegistry(environment: _environment)).resolve(
          skill: skill,
          workspacePath: workspacePath,
        );
    if (resolved == null) {
      throw Exception('Unknown skill: ${skill.trim()}');
    }

    return '$sourcePrefix${resolved.sourcePath}\n\n${resolved.prompt}';
  }
}
