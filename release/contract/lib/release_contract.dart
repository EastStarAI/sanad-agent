import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

const sanadReleaseRepository = 'EastStarAI/sanad-agent';

enum ReleaseChannel { rc, stable }

class ReleaseVersion implements Comparable<ReleaseVersion> {
  const ReleaseVersion(
    this.major,
    this.minor,
    this.patch, [
    this.prerelease = const [],
  ]);

  factory ReleaseVersion.parse(String value) {
    final normalized = value.startsWith('v') ? value.substring(1) : value;
    final match = RegExp(
      r'^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$',
    ).firstMatch(normalized);
    if (match == null) {
      throw FormatException('Invalid semantic version: $value');
    }
    final prerelease = match.group(4)?.split('.') ?? const <String>[];
    if (prerelease.any(
      (identifier) =>
          RegExp(r'^\d+$').hasMatch(identifier) &&
          identifier.length > 1 &&
          identifier.startsWith('0'),
    )) {
      throw FormatException('Invalid semantic version: $value');
    }
    return ReleaseVersion(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
      List.unmodifiable(prerelease),
    );
  }

  final int major;
  final int minor;
  final int patch;
  final List<String> prerelease;

  bool get isPrerelease => prerelease.isNotEmpty;
  String get marketingVersion => '$major.$minor.$patch';

  @override
  int compareTo(ReleaseVersion other) {
    final majorResult = major.compareTo(other.major);
    if (majorResult != 0) return majorResult;
    final minorResult = minor.compareTo(other.minor);
    if (minorResult != 0) return minorResult;
    final patchResult = patch.compareTo(other.patch);
    if (patchResult != 0) return patchResult;
    if (!isPrerelease || !other.isPrerelease) {
      return isPrerelease == other.isPrerelease ? 0 : (isPrerelease ? -1 : 1);
    }
    for (
      var index = 0;
      index < prerelease.length && index < other.prerelease.length;
      index++
    ) {
      final left = prerelease[index];
      final right = other.prerelease[index];
      if (left == right) continue;
      final leftNumber = int.tryParse(left);
      final rightNumber = int.tryParse(right);
      if (leftNumber != null && rightNumber != null) {
        return leftNumber.compareTo(rightNumber);
      }
      if (leftNumber != null) return -1;
      if (rightNumber != null) return 1;
      return left.compareTo(right);
    }
    return prerelease.length.compareTo(other.prerelease.length);
  }

  @override
  String toString() =>
      [marketingVersion, if (isPrerelease) prerelease.join('.')].join('-');
}

String releaseArtifactFilename(
  String contractFilename, {
  required String marketingVersion,
  required ReleaseVersion releaseVersion,
}) {
  if (releaseVersion.marketingVersion != marketingVersion ||
      !contractFilename.contains(marketingVersion)) {
    throw const FormatException(
      'Artifact filename, marketing version, and release version must agree.',
    );
  }
  return contractFilename.replaceFirst(
    marketingVersion,
    releaseVersion.toString(),
  );
}

class ReleaseArtifact {
  const ReleaseArtifact({
    required this.component,
    required this.platform,
    required this.architecture,
    required this.format,
    required this.filename,
    required this.url,
    required this.sha256,
    required this.size,
    required this.public,
    required this.signatureType,
    this.updateSignature,
  });

  factory ReleaseArtifact.fromJson(Map<String, dynamic> json) {
    final size = json['size'];
    return ReleaseArtifact(
      component: _requiredString(json, 'component'),
      platform: _requiredString(json, 'platform'),
      architecture: _requiredString(json, 'architecture'),
      format: _requiredString(json, 'format'),
      filename: _requiredString(json, 'filename'),
      url: Uri.parse(_requiredString(json, 'url')),
      sha256: _requiredString(json, 'sha256').toLowerCase(),
      size: size is int ? size : int.parse(size.toString()),
      public: json['public'] == true,
      signatureType: _requiredString(json, 'signature_type'),
      updateSignature: json['update_signature']?.toString(),
    );
  }

  final String component;
  final String platform;
  final String architecture;
  final String format;
  final String filename;
  final Uri url;
  final String sha256;
  final int size;
  final bool public;
  final String signatureType;
  final String? updateSignature;

