import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:sanad_agent/capabilities/skills/skill_registry.dart';

void main() {
  test('SANAD_HOME skills are user skills even when HOME differs', () async {
    final root = Directory.systemTemp.createTempSync('skill-registry-home-');
    final otherHome = Directory.systemTemp.createTempSync(
      'skill-registry-user-',
    );
    addTearDown(() {
      try {
        if (root.existsSync()) root.deleteSync(recursive: true);
      } catch (_) {}
      try {
        if (otherHome.existsSync()) otherHome.deleteSync(recursive: true);
      } catch (_) {}
    });
    final skill = Directory(p.join(root.path, 'skills', 'product-skill'))
      ..createSync(recursive: true);
    File(p.join(skill.path, 'SKILL.md')).writeAsStringSync(
      '---\nname: product-skill\ndescription: Product skill.\n---\n# Product\n',
    );

    final definition = await SkillRegistry(
      environment: {'SANAD_HOME': root.path, 'HOME': otherHome.path},
    ).resolve(skill: 'product-skill');

    expect(definition, isNotNull);
    expect(
      p.normalize(definition!.sourcePath),
      contains(p.normalize(p.join(root.path, 'skills', 'product-skill'))),
    );
    expect(definition.origin.rootKind.name, 'sanadSkills');
  });
}
