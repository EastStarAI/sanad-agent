import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sanad_agent/capabilities/skills/skill_install_service.dart';
import 'package:sanad_agent/capabilities/skills/skill_source.dart';
import 'package:test/test.dart';

String skillMarkdown(String name, {String? description}) =>
    '''
---
name: $name
description: ${description ?? 'Demonstrates the install command. Use when testing installs.'}
---

# $name

Body.
''';

void writeFile(Directory root, String relative, String content) {
  final file = File(p.join(root.path, relative));
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(content);
}

void main() {
  late Directory temp;
  late Directory source;
  late Directory root;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('skill-install-');
    source = Directory(p.join(temp.path, 'source'))
      ..createSync(recursive: true);
    root = Directory(p.join(temp.path, 'home', 'skills'));
  });

  tearDown(() => temp.deleteSync(recursive: true));

  SkillInstallService service() =>
      SkillInstallService(skillsRoot: root, scope: SkillScope.user);

  test('installs a single skill from a multi-skill source', () async {
    writeFile(source, 'skills/alpha/SKILL.md', skillMarkdown('alpha'));
    writeFile(source, 'skills/alpha/references/a.md', 'ref');
    writeFile(source, 'skills/beta/SKILL.md', skillMarkdown('beta'));

    final installer = service();
    final outcome = await installer.install(
      SkillSource.parse(source.path),
      skill: 'alpha',
    );

    expect(outcome.changed, isTrue);
    expect(File(p.join(root.path, 'alpha', 'SKILL.md')).existsSync(), isTrue);
    expect(
      File(p.join(root.path, 'alpha', 'references', 'a.md')).existsSync(),
      isTrue,
    );
    expect(Directory(p.join(root.path, 'beta')).existsSync(), isFalse);

    final records = installer.readProvenance();
    expect(records['alpha']!.source, source.absolute.path);
    expect(records['alpha']!.scope, SkillScope.user);
    expect(records['alpha']!.digest, isNotEmpty);
    installer.close();
  });

  test('refuses an ambiguous multi-skill source', () async {
    writeFile(source, 'skills/alpha/SKILL.md', skillMarkdown('alpha'));
    writeFile(source, 'skills/beta/SKILL.md', skillMarkdown('beta'));

    final installer = service();
    await expectLater(
      installer.install(SkillSource.parse(source.path)),
      throwsA(
        isA<SkillInstallException>().having(
          (error) => error.message,
          'message',
          allOf(contains('alpha'), contains('beta'), contains('--skill')),
        ),
      ),
    );
    expect(root.existsSync(), isFalse);
    installer.close();
  });

  test('installs a source that has a single root SKILL.md', () async {
    final single = Directory(p.join(temp.path, 'whatever-dir'))
      ..createSync(recursive: true);
    writeFile(single, 'SKILL.md', skillMarkdown('root-skill'));
    writeFile(single, 'scripts/run.sh', 'echo hi');

    final installer = service();
    final outcome = await installer.install(SkillSource.parse(single.path));

    expect(outcome.name, 'root-skill');
    expect(
      File(p.join(root.path, 'root-skill', 'scripts', 'run.sh')).existsSync(),
      isTrue,
    );
    installer.close();
  });

  test('rejects a declared name that differs from its folder', () async {
    writeFile(source, 'skills/folder/SKILL.md', skillMarkdown('other'));

    final installer = service();
    await expectLater(
      installer.install(SkillSource.parse(source.path), skill: 'folder'),
      throwsA(
        isA<SkillInstallException>().having(
          (error) => error.message,
          'message',
          contains('must match its directory'),
        ),
      ),
    );
    installer.close();
  });

  test('protects an existing install unless force is set', () async {
    writeFile(source, 'skills/alpha/SKILL.md', skillMarkdown('alpha'));

    final installer = service();
    await installer.install(SkillSource.parse(source.path), skill: 'alpha');

    await expectLater(
      installer.install(SkillSource.parse(source.path), skill: 'alpha'),
      throwsA(
        isA<SkillInstallException>().having(
          (error) => error.message,
          'message',
          contains('--force'),
        ),
      ),
    );

    writeFile(
      source,
      'skills/alpha/SKILL.md',
      skillMarkdown('alpha', description: 'Changed.'),
    );
    final replaced = await installer.install(
      SkillSource.parse(source.path),
      skill: 'alpha',
      force: true,
    );
    expect(replaced.changed, isTrue);
    expect(
      File(p.join(root.path, 'alpha', 'SKILL.md')).readAsStringSync(),
      contains('Changed.'),
    );
    installer.close();
  });

  test('update reports unchanged and then detects a change', () async {
    writeFile(source, 'skills/alpha/SKILL.md', skillMarkdown('alpha'));

    final installer = service();
    await installer.install(SkillSource.parse(source.path), skill: 'alpha');

    final first = await installer.update();
    expect(first.single.changed, isFalse);

    writeFile(
      source,
      'skills/alpha/SKILL.md',
      skillMarkdown('alpha', description: 'Newer.'),
    );
    final second = await installer.update(name: 'alpha');
    expect(second.single.changed, isTrue);
    expect(
      File(p.join(root.path, 'alpha', 'SKILL.md')).readAsStringSync(),
      contains('Newer.'),
    );
    installer.close();
  });

  test('update without provenance fails with guidance', () async {
    final installer = service();
    await expectLater(
      installer.update(),
      throwsA(isA<SkillInstallException>()),
    );
    installer.close();
  });

  test('remove deletes the skill and its provenance only', () async {
    writeFile(source, 'skills/alpha/SKILL.md', skillMarkdown('alpha'));
    writeFile(source, 'skills/beta/SKILL.md', skillMarkdown('beta'));

    final installer = service();
    await installer.install(SkillSource.parse(source.path), skill: 'alpha');
    await installer.install(SkillSource.parse(source.path), skill: 'beta');
    installer.remove('alpha');

    expect(Directory(p.join(root.path, 'alpha')).existsSync(), isFalse);
    expect(Directory(p.join(root.path, 'beta')).existsSync(), isTrue);
    expect(installer.readProvenance().keys, ['beta']);
    installer.close();
  });

  test('remove refuses an unmanaged skill without force', () async {
    Directory(p.join(root.path, 'copied')).createSync(recursive: true);
    File(
      p.join(root.path, 'copied', 'SKILL.md'),
    ).writeAsStringSync(skillMarkdown('copied'));

    final installer = service();
    expect(
      () => installer.remove('copied'),
      throwsA(
        isA<SkillInstallException>().having(
          (error) => error.message,
          'message',
          contains('--force'),
        ),
      ),
    );
    installer.remove('copied', force: true);
    expect(Directory(p.join(root.path, 'copied')).existsSync(), isFalse);
    installer.close();
  });

  test('digest ignores ordering and changes with content', () async {
    writeFile(source, 'skills/alpha/SKILL.md', skillMarkdown('alpha'));
    writeFile(source, 'skills/alpha/b.md', 'b');

    final installer = service();
    final outcome = await installer.install(
      SkillSource.parse(source.path),
      skill: 'alpha',
    );
    final records = installer.readProvenance();
    expect(records['alpha']!.digest, outcome.digest);

    final provenance =
        jsonDecode(
              File(p.join(root.path, '.sanad-skills.json')).readAsStringSync(),
            )
            as Map<String, Object?>;
    expect(provenance['version'], 1);
    installer.close();
  });
}
