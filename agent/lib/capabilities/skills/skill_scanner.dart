import 'dart:convert';
import 'dart:io';

import 'skill_archive.dart';
import 'skill_frontmatter.dart';

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
  const SkillScanReport(this.findings, {this.allowedFindings = const []});

  final List<SkillScanFinding> findings;
  final List<SkillScanFinding> allowedFindings;

  bool get isClean => findings.isEmpty && allowedFindings.isEmpty;

  bool get isAllowed => findings.isEmpty && allowedFindings.isNotEmpty;

  bool get isFlagged => findings.isNotEmpty;

  bool get isPassed => findings.isEmpty;

  String get verdict {
    if (isFlagged) return 'flagged';
    if (isAllowed) return 'allowed';
    return 'clean';
  }

  /// A short, model-safe summary used in command output and provenance.
  String describe({int limit = 5}) {
    if (isClean) return 'clean';
    if (isAllowed) {
      final shown = allowedFindings
          .take(limit)
          .map((finding) => '  - $finding (allowed by declaration)');
      final extra = allowedFindings.length > limit
          ? '\n  - …and ${allowedFindings.length - limit} more'
          : '';
      return 'allowed (${allowedFindings.length} finding(s) permitted by publisher declaration):\n${shown.join('\n')}$extra';
    }
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

  static final RegExp _urlCandidateRegex = RegExp(
    r'''(?:[a-zA-Z][a-zA-Z0-9+.-]*:)?//[^\s"'`<>|]+''',
  );

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
      isHostScoped: true,
    ),
    _Rule(
      'encoded-exec',
      'Decodes content into a shell',
      RegExp(
        r'\bbase64\s+(-d|--decode|-D)[^\n|]{0,80}\|\s*(sudo\s+)?(/bin/)?(ba|z|k|d)?sh\b',
        caseSensitive: false,
      ),
      isHostScoped: true,
    ),
    _Rule(
      'exfiltration',
      'Uploads local files to a remote endpoint',
      RegExp(
        r'\b(curl|wget)\b[^\n]{0,160}\s(-F|-T|--data-binary|--upload-file|--post-file)(\s|=)',
        caseSensitive: false,
      ),
      isHostScoped: true,
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
    final allowedFindings = <SkillScanFinding>[];
    final paths = files.keys.toList()..sort();
    for (final path in paths) {
      final entry = files[path]!;
      if (entry.bytes.length > maxScanBytes) continue;
      final decoded = _decodeText(entry.bytes);
      if (decoded == null) continue;
      final allowedHosts = _extractAllowedHosts(decoded);
      final lines = const LineSplitter().convert(decoded);
      for (var index = 0; index < lines.length; index++) {
        final text = lines[index];
        for (final rule in _rules) {
          if (rule.pattern.hasMatch(text)) {
            final finding = SkillScanFinding(
              rule: rule.id,
              path: entry.path,
              line: index + 1,
              detail: rule.detail,
            );
            if (rule.isHostScoped && _isLineCovered(text, allowedHosts)) {
              allowedFindings.add(finding);
            } else {
              findings.add(finding);
            }
          }
        }
      }
    }
    return SkillScanReport(findings, allowedFindings: allowedFindings);
  }

  List<String> _extractAllowedHosts(String text) {
    if (!text.trimLeft().startsWith('---')) return const [];
    final frontmatter = SkillFrontmatter.parse(text);
    return frontmatter.allowedRemoteExec;
  }

  static List<String> _extractUrlHosts(String line) {
    final matches = _urlCandidateRegex.allMatches(line);
    if (matches.isEmpty) return const [];

    final hosts = <String>[];
    for (final match in matches) {
      var candidate = match.group(0)!;
      while (candidate.isNotEmpty &&
          (candidate.endsWith('.') ||
              candidate.endsWith(',') ||
              candidate.endsWith(';') ||
              candidate.endsWith(')') ||
              candidate.endsWith(']') ||
              candidate.endsWith('}') ||
              candidate.endsWith('>') ||
              candidate.endsWith('\\'))) {
        candidate = candidate.substring(0, candidate.length - 1);
      }
      final uri = candidate.startsWith('//')
          ? Uri.tryParse('http:$candidate')
          : Uri.tryParse(candidate);
      if (uri != null) {
        var host = uri.host.trim().toLowerCase();
        if (host.endsWith('.')) {
          host = host.substring(0, host.length - 1);
        }
        hosts.add(host);
      }
    }
    return hosts;
  }

  static bool _isLineCovered(String line, List<String> allowedDeclarations) {
    final hosts = _extractUrlHosts(line);
    if (hosts.isEmpty || allowedDeclarations.isEmpty) {
      return false;
    }
    return hosts.every((host) => _isHostCovered(host, allowedDeclarations));
  }

  static bool _isHostCovered(
    String actualHost,
    List<String> allowedDeclarations,
  ) {
    final host = actualHost.trim().toLowerCase();
    if (host.isEmpty || host == 'localhost') return false;
    if (host.startsWith('[') || host.contains(':')) return false;
    if (RegExp(r'^(\d{1,3}\.){3}\d{1,3}$').hasMatch(host)) return false;
    if (InternetAddress.tryParse(host) != null) return false;

    for (final declaration in allowedDeclarations) {
      var declared = declaration.trim().toLowerCase();
      if (declared.endsWith('.')) {
        declared = declared.substring(0, declared.length - 1);
      }
      if (!_isValidDeclaredHost(declared)) continue;
      if (host == declared || host.endsWith('.$declared')) {
        return true;
      }
    }
    return false;
  }

  static bool _isValidDeclaredHost(String declared) {
    if (declared.isEmpty || declared == 'localhost') return false;
    if (declared.startsWith('[') || declared.contains(':')) return false;
    if (RegExp(r'^(\d{1,3}\.){3}\d{1,3}$').hasMatch(declared)) return false;
    if (InternetAddress.tryParse(declared) != null) return false;
    if (!RegExp(
      r'^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$',
    ).hasMatch(declared)) {
      return false;
    }
    return true;
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
  _Rule(this.id, this.detail, this.pattern, {this.isHostScoped = false});

  final String id;
  final String detail;
  final RegExp pattern;
  final bool isHostScoped;
}
