import 'dart:io';
import 'dart:math';

import 'ansi_styles.dart';
import 'markdown_renderer.dart';
import 'reasoning_box.dart';
import 'syntax_highlighter.dart';
import 'terminal_theme.dart';
import 'tool_progress_spinner.dart';

export 'ansi_styles.dart';
export 'markdown_renderer.dart';
export 'reasoning_box.dart';
export 'syntax_highlighter.dart';
export 'terminal_theme.dart';
export 'tool_progress_spinner.dart';

/// Central visual rendering engine for Sanad CLI terminal output.
///
/// Handles rich ANSI-styled Markdown, syntax-colored code blocks, animated tool spinners,
/// reasoning boxes, formatted tables, and status notices with full non-TTY and plain text fallback.
class TerminalRenderer {
  final StringSink out;
  final StringSink err;
  final bool isTerminal;
  final bool enableColor;
  final TerminalTheme theme;
  final int terminalWidth;
  final ToolProgressMode toolProgressMode;

  late final MarkdownRenderer _markdownRenderer;
  late final SyntaxHighlighter _syntaxHighlighter;
  late final ReasoningBox _reasoningBox;

  TerminalRenderer({
    StringSink? stdoutSink,
    StringSink? stderrSink,
    bool? isTerminal,
    bool? enableColor,
    TerminalTheme? theme,
    int? terminalWidth,
    this.toolProgressMode = ToolProgressMode.all,
  }) : out = stdoutSink ?? stdout,
       err = stderrSink ?? stderr,
       isTerminal = isTerminal ?? _detectTerminal(),
       enableColor =
           enableColor ?? _detectColorSupport(isTerminal ?? _detectTerminal()),
       theme =
           theme ??
           _resolveTheme(
             enableColor ??
                 _detectColorSupport(isTerminal ?? _detectTerminal()),
           ),
       terminalWidth = terminalWidth ?? _detectTerminalWidth() {
    _markdownRenderer = MarkdownRenderer(
      theme: this.theme,
      defaultWidth: this.terminalWidth,
    );
    _syntaxHighlighter = SyntaxHighlighter(this.theme);
    _reasoningBox = ReasoningBox(
      theme: this.theme,
      defaultWidth: this.terminalWidth,
    );
  }

  static bool _detectTerminal() {
    try {
      return stdout.hasTerminal;
    } catch (_) {
      return false;
    }
  }

  static bool _detectColorSupport(bool isTerminal) {
    if (!isTerminal) return false;
    final env = Platform.environment;
    if (env.containsKey('NO_COLOR')) return false;
    if (env['TERM'] == 'dumb') return false;
    return true;
  }

  static int _detectTerminalWidth() {
    try {
      if (stdout.hasTerminal) {
        return stdout.terminalColumns;
      }
    } catch (_) {}
    return 80;
  }

  static TerminalTheme _resolveTheme(bool enableColor) {
    if (!enableColor) return TerminalTheme.plain();
    return TerminalTheme.dark();
  }

  /// Renders formatted Markdown text directly to output or returns the formatted string.
  String renderMarkdown(
    String markdown, {
    int? maxWidth,
    bool printToStdout = false,
  }) {
    final rendered = _markdownRenderer.render(
      markdown,
      maxWidth: maxWidth ?? terminalWidth,
    );
    if (printToStdout) {
      out.writeln(rendered);
    }
    return rendered;
  }

  /// Highlights code string according to language.
  String highlightCode(String code, {String? language}) {
    return _syntaxHighlighter.highlight(code, language: language);
  }

  /// Creates a [ToolProgressSpinner] matching the renderer configuration.
  ToolProgressSpinner createToolSpinner({
    ToolProgressMode? mode,
    Duration tickInterval = const Duration(milliseconds: 80),
  }) {
    return ToolProgressSpinner(
      stdoutSink: out,
      theme: theme,
      isTerminal: isTerminal,
      mode: mode ?? toolProgressMode,
      tickInterval: tickInterval,
    );
  }

  /// Renders a completed reasoning block or collapsed summary.
  String renderReasoningBox(
    String reasoningText, {
    Duration? duration,
    int? tokenCount,
    bool collapse = false,
    String? summary,
    bool printToStdout = false,
  }) {
    final String result;
    if (collapse) {
      result = _reasoningBox.renderRecap(
        duration: duration ?? Duration.zero,
        tokenCount: tokenCount,
        summary: summary,
      );
    } else {
      result = _reasoningBox.render(
        reasoningText,
        duration: duration,
        tokenCount: tokenCount,
        maxWidth: terminalWidth,
      );
    }

    if (printToStdout) {
      out.writeln(result);
    }
    return result;
  }

