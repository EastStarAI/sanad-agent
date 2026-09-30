import 'dart:async';
import 'dart:io';

import 'ansi_styles.dart';
import 'terminal_theme.dart';

/// Progress display mode for tool execution.
enum ToolProgressMode {
  /// No tool progress or status lines are output.
  off,

  /// Output a single static line on tool start and complete (no animated spinner).
  newOnly,

  /// Full animated spinner with elapsed timer and status updates.
  all,

  /// Animated spinner with detailed arguments on call and result summary on complete.
  verbose;

  /// Parses a string into a [ToolProgressMode], defaulting to [all].
  static ToolProgressMode fromString(String? value) {
    final lower = (value ?? '').trim().toLowerCase();
    switch (lower) {
      case 'off':
      case 'none':
      case 'false':
        return ToolProgressMode.off;
      case 'new':
      case 'newonly':
      case 'minimal':
        return ToolProgressMode.newOnly;
      case 'verbose':
      case 'debug':
        return ToolProgressMode.verbose;
      case 'all':
      default:
        return ToolProgressMode.all;
    }
  }
}

/// Status of an active or completed tool execution.
enum ToolExecutionStatus { calling, completed, failed, cancelled }

/// Represents an individual tool execution tracked by [ToolProgressSpinner].
class ActiveToolItem {
  final String toolCallId;
  final String toolName;
  final Map<String, dynamic> arguments;
  final DateTime startTime;
  ToolExecutionStatus status;
  String? currentMessage;
  dynamic result;
  Duration? duration;

  ActiveToolItem({
    required this.toolCallId,
    required this.toolName,
    this.arguments = const {},
    DateTime? startTime,
    this.status = ToolExecutionStatus.calling,
    this.currentMessage,
  }) : startTime = startTime ?? DateTime.now();

  Duration get elapsed => duration ?? DateTime.now().difference(startTime);
}

/// Manages interactive terminal spinners, elapsed timers, and tool execution status lines.
class ToolProgressSpinner {
  static const List<String> unicodeFrames = [
    '⠋',
    '⠙',
    '⠹',
    '⠸',
    '⠼',
    '⠴',
    '⠦',
    '⠧',
    '⠇',
    '⠏',
  ];

  static const List<String> asciiFrames = ['-', '\\', '|', '/'];

  final StringSink out;
  final TerminalTheme theme;
  final bool isTerminal;
  final bool useUnicode;
  final ToolProgressMode mode;
  final Duration tickInterval;

  final Map<String, ActiveToolItem> _tools = {};
  Timer? _ticker;
  int _frameIndex = 0;
  bool _isDisposed = false;
  bool _hasActiveSpinnerLine = false;

  ToolProgressSpinner({
    StringSink? stdoutSink,
    TerminalTheme? theme,
    bool? isTerminal,
    bool? useUnicode,
    this.mode = ToolProgressMode.all,
    this.tickInterval = const Duration(milliseconds: 80),
  }) : out = stdoutSink ?? stdout,
       theme = theme ?? TerminalTheme.dark(),
       isTerminal = isTerminal ?? stdout.hasTerminal,
       useUnicode = useUnicode ?? true;

  bool get isInteractive =>
      isTerminal && mode == ToolProgressMode.all ||
      mode == ToolProgressMode.verbose;

  List<String> get _frames => useUnicode ? unicodeFrames : asciiFrames;

  /// Starts tracking a tool invocation.
  void start({
    required String toolCallId,
    required String toolName,
    Map<String, dynamic> arguments = const {},
    String? message,
  }) {
    if (mode == ToolProgressMode.off || _isDisposed) return;

    final item = ActiveToolItem(
      toolCallId: toolCallId,
      toolName: toolName,
      arguments: arguments,
      currentMessage: message,
    );
    _tools[toolCallId] = item;

    if (!isTerminal || mode == ToolProgressMode.newOnly) {
      // Non-interactive / static mode: print discrete line
      _printStaticCalling(item);
      return;
    }

    _clearSpinnerLine();
    if (mode == ToolProgressMode.verbose && arguments.isNotEmpty) {
      final argsStr = _formatArguments(arguments);
      out.writeln('  ${theme.style('↳ args: $argsStr', theme.dim)}');
    }

    _ensureTickerRunning();
    _renderActiveSpinner();
  }

  /// Updates status message of a running tool.
  void update({required String toolCallId, required String message}) {
    if (mode == ToolProgressMode.off || _isDisposed) return;
    final item = _tools[toolCallId];
    if (item != null && item.status == ToolExecutionStatus.calling) {
      item.currentMessage = message;
      if (isInteractive) {
        _renderActiveSpinner();
      }
    }
  }

  /// Marks tool as successfully completed.
  void success({required String toolCallId, dynamic result, String? message}) {
    _finishTool(
      toolCallId: toolCallId,
      status: ToolExecutionStatus.completed,
      result: result,
      message: message,
    );
  }

  /// Marks tool as failed with an error.
  void failure({required String toolCallId, dynamic error, String? message}) {
    _finishTool(
      toolCallId: toolCallId,
      status: ToolExecutionStatus.failed,
      result: error,
      message: message,
    );
  }

