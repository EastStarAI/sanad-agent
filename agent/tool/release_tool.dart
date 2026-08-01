import 'dart:convert';
import 'dart:io';

import 'package:sanad_release_contract/release_contract.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.isEmpty) _usage();
  final command = arguments.first;
  final options = _options(arguments.skip(1));
  final repoRoot = Directory(options['repo-root'] ?? '..').absolute;
  try {
    switch (command) {
      case 'validate-contract':
        await _validateContract(
          repoRoot,
          tag: options['tag'],
          channel: options['channel'],
        );
        return;
      case 'generate-manifest':
        await _generateManifest(
          repoRoot,
          artifactsDirectory: _required(options, 'artifacts'),
          commit: _required(options, 'commit'),
          tag: options['tag'],
          channel: options['channel'],
          output: _required(options, 'output'),
        );
        return;
      case 'verify-manifest':
        await _verifyManifest(
          File(_required(options, 'manifest')),
          artifactsDirectory: options['artifacts'],
        );
        return;
      case 'generate-appcast':
        await _generateAppcast(
          File(_required(options, 'manifest')),
          File(_required(options, 'output')),
          publishedAt: options['published-at'],
        );
        return;
      default:
        _usage('Unknown command: $command');
    }
  } on FormatException catch (error) {
    stderr.writeln('Release contract error: ${error.message}');
    exitCode = 2;
  }
}

Future<_ReleaseIdentity> _validateContract(
  Directory root, {
  String? tag,
  String? channel,
}) async {
  final contract = await _readContract(root);
  final agentVersion = _pubspecVersion(
    File('${root.path}/agent/pubspec.yaml'),
  ).split('+').first;
  final clientParts = _pubspecVersion(
    File('${root.path}/client/pubspec.yaml'),
  ).split('+');
  final clientVersion = clientParts.first;
  final clientBuild = int.tryParse(
    clientParts.length > 1 ? clientParts[1] : '',
  );
  final marketingVersion = contract['version']?.toString();
  if (marketingVersion == null || marketingVersion.isEmpty) {
    throw const FormatException('Contract version is required.');
  }
  ReleaseVersion.parse(marketingVersion);
  final build = contract['build_number'] as int?;
  final stableTag = contract['tag']?.toString();
  if (contract['repository'] != sanadReleaseRepository) {
    throw FormatException(
      'Contract repository must be $sanadReleaseRepository.',
    );
  }
  if (agentVersion != marketingVersion || clientVersion != marketingVersion) {
    throw FormatException(
      'Agent ($agentVersion), client ($clientVersion), and contract ($marketingVersion) versions must match.',
    );
  }
  if (build == null || build < 1 || clientBuild != build) {
    throw FormatException(
      'Client build ($clientBuild) must match positive contract build ($build).',
    );
  }
  if (stableTag != 'v$marketingVersion') {
    throw FormatException('Contract stable tag must be v$marketingVersion.');
  }

  final selectedTag = tag ?? stableTag!;
  final releaseVersion = ReleaseVersion.parse(selectedTag);
  if (releaseVersion.marketingVersion != marketingVersion) {
    throw FormatException(
      'Workflow tag $selectedTag does not match marketing version $marketingVersion.',
    );
  }
  final derivedChannel = releaseVersion.isPrerelease ? 'rc' : 'stable';
  final validRc =
      releaseVersion.prerelease.length == 2 &&
      releaseVersion.prerelease.first == 'rc' &&
      int.tryParse(releaseVersion.prerelease.last) != null &&
      int.parse(releaseVersion.prerelease.last) > 0;
  if ((derivedChannel == 'stable' && selectedTag != stableTag) ||
      (derivedChannel == 'rc' && !validRc)) {
    throw FormatException('Unsupported release tag: $selectedTag.');
  }
  if (channel != null && channel != derivedChannel) {
    throw FormatException(
      'Workflow channel $channel does not match $selectedTag ($derivedChannel).',
    );
  }

  final channels = contract['channels'];
  if (channels is! Map ||
      channels['stable_manifest'] != 'release-manifest.json' ||
      channels['stable_appcast'] != 'appcast.xml' ||
      channels['rc_manifest'] != 'release-manifest-rc.json' ||
      channels['rc_appcast'] != 'appcast-rc.xml') {
    throw const FormatException(
      'Contract must define distinct canonical stable and RC feed files.',
    );
  }
  final artifacts = contract['artifacts'];
  if (artifacts is! List || artifacts.isEmpty) {
    throw const FormatException('Contract must define artifacts.');
  }
  final names = <String>{};
  for (final raw in artifacts) {
    final artifact = Map<String, dynamic>.from(raw as Map);
    final filename = artifact['filename']?.toString() ?? '';
    if (!filename.contains(marketingVersion) || !names.add(filename)) {
      throw FormatException('Invalid or duplicate filename: $filename');
    }
  }
  stdout.writeln(
    'Release contract valid: $selectedTag+$build ($derivedChannel)',
  );
  return _ReleaseIdentity(
    version: releaseVersion.toString(),
    tag: selectedTag,
    channel: derivedChannel,
  );
}

