import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/constants.dart';
import 'skill_definition.dart';
import 'skill_frontmatter.dart';
import 'skill_inventory.dart';

class SkillRegistry {
  static const int maxSkillBytes = 256 * 1024;

  final Map<String, String>? _environment;

  const SkillRegistry({Map<String, String>? environment})
    : _environment = environment;

  Future<SkillDefinition?> resolve({
    required String skill,
    String? workspacePath,
  }) async {
    final requested = _normalizeRequestedSkill(skill);
    if (requested.isEmpty) {
      throw const FormatException('skill is required.');
    }

    final matches = await _discoverMatches(
      requested: requested,
      workspacePath: workspacePath,
    );
    if (matches.isEmpty) {
      return null;
    }

    final selected = matches.first;
    return selected.toDefinition(
      requestedSkill: requested,
      shadowedMatches: matches.skip(1).toList(growable: false),
    );
  }

  Future<SkillInventoryReport> list({
    String? workspacePath,
    bool includeShadowed = true,
  }) async {
    final roots = _lookupRoots(workspacePath: workspacePath);
    final entries = <SkillInventoryEntry>[];
    final activeByName = <String, SkillInventoryEntry>{};

    for (final root in roots) {
      final rootEntries = await _loadRootInventory(root);
      rootEntries.sort(
        (left, right) => (left.name ?? '').toLowerCase().compareTo(
          (right.name ?? '').toLowerCase(),
        ),
      );

      for (final entry in rootEntries) {
        final entryName =
            entry.name ?? p.basenameWithoutExtension(entry.sourcePath);
        final key = entryName.toLowerCase();
        final activeEntry = activeByName[key];
        if (activeEntry == null) {
          final active = SkillInventoryEntry(
            name: entryName,
            description: entry.description,
            path: entry.sourcePath,
            origin: entry.origin,
            metadata: entry.metadata.toMetadata(),
            active: true,
          );
          activeByName[key] = active;
          entries.add(active);
          continue;
        }

        entries.add(
          SkillInventoryEntry(
            name: entryName,
            description: entry.description,
            path: entry.sourcePath,
            origin: entry.origin,
            metadata: entry.metadata.toMetadata(),
            active: false,
            shadowedBy: SkillShadowedBy(
              name: activeEntry.name,
              path: activeEntry.path,
              origin: activeEntry.origin,
            ),
          ),
        );
      }
    }

    final filtered = includeShadowed
        ? entries
        : entries.where((entry) => entry.active).toList(growable: false);

    return SkillInventoryReport(
      skills: filtered,
      includeShadowed: includeShadowed,
      workspacePath: _normalizeExistingDirectory(workspacePath),
    );
  }

  Future<List<SkillMatch>> _discoverMatches({
    required String requested,
    required String? workspacePath,
  }) async {
    final matches = <SkillMatch>[];
    for (final root in _lookupRoots(workspacePath: workspacePath)) {
      final match = await _resolveInRoot(root, requested);
      if (match != null) {
        matches.add(match);
      }
    }
    return matches;
  }

  List<_SkillLookupRoot> _lookupRoots({required String? workspacePath}) {
    final roots = <_SkillLookupRoot>[];
    var precedence = 0;

    final normalizedWorkspace = _normalizeExistingDirectory(workspacePath);
    if (normalizedWorkspace != null) {
      for (final ancestor in _ancestors(normalizedWorkspace)) {
        precedence = _appendRootsForBase(
          roots: roots,
          basePath: ancestor,
          scope: SkillSourceScope.workspace,
          precedenceStart: precedence,
        );
      }
    }

    final environment = _environment ?? Platform.environment;
    final sanadHome = environment['SANAD_HOME']?.trim();
    if (sanadHome != null && sanadHome.isNotEmpty) {
      _pushRoot(
        roots,
        _SkillLookupRoot(
          path: p.join(sanadHome, 'skills'),
          scope: SkillSourceScope.user,
          kind: SkillRootKind.sanadSkills,
          precedence: precedence++,
        ),
      );
    } else if (_environment == null) {
      _pushRoot(
        roots,
        _SkillLookupRoot(
          path: p.join(getSanadHome(), 'skills'),
          scope: SkillSourceScope.user,
          kind: SkillRootKind.sanadSkills,
          precedence: precedence++,
        ),
      );
    }

    final home = environment['HOME'] ?? environment['USERPROFILE'];
    if (home != null && home.trim().isNotEmpty) {
      precedence = _appendRootsForBase(
        roots: roots,
        basePath: home,
        scope: SkillSourceScope.user,
        precedenceStart: precedence,
        includeSanad: sanadHome == null || sanadHome.isEmpty,
      );
    }

    return roots;
  }

