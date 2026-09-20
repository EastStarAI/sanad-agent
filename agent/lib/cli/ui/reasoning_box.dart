import 'dart:io';
import 'dart:math';

import 'ansi_styles.dart';
import 'terminal_theme.dart';

/// Renders reasoning and thinking tokens (`thinking_mode`) with distinct stylized borders
/// and collapsible recap summaries.
class ReasoningBox {
  final TerminalTheme theme;
  final int defaultWidth;

  ReasoningBox({TerminalTheme? theme, this.defaultWidth = 80})
    : theme = theme ?? TerminalTheme.dark();

  /// Renders full reasoning text inside a stylized thinking box.
  String render(
    String reasoningText, {
    Duration? duration,
    int? tokenCount,
    int? maxWidth,
  }) {
    if (reasoningText.trim().isEmpty) return '';

    final width = min(maxWidth ?? defaultWidth, 80);
    final isPlain = !theme.enableColor;

    final cTopLeft = isPlain ? '+-' : '╭─';
    final cBottomLeft = isPlain ? '+-' : '╰─';
    final cBar = isPlain ? '-' : '─';
    final cVert = isPlain ? '|' : '│';

    final borderStyle = theme.reasoningBorder;
    final titleStyle = theme.reasoningTitle;
    final textStyle = theme.reasoningText;
    final timerStyle = theme.toolTimer;

    // Header label
    final durationStr = duration != null
        ? ' (${(duration.inMilliseconds / 1000.0).toStringAsFixed(1)}s)'
        : '';
    final tokenStr = tokenCount != null ? ' [$tokenCount tokens]' : '';
    final headerLabel = ' Thinking$durationStr$tokenStr ';

    final remainingHeaderWidth = max(width - headerLabel.length - 3, 2);
    final topBar = cBar * remainingHeaderWidth;
    final bottomBar = cBar * (width - 3);

    final buffer = StringBuffer();
    if (isPlain) {
      buffer.writeln('$cTopLeft$headerLabel$topBar');
    } else {
      buffer.writeln(
        '$borderStyle$cTopLeft$titleStyle$headerLabel$timerStyle$borderStyle$topBar${Ansi.reset}',
      );
    }

    // Body lines
    final lines = reasoningText.split('\n');
    for (final line in lines) {
      if (isPlain) {
        buffer.writeln('$cVert $line');
      } else {
        buffer.writeln(
          '$borderStyle$cVert${Ansi.reset} $textStyle$line${Ansi.reset}',
        );
      }
    }

    if (isPlain) {
      buffer.write('$cBottomLeft$bottomBar');
    } else {
      buffer.write('$borderStyle$cBottomLeft$bottomBar${Ansi.reset}');
    }

    return buffer.toString();
  }

  /// Renders a single-line compact collapsible recap for reasoning.
  String renderRecap({
    required Duration duration,
    int? tokenCount,
    int? wordCount,
    String? summary,
  }) {
    final durSec = (duration.inMilliseconds / 1000.0).toStringAsFixed(1);
    final words = wordCount != null ? ', $wordCount words' : '';
    final tokens = tokenCount != null ? ', $tokenCount tokens' : '';
    final label = 'Thought for ${durSec}s$words$tokens';

    if (!theme.enableColor) {
      return summary != null && summary.isNotEmpty
          ? '✔ $label: $summary'
          : '✔ $label';
    }

    final icon = '${theme.reasoningTitle}💭${Ansi.reset}';
    final styledLabel = '${theme.reasoningSummary}$label${Ansi.reset}';
    final styledSummary = summary != null && summary.isNotEmpty
        ? ' ${theme.dim}$summary${Ansi.reset}'
        : '';

    return '$icon $styledLabel$styledSummary';
  }
}

/// Handler for streaming live reasoning tokens into a terminal.
class ReasoningStreamHandler {
  final StringSink out;
  final TerminalTheme theme;
  final bool isTerminal;
  final bool collapsible;
  final int maxWidth;

  final StringBuffer _buffer = StringBuffer();
  final DateTime _startTime = DateTime.now();
  bool _hasStarted = false;
  bool _isFinished = false;

  ReasoningStreamHandler({
    StringSink? stdoutSink,
    TerminalTheme? theme,
    bool? isTerminal,
    this.collapsible = false,
    this.maxWidth = 80,
  }) : out = stdoutSink ?? stdout,
       theme = theme ?? TerminalTheme.dark(),
       isTerminal = isTerminal ?? stdout.hasTerminal;

  /// Appends incoming reasoning token [chunk].
  void addChunk(String chunk) {
    if (_isFinished) return;
    _buffer.write(chunk);

    if (!collapsible) {
      if (!_hasStarted) {
        _hasStarted = true;
        final isPlain = !theme.enableColor;
        final cTopLeft = isPlain ? '+-' : '╭─';
        final cBar = isPlain ? '-' : '─';
        final topBar = cBar * (maxWidth - 12);
        if (isPlain) {
          out.writeln('$cTopLeft Thinking $topBar');
        } else {
          out.writeln(
            '${theme.reasoningBorder}$cTopLeft${theme.reasoningTitle} Thinking ${theme.reasoningBorder}$topBar${Ansi.reset}',
          );
        }
      }

      final styledChunk = theme.enableColor
          ? '${theme.reasoningText}$chunk${Ansi.reset}'
          : chunk;
      out.write(styledChunk);
    }
  }

  /// Concludes reasoning stream and outputs either footer or collapsed summary.
  void finish({String? summary}) {
    if (_isFinished) return;
    _isFinished = true;

    final duration = DateTime.now().difference(_startTime);
    final text = _buffer.toString();
    final wordCount = text
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .length;

    if (collapsible) {
      final box = ReasoningBox(theme: theme, defaultWidth: maxWidth);
      final recap = box.renderRecap(
        duration: duration,
        wordCount: wordCount,
        summary: summary,
      );
      out.writeln(recap);
    } else {
      if (_hasStarted) {
        if (!text.endsWith('\n')) out.writeln();
        final isPlain = !theme.enableColor;
        final cBottomLeft = isPlain ? '+-' : '╰─';
        final cBar = isPlain ? '-' : '─';
        final bottomBar = cBar * (maxWidth - 3);
        if (isPlain) {
          out.writeln('$cBottomLeft$bottomBar');
        } else {
          out.writeln(
            '${theme.reasoningBorder}$cBottomLeft$bottomBar${Ansi.reset}',
          );
        }
      }
    }
  }

  String get bufferedText => _buffer.toString();
}
