import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../../tool/release_preparation.dart';

const _clientCliVersionPath =
    'client/lib/features/client_cli/domain/models/client_cli_version.dart';

const _releaseFiles = [
  'agent/CHANGELOG.md',
  'agent/pubspec.lock',
  'agent/pubspec.yaml',
  'client/lib/features/client_cli/domain/models/client_cli_version.dart',
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
  late String currentVersion;
  late String nextVersion;
  late int currentBuildNumber;
  late int nextBuildNumber;

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
    final contract = jsonDecode(
      File('${fixture.path}/release/release-contract.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    currentVersion = contract['version'] as String;
    currentBuildNumber = contract['build_number'] as int;
    final parts = currentVersion.split('.').map(int.parse).toList();
    nextVersion = '${parts[0]}.${parts[1]}.${parts[2] + 1}';
    nextBuildNumber = currentBuildNumber + 1;
  });

  tearDown(() async {
    if (fixture.existsSync()) {
      try {
        await fixture.delete(recursive: true);
      } catch (_) {}
    }
  });

  String readFixture(String path) =>
      File('${fixture.path}/$path').readAsStringSync();

  void writeFixture(String path, String content) {
    File('${fixture.path}/$path').writeAsStringSync(content);
  }

  test('updates every mechanical release identity surface', () async {
    final preparation = ReleasePreparation(fixture);

    await preparation.prepare(
      version: nextVersion,
      buildNumber: nextBuildNumber,
    );

    expect(
      readFixture('agent/pubspec.yaml'),
      contains('version: $nextVersion'),
    );
    expect(
      readFixture('client/pubspec.yaml'),
      contains('version: $nextVersion+$nextBuildNumber'),
    );
    expect(
      readFixture(_clientCliVersionPath),
      contains("const String sanadClientCliVersion = '$nextVersion';"),
    );
    expect(
      readFixture('client/release/windows/sanad_client_installer.iss'),
      contains('AppVersion=$nextVersion'),
    );
    expect(
      readFixture('client/windows/runner/Runner.rc'),
      contains(
        '#define VERSION_AS_NUMBER ${nextVersion.replaceAll('.', ',')},$nextBuildNumber',
      ),
    );
    expect(
      readFixture('release/release-contract.json'),
      contains('sanad-agent-$nextVersion'),
    );
    // The runtime archives are published by their own workflow, so a stale
    // literal there would only surface as a duplicate-filename error at
    // validation time. Preparation must rename them with everything else.
    expect(
      readFixture('release/release-contract.json'),
      contains('sanad-agent-runtime-$nextVersion-macos-arm64.tar.gz'),
    );
    expect(
      readFixture('release/release-notes.md'),
      startsWith('# Sanad $nextVersion'),
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

  test('check rejects a stale agent-runtime archive filename', () {
    final preparation = ReleasePreparation(fixture);
    final original = readFixture('release/release-contract.json');
    for (final replacement in [
      // A stale version and a non-canonical suffix are both wrong, and both
      // must name the runtime archive instead of a generic filename error.
      (
        from: 'sanad-agent-runtime-$currentVersion-macos-arm64.tar.gz',
        to: 'sanad-agent-runtime-0.0.1-macos-arm64.tar.gz',
      ),
      (
        from: 'sanad-agent-runtime-$currentVersion-macos-arm64.tar.gz',
        to: 'sanad-agent-runtime-$currentVersion-macos-arm64.zip',
      ),
    ]) {
      writeFixture(
        'release/release-contract.json',
        original.replaceFirst(replacement.from, replacement.to),
      );

      expect(
        preparation.check,
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('agent-runtime filename must track the release identity'),
          ),
        ),
        reason: replacement.to,
      );
    }
  });

  test('rejects non-increasing identity before changing files', () async {
    final before = {for (final path in _releaseFiles) path: readFixture(path)};
    final preparation = ReleasePreparation(fixture);

    expect(
      () => preparation.prepare(
        version: currentVersion,
        buildNumber: nextBuildNumber,
      ),
      throwsFormatException,
    );
    expect(
      () => preparation.prepare(
        version: nextVersion,
        buildNumber: currentBuildNumber,
      ),
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
        '#define VERSION_AS_STRING "$currentVersion"',
        '#define VERSION_AS_STRING "stale"',
      ),
    );
    final before = {for (final path in _releaseFiles) path: readFixture(path)};

    expect(
      () =>
          ReleasePreparation(fixture)
              .prepare(version: nextVersion, buildNumber: nextBuildNumber),
      throwsFormatException,
    );

    for (final entry in before.entries) {
      expect(readFixture(entry.key), entry.value, reason: entry.key);
    }
  });

  test('check rejects a contract without the Linux arm64 Agent target', () {
    final path = 'release/release-contract.json';
    final contract = jsonDecode(readFixture(path)) as Map<String, dynamic>;
    contract['artifacts'] = (contract['artifacts'] as List)
        .where(
          (raw) =>
              raw is! Map ||
              raw['component'] != 'agent' ||
              raw['platform'] != 'linux' ||
              raw['architecture'] != 'arm64',
        )
        .toList();
    writeFixture(
      path,
      '${const JsonEncoder.withIndent('  ').convert(contract)}\n',
    );

    expect(
      () => ReleasePreparation(fixture).check(),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('linux/arm64'),
        ),
      ),
    );
  });

  test('check rejects a stale sanad-client CLI version constant', () async {
    final preparation = ReleasePreparation(fixture);
    preparation.check();

    writeFixture(
      _clientCliVersionPath,
      readFixture(_clientCliVersionPath).replaceFirst(
        "const String sanadClientCliVersion = '$currentVersion';",
        "const String sanadClientCliVersion = '0.0.0';",
      ),
    );
    expect(preparation.check, throwsFormatException);
  });

  test('prepare rejects a stale sanad-client CLI version constant', () async {
    writeFixture(
      _clientCliVersionPath,
      readFixture(_clientCliVersionPath).replaceFirst(
        "const String sanadClientCliVersion = '$currentVersion';",
        "const String sanadClientCliVersion = '0.0.0';",
      ),
    );
    final before = {for (final path in _releaseFiles) path: readFixture(path)};

    expect(
      () =>
          ReleasePreparation(fixture)
              .prepare(version: nextVersion, buildNumber: nextBuildNumber),
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
      readFixture('client/release/windows/sanad_client_installer.iss')
          .replaceFirst('AppVersion=$currentVersion', 'AppVersion=0.0.0'),
    );
    expect(preparation.check, throwsFormatException);
  });
}
