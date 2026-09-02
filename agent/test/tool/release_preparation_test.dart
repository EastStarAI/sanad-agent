import 'dart:io';

import 'package:test/test.dart';

import '../../tool/release_preparation.dart';

const _releaseFiles = [
  'agent/CHANGELOG.md',
  'agent/pubspec.lock',
  'agent/pubspec.yaml',
  'client/pubspec.lock',
  'client/pubspec.yaml',
  'client/release/windows/sanad_client_installer.iss',
  'client/windows/runner/Runner.rc',
  'docs/operations/release_and_signing.md',
  'release/contract/pubspec.yaml',
  'release/release-contract.json',
  'release/release-notes.md',
];

void main() {
  late Directory fixture;

  setUp(() async {
    fixture = await Directory.systemTemp.createTemp(
      'sanad-release-preparation-',
    );
    final sourceRoot = Directory.current.parent;
    for (final path in _releaseFiles) {
      final source = File('${sourceRoot.path}/$path');
      final target = File('${fixture.path}/$path');
      await target.parent.create(recursive: true);
      await source.copy(target.path);
    }
  });

  tearDown(() async {
    if (fixture.existsSync()) await fixture.delete(recursive: true);
  });

  String readFixture(String path) =>
      File('${fixture.path}/$path').readAsStringSync();

  void writeFixture(String path, String content) {
    File('${fixture.path}/$path').writeAsStringSync(content);
  }

  test('updates every mechanical release identity surface', () async {
    final preparation = ReleasePreparation(fixture);

    await preparation.prepare(version: '1.0.7', buildNumber: 8);

    expect(readFixture('agent/pubspec.yaml'), contains('version: 1.0.7'));
    expect(readFixture('client/pubspec.yaml'), contains('version: 1.0.7+8'));
    expect(
      readFixture('client/release/windows/sanad_client_installer.iss'),
      contains('AppVersion=1.0.7'),
    );
    expect(
      readFixture('client/windows/runner/Runner.rc'),
      contains('#define VERSION_AS_NUMBER 1,0,7,8'),
    );
    expect(
      readFixture('release/release-contract.json'),
      contains('sanad-agent-1.0.7'),
    );
    expect(
      readFixture('release/release-notes.md'),
      startsWith('# Sanad 1.0.7'),
    );
    expect(readFixture('agent/CHANGELOG.md'), contains('TODO'));
    expect(preparation.check, throwsFormatException);

    writeFixture(
      'agent/CHANGELOG.md',
      readFixture('agent/CHANGELOG.md').replaceFirst(
        '- TODO: summarize Agent changes included in this release.',
        '- Automated release preparation coverage.',
      ),
    );
    preparation.check();
  });

  test('rejects non-increasing identity before changing files', () async {
    final before = {for (final path in _releaseFiles) path: readFixture(path)};
    final preparation = ReleasePreparation(fixture);

    expect(
      () => preparation.prepare(version: '1.0.6', buildNumber: 8),
      throwsFormatException,
    );
    expect(
      () => preparation.prepare(version: '1.0.7', buildNumber: 7),
      throwsFormatException,
    );

    for (final entry in before.entries) {
      expect(readFixture(entry.key), entry.value, reason: entry.key);
    }
  });

  test('validates every transformation before writing any file', () async {
    writeFixture(
      'client/windows/runner/Runner.rc',
      readFixture('client/windows/runner/Runner.rc').replaceFirst(
        '#define VERSION_AS_STRING "1.0.6"',
        '#define VERSION_AS_STRING "stale"',
      ),
    );
    final before = {for (final path in _releaseFiles) path: readFixture(path)};

    expect(
      () =>
          ReleasePreparation(fixture).prepare(version: '1.0.7', buildNumber: 8),
      throwsFormatException,
    );

    for (final entry in before.entries) {
      expect(readFixture(entry.key), entry.value, reason: entry.key);
    }
  });

  test('check rejects stale native metadata and unfinished prose', () async {
    final preparation = ReleasePreparation(fixture);
    preparation.check();

    writeFixture(
      'client/release/windows/sanad_client_installer.iss',
      readFixture(
        'client/release/windows/sanad_client_installer.iss',
      ).replaceFirst('AppVersion=1.0.6', 'AppVersion=0.0.0'),
    );
    expect(preparation.check, throwsFormatException);
  });
}