  Map<String, dynamic> toJson() => {
    'component': component,
    'platform': platform,
    'architecture': architecture,
    'format': format,
    'filename': filename,
    'url': url.toString(),
    'sha256': sha256,
    'size': size,
    'public': public,
    'signature_type': signatureType,
    if (updateSignature != null) 'update_signature': updateSignature,
  };
}

class ReleaseManifest {
  const ReleaseManifest({
    required this.schemaVersion,
    required this.version,
    required this.buildNumber,
    required this.tag,
    required this.commit,
    required this.channel,
    required this.repository,
    required this.artifacts,
  });

  factory ReleaseManifest.fromJsonString(String value) {
    final decoded = jsonDecode(value);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Release manifest must be a JSON object.');
    }
    return ReleaseManifest.fromJson(decoded);
  }

  factory ReleaseManifest.fromJson(Map<String, dynamic> json) {
    final artifacts = json['artifacts'];
    if (artifacts is! List) {
      throw const FormatException('Release manifest artifacts must be a list.');
    }
    final channelName = _requiredString(json, 'channel');
    final channel = switch (channelName) {
      'rc' => ReleaseChannel.rc,
      'stable' => ReleaseChannel.stable,
      _ => throw FormatException('Unsupported release channel: $channelName'),
    };
    final manifest = ReleaseManifest(
      schemaVersion: json['schema_version'] as int? ?? 0,
      version: ReleaseVersion.parse(_requiredString(json, 'version')),
      buildNumber: json['build_number'] as int? ?? 0,
      tag: _requiredString(json, 'tag'),
      commit: _requiredString(json, 'commit'),
      channel: channel,
      repository: _requiredString(json, 'repository'),
      artifacts: artifacts
          .map(
            (entry) => ReleaseArtifact.fromJson(
              Map<String, dynamic>.from(entry as Map),
            ),
          )
          .toList(growable: false),
    );
    manifest.validate();
    return manifest;
  }

  final int schemaVersion;
  final ReleaseVersion version;
  final int buildNumber;
  final String tag;
  final String commit;
  final ReleaseChannel channel;
  final String repository;
  final List<ReleaseArtifact> artifacts;

  void validate() {
    if (schemaVersion != 1) {
      throw FormatException('Unsupported manifest schema: $schemaVersion');
    }
    if (buildNumber < 1) {
      throw const FormatException('Build number must be positive.');
    }
    if (tag != 'v$version') {
      throw FormatException('Tag $tag does not match version $version.');
    }
    final isRcVersion =
        version.prerelease.length == 2 &&
        version.prerelease.first == 'rc' &&
        int.tryParse(version.prerelease.last) != null &&
        int.parse(version.prerelease.last) > 0;
    if ((channel == ReleaseChannel.stable && version.isPrerelease) ||
        (channel == ReleaseChannel.rc && !isRcVersion)) {
      throw FormatException(
        'Channel ${channel.name} does not match release version $version.',
      );
    }
    if (!RegExp(r'^[0-9a-f]{7,40}$').hasMatch(commit)) {
      throw const FormatException('Commit must be a Git hexadecimal id.');
    }
    if (repository != sanadReleaseRepository) {
      throw FormatException('Unsupported release repository: $repository');
    }
    final filenames = <String>{};
    for (final artifact in artifacts) {
      if (!filenames.add(artifact.filename)) {
        throw FormatException('Duplicate artifact: ${artifact.filename}');
      }
      if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(artifact.sha256)) {
        throw FormatException('Invalid SHA-256 for ${artifact.filename}.');
      }
      if (artifact.size < 1) {
        throw FormatException('Invalid size for ${artifact.filename}.');
      }
      if (!artifact.url.isScheme('https')) {
        throw FormatException('Artifact URL must use HTTPS.');
      }
      if (!artifact.filename.contains(version.marketingVersion)) {
        throw FormatException(
          'Artifact filename must contain marketing version: ${artifact.filename}',
        );
      }
      final expectedUrl = Uri.parse(
        'https://github.com/$repository/releases/download/$tag/${artifact.filename}',
      );
      if (artifact.url != expectedUrl) {
        throw FormatException(
          'Artifact URL is not canonical: ${artifact.filename}',
        );
      }
    }
  }

  ReleaseArtifact? findArtifact({
    required String component,
    required String platform,
    required String architecture,
    String? format,
    bool publicOnly = false,
  }) {
    for (final artifact in artifacts) {
      if (artifact.component == component &&
          artifact.platform == platform &&
          artifact.architecture == architecture &&
          (format == null || artifact.format == format) &&
          (!publicOnly || artifact.public)) {
        return artifact;
      }
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
    'schema_version': schemaVersion,
    'version': version.toString(),
    'build_number': buildNumber,
    'tag': tag,
    'commit': commit,
    'channel': channel.name,
    'repository': repository,
    'artifacts': artifacts.map((artifact) => artifact.toJson()).toList(),
  };
}