  int _appendRootsForBase({
    required List<_SkillLookupRoot> roots,
    required String basePath,
    required SkillSourceScope scope,
    required int precedenceStart,
    bool includeSanad = true,
  }) {
    var precedence = precedenceStart;

    void add(String relativePath, SkillRootKind kind) {
      final root = _SkillLookupRoot(
        path: p.join(basePath, relativePath),
        scope: scope,
        kind: kind,
        precedence: precedence,
      );
      precedence += 1;
      _pushRoot(roots, root);
    }

    if (includeSanad) {
      add('.sanad/skills', SkillRootKind.sanadSkills);
      add('.sanad/commands', SkillRootKind.sanadLegacyCommands);
    }
    add('.agent/skills', SkillRootKind.agentSkills);
    add('.agents/skills', SkillRootKind.agentsSkills);
    add('.codex/skills', SkillRootKind.codexSkills);
    add('.codex/commands', SkillRootKind.codexLegacyCommands);
    add('.claude/skills', SkillRootKind.claudeSkills);
    add('.claude/skills/omc-learned', SkillRootKind.claudeOmcLearnedSkills);
    add('.claude/commands', SkillRootKind.claudeLegacyCommands);

    return precedence;
  }

  Future<SkillMatch?> _resolveInRoot(
    _SkillLookupRoot root,
    String requested,
  ) async {
    switch (root.kind) {
      case SkillRootKind.sanadSkills:
      case SkillRootKind.agentSkills:
      case SkillRootKind.agentsSkills:
      case SkillRootKind.codexSkills:
      case SkillRootKind.claudeSkills:
      case SkillRootKind.claudeOmcLearnedSkills:
        return _resolveInSkillsDir(root, requested);
      case SkillRootKind.sanadLegacyCommands:
      case SkillRootKind.codexLegacyCommands:
      case SkillRootKind.claudeLegacyCommands:
        return _resolveInLegacyCommandsDir(root, requested);
    }
  }

  Future<List<SkillMatch>> _loadRootInventory(_SkillLookupRoot root) async {
    switch (root.kind) {
      case SkillRootKind.sanadSkills:
      case SkillRootKind.agentSkills:
      case SkillRootKind.agentsSkills:
      case SkillRootKind.codexSkills:
      case SkillRootKind.claudeSkills:
      case SkillRootKind.claudeOmcLearnedSkills:
        return _loadSkillsDirInventory(root);
      case SkillRootKind.sanadLegacyCommands:
      case SkillRootKind.codexLegacyCommands:
      case SkillRootKind.claudeLegacyCommands:
        return _loadLegacyCommandsInventory(root);
    }
  }

  Future<SkillMatch?> _resolveInSkillsDir(
    _SkillLookupRoot root,
    String requested,
  ) async {
    final directFile = File(p.join(root.path, requested, 'SKILL.md'));
    if (await directFile.exists()) {
      return _readSkillMatch(root, directFile);
    }

    final directory = Directory(root.path);
    if (!await directory.exists()) {
      return null;
    }

    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! Directory) {
        continue;
      }
      final skillFile = File(p.join(entity.path, 'SKILL.md'));
      if (!await skillFile.exists()) {
        continue;
      }

      final basename = p.basename(entity.path);
      if (_matchesRequestedValue(basename, requested)) {
        return _readSkillMatch(root, skillFile);
      }

