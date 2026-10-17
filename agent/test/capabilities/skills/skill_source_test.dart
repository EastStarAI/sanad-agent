import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sanad_agent/capabilities/skills/skill_source.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('skill-source-'));
  tearDown(() => temp.deleteSync(recursive: true));

  group('SkillSource.parse', () {
    test('accepts owner/repo', () {
      final source = SkillSource.parse('AhmedAttia3/agent-skills');
      expect(source.kind, SkillSourceKind.github);
      expect(source.owner, 'AhmedAttia3');
      expect(source.repo, 'agent-skills');
      expect(source.ref, isNull);
      expect(source.recordedSource, 'AhmedAttia3/agent-skills');
    });

    test('accepts owner/repo@ref', () {
      final source = SkillSource.parse('owner/repo@v1.2.0');
      expect(source.ref, 'v1.2.0');
      expect(source.repo, 'repo');
    });

    test('accepts a GitHub URL with ref and sub-path', () {
      final source = SkillSource.parse(
        'https://github.com/owner/repo/tree/main/skills/one',
      );
      expect(source.owner, 'owner');
      expect(source.repo, 'repo');
      expect(source.ref, 'main');
      expect(source.subPath, 'skills/one');
    });

    test('accepts a plain GitHub URL and strips .git', () {
      final source = SkillSource.parse('https://github.com/owner/repo.git');
      expect(source.repo, 'repo');
      expect(source.ref, isNull);
    });

    test('accepts an existing local directory', () {
      final source = SkillSource.parse(temp.path);
      expect(source.isLocal, isTrue);
      expect(source.directory, temp.absolute.path);
    });

    test('applies ref overrides', () {
      final source = SkillSource.parse('owner/repo', ref: 'dev');
      expect(source.ref, 'dev');
    });

    test('rejects ssh and private git forms with guidance', () {
      expect(
        () => SkillSource.parse('git@github.com:owner/repo.git'),
        throwsA(
          isA<SkillSourceException>().having(
            (error) => error.message,
            'message',
            contains('local-path'),
          ),
        ),
      );
    });

    test('rejects non-GitHub hosts', () {
      expect(
        () => SkillSource.parse('https://gitlab.com/owner/repo'),
        throwsA(isA<SkillSourceException>()),
      );
    });

    test('rejects empty and malformed input', () {
      expect(
        () => SkillSource.parse('   '),
        throwsA(isA<SkillSourceException>()),
      );
      expect(
        () => SkillSource.parse('onlyone'),
        throwsA(isA<SkillSourceException>()),
      );
      expect(
        () => SkillSource.parse('a/b/c'),
        throwsA(isA<SkillSourceException>()),
      );
    });

    test('does not treat a missing path as a GitHub slug', () {
      final missing = p.join(temp.path, 'nope');
      expect(
        () => SkillSource.parse(missing),
        throwsA(isA<SkillSourceException>()),
      );
    });
  });
}