  /// Marks tool as cancelled.
  void cancel({required String toolCallId, String? message}) {
    _finishTool(
      toolCallId: toolCallId,
      status: ToolExecutionStatus.cancelled,
      message: message,
    );
  }

  void _finishTool({
    required String toolCallId,
    required ToolExecutionStatus status,
    dynamic result,
    String? message,
  }) {
    if (mode == ToolProgressMode.off || _isDisposed) return;

    final item =
        _tools[toolCallId] ??
        ActiveToolItem(toolCallId: toolCallId, toolName: 'unknown_tool');
    item.status = status;
    item.result = result;
    item.duration = DateTime.now().difference(item.startTime);
    if (message != null) item.currentMessage = message;

    if (isInteractive) {
      _clearSpinnerLine();
    }

    _printStatusResult(item);

    if (mode == ToolProgressMode.verbose && result != null) {
      final resultStr = _formatResult(result);
      out.writeln('  ${theme.style('↳ result: $resultStr', theme.dim)}');
    }

    _tools.remove(toolCallId);

    if (_hasRunningTools) {
      if (isInteractive) {
        _renderActiveSpinner();
      }
    } else {
      _stopTicker();
    }
  }

  bool get _hasRunningTools =>
      _tools.values.any((t) => t.status == ToolExecutionStatus.calling);

  ActiveToolItem? get _firstRunningTool => _tools.values
      .where((t) => t.status == ToolExecutionStatus.calling)
      .firstOrNull;

  void _ensureTickerRunning() {
    if (_ticker == null && isInteractive) {
      _ticker = Timer.periodic(tickInterval, (_) {
        _frameIndex = (_frameIndex + 1) % _frames.length;
        _renderActiveSpinner();
      });
    }
  }

  void _stopTicker() {
    _ticker?.cancel();
    _ticker = null;
    _clearSpinnerLine();
  }

  void _renderActiveSpinner() {
    if (!isInteractive || _isDisposed) return;
    final active = _firstRunningTool;
    if (active == null) {
      _clearSpinnerLine();
      return;
    }

    final frame = _frames[_frameIndex];
    final coloredFrame = theme.style(frame, theme.toolSpinner);
    final elapsedStr = theme.style(
      '(${_formatElapsed(active.elapsed)})',
      theme.toolTimer,
    );
    final msg = active.currentMessage != null
        ? ' - ${active.currentMessage}'
        : '';

    final line =
        '$coloredFrame [Calling tool: ${active.toolName}$msg] $elapsedStr';
    out.write('${Ansi.carriageReturn}${Ansi.clearLine}$line');
    _hasActiveSpinnerLine = true;
  }

  void _clearSpinnerLine() {
    if (_hasActiveSpinnerLine && isTerminal) {
      out.write('${Ansi.carriageReturn}${Ansi.clearLine}');
      _hasActiveSpinnerLine = false;
    }
  }

  void _printStaticCalling(ActiveToolItem item) {
    final prefix = theme.style(
      '[Calling tool: ${item.toolName}]',
      theme.toolCalling,
    );
    out.writeln('🔧 $prefix');
  }

  void _printStatusResult(ActiveToolItem item) {
    final durationStr = item.duration != null
        ? ' (${_formatElapsed(item.duration!)})'
        : '';
    final styledDuration = theme.style(durationStr, theme.toolTimer);

    switch (item.status) {
      case ToolExecutionStatus.completed:
        final statusText = theme.style(
          '[Tool ${item.toolName} completed ✓]',
          theme.toolSuccess,
        );
        out.writeln('  $statusText$styledDuration');
        break;
      case ToolExecutionStatus.failed:
        final statusText = theme.style(
          '[Tool ${item.toolName} failed ❌]',
          theme.toolError,
        );
        out.writeln('  $statusText$styledDuration');
        break;
      case ToolExecutionStatus.cancelled:
        final statusText = theme.style(
          '[Tool ${item.toolName} cancelled]',
          theme.toolCancelled,
        );
        out.writeln('  $statusText$styledDuration');
        break;
      case ToolExecutionStatus.calling:
        break;
    }
  }

  String _formatElapsed(Duration d) {
    final seconds = d.inMilliseconds / 1000.0;
    return '${seconds.toStringAsFixed(1)}s';
  }

  String _formatArguments(Map<String, dynamic> args) {
    if (args.isEmpty) return '{}';
    final entries = args.entries
        .map((e) {
          final val = e.value is String ? "'${e.value}'" : '${e.value}';
          return '${e.key}: $val';
        })
        .join(', ');
    if (entries.length > 80) {
      return '{${entries.substring(0, 77)}...}';
    }
    return '{$entries}';
  }

  String _formatResult(dynamic result) {
    final str = result.toString().replaceAll('\n', ' ').trim();
    if (str.length > 100) {
      return '${str.substring(0, 97)}...';
    }
    return str;
  }

  /// Stops all animations and releases active resources.
  void dispose() {
    _isDisposed = true;
    _stopTicker();
    _tools.clear();
  }
}
