import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'skill_archive.dart';
import 'skill_frontmatter.dart';
import 'skill_scanner.dart';
import 'skill_source.dart';

/// Raised when an install, removal, or update cannot be completed safely.
class SkillInstallException implements Exception {
  SkillInstallException(this.message);

  final String message;

  @override
  String toString() => message;
}

enum SkillScope { user, project }

enum SkillInstallStatus { installed, updated, unchanged, skippedLocalEdits }

/// One skill found inside a fetched source, ready to install.
class SkillInstallPlan {
  const SkillInstallPlan({
    required this.name,
    required this.files,
    this.description,
  });

  final String name;
  final String? description;
  final Map<String, SkillArchiveEntry> files;
}

/// Result of an install or update of a single skill.
class SkillInstallOutcome {
  const SkillInstallOutcome({
    required this.name,
    required this.scope,
    required this.path,
    required this.digest,
    required this.changed,
    this.status = SkillInstallStatus.installed,
  });

  final String name;
  final SkillScope scope;
  final String path;
  final String digest;
  final bool changed;
  final SkillInstallStatus status;
}

/// Provenance for one installed skill, used by `remove` and `update`.
class InstalledSkillRecord {
  const InstalledSkillRecord({
    required this.name,
    required this.source,
    required this.scope,
    required this.digest,
    required this.installedAt,
    this.kind = SkillSourceKind.github,
    this.ref,
    this.subPath,
    this.scan,
  });

  final String name;
  final String source;
  final SkillScope scope;
  final String digest;
  final DateTime installedAt;
  final SkillSourceKind kind;
  final String? ref;
  final String? subPath;
  final String? scan;

  Map<String, Object?> toJson() => {
    'source': source,
    'kind': kind.name,
    'scope': scope.name,
    'digest': digest,
    'installedAt': installedAt.toUtc().toIso8601String(),
    if (ref != null) 'ref': ref,
    if (subPath != null) 'subPath': subPath,
    if (scan != null) 'scan': scan,
  };

  factory InstalledSkillRecord.fromJson(
    String name,
    Map<String, Object?> json,
  ) {
    return InstalledSkillRecord(
      name: name,
      source: (json['source'] as String?) ?? '',
      kind: SkillSourceKind.values.firstWhere(
        (value) => value.name == json['kind'],
        orElse: () => SkillSourceKind.github,
      ),
      scope: SkillScope.values.firstWhere(
        (value) => value.name == json['scope'],
        orElse: () => SkillScope.user,
      ),
      digest: (json['digest'] as String?) ?? '',
      installedAt:
          DateTime.tryParse((json['installedAt'] as String?) ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      ref: json['ref'] as String?,
      subPath: json['subPath'] as String?,
      scan: json['scan'] as String?,
    );
  }
}

/// Installs third-party Agent Skills from a public GitHub repository or a local
/// directory into one skills root.
///
/// The skills root is the directory the daemon already scans (`<SANAD_HOME>/skills`
/// for user scope, `<workspace>/.sanad/skills` for project scope), so an installed
/// skill becomes available on the next turn without touching the daemon.
class SkillInstallService {
  SkillInstallService({
    required this.skillsRoot,
    required this.scope,
    http.Client? client,
    this.maxArchiveBytes = 5 * 1024 * 1024,
    this.maxExtractedBytes = 20 * 1024 * 1024,
  }) : _client = client ?? http.Client();

  static const String provenanceFileName = '.sanad-skills.json';
  static const int provenanceVersion = 1;

  /// Bundled skills are product-owned; user installs must never write this file.
  static const String bundledStateFileName = '.sanad-managed.json';

  static final RegExp _validName = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$');

  final Directory skillsRoot;
  final SkillScope scope;
  final int maxArchiveBytes;
  final int maxExtractedBytes;
  final http.Client _client;

  void close() => _client.close();

  File get _provenanceFile => File(p.join(skillsRoot.path, provenanceFileName));