      final frontmatterName = await _readFrontmatterValue(skillFile, 'name');
      if (_matchesRequestedValue(frontmatterName, requested)) {
        return _readSkillMatch(root, skillFile);
      }
    }

    return null;
  }

  Future<List<SkillMatch>> _loadSkillsDirInventory(
    _SkillLookupRoot root,
  ) async {
    final directory = Directory(root.path);
    if (!await directory.exists()) {
      return const [];
    }

    final matches = <SkillMatch>[];
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! Directory) {
        continue;
      }
      final skillFile = File(p.join(entity.path, 'SKILL.md'));
      if (!await skillFile.exists()) {
        continue;
      }
      matches.add(await _readSkillMatch(root, skillFile));
    }
    return matches;
  }

  Future<SkillMatch?> _resolveInLegacyCommandsDir(
    _SkillLookupRoot root,
    String requested,
  ) async {
    final directSkill = File(p.join(root.path, requested, 'SKILL.md'));
    if (await directSkill.exists()) {
      return _readSkillMatch(root, directSkill);
    }

    final directMarkdown = File(p.join(root.path, '$requested.md'));
    if (await directMarkdown.exists()) {
      return _readSkillMatch(root, directMarkdown);
    }

    final directory = Directory(root.path);
    if (!await directory.exists()) {
      return null;
    }

    await for (final entity in directory.list(followLinks: false)) {
      File? candidate;
      if (entity is Directory) {
        final skillFile = File(p.join(entity.path, 'SKILL.md'));
        if (await skillFile.exists()) {
          candidate = skillFile;
        }
      } else if (entity is File &&
          p.extension(entity.path).toLowerCase() == '.md') {
        candidate = entity;
      }

      if (candidate == null) {
        continue;
      }

      final basenames = <String>{
        p.basenameWithoutExtension(candidate.path),
        p.basenameWithoutExtension(entity.path),
      };
      if (basenames.any((value) => _matchesRequestedValue(value, requested))) {
        return _readSkillMatch(root, candidate);
      }

      final frontmatterName = await _readFrontmatterValue(candidate, 'name');
      if (_matchesRequestedValue(frontmatterName, requested)) {
        return _readSkillMatch(root, candidate);
      }
    }

    return null;
  }

  Future<List<SkillMatch>> _loadLegacyCommandsInventory(
    _SkillLookupRoot root,
  ) async {
    final directory = Directory(root.path);
    if (!await directory.exists()) {
      return const [];
    }

    final matches = <SkillMatch>[];
    await for (final entity in directory.list(followLinks: false)) {
      File? candidate;
      if (entity is Directory) {
        final skillFile = File(p.join(entity.path, 'SKILL.md'));
        if (await skillFile.exists()) {
          candidate = skillFile;
        }
      } else if (entity is File &&
          p.extension(entity.path).toLowerCase() == '.md') {
        candidate = entity;
      }

      if (candidate != null) {
        matches.add(await _readSkillMatch(root, candidate));
      }
    }
    return matches;
  }

  Future<SkillMatch> _readSkillMatch(_SkillLookupRoot root, File file) async {
    final stat = await file.stat();
    if (stat.size > maxSkillBytes) {
      throw FileSystemException(
        'Skill file is too large to load safely (${stat.size} bytes).',
        file.path,
      );
    }

    final contents = await file.readAsString();
    final metadata = SkillFrontmatter.parse(contents);
    final fallbackName =
        root.kind == SkillRootKind.sanadLegacyCommands ||
            root.kind == SkillRootKind.codexLegacyCommands ||
            root.kind == SkillRootKind.claudeLegacyCommands
        ? p.basenameWithoutExtension(file.path)
        : p.basename(p.dirname(file.path));
    return SkillMatch(
      sourcePath: file.path,
      prompt: contents,
      name: metadata.name ?? fallbackName,
      description: metadata.description,
      metadata: metadata,
      origin: SkillOrigin(
        rootPath: root.path,
        filePath: file.path,
        scope: root.scope,
        rootKind: root.kind,
        precedence: root.precedence,
      ),
    );
  }

  Future<String?> _readFrontmatterValue(File file, String key) async {
    final stat = await file.stat();
    if (stat.size > maxSkillBytes) {
      return null;
    }
    final contents = await file.readAsString();
    final metadata = SkillFrontmatter.parse(contents);
    switch (key) {
      case 'name':
        return metadata.name;
      case 'description':
        return metadata.description;
      default:
        final rawValue = metadata.raw[key];
        return rawValue is String ? rawValue : null;
    }
  }

  String _normalizeRequestedSkill(String value) {
    return value.trim().replaceFirst(RegExp(r'^[/$]+'), '');
  }

  bool _matchesRequestedValue(String? candidate, String requested) {
    if (candidate == null) {
      return false;
    }
    return candidate.toLowerCase() == requested.toLowerCase();
  }

  String? _normalizeExistingDirectory(String? path) {
    final trimmed = path?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      return null;
    }

    final directory = Directory(trimmed);
    if (!directory.existsSync()) {
      return null;
    }
    return p.normalize(directory.absolute.path);
  }

  List<String> _ancestors(String directoryPath) {
    final ancestors = <String>[];
    var current = p.normalize(directoryPath);
    while (true) {
      ancestors.add(current);
      final parent = p.dirname(current);
      if (parent == current) {
        break;
      }
      current = parent;
    }
    return ancestors;
  }

  void _pushRoot(List<_SkillLookupRoot> roots, _SkillLookupRoot root) {
    final directory = Directory(root.path);
    if (!directory.existsSync()) {
      return;
    }
    if (roots.any((existing) => existing.path == root.path)) {
      return;
    }
    roots.add(root);
  }
}

class _SkillLookupRoot {
  final String path;
  final SkillSourceScope scope;
  final SkillRootKind kind;
  final int precedence;

  const _SkillLookupRoot({
    required this.path,
    required this.scope,
    required this.kind,
    required this.precedence,
  });
}
