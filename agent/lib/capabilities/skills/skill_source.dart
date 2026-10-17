import 'dart:io';

/// Raised when a skill source string cannot be understood or is unsupported.
class SkillSourceException implements Exception {
  SkillSourceException(this.message);

  final String message;

  @override
  String toString() => message;
}

enum SkillSourceKind { github, local }

/// A location skills can be fetched from.
///
/// Supported forms: `owner/repo`, `owner/repo@ref`, a GitHub URL (optionally
/// with `/tree/<ref>/<sub-path>`), and an existing local directory.
class SkillSource {
  const SkillSource._({
    required this.kind,
    required this.original,
    this.owner,
    this.repo,
    this.ref,
    this.subPath,
    this.directory,
  });

  factory SkillSource.github({
    required String original,
    required String owner,
    required String repo,
    String? ref,
    String? subPath,
  }) => SkillSource._(
    kind: SkillSourceKind.github,
    original: original,
    owner: owner,
    repo: repo,
    ref: ref,
    subPath: subPath,
  );

  factory SkillSource.local({
    required String original,
    required String directory,
  }) => SkillSource._(
    kind: SkillSourceKind.local,
    original: original,
    directory: directory,
  );

  final SkillSourceKind kind;
  final String original;
  final String? owner;
  final String? repo;
  final String? ref;
  final String? subPath;
  final String? directory;

  bool get isLocal => kind == SkillSourceKind.local;

  /// Re-parseable form stored in the provenance file.
  String get recordedSource => isLocal
      ? directory!
      : '${owner!}/${repo!}${subPath == null ? '' : '/$subPath'}';

  static final RegExp _segmentPattern = RegExp(r'^[A-Za-z0-9._-]+$');

  SkillSource copyWith({String? ref, String? subPath}) {
    if (isLocal) return this;
    return SkillSource.github(
      original: original,
      owner: owner!,
      repo: repo!,
      ref: ref ?? this.ref,
      subPath: subPath ?? this.subPath,
    );
  }

  static SkillSource parse(String raw, {String? ref, String? subPath}) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      throw SkillSourceException(
        'A source is required: owner/repo, a GitHub URL, or a local directory.',
      );
    }

    if (trimmed.startsWith('git@') || trimmed.startsWith('ssh://')) {
      throw SkillSourceException(
        'Only public GitHub sources and local directories are supported. '
        'Clone "$trimmed" yourself, then run: sanad skills add <local-path>',
      );
    }

    if (!trimmed.contains('://')) {
      final directory = Directory(trimmed);
      if (directory.existsSync()) {
        return SkillSource.local(
          original: trimmed,
          directory: directory.absolute.path,
        );
      }
    }

    final SkillSource source;
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      source = _fromUri(trimmed);
    } else {
      source = _fromSlug(trimmed);
    }

    return source.copyWith(
      ref: ref ?? source.ref,
      subPath: subPath ?? source.subPath,
    );
  }

  static SkillSource _fromSlug(String slug) {
    var value = slug;
    String? ref;
    final atIndex = value.lastIndexOf('@');
    if (atIndex > 0) {
      ref = value.substring(atIndex + 1);
      value = value.substring(0, atIndex);
    }
    final segments = value.split('/').where((s) => s.isNotEmpty).toList();
    if (segments.length != 2) {
      throw SkillSourceException(
        'Expected owner/repo, a GitHub URL, or a local directory — got "$slug".',
      );
    }
    return SkillSource.github(
      original: slug,
      owner: _validateSegment(segments[0], slug),
      repo: _trimGitSuffix(_validateSegment(segments[1], slug)),
      ref: ref,
    );
  }

  static SkillSource _fromUri(String url) {
    final uri = Uri.parse(url);
    final host = uri.host.toLowerCase();
    if (host != 'github.com' && host != 'www.github.com') {
      throw SkillSourceException(
        'Only github.com URLs are supported — got "${uri.host}". '
        'Clone the repository yourself, then run: sanad skills add <local-path>',
      );
    }
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.length < 2) {
      throw SkillSourceException('Expected a repository URL: "$url".');
    }
    String? ref;
    String? subPath;
    if (segments.length >= 4 && segments[2] == 'tree') {
      ref = segments[3];
      if (segments.length > 4) {
        subPath = segments.sublist(4).join('/');
      }
    }
    return SkillSource.github(
      original: url,
      owner: _validateSegment(segments[0], url),
      repo: _trimGitSuffix(_validateSegment(segments[1], url)),
      ref: ref,
      subPath: subPath,
    );
  }

  static String _trimGitSuffix(String value) =>
      value.endsWith('.git') ? value.substring(0, value.length - 4) : value;

  static String _validateSegment(String value, String raw) {
    if (!_segmentPattern.hasMatch(value) || value == '.' || value == '..') {
      throw SkillSourceException('"$raw" is not a valid GitHub owner/repo.');
    }
    return value;
  }

  @override
  String toString() => isLocal ? 'local:$directory' : '$owner/$repo';
}
