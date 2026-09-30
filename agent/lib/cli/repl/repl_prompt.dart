/// Helpers for formatting REPL prompt and banners with optional ANSI styling.
class ReplPrompt {
  /// Builds the dynamic prompt line.
  ///
  /// Format: `sanad [workspace : model] > `
  static String format({String? workspace, String? model, bool ansi = false}) {
    final effectiveWs = (workspace != null && workspace.trim().isNotEmpty)
        ? workspace.trim()
        : 'default';
    final effectiveModel = (model != null && model.trim().isNotEmpty)
        ? model.trim()
        : null;

    final descriptor = effectiveModel != null
        ? '$effectiveWs : $effectiveModel'
        : effectiveWs;

    if (!ansi) {
      return 'sanad [$descriptor] > ';
    }

    // Bold cyan 'sanad', dark gray brackets, yellow workspace, magenta model, green '>'
    final styledDescriptor = effectiveModel != null
        ? '\x1b[33m$effectiveWs\x1b[90m : \x1b[35m$effectiveModel\x1b[90m'
        : '\x1b[33m$effectiveWs\x1b[90m';

    return '\x1b[1;36msanad\x1b[0m \x1b[90m[\x1b[0m$styledDescriptor\x1b[90m]\x1b[0m \x1b[1;32m>\x1b[0m ';
  }

  /// Builds the continuation prompt for multi-line inputs.
  static String formatContinuation({bool ansi = false}) {
    if (!ansi) {
      return '... ';
    }
    return '\x1b[90m... \x1b[0m';
  }

  /// Returns the startup banner.
  static String banner({String version = '1.0.7', bool ansi = false}) {
    if (!ansi) {
      return '''
╭──────────────────────────────────────────────────────────────╮
│ ⚕ Sanad Agent CLI (v$version) — Autonomous Reasoning Assistant   │
│ Type your prompt or /help. Press Ctrl+C to cancel, Ctrl+D exit.│
╰──────────────────────────────────────────────────────────────╯''';
    }

    return '''
\x1b[36m╭──────────────────────────────────────────────────────────────╮\x1b[0m
\x1b[36m│\x1b[0m \x1b[1;32m⚕ Sanad Agent CLI\x1b[0m \x1b[90m(v$version)\x1b[0m \x1b[36m— Autonomous Reasoning Assistant   │\x1b[0m
\x1b[36m│\x1b[0m \x1b[90mType your prompt or /help. Press Ctrl+C to cancel, Ctrl+D exit.\x1b[0m\x1b[36m│\x1b[0m
\x1b[36m╰──────────────────────────────────────────────────────────────╯\x1b[0m''';
  }
}