  /// Creates a [ReasoningStreamHandler] for handling live streaming reasoning tokens.
  ReasoningStreamHandler createReasoningStream({bool collapsible = false}) {
    return ReasoningStreamHandler(
      stdoutSink: out,
      theme: theme,
      isTerminal: isTerminal,
      collapsible: collapsible,
      maxWidth: terminalWidth,
    );
  }

  /// Formats and renders a tabular data matrix.
  String formatTable(
    List<String> headers,
    List<List<String>> rows, {
    bool printToStdout = false,
  }) {
    final buffer = StringBuffer();
    buffer.writeln('| ${headers.join(' | ')} |');
    buffer.writeln('| ${headers.map((_) => '---').join(' | ')} |');
    for (final row in rows) {
      buffer.writeln('| ${row.join(' | ')} |');
    }

    final rendered = _markdownRenderer.render(
      buffer.toString(),
      maxWidth: terminalWidth,
    );
    if (printToStdout) {
      out.writeln(rendered);
    }
    return rendered;
  }

  /// Renders an error notice with distinct styling to stderr.
  void renderError(String message, {String? code, bool isFatal = false}) {
    final prefix = isFatal ? 'FATAL ERROR' : 'ERROR';
    final codeStr = code != null ? ' [$code]' : '';
    if (!enableColor) {
      err.writeln('[$prefix]$codeStr $message');
      return;
    }

    final badge = '${theme.bold}${theme.error}[$prefix]$codeStr${Ansi.reset}';
    err.writeln('$badge ${theme.error}$message${Ansi.reset}');
  }

  /// Renders a warning notice to stderr.
  void renderWarning(String message) {
    if (!enableColor) {
      err.writeln('[WARNING] $message');
      return;
    }
    final badge = '${theme.bold}${theme.warning}[WARNING]${Ansi.reset}';
    err.writeln('$badge ${theme.warning}$message${Ansi.reset}');
  }

  /// Renders an informative or advisory notice to stdout.
  void renderNotice(String message, {String? code}) {
    final codeStr = code != null ? ' ($code)' : '';
    if (!enableColor) {
      out.writeln('ℹ $message$codeStr');
      return;
    }
    final icon = '${theme.info}ℹ${Ansi.reset}';
    out.writeln(
      '$icon ${theme.normal}$message${theme.dim}$codeStr${Ansi.reset}',
    );
  }

  /// Renders a success notice to stdout.
  void renderSuccess(String message) {
    if (!enableColor) {
      out.writeln('✔ $message');
      return;
    }
    final icon = '${theme.success}✔${Ansi.reset}';
    out.writeln('$icon ${theme.success}$message${Ansi.reset}');
  }

  /// Renders a stylized ASCII/Unicode header banner for CLI commands and REPL.
  void renderBanner({
    required String title,
    String? subtitle,
    Map<String, String>? metadata,
  }) {
    final boxWidth = min(terminalWidth, 76);
    final isPlain = !enableColor;

    final cTopLeft = isPlain ? '+-' : '╭─';
    final cBottomLeft = isPlain ? '+-' : '╰─';
    final cBar = isPlain ? '-' : '─';
    final cVert = isPlain ? '|' : '│';

    final border = theme.codeBlockBorder;
    final titleStyle = '${theme.bold}${theme.h1}';
    final subStyle = theme.dim;

    out.writeln();
    final topBar = cBar * (boxWidth - 4);
    if (isPlain) {
      out.writeln('$cTopLeft$topBar+');
      out.writeln('$cVert $title');
      if (subtitle != null) out.writeln('$cVert $subtitle');
    } else {
      out.writeln('$border$cTopLeft$topBar╮${Ansi.reset}');
      out.writeln('$border$cVert${Ansi.reset} $titleStyle$title${Ansi.reset}');
      if (subtitle != null) {
        out.writeln(
          '$border$cVert${Ansi.reset} $subStyle$subtitle${Ansi.reset}',
        );
      }
    }

    if (metadata != null && metadata.isNotEmpty) {
      for (final entry in metadata.entries) {
        final key = entry.key;
        final val = entry.value;
        if (isPlain) {
          out.writeln('$cVert   $key: $val');
        } else {
          out.writeln(
            '$border$cVert${Ansi.reset}   ${theme.dim}$key:${Ansi.reset} ${theme.normal}$val${Ansi.reset}',
          );
        }
      }
    }

    final bottomBar = cBar * (boxWidth - 4);
    if (isPlain) {
      out.writeln('$cBottomLeft$bottomBar+');
    } else {
      out.writeln('$border$cBottomLeft$bottomBar╯${Ansi.reset}');
    }
  }

  /// Strips all ANSI codes from [text].
  static String stripAnsi(String text) => Ansi.strip(text);
}
