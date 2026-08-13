import 'dart:io';

import 'package:test/test.dart';

import 'package:sanad_agent/capabilities/skills/skill_registry.dart';

void main() {
  test('SANAD_HOME skills are user skills even when HOME differs', () async {
    final root = Directory.systemTemp.createTempSync('skill-registry-home-');
    final otherHome = Directory.systemTemp.createTempSync(
      'skill-registry-user-',
    );
    addTearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
      if (otherHome.existsSync()) otherHome.deleteSync(recursive: true);
    });
    final skill = Directory('${root.path}/skills/product-skill')
      ..createSync(recursive: true);
    File('${skill.path}/SKILL.md').writeAsStringSync(
      '---\nname: product-skill\ndescription: Product skill.\n---\n# Product\n',
    );

    final definition = await SkillRegistry(
      environment: {'SANAD_HOME': root.path, 'HOME': otherHome.path},
    ).resolve(skill: 'product-skill');

    expect(definition, isNotNull);
    expect(
      definition!.sourcePath,
      contains('${root.path}/skills/product-skill'),
    );
    expect(definition.origin.rootKind.name, 'sanadSkills');
  });
}
