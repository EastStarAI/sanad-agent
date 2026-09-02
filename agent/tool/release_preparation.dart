import 'dart:convert';
import 'dart:io';

class ReleasePreparation {
  ReleasePreparation(Directory repoRoot) : root = repoRoot.absolute;

  final Directory root;

  Future<void> prepare({
    required String version,
    required int buildNumber,
  }) async {
    final target = _SemanticVersion.parse(version);
    final contractFile = _file('release/release-contract.json');
    final contract = _readJsonObject(contractFile);
    final currentVersionText = contract['version']?.toString() ?? '';
    final current = _SemanticVersion.parse(currentVersionText);
    final currentBuild = contract['build_number'];
    if (target.compareTo(current) <= 0) {
      throw FormatException(
        'Target version $version must be greater than $currentVersionText.',
      );
    }
    if (currentBuild is! int || buildNumber <= currentBuild) {
      throw FormatException(
        'Target build $buildNumber must be greater than ${currentBuild ?? 'the current build'}.',
      );
    }

    final updates = <File, String>{};
    void update(String path, String Function(String) transform) {
      final file = _file(path);
      updates[file] = transform(file.readAsStringSync());
    }

    update(
      'agent/pubspec.yaml',
      (text) => _replaceExactly(
        text,
        'version: $currentVersionText',
        'version: $version',
      ),
    );
    update(
      'client/pubspec.yaml',
      (text) => _replaceExactly(
        text,
        'version: $currentVersionText+$currentBuild',
        'version: $version+$buildNumber',
      ),
    );
    update(
      'release/contract/pubspec.yaml',
      (text) => _replaceExactly(
        text,
        'version: $currentVersionText',
        'version: $version',
      ),
    );
    for (final path in ['agent/pubspec.lock', 'client/pubspec.lock']) {
      update(
        path,
        (text) => _replacePathPackageVersion(
          text,
          package: 'sanad_release_contract',
          from: currentVersionText,
          to: version,
        ),
      );
    }
    update(
      'client/release/windows/sanad_client_installer.iss',
      (text) => _replaceExactly(
        text,
        'AppVersion=$currentVersionText',
        'AppVersion=$version',
      ),
    );
    final currentParts = current.parts.join(',');
    final targetParts = target.parts.join(',');
    update(
      'client/windows/runner/Runner.rc',
      (text) => _replaceExactly(
        _replaceExactly(
          text,
          '#define VERSION_AS_NUMBER $currentParts,$currentBuild',
          '#define VERSION_AS_NUMBER $targetParts,$buildNumber',
        ),
        '#define VERSION_AS_STRING "$currentVersionText"',
        '#define VERSION_AS_STRING "$version"',
      ),
    );

    contract['version'] = version;
    contract['build_number'] = buildNumber;
    contract['tag'] = 'v$version';
    final artifacts = contract['artifacts'];
    if (artifacts is! List || artifacts.isEmpty) {
      throw const FormatException('Release contract artifacts are required.');
    }
    for (final rawArtifact in artifacts) {
      if (rawArtifact is! Map<String, dynamic>) {
        throw const FormatException(
          'Release contract artifact must be an object.',
        );
      }
      final filename = rawArtifact['filename']?.toString() ?? '';
      if (!filename.contains(currentVersionText)) {
        throw FormatException(
          'Artifact filename has stale identity: $filename',
        );
      }
      rawArtifact['filename'] = filename.replaceFirst(
        currentVersionText,
        version,
      );
    }
    updates[contractFile] =
        '${const JsonEncoder.withIndent('  ').convert(contract)}\n';

    update('docs/operations/release_and_signing.md', (text) {
      final oldSentence =
          'The current patch release uses marketing version `$currentVersionText` and build number `$currentBuild` for both Sanad Agent and Sanad Client. RC tags use `v$currentVersionText-rc.N`; Stable uses `v$currentVersionText`.';
      final newSentence =
          'The current patch release uses marketing version `$version` and build number `$buildNumber` for both Sanad Agent and Sanad Client. RC tags use `v$version-rc.N`; Stable uses `v$version`.';
      return _replaceExactly(text, oldSentence, newSentence);
    });
    update('release/release-notes.md', (text) {
      final replacedVersion = text.replaceAll(currentVersionText, version);
      return _replaceExactly(
        replacedVersion,
        'Build number `$currentBuild`',
        'Build number `$buildNumber`',
      );
    });
    update(
      'agent/CHANGELOG.md',
      (text) =>
          '## $version\n\n- TODO: summarize Agent changes included in this release.\n\n$text',
    );

    await _writeUpdates(updates);
  }