Future<String> sha256OfFile(File file) async {
  final digest = await sha256.bind(file.openRead()).first;
  return digest.toString();
}

Future<bool> verifyPlatformCodeSignature(
  File file, {
  required String operatingSystem,
}) async {
  if (operatingSystem == 'macos') {
    final verification = await Process.run('/usr/bin/codesign', [
      '--verify',
      '--strict',
      '--verbose=2',
      file.path,
    ]);
    if (verification.exitCode != 0) return false;
    final details = await Process.run('/usr/bin/codesign', [
      '-dv',
      '--verbose=4',
      file.path,
    ]);
    final output = '${details.stdout}\n${details.stderr}';
    if (details.exitCode != 0 ||
        !output.contains('Developer ID Application: NanoSoft LY LLC')) {
      return false;
    }
    final notarization = await Process.run('/usr/sbin/spctl', [
      '--assess',
      '--type',
      'execute',
      '--verbose=2',
      file.path,
    ]);
    return notarization.exitCode == 0;
  }
  if (operatingSystem == 'windows') {
    final escaped = file.path.replaceAll("'", "''");
    final verification = await Process.run('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      "(Get-AuthenticodeSignature -LiteralPath '$escaped').Status -eq 'Valid'",
    ]);
    return verification.exitCode == 0 &&
        verification.stdout.toString().trim().toLowerCase() == 'true';
  }
  return true;
}

String generateAppcastXml(ReleaseManifest manifest, DateTime publishedAt) {
  final macos = manifest.findArtifact(
    component: 'client',
    platform: 'macos',
    architecture: 'universal',
    publicOnly: true,
  );
  final windows = manifest.findArtifact(
    component: 'client',
    platform: 'windows',
    architecture: 'x64',
    publicOnly: true,
  );
  if (macos?.updateSignature == null || windows?.updateSignature == null) {
    throw const FormatException(
      'macOS and Windows update signatures are required for Appcast.',
    );
  }
  final pubDate = HttpDate.format(publishedAt.toUtc());
  final notes =
      'https://github.com/${manifest.repository}/releases/tag/${manifest.tag}';
  final channelTitle = manifest.channel == ReleaseChannel.rc ? 'RC' : 'stable';
  return '''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Sanad $channelTitle updates</title>
    <link>https://github.com/${manifest.repository}</link>
    <description>Signed Sanad client updates.</description>
    <language>en</language>
    <item>
      <title>Sanad ${manifest.version} for macOS</title>
      <pubDate>$pubDate</pubDate>
      <sparkle:releaseNotesLink>$notes</sparkle:releaseNotesLink>
      <enclosure url="${_xmlAttribute(macos!.url.toString())}" length="${macos.size}" type="application/octet-stream" sparkle:os="macos" sparkle:version="${manifest.buildNumber}" sparkle:shortVersionString="${manifest.version}" sparkle:edSignature="${_xmlAttribute(macos.updateSignature!)}" />
    </item>
    <item>
      <title>Sanad ${manifest.version} for Windows</title>
      <pubDate>$pubDate</pubDate>
      <sparkle:releaseNotesLink>$notes</sparkle:releaseNotesLink>
      <enclosure url="${_xmlAttribute(windows!.url.toString())}" length="${windows.size}" type="application/octet-stream" sparkle:os="windows" sparkle:version="${manifest.version}+${manifest.buildNumber}" sparkle:shortVersionString="${manifest.version}" sparkle:dsaSignature="${_xmlAttribute(windows.updateSignature!)}" />
    </item>
  </channel>
</rss>
''';
}

String _requiredString(Map<String, dynamic> json, String key) {
  final value = json[key]?.toString().trim() ?? '';
  if (value.isEmpty) {
    throw FormatException('Missing required field: $key');
  }
  return value;
}

String _xmlAttribute(String value) =>
    const HtmlEscape(HtmlEscapeMode.attribute).convert(value);
