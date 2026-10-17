import 'dart:convert';

class SkillFrontmatter {
  final String? name;
  final String? description;
  final List<String> instructions;
  final List<String> activationRules;
  final List<String> preferredTools;
  final List<String> blockedTools;
  final bool? requiresApproval;
  final List<String> allowedRemoteExec;
  final Map<String, dynamic> raw;

  const SkillFrontmatter({
    this.name,
    this.description,
    this.instructions = const [],
    this.activationRules = const [],
    this.preferredTools = const [],
    this.blockedTools = const [],
    this.requiresApproval,
    this.allowedRemoteExec = const [],
    this.raw = const {},
  });

  factory SkillFrontmatter.parse(String contents) {
    final frontmatter = _parseFrontmatterMap(contents);
    if (frontmatter.isEmpty) {
      return const SkillFrontmatter();
    }

    return SkillFrontmatter(
      name: _stringValue(frontmatter['name']),
      description: _stringValue(frontmatter['description']),
      instructions: _stringListValue(frontmatter['instructions']),
      activationRules: _stringListValue(frontmatter['activation_rules']),
      preferredTools: _stringListValue(frontmatter['preferred_tools']),
      blockedTools: _stringListValue(frontmatter['blocked_tools']),
      requiresApproval: _boolValue(frontmatter['requires_approval']),
      allowedRemoteExec: _extractAllowedRemoteExec(frontmatter['metadata']),
      raw: frontmatter,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (name != null) 'name': name,
      if (description != null) 'description': description,
      if (instructions.isNotEmpty) 'instructions': instructions,
      if (activationRules.isNotEmpty) 'activation_rules': activationRules,
      if (preferredTools.isNotEmpty) 'preferred_tools': preferredTools,
      if (blockedTools.isNotEmpty) 'blocked_tools': blockedTools,
      if (requiresApproval != null) 'requires_approval': requiresApproval,
      if (allowedRemoteExec.isNotEmpty)
        'allowed_remote_exec': allowedRemoteExec,
      if (raw.isNotEmpty) 'raw': raw,
    };
  }

  static Map<String, dynamic> _parseFrontmatterMap(String contents) {
    final lines = const LineSplitter().convert(contents);
    if (lines.isEmpty || lines.first.trim() != '---') {
      return const {};
    }

    final frontmatterLines = <String>[];
    for (final line in lines.skip(1)) {
      if (line.trim() == '---') {
        break;
      }
      frontmatterLines.add(line);
    }

    if (frontmatterLines.isEmpty) {
      return const {};
    }

    var index = 0;

    Map<String, dynamic> parseMap(int baseIndent) {
      final result = <String, dynamic>{};

      while (index < frontmatterLines.length) {
        final rawLine = frontmatterLines[index];
        final trimmed = rawLine.trim();
        if (trimmed.isEmpty || trimmed.startsWith('#')) {
          index++;
          continue;
        }

        final indent = rawLine.length - rawLine.trimLeft().length;
        if (indent < baseIndent) {
          break;
        }

        final separatorIndex = trimmed.indexOf(':');
        if (separatorIndex <= 0) {
          index++;
          continue;
        }

        final key = trimmed.substring(0, separatorIndex).trim();
        final value = trimmed.substring(separatorIndex + 1).trim();
        index++;

        if (value.isNotEmpty) {
          result[key] = _parseScalar(value);
          continue;
        }

        int nextIndex = index;
        while (nextIndex < frontmatterLines.length) {
          final candidate = frontmatterLines[nextIndex].trim();
          if (candidate.isNotEmpty && !candidate.startsWith('#')) {
            break;
          }
          nextIndex++;
        }

        if (nextIndex >= frontmatterLines.length) {
          result[key] = const <String>[];
          break;
        }

        final nextRaw = frontmatterLines[nextIndex];
        final nextIndent = nextRaw.length - nextRaw.trimLeft().length;
        final nextTrimmed = nextRaw.trim();

        if (nextTrimmed.startsWith('-')) {
          final list = <String>[];
          while (index < frontmatterLines.length) {
            final childRaw = frontmatterLines[index];
            final childTrimmed = childRaw.trim();
            if (childTrimmed.isEmpty || childTrimmed.startsWith('#')) {
              index++;
              continue;
            }
            final childIndent = childRaw.length - childRaw.trimLeft().length;
            if (childIndent < nextIndent && !childTrimmed.startsWith('-')) {
              break;
            }
            if (childTrimmed.startsWith('-')) {
              list.add(_unquote(childTrimmed.substring(1).trim()));
              index++;
            } else {
              break;
            }
          }
          result[key] = List<String>.unmodifiable(list);
        } else if (nextIndent > indent) {
          final nested = parseMap(nextIndent);
          result[key] = Map<String, dynamic>.unmodifiable(nested);
        } else {
          result[key] = const <String>[];
        }
      }

      return result;
    }

    final parsed = parseMap(0);
    return Map<String, dynamic>.unmodifiable(parsed);
  }

  static dynamic _parseScalar(String value) {
    final normalized = _unquote(value);
    final lower = normalized.toLowerCase();
    if (lower == 'true') {
      return true;
    }
    if (lower == 'false') {
      return false;
    }
    return normalized;
  }

  static String _unquote(String value) {
    return value.replaceAll(RegExp(r'''^["']|["']$'''), '').trim();
  }

  static String? _stringValue(dynamic value) {
    if (value is! String) {
      return null;
    }
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static List<String> _stringListValue(dynamic value) {
    if (value is String) {
      final trimmed = value.trim();
      return trimmed.isEmpty ? const [] : <String>[trimmed];
    }
    if (value is! List) {
      return const [];
    }

    return value
        .whereType<String>()
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
  }

  static List<String> _extractAllowedRemoteExec(dynamic metadata) {
    if (metadata is! Map) {
      return const [];
    }
    final raw = metadata['allowed_remote_exec'];
    if (raw is String) {
      final trimmed = raw.trim();
      return trimmed.isEmpty ? const [] : <String>[trimmed];
    }
    if (raw is! List) {
      return const [];
    }

    return raw
        .whereType<String>()
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
  }

  static bool? _boolValue(dynamic value) {
    return value is bool ? value : null;
  }
}

class SkillFrontmatterMetadata {
  final Map<String, dynamic> json;

  const SkillFrontmatterMetadata(this.json);

  Map<String, dynamic> toJson() => json;
}