  void check() {
    final contract = _readJsonObject(_file('release/release-contract.json'));
    final version = contract['version']?.toString() ?? '';
    final parsed = _SemanticVersion.parse(version);
    final build = contract['build_number'];
    if (build is! int || build < 1 || contract['tag'] != 'v$version') {
      throw const FormatException(
        'Release contract version, build, and tag are inconsistent.',
      );
    }

    _requireContains('agent/pubspec.yaml', 'version: $version');
    _requireContains('client/pubspec.yaml', 'version: $version+$build');
    _requireContains('release/contract/pubspec.yaml', 'version: $version');
    for (final path in ['agent/pubspec.lock', 'client/pubspec.lock']) {
      _replacePathPackageVersion(
        _file(path).readAsStringSync(),
        package: 'sanad_release_contract',
        from: version,
        to: version,
      );
    }
    _requireContains(
      'client/release/windows/sanad_client_installer.iss',
      'AppVersion=$version',
    );
    _requireContains(
      'client/windows/runner/Runner.rc',
      '#define VERSION_AS_NUMBER ${parsed.parts.join(',')},$build',
    );
    _requireContains(
      'client/windows/runner/Runner.rc',
      '#define VERSION_AS_STRING "$version"',
    );
    _requireContains(
      'docs/operations/release_and_signing.md',
      'marketing version `$version` and build number `$build`',
    );

    final artifacts = contract['artifacts'];
    if (artifacts is! List || artifacts.isEmpty) {
      throw const FormatException('Release contract artifacts are required.');
    }
    for (final rawArtifact in artifacts) {
      if (rawArtifact is! Map ||
          !(rawArtifact['filename']?.toString().contains(version) ?? false)) {
        throw const FormatException(
          'Every artifact filename must contain the release version.',
        );
      }
    }

    final notes = _file('release/release-notes.md').readAsStringSync();
    if (!notes.startsWith('# Sanad $version\n') ||
        !notes.contains('Client `$version` artifacts') ||
        !notes.contains('Build number `$build`') ||
        notes.contains('TODO')) {
      throw const FormatException('Release notes are stale or unfinished.');
    }
    final changelog = _file('agent/CHANGELOG.md').readAsStringSync();
    final firstSection = changelog.split(RegExp(r'\n## ')).first;
    if (!firstSection.startsWith('## $version\n') ||
        firstSection.contains('TODO')) {
      throw const FormatException('Agent changelog is stale or unfinished.');
    }
  }

  File _file(String path) {
    final file = File('${root.path}/$path');
    if (!file.existsSync()) {
      throw FormatException('Required release file is missing: $path');
    }
    return file;
  }

  Map<String, dynamic> _readJsonObject(File file) {
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! Map<String, dynamic>) {
      throw FormatException('${file.path} must contain a JSON object.');
    }
    return decoded;
  }

  void _requireContains(String path, String expected) {
    if (!_file(path).readAsStringSync().contains(expected)) {
      throw FormatException('$path is missing release identity: $expected');
    }
  }
}

Future<void> _writeUpdates(Map<File, String> updates) async {
  final originals = <File, String>{
    for (final file in updates.keys) file: file.readAsStringSync(),
  };
  final changed = <File>[];
  try {
    for (final entry in updates.entries) {
      if (originals[entry.key] != entry.value) {
        changed.add(entry.key);
        await entry.key.writeAsString(entry.value);
      }
    }
  } catch (_) {
    for (final file in changed.reversed) {
      await file.writeAsString(originals[file]!);
    }
    rethrow;
  }
}

String _replaceExactly(String text, String from, String to) {
  final first = text.indexOf(from);
  if (first < 0 || text.indexOf(from, first + from.length) >= 0) {
    throw FormatException('Expected exactly one occurrence of: $from');
  }
  return text.replaceRange(first, first + from.length, to);
}

String _replacePathPackageVersion(
  String text, {
  required String package,
  required String from,
  required String to,
}) {
  final start = text.indexOf('  $package:\n');
  if (start < 0) throw FormatException('Missing path package $package.');
  var blockEnd = text.length;
  for (final match in RegExp(
    r'^  [A-Za-z0-9_]+:$',
    multiLine: true,
  ).allMatches(text)) {
    if (match.start > start) {
      blockEnd = match.start;
      break;
    }
  }
  final block = text.substring(start, blockEnd);
  final updated = _replaceExactly(
    block,
    '    version: "$from"',
    '    version: "$to"',
  );
  return text.replaceRange(start, blockEnd, updated);
}

class _SemanticVersion implements Comparable<_SemanticVersion> {
  const _SemanticVersion(this.parts);

  factory _SemanticVersion.parse(String value) {
    final match = RegExp(
      r'^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$',
    ).firstMatch(value);
    if (match == null) {
      throw FormatException('Invalid stable semantic version: $value');
    }
    return _SemanticVersion([
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
    ]);
  }

  final List<int> parts;

  @override
  int compareTo(_SemanticVersion other) {
    for (var index = 0; index < parts.length; index++) {
      final comparison = parts[index].compareTo(other.parts[index]);
      if (comparison != 0) return comparison;
    }
    return 0;
  }
}
