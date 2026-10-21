import 'package:path/path.dart' as p;

/// Keeps project environment-file values out of model-visible tool results.
///
/// Project processes still open the file directly (build, test, run); only
/// the projection returned to the model is redacted. Variable names and
/// comments stay visible so the model can reason about configuration shape.
/// Template files (`.env.example`, `.env.sample`, ...) stay readable.
abstract final class ProjectEnvRedactor {
  static const placeholder = '<redacted>';

  /// Exact template names that stay readable. A suffixed variant such as
  /// `.env.example.local` holds real values and is redacted.
  static const _templateNames = {
    '.env.example',
    '.env.sample',
    '.env.template',
    '.env.dist',
    '.env.defaults',
  };

  static final _assignment = RegExp(
    r'^(\s*(?:export\s+)?[A-Za-z_][A-Za-z0-9_.\-]*\s*[=:])(.*)$',
  );

  /// Whether [path] names a project environment file with real values.
  static bool isProjectEnvFile(String path) {
    final name = p.basename(path).toLowerCase();
    if (_templateNames.contains(name)) return false;
    return name == '.env' ||
        name == '.envrc' ||
        name.startsWith('.env.') ||
        name.endsWith('.env');
  }

  /// Replaces every value in [content] while keeping line structure, names,
  /// blank lines and comments. A quoted value that spans lines is redacted
  /// on every line until its closing quote.
  static String redact(String content) {
    final out = <String>[];
    String? openQuote;
    for (final line in content.split('\n')) {
      if (openQuote != null) {
        out.add(placeholder);
        if (_closes(line, openQuote)) openQuote = null;
        continue;
      }
      final trimmed = line.trimLeft();
      if (trimmed.isEmpty || trimmed.startsWith('#')) {
        out.add(line);
        continue;
      }
      final match = _assignment.firstMatch(line);
      if (match == null) {
        out.add(placeholder);
        continue;
      }
      out.add('${match.group(1)}$placeholder');
      final value = match.group(2)!.trimLeft();
      if (value.isNotEmpty && (value[0] == '"' || value[0] == "'")) {
        if (!_closes(value.substring(1), value[0])) openQuote = value[0];
      }
    }
    return out.join('\n');
  }

  /// Whether [text] contains an unescaped [quote].
  static bool _closes(String text, String quote) {
    for (var i = 0; i < text.length; i++) {
      if (text[i] == '\\' && quote == '"') {
        i++;
        continue;
      }
      if (text[i] == quote) return true;
    }
    return false;
  }
}
