import 'dart:convert';

import 'skill_archive.dart';

/// Raised when staged skill content trips a security rule.
class SkillScanException implements Exception {
  SkillScanException(this.message, {this.report});

  final String message;
  final SkillScanReport? report;

  @override
  String toString() => message;
}

/// One rule violation found in staged content.
class SkillScanFinding {
  const SkillScanFinding({
    required this.rule,
    required this.path,
    required this.line,
    required this.detail,
  });

  final String rule;
  final String path;
  final int line;
  final String detail;

  @override
  String toString() => '$path:$line [$rule] $detail';
}

/// Outcome of scanning staged skill content before installation.
class SkillScanReport {
  const SkillScanReport(this.findings);

  final List<SkillScanFinding> findings;

  bool get isClean => findings.isEmpty;

  String get verdict => isClean ? 'clean' : 'flagged';

  /// A short, model-safe summary used in command output and provenance.
  String describe({int limit = 5}) {
    if (isClean) return 'clean';
    final shown = findings.take(limit).map((finding) => '  - $finding');
    final extra = findings.length > limit
        ? '\n  - …and ${findings.length - limit} more'
        : '';
    return 'flagged (${findings.length} finding(s)):\n${shown.join('\n')}$extra';
  }
}

/// Static, dependency-free screening of skill content before it becomes active.
///
/// This is a coarse first barrier, not a sandbox: it looks for patterns that are
/// never legitimate in a skill package — credential paths, piping remote content
/// into a shell, destructive filesystem commands, and instruction-override
/// phrasing aimed at the agent. A flagged package is refused by default and can
/// only be installed with an explicit override.
class SkillScanner {
  const SkillScanner();

  /// Files larger than this are not scanned; skill instructions are text.
  static const int maxScanBytes = 256 * 1024;

  /// Skill packages are instruction content: one rule set, kept small enough to
  /// review by hand.
  static final List<_Rule> _rules = [
    _Rule(
      'credential-path',
      'Reads a credential store',
      RegExp(
        r'(\.ssh/(id_|authorized)|\.aws/credentials|\.config/gcloud/|'
        r'\.netrc|\.npmrc\b|login\.keychain|Library/Keychains/)',
        caseSensitive: false,
      ),
    ),
    _Rule(
      'remote-exec',
      'Pipes remote content into a shell',
      RegExp(
        r'\b(curl|wget)\b[^\n|]{0,120}\|\s*(sudo\s+)?(/bin/)?(ba|z|k|d)?sh\b',
        caseSensitive: false,
      ),
    ),
    _Rule(
      'encoded-exec',
      'Decodes content into a shell',
      RegExp(
        r'\bbase64\s+(-d|--decode|-D)[^\n|]{0,80}\|\s*(sudo\s+)?(/bin/)?(ba|z|k|d)?sh\b',
        caseSensitive: false,
      ),
    ),
    _Rule(
      'exfiltration',
      'Uploads local files to a remote endpoint',
      RegExp(
        r'\b(curl|wget)\b[^\n]{0,160}\s(-F|-T|--data-binary|--upload-file|--post-file)(\s|=)',
        caseSensitive: false,
      ),
    ),
    _Rule(
      'destructive-fs',
      'Deletes or rewrites broad filesystem paths',
      RegExp(
        r'\brm\s+-[a-zA-Z]*r[a-zA-Z]*\s+(/\*?|~/?|\$HOME/?|\${HOME}/?)(\s|$)',
        caseSensitive: false,
      ),
    ),
    _Rule(
      'permission-relaxation',
      'Grants world read/write/execute',
      RegExp(r'\bchmod\s+(-[a-zA-Z]*\s+)?777\b'),
    ),
    _Rule(
      'instruction-override',
      'Tells the agent to ignore its own instructions',
      RegExp(
        r'\b(ignore|disregard|forget)\s+(all\s+)?(your\s+)?(previous|prior|earlier|above)\s+(instructions|rules|prompts|directives)\b',
        caseSensitive: false,
      ),
    ),
    _Rule(
      'secret-harvest',
      'Asks the agent to reveal secrets or tokens',
      RegExp(
        r'\b(reveal|expose|dump|leak|extract)\s+([a-zA-Z_-]+\s+){0,3}'
        r'(api[_\s-]?key|private[_\s-]?key|token|password|secret|credential)s?\b|'
        r'\b(print|echo|send|post|upload)\s+(your|the\s+user(?:\x27s)?)\s+'
        r'([a-zA-Z_-]+\s+){0,2}(api[_\s-]?key|private[_\s-]?key|token|password|secret|credential)s?\b',
        caseSensitive: false,
      ),
    ),
  ];

  SkillScanReport scan(Map<String, SkillArchiveEntry> files) {
    final findings = <SkillScanFinding>[];
    final paths = files.keys.toList()..sort();
    for (final path in paths) {
      final entry = files[path]!;
      if (entry.bytes.length > maxScanBytes) continue;
      final decoded = _decodeText(entry.bytes);
      if (decoded == null) continue;
      final lines = const LineSplitter().convert(decoded);
      for (var index = 0; index < lines.length; index++) {
        final text = lines[index];
        for (final rule in _rules) {
          if (rule.pattern.hasMatch(text)) {
            findings.add(
              SkillScanFinding(
                rule: rule.id,
                path: entry.path,
                line: index + 1,
                detail: rule.detail,
              ),
            );
          }
        }
      }
    }
    return SkillScanReport(findings);
  }

  /// Returns null for binary content so images and archives are not analysed.
  String? _decodeText(List<int> bytes) {
    if (bytes.contains(0)) return null;
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return null;
    }
  }
}

class _Rule {
  _Rule(this.id, this.detail, this.pattern);

  final String id;
  final String detail;
  final RegExp pattern;
}