  /// Every skill that was installed by this command, never bundled skills.
  Map<String, InstalledSkillRecord> readProvenance() {
    final file = _provenanceFile;
    if (!file.existsSync()) return const {};
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map<String, Object?>) return const {};
      final skills = decoded['skills'];
      if (skills is! Map<String, Object?>) return const {};
      return {
        for (final entry in skills.entries)
          if (entry.value is Map<String, Object?>)
            entry.key: InstalledSkillRecord.fromJson(
              entry.key,
              entry.value as Map<String, Object?>,
            ),
      };
    } on FormatException {
      throw SkillInstallException(
        'The provenance file is not valid JSON: ${file.path}',
      );
    }
  }

  Future<List<SkillInstallPlan>> plansFor(SkillSource source) async {
    final files = await _fetch(source);
    return _discover(files, source);
  }

  Future<SkillInstallOutcome> install(
    SkillSource source, {
    String? skill,
    bool force = false,
    bool allowFlagged = false,
  }) async {
    final plans = await plansFor(source);
    final plan = _select(plans, skill, source);
    final target = Directory(p.join(skillsRoot.path, plan.name));
    final existed = target.existsSync();
    if (existed && !force) {
      throw SkillInstallException(
        'Skill "${plan.name}" is already installed at ${target.path}. '
        'Re-run with --force to replace it.',
      );
    }

    final scanner = const SkillScanner();
    final report = scanner.scan(plan.files);
    if (!report.isClean && !allowFlagged) {
      throw SkillScanException(
        'Skill "${plan.name}" was flagged by security screening:\n'
        '${report.describe()}\n'
        'Re-run with --allow-flagged to install anyway.',
        report: report,
      );
    }

    await skillsRoot.create(recursive: true);
    final records = Map<String, InstalledSkillRecord>.from(readProvenance());
    final previous = records[plan.name];
    final digest = digestOf(plan.files);
    await _writeAtomically(target, plan.files);

    records[plan.name] = InstalledSkillRecord(
      name: plan.name,
      source: source.recordedSource,
      kind: source.kind,
      scope: scope,
      digest: digest,
      installedAt: DateTime.now().toUtc(),
      ref: source.ref,
      subPath: source.subPath,
      scan: report.verdict,
    );
    _writeProvenance(records);

    return SkillInstallOutcome(
      name: plan.name,
      scope: scope,
      path: target.path,
      digest: digest,
      changed: !existed || previous?.digest != digest,
      status: existed
          ? SkillInstallStatus.updated
          : SkillInstallStatus.installed,
    );
  }

  /// Removes a command-installed skill. Bundled and hand-copied skills are left
  /// alone unless [force] is set.
  bool remove(String name, {bool force = false}) {
    if (name == '.' || name == '..' || !_validName.hasMatch(name)) {
      throw SkillInstallException(
        'Invalid skill name "$name". Use letters, digits, dots, dashes, '
        'and underscores, starting with a letter or digit.',
      );
    }

    final targetPath = p.join(skillsRoot.path, name);
    final entityType = FileSystemEntity.typeSync(
      targetPath,
      followLinks: false,
    );
    if (entityType == FileSystemEntityType.notFound) {
      throw SkillInstallException(
        'Skill "$name" is not installed in ${skillsRoot.path}.',
      );
    }
    if (entityType == FileSystemEntityType.link) {
      throw SkillInstallException(
        'Skill "$name" is a symbolic link; refusing to remove.',
      );
    }

    final resolvedRoot = skillsRoot.existsSync()
        ? skillsRoot.resolveSymbolicLinksSync()
        : p.canonicalize(skillsRoot.path);
    final resolvedTarget = Directory(targetPath).resolveSymbolicLinksSync();

    if (!p.isWithin(resolvedRoot, resolvedTarget) ||
        resolvedTarget == resolvedRoot) {
      throw SkillInstallException(
        'Target for skill "$name" resolves outside the skills root: $resolvedTarget',
      );
    }

    final records = Map<String, InstalledSkillRecord>.from(readProvenance());
    if (!records.containsKey(name)) {
      final bundled = _isBundled(name);
      if (!force) {
        throw SkillInstallException(
          bundled
              ? 'Skill "$name" is provided by Sanad and is not managed by this command.'
              : 'Skill "$name" was not installed by "sanad skills add". '
                    'Re-run with --force to delete it anyway.',
        );
      }
    }

    Directory(resolvedTarget).deleteSync(recursive: true);
    if (records.remove(name) != null) {
      _writeProvenance(records);
    }
    return true;
  }

  Future<List<SkillInstallOutcome>> update({
    String? name,
    bool force = false,
  }) async {
    final records = readProvenance();
    final selected = name == null
        ? records.values.toList(growable: false)
        : [if (records[name] != null) records[name]!];
    if (selected.isEmpty) {
      throw SkillInstallException(
        name == null
            ? 'No skills were installed by "sanad skills add" in ${skillsRoot.path}.'
            : 'Skill "$name" was not installed by "sanad skills add".',
      );
    }

    final outcomes = <SkillInstallOutcome>[];
    final updatedRecords = Map<String, InstalledSkillRecord>.from(records);

    for (final record in selected) {
      final target = Directory(p.join(skillsRoot.path, record.name));
      final exists = target.existsSync();
      final onDiskDigest = exists
          ? digestOf(await _readDirectory(target))
          : null;
      final hasLocalEdits = exists && onDiskDigest != record.digest;

      if (hasLocalEdits && !force) {
        outcomes.add(
          SkillInstallOutcome(
            name: record.name,
            scope: scope,
            path: target.path,
            digest: record.digest,
            changed: false,
            status: SkillInstallStatus.skippedLocalEdits,
          ),
        );
        continue;
      }

      final source = SkillSource.parse(
        record.source,
        ref: record.ref,
        subPath: record.subPath,
      );
      final plans = await plansFor(source);
      final plan = _select(plans, record.name, source);
      final remoteDigest = digestOf(plan.files);
      final changed =
          remoteDigest != record.digest || !exists || (hasLocalEdits && force);

      if (changed) {
        await _writeAtomically(target, plan.files);
      }

      outcomes.add(
        SkillInstallOutcome(
          name: record.name,
          scope: scope,
          path: target.path,
          digest: remoteDigest,
          changed: changed,
          status: changed
              ? SkillInstallStatus.updated
              : SkillInstallStatus.unchanged,
        ),
      );

      updatedRecords[record.name] = InstalledSkillRecord(
        name: record.name,
        source: source.recordedSource,
        kind: source.kind,
        scope: scope,
        digest: remoteDigest,
        installedAt: changed ? DateTime.now().toUtc() : record.installedAt,
        ref: source.ref,
        subPath: source.subPath,
        scan: record.scan,
      );
    }

    _writeProvenance(updatedRecords);
    return outcomes;
  }

  bool _isBundled(String name) {
    final stateFile = File(p.join(skillsRoot.path, bundledStateFileName));
    if (!stateFile.existsSync()) return false;
    try {
      final decoded = jsonDecode(stateFile.readAsStringSync());
      if (decoded is Map<String, Object?>) {
        final entries = decoded['skills'];
        if (entries is Map<String, Object?>) return entries.containsKey(name);
      }
    } on FormatException {
      return false;
    }
    return false;
  }

  SkillInstallPlan _select(
    List<SkillInstallPlan> plans,
    String? requested,
    SkillSource source,
  ) {
    if (plans.isEmpty) {
      throw SkillInstallException(
        'No SKILL.md was found in ${source.original}. '
        'Expected a root SKILL.md or skills/<name>/SKILL.md.',
      );
    }
    if (requested == null) {
      if (plans.length == 1) return plans.first;
      final names = plans.map((plan) => plan.name).join(', ');
      throw SkillInstallException(
        '${source.original} contains ${plans.length} skills: $names. '
        'Choose one with --skill <name>.',
      );
    }
    final wanted = requested.toLowerCase();
    for (final plan in plans) {
      if (plan.name.toLowerCase() == wanted) return plan;
    }
    final names = plans.map((plan) => plan.name).join(', ');
    throw SkillInstallException(
      'Skill "$requested" was not found in ${source.original}. Available: $names.',
    );
  }

  Future<Map<String, SkillArchiveEntry>> _fetch(SkillSource source) async {
    if (source.isLocal) {
      return _readDirectory(Directory(source.directory!));
    }
    final ref = source.ref ?? 'HEAD';
    final uri = Uri.parse(
      'https://codeload.github.com/${source.owner}/${source.repo}/tar.gz/${Uri.encodeComponent(ref)}',
    );
    final http.Response response;
    try {
      response = await _client.get(uri);
    } on Object catch (error) {
      throw SkillInstallException('Could not reach GitHub: $error');
    }
    if (response.statusCode != 200) {
      throw SkillInstallException(
        response.statusCode == 404
            ? 'GitHub returned 404 for ${source.owner}/${source.repo} at "$ref". '
                  'Check the repository, or pass --ref <branch|tag|commit>.'
            : 'GitHub returned HTTP ${response.statusCode} for $uri.',
      );
    }
    if (response.bodyBytes.length > maxArchiveBytes) {
      throw SkillInstallException(
        'The archive is larger than ${maxArchiveBytes ~/ (1024 * 1024)} MB.',
      );
    }
    return SkillArchive.decode(
      response.bodyBytes,
      maxExtractedBytes: maxExtractedBytes,
    );
  }

  Future<Map<String, SkillArchiveEntry>> _readDirectory(
    Directory directory,
  ) async {
    if (!directory.existsSync()) {
      throw SkillInstallException('Directory not found: ${directory.path}');
    }
    final entries = <String, SkillArchiveEntry>{};
    final root = directory.absolute.path;
    await for (final entity in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) continue;
      final relative = p.relative(entity.path, from: root);
      final normalized = SkillArchive.safeRelativePath(relative);
      if (normalized == null) continue;
      if (normalized == '.git' || normalized.startsWith('.git/')) continue;
      if (p.basename(normalized) == provenanceFileName) continue;
      final stat = await entity.stat();
      entries[normalized] = SkillArchiveEntry(
        path: normalized,
        bytes: await entity.readAsBytes(),
        mode: stat.mode & 0x1FF,
      );
    }
    return entries;
  }

  List<SkillInstallPlan> _discover(
    Map<String, SkillArchiveEntry> files,
    SkillSource source,
  ) {
    final scoped = _applySubPath(_stripCommonRoot(files), source.subPath);
    if (scoped.isEmpty) return const [];

    final rootSkill = scoped['SKILL.md'];
    if (rootSkill != null) {
      final fallback = source.isLocal
          ? p.basename(source.directory!)
          : source.repo ?? 'skill';
      return [
        _plan(source, fallback, scoped, rootSkill, enforceNameMatch: false),
      ];
    }

    final plans = <SkillInstallPlan>[];
    for (final entry in scoped.entries) {
      final key = entry.key;
      if (!key.endsWith('/SKILL.md')) continue;
      final directory = key.substring(0, key.length - '/SKILL.md'.length);
      final segments = directory.split('/');
      final isSkillFolder =
          segments.length == 1 ||
          (segments.length == 2 && segments.first == 'skills');
      if (!isSkillFolder) continue;
      final folderName = segments.last;
      final prefix = '$directory/';
      final skillFiles = <String, SkillArchiveEntry>{
        for (final file in scoped.entries)
          if (file.key.startsWith(prefix))
            file.key.substring(prefix.length): SkillArchiveEntry(
              path: file.key.substring(prefix.length),
              bytes: file.value.bytes,
              mode: file.value.mode,
            ),
      };
      plans.add(_plan(source, folderName, skillFiles, entry.value));
    }
    return plans;
  }

  SkillInstallPlan _plan(
    SkillSource source,
    String fallbackName,
    Map<String, SkillArchiveEntry> files,
    SkillArchiveEntry skillFile, {
    bool enforceNameMatch = true,
  }) {
    final frontmatter = SkillFrontmatter.parse(
      utf8.decode(skillFile.bytes, allowMalformed: true),
    );
    final declared = frontmatter.name?.trim();
    final name = (declared != null && declared.isNotEmpty)
        ? declared
        : fallbackName;
    if (!_validName.hasMatch(name)) {
      throw SkillInstallException(
        'Invalid skill name "$name". Use letters, digits, dots, dashes, '
        'and underscores, starting with a letter or digit.',
      );
    }
    if (enforceNameMatch &&
        declared != null &&
        declared.isNotEmpty &&
        declared != fallbackName) {
      throw SkillInstallException(
        'SKILL.md declares name "$declared" but lives in "$fallbackName". '
        'The declared name must match its directory.',
      );
    }
    return SkillInstallPlan(
      name: name,
      description: frontmatter.description,
      files: files,
    );
  }

  Map<String, SkillArchiveEntry> _stripCommonRoot(
    Map<String, SkillArchiveEntry> files,
  ) {
    if (files.isEmpty) return files;
    final first = files.keys.first.split('/').first;
    final hasRoot =
        first.isNotEmpty &&
        files.keys.every((key) => key.startsWith('$first/'));
    if (!hasRoot) return files;
    final stripped = <String, SkillArchiveEntry>{};
    for (final entry in files.entries) {
      if (!entry.key.startsWith('$first/')) continue;
      final path = entry.key.substring(first.length + 1);
      stripped[path] = SkillArchiveEntry(
        path: path,
        bytes: entry.value.bytes,
        mode: entry.value.mode,
      );
    }
    return stripped;
  }

  Map<String, SkillArchiveEntry> _applySubPath(
    Map<String, SkillArchiveEntry> files,
    String? subPath,
  ) {
    if (subPath == null || subPath.isEmpty) return files;
    final prefix = '${subPath.replaceAll(RegExp(r'^/+|/+$'), '')}/';
    final scoped = <String, SkillArchiveEntry>{};
    for (final entry in files.entries) {
      if (!entry.key.startsWith(prefix)) continue;
      final path = entry.key.substring(prefix.length);
      scoped[path] = SkillArchiveEntry(
        path: path,
        bytes: entry.value.bytes,
        mode: entry.value.mode,
      );
    }
    return scoped;
  }

  Future<void> _writeAtomically(
    Directory target,
    Map<String, SkillArchiveEntry> files,
  ) async {
    final parent = target.parent;
    await parent.create(recursive: true);
    final temp = Directory(
      p.join(
        parent.path,
        '.sanad-install-${DateTime.now().microsecondsSinceEpoch}',
      ),
    );
    await temp.create(recursive: true);
    try {
      for (final entry in files.values) {
        final destination = File(p.join(temp.path, entry.path));
        await destination.parent.create(recursive: true);
        await destination.writeAsBytes(entry.bytes, flush: true);
        if (!Platform.isWindows && entry.isExecutable) {
          await Process.run('chmod', ['755', destination.path]);
        }
      }
      if (target.existsSync()) {
        await target.delete(recursive: true);
      }
      await temp.rename(target.path);
    } on Object {
      if (temp.existsSync()) {
        await temp.delete(recursive: true);
      }
      rethrow;
    }
  }

  void _writeProvenance(Map<String, InstalledSkillRecord> records) {
    skillsRoot.createSync(recursive: true);
    final sorted = records.keys.toList()..sort();
    final payload = <String, Object?>{
      'version': provenanceVersion,
      'skills': {for (final name in sorted) name: records[name]!.toJson()},
    };
    final file = _provenanceFile;
    final temp = File('${file.path}.tmp');
    temp.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(payload),
      flush: true,
    );
    temp.renameSync(file.path);
  }

  static String digestOf(Map<String, SkillArchiveEntry> files) {
    final keys = files.keys.toList()..sort();
    final buffer = StringBuffer();
    for (final key in keys) {
      final entry = files[key]!;
      buffer
        ..write(key)
        ..write('|')
        ..write(entry.mode.toRadixString(8))
        ..write('|')
        ..write(sha256.convert(entry.bytes))
        ..write('\n');
    }
    return sha256.convert(utf8.encode(buffer.toString())).toString();
  }
}
