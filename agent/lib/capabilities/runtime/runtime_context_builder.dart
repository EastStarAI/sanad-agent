import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sanad_agent/capabilities/registry/tools_registry.dart';
import 'package:sanad_agent/capabilities/skills/skill_inventory.dart';
import 'package:sanad_agent/capabilities/skills/skill_registry.dart';

import 'workspace_path_resolver.dart';

class RuntimeContextBuilder {
  static const int _maxInstructionChars = 20000;
  static const int _maxTotalInstructionChars = 40000;
  static const int _maxSkillEntries = 64;

  final WorkspacePathResolver _pathResolver;
  final SkillRegistry _skillRegistry;

  const RuntimeContextBuilder({
    WorkspacePathResolver pathResolver = const WorkspacePathResolver(),
    SkillRegistry skillRegistry = const SkillRegistry(),
  }) : _pathResolver = pathResolver,
       _skillRegistry = skillRegistry;

  String buildWithoutWorkspace() =>
      'No workspace is attached, so file and terminal tools are unavailable. If the user requests them, ask them to select an existing workspace or create one from the workspace control in the upper-left corner.';

  Future<String?> build({
    required String workspacePath,
    String? workspaceName,
    ToolsRegistry? registry,
  }) async {
    final root = _pathResolver.normalizeWorkspaceRoot(workspacePath);
    final lines = <String>[
      '# Runtime context',
      'Workspace: ${workspaceName?.trim().isNotEmpty == true ? workspaceName!.trim() : p.basename(root)}',
      'Working directory: $root (commands run here by default; do not "cd" to it)',
      '',
      'This context is regenerated per session. Treat it as the current local operating context, not as historical conversation content.',
    ];

    final instructionSections = await _renderInstructionFiles(root);
    if (instructionSections != null) {
      lines
        ..add('')
        ..addAll(instructionSections);
    }

    final skillSections = await _renderSkillSummaries(root);
    if (skillSections != null) {
      lines
        ..add('')
        ..addAll(skillSections);
    }

    final result = lines.join('\n').trim();
    return result.isEmpty ? null : result;
  }

  Future<List<String>?> _renderInstructionFiles(String root) async {
    final files = await _discoverInstructionFiles(root);
    if (files.isEmpty) {
      return null;
    }

    final sections = <String>[
      'Workspace instruction contracts (hierarchy: more specific contracts closer to the active workspace are listed first; parent contracts follow and provide broader defaults unless a closer contract specializes them):',
    ];
    var remaining = _maxTotalInstructionChars;
    for (final file in files) {
      if (remaining <= 0) {
        sections.add(
          '_Additional instruction content omitted after reaching the prompt budget._',
        );
        break;
      }
      final raw = await file.readAsString();
      final trimmed = _sanitizeContent(raw.trim(), file.path);
      if (trimmed.isEmpty) {
        continue;
      }

      final limited = _truncateHeadTail(
        trimmed,
        remaining < _maxInstructionChars ? remaining : _maxInstructionChars,
        p.basename(file.path),
      );
      remaining -= limited.length;
      sections
        ..add('## ${_describeFile(root, file.path)}')
        ..add(limited);
    }

    return sections.length > 1 ? sections : null;
  }

  Future<List<String>?> _renderSkillSummaries(String root) async {
    final report = await _skillRegistry.list(
      workspacePath: root,
      includeShadowed: false,
    );
    final activeSkills = report.skills
        .where((skill) => skill.active)
        .take(_maxSkillEntries)
        .toList(growable: false);
    if (activeSkills.isEmpty) {
      return null;
    }

    final sections = <String>['Available skills:'];
    for (final skill in activeSkills) {
      sections.addAll(_renderSkillSummary(skill));
    }

    if (report.skills.where((skill) => skill.active).length >
        activeSkills.length) {
      sections.add(
        '_Additional skills omitted after reaching the summary limit._',
      );
    }

    return sections;
  }

  Future<List<File>> _discoverInstructionFiles(String root) async {
    final directories = <Directory>[];
    var current = Directory(root);
    while (true) {
      directories.add(current);
      final parentPath = current.parent.path;
      if (parentPath == current.path) {
        break;
      }
      current = current.parent;
    }
    final seen = <String>{};
    final files = <File>[];
    for (final dir in directories) {
      final candidates = [
        File('${dir.path}${Platform.pathSeparator}AGENTS.md'),
        File('${dir.path}${Platform.pathSeparator}CLAUDE.md'),
        File(
          '${dir.path}${Platform.pathSeparator}.sanad${Platform.pathSeparator}AGENTS.md',
        ),
        File(
          '${dir.path}${Platform.pathSeparator}.sanad${Platform.pathSeparator}instructions.md',
        ),
      ];

      for (final file in candidates) {
        final path = file.path;
        if (!seen.add(path)) {
          continue;
        }
        if (await file.exists()) {
          files.add(file);
        }
      }
    }
    return files;
  }

  String _describeFile(String root, String path) {
    final normalizedRoot = root.endsWith(Platform.pathSeparator)
        ? root
        : '$root${Platform.pathSeparator}';
    if (path.startsWith(normalizedRoot)) {
      return '[Local Project Contract] ${path.substring(normalizedRoot.length)}';
    }
    return '[Parent Contract] $path';
  }

  String _truncateHeadTail(String content, int maxChars, String filename) {
    if (content.length <= maxChars) {
      return content;
    }

    final markerTemplate =
        '\n\n[...truncated $filename: kept H+T of ${content.length} chars.]\n\n';
    final availableChars = maxChars - markerTemplate.length;
    if (availableChars <= 16) {
      return content.substring(0, maxChars);
    }

    final headChars = (availableChars * 0.7).floor();
    final tailChars = availableChars - headChars;
    final head = content.substring(0, headChars);
    final tail = content.substring(content.length - tailChars);
    return '$head\n\n[...truncated $filename: kept $headChars+$tailChars of ${content.length} chars.]\n\n$tail';
  }

  String _sanitizeContent(String content, String filename) {
    final lower = content.toLowerCase();
    const injectionPatterns = [
      'ignore previous instructions',
      'ignore all instructions',
      'system prompt override',
      'you are now a',
    ];
    for (final pattern in injectionPatterns) {
      if (lower.contains(pattern)) {
        return '[SECURITY WARNING: Content from $filename was blocked because it contained potential prompt injection patterns. Content not loaded.]';
      }
    }
    return content;
  }

  List<String> _renderSkillSummary(SkillInventoryEntry skill) {
    final description = skill.description?.trim();
    return [
      'name: ${skill.name}',
      'description: ${description == null || description.isEmpty ? 'No description provided.' : description}',
      '',
    ];
  }
}