Future<void> _generateManifest(
  Directory root, {
  required String artifactsDirectory,
  required String commit,
  required String output,
  String? tag,
  String? channel,
}) async {
  final identity = await _validateContract(root, tag: tag, channel: channel);
  if (!RegExp(r'^[0-9a-f]{7,40}$').hasMatch(commit)) {
    throw const FormatException('Commit must be a hexadecimal Git id.');
  }
  final contract = await _readContract(root);
  final artifactsRoot = Directory(artifactsDirectory).absolute;
  final repository = contract['repository']!.toString();
  final releaseTag = identity.tag;
  final marketingVersion = contract['version']!.toString();
  final generated = <Map<String, dynamic>>[];
  for (final raw in contract['artifacts'] as List) {
    final item = Map<String, dynamic>.from(raw as Map);
    final filename = releaseArtifactFilename(
      item['filename']!.toString(),
      marketingVersion: marketingVersion,
      releaseVersion: ReleaseVersion.parse(identity.version),
    );
    final file = File('${artifactsRoot.path}/$filename');
    if (!file.existsSync()) {
      throw FormatException('Missing required artifact: $filename');
    }
    if (item['public'] != true) {
      continue;
    }
    final signatureFile = File('${file.path}.update-signature');
    generated.add({
      ...item,
      'filename': filename,
      'url':
          'https://github.com/$repository/releases/download/$releaseTag/$filename',
      'sha256': await sha256OfFile(file),
      'size': await file.length(),
      if (signatureFile.existsSync())
        'update_signature': (await signatureFile.readAsString()).trim(),
    });
  }
  final manifest = ReleaseManifest.fromJson({
    'schema_version': contract['schema_version'],
    'version': identity.version,
    'build_number': contract['build_number'],
    'tag': releaseTag,
    'commit': commit,
    'channel': identity.channel,
    'repository': repository,
    'artifacts': generated,
  });
  final outputFile = File(output);
  await outputFile.parent.create(recursive: true);
  await outputFile.writeAsString(
    '${const JsonEncoder.withIndent('  ').convert(manifest.toJson())}\n',
  );
  await _writeChecksums(outputFile.parent, manifest);
  stdout.writeln('Generated ${outputFile.path}');
}

Future<void> _verifyManifest(
  File manifestFile, {
  String? artifactsDirectory,
}) async {
  final manifest = ReleaseManifest.fromJsonString(
    await manifestFile.readAsString(),
  );
  if (artifactsDirectory != null) {
    final directory = Directory(artifactsDirectory).absolute;
    for (final artifact in manifest.artifacts) {
      final file = File('${directory.path}/${artifact.filename}');
      if (!file.existsSync() ||
          await file.length() != artifact.size ||
          await sha256OfFile(file) != artifact.sha256) {
        throw FormatException(
          'Artifact verification failed: ${artifact.filename}',
        );
      }
    }
  }
  stdout.writeln('Release manifest valid: ${manifest.tag}');
}

Future<void> _generateAppcast(
  File manifestFile,
  File outputFile, {
  String? publishedAt,
}) async {
  final manifest = ReleaseManifest.fromJsonString(
    await manifestFile.readAsString(),
  );
  final date = publishedAt == null
      ? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true)
      : DateTime.parse(publishedAt).toUtc();
  await outputFile.parent.create(recursive: true);
  await outputFile.writeAsString(generateAppcastXml(manifest, date));
  stdout.writeln('Generated ${outputFile.path}');
}

Future<Map<String, dynamic>> _readContract(Directory root) async {
  final file = File('${root.path}/release/release-contract.json');
  final decoded = jsonDecode(await file.readAsString());
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('Release contract must be a JSON object.');
  }
  return decoded;
}

String _pubspecVersion(File file) {
  final match = RegExp(
    r'^version:\s*(\S+)\s*$',
    multiLine: true,
  ).firstMatch(file.readAsStringSync());
  if (match == null) throw FormatException('Missing version in ${file.path}');
  return match.group(1)!;
}

Future<void> _writeChecksums(
  Directory outputDirectory,
  ReleaseManifest manifest,
) async {
  final buffer = StringBuffer();
  for (final artifact in [
    ...manifest.artifacts.where((artifact) => artifact.public),
  ]..sort((left, right) => left.filename.compareTo(right.filename))) {
    buffer.writeln('${artifact.sha256}  ${artifact.filename}');
  }
  await File(
    '${outputDirectory.path}/SHA256SUMS',
  ).writeAsString(buffer.toString());
}

class _ReleaseIdentity {
  const _ReleaseIdentity({
    required this.version,
    required this.tag,
    required this.channel,
  });

  final String version;
  final String tag;
  final String channel;
}

Map<String, String> _options(Iterable<String> arguments) {
  final values = <String, String>{};
  final list = arguments.toList();
  for (var index = 0; index < list.length; index++) {
    final key = list[index];
    if (!key.startsWith('--') || index + 1 >= list.length) {
      _usage('Expected --name value options.');
    }
    values[key.substring(2)] = list[++index];
  }
  return values;
}

String _required(Map<String, String> values, String key) {
  final value = values[key];
  if (value == null || value.isEmpty) _usage('Missing --$key.');
  return value;
}

Never _usage([String? error]) {
  if (error != null) stderr.writeln(error);
  stderr.writeln(
    'Usage: release_tool.dart <validate-contract|generate-manifest|verify-manifest|generate-appcast> [options]',
  );
  exit(64);
}
