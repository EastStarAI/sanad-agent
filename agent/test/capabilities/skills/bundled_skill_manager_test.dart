import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

import 'package:sanad_agent/capabilities/skills/bundled_skill_manager.dart';
import 'package:sanad_agent/capabilities/skills/generated_bundled_skills.dart';
import 'package:sanad_agent/core/sanad_home/sanad_home_bootstrap.dart';

void main() {
  late Directory home;
  late SanadHomeBootstrap boundary;

  setUp(() {
    home = Directory.systemTemp.createTempSync('sanad-bundled-skills-test-');
    boundary = SanadHomeBootstrap.atRoot(
      home.path,
      scope: SanadHomeScope.identity,
    );
    boundary.prepareDatabaseSync();
  });

  tearDown(() {
    if (home.existsSync()) home.deleteSync(recursive: true);
  });

  test('fresh install writes complete packages and state', () {
    final result = _manager(boundary, 'v1', [
      _skill('alpha', {'SKILL.md': '# Alpha', 'references/guide.md': 'Guide'}),
    ]).reconcileSync();

    expect(result.fastPath, isFalse);
    expect(result.installed, 1);
    expect(
      File('${home.path}/skills/alpha/references/guide.md').readAsStringSync(),
      'Guide',
    );
    expect(
      File('${home.path}/skills/.sanad-managed.json').existsSync(),
      isTrue,
    );
  });

  test('matching revision takes fast path without inspecting skill tree', () {
    final manager = _manager(boundary, 'v1', [
      _skill('alpha', {'SKILL.md': '# Alpha'}),
    ]);
    manager.reconcileSync();
    Directory('${home.path}/skills/alpha').deleteSync(recursive: true);
    Link('${home.path}/skills/alpha').createSync(home.parent.path);

    final result = manager.reconcileSync();

    expect(result.fastPath, isTrue);
    expect(Link('${home.path}/skills/alpha').existsSync(), isTrue);
  });

  test('new revision updates unchanged skill and installs new skill', () {
    _manager(boundary, 'v1', [
      _skill('alpha', {'SKILL.md': '# Alpha v1'}),
    ]).reconcileSync();

    final result = _manager(boundary, 'v2', [
      _skill('alpha', {'SKILL.md': '# Alpha v2', 'script.sh': 'echo ok'}),
      _skill('beta', {'SKILL.md': '# Beta'}),
    ]).reconcileSync();

    expect(result.updated, 1);
    expect(result.installed, 1);
    expect(
      File('${home.path}/skills/alpha/SKILL.md').readAsStringSync(),
      '# Alpha v2',
    );
    expect(File('${home.path}/skills/beta/SKILL.md').existsSync(), isTrue);
  });

  test('new revision preserves user-modified managed skill', () {
    _manager(boundary, 'v1', [
      _skill('alpha', {'SKILL.md': '# Alpha v1'}),
    ]).reconcileSync();
    File('${home.path}/skills/alpha/SKILL.md').writeAsStringSync('# User copy');

    final result = _manager(boundary, 'v2', [
      _skill('alpha', {'SKILL.md': '# Alpha v2'}),
    ]).reconcileSync();

    expect(result.preserved, 1);
    expect(
      File('${home.path}/skills/alpha/SKILL.md').readAsStringSync(),
      '# User copy',
    );
    final state =
        jsonDecode(
              File(
                '${home.path}/skills/.sanad-managed.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    expect(
      (state['skills'] as Map<String, dynamic>).containsKey('alpha'),
      isFalse,
    );
  });

  test('interrupted state advance re-baselines exact new bundle content', () {
    final v1 = _skill('alpha', {'SKILL.md': '# Alpha v1'});
    final v2 = _skill('alpha', {'SKILL.md': '# Alpha v2'});
    _manager(boundary, 'v1', [v1]).reconcileSync();

    boundary.replaceDirectoryBytesSync('skills/alpha', {
      for (final file in v2.files) file.path: file.decode(),
    });

    final result = _manager(boundary, 'v2', [v2]).reconcileSync();

    expect(result.preserved, 0);
    expect(result.updated, 0);
    expect(
      File('${home.path}/skills/alpha/SKILL.md').readAsStringSync(),
      '# Alpha v2',
    );
  });

  test('removed unchanged skill is deleted', () {
    _manager(boundary, 'v1', [
      _skill('alpha', {'SKILL.md': '# Alpha'}),
      _skill('beta', {'SKILL.md': '# Beta'}),
    ]).reconcileSync();

    final result = _manager(boundary, 'v2', [
      _skill('alpha', {'SKILL.md': '# Alpha'}),
    ]).reconcileSync();

    expect(result.removed, 1);
    expect(Directory('${home.path}/skills/beta').existsSync(), isFalse);
  });

  test('removed modified skill survives and becomes user-owned', () {
    _manager(boundary, 'v1', [
      _skill('alpha', {'SKILL.md': '# Alpha'}),
      _skill('beta', {'SKILL.md': '# Beta'}),
    ]).reconcileSync();
    File('${home.path}/skills/beta/SKILL.md').writeAsStringSync('# Customized');

    final result = _manager(boundary, 'v2', [
      _skill('alpha', {'SKILL.md': '# Alpha'}),
    ]).reconcileSync();

    expect(result.preserved, 1);
    expect(
      File('${home.path}/skills/beta/SKILL.md').readAsStringSync(),
      '# Customized',
    );
  });

  test(
    'user deletion is recorded on next bundle revision and not restored',
    () {
      _manager(boundary, 'v1', [
        _skill('alpha', {'SKILL.md': '# Alpha v1'}),
      ]).reconcileSync();
      Directory('${home.path}/skills/alpha').deleteSync(recursive: true);

      final result = _manager(boundary, 'v2', [
        _skill('alpha', {'SKILL.md': '# Alpha v2'}),
      ]).reconcileSync();

      expect(result.preserved, 1);
      expect(Directory('${home.path}/skills/alpha').existsSync(), isFalse);
    },
  );

  test('pre-existing collision is preserved and never claimed', () {
    Directory('${home.path}/skills/alpha').createSync(recursive: true);
    File('${home.path}/skills/alpha/SKILL.md').writeAsStringSync('# Local');

    final result = _manager(boundary, 'v1', [
      _skill('alpha', {'SKILL.md': '# Bundled'}),
    ]).reconcileSync();

    expect(result.preserved, 1);
    expect(
      File('${home.path}/skills/alpha/SKILL.md').readAsStringSync(),
      '# Local',
    );
  });

  test('corrupt state never overwrites a pre-existing skill', () {
    Directory('${home.path}/skills/alpha').createSync(recursive: true);
    File('${home.path}/skills/alpha/SKILL.md').writeAsStringSync('# Local');
    File(
      '${home.path}/skills/.sanad-managed.json',
    ).writeAsStringSync('{broken');

    final result = _manager(boundary, 'v2', [
      _skill('alpha', {'SKILL.md': '# Bundled'}),
    ]).reconcileSync();

    expect(result.preserved, 1);
    expect(
      File('${home.path}/skills/alpha/SKILL.md').readAsStringSync(),
      '# Local',
    );
  });

  test('generated product bundle contains exactly the selected skills', () {
    expect(
      bundledSkills.map((skill) => skill.id),
      containsAllInOrder(['skill-creator', 'find-skills', 'agent-browser']),
    );
    expect(bundledSkills, hasLength(3));
    for (final skill in bundledSkills) {
      expect(skill.files.any((file) => file.path == 'SKILL.md'), isTrue);
      expect(skill.files.any((file) => file.path == 'LICENSE.txt'), isTrue);
      for (final file in skill.files) {
        expect(sha256.convert(file.decode()).toString(), file.sha256);
      }
    }
  });
}

BundledSkillManager _manager(
  SanadHomeBootstrap home,
  String revision,
  List<BundledSkill> skills,
) => BundledSkillManager(home: home, bundleRevision: revision, skills: skills);

BundledSkill _skill(String id, Map<String, String> files) {
  return BundledSkill(
    id: id,
    upstream: 'https://example.invalid/$id',
    upstreamRevision: 'revision',
    license: 'test',
    files: [
      for (final entry in files.entries)
        BundledSkillFile(
          path: entry.key,
          sha256: sha256.convert(utf8.encode(entry.value)).toString(),
          executable: entry.key.endsWith('.sh'),
          compressedBase64: base64Encode(
            ZLibCodec(level: 9).encode(utf8.encode(entry.value)),
          ),
        ),
    ],
  );
}
