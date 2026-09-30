import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'repl_history.dart';

/// Key event types recognized by the interactive line editor.
enum KeyType {
  char,
  enter,
  backspace,
  delete,
  up,
  down,
  left,
  right,
  home,
  end,
  ctrlC,
  ctrlD,
  ctrlU,
  ctrlK,
  ctrlL,
  eof,
}

/// Represents a single decoded keystroke.
class KeyStroke {
  final KeyType type;
  final String char;

  const KeyStroke(this.type, [this.char = '']);

  @override
  String toString() => 'KeyStroke($type, "$char")';
}

/// Abstract contract for reading interactive lines.
abstract class ReplLineReader {
  /// Reads a single line with the given [prompt].
  ///
  /// Returns `null` on EOF or when Ctrl+D is pressed on an empty buffer.
  Future<String?> readLine({String prompt = ''});

  /// Interactively selects an option from [options] with Up/Down arrow keys.
  ///
  /// Returns the selected index (0-based).
  Future<int> selectOption({
    required String title,
    required List<String> options,
    int defaultIndex = 0,
    Map<String, int>? shortcutMap,
  });

  /// Optional direct free-form input captured during selection.
  String? get lastCustomInput => null;

  /// Clears any queued keystrokes and pending input buffers.
  void flush() {}

  /// Disposes resources held by the reader.
  Future<void> dispose();
}

/// Full interactive terminal line reader supporting raw mode, cursor navigation,
/// in-place line editing, command history, and multi-line continuation.
class TerminalReplLineReader implements ReplLineReader {
  final Stream<List<int>>? _inputByteStream;
  final Stream<String>? _inputStringStream;
  final StringSink _output;
  final ReplHistory history;
  final bool isTerminal;
  final bool enableAnsi;

  StreamSubscription<dynamic>? _inputSub;
  final _keyQueue = <KeyStroke>[];
  final _waiters = <Completer<KeyStroke>>[];
  String _pendingBuffer = '';
  bool _isDisposed = false;
  bool _terminalModesConfigured = false;
  bool _originalLineMode = true;
  bool _originalEchoMode = true;
  bool _lastWasCr = false;
  bool _isInBracketedPaste = false;

  @override
  String? get lastCustomInput => null;

  @override
  void flush() {
    _keyQueue.clear();
    _pendingBuffer = '';
    _lastWasCr = false;
    _isInBracketedPaste = false;
  }

  TerminalReplLineReader({
    Stream<List<int>>? inputByteStream,
    Stream<String>? inputStringStream,
    StringSink? output,
    ReplHistory? history,
    bool? isTerminal,
    bool? enableAnsi,
  }) : _inputByteStream = inputByteStream,
       _inputStringStream = inputStringStream,
       _output = output ?? stdout,
       history = history ?? ReplHistory(),
       isTerminal =
           isTerminal ??
           (inputByteStream == null &&
               inputStringStream == null &&
               stdin.hasTerminal),
       enableAnsi =
           enableAnsi ??
           ((output == null || identical(output, stdout)) &&
               stdout.hasTerminal) {
    _configureTerminalRawMode();
    _initInputStream();
  }

  void _initInputStream() {
    if (_inputStringStream != null) {
      _inputSub = _inputStringStream.listen(
        _onStringChunk,
        onDone: _onEof,
        onError: (_) => _onEof(),
        cancelOnError: false,
      );
    } else {
      final stream = _inputByteStream ?? stdin;
      _inputSub = stream
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(
            _onStringChunk,
            onDone: _onEof,
            onError: (_) => _onEof(),
            cancelOnError: false,
          );
    }
  }

  void _configureTerminalRawMode() {
    if (!isTerminal || _terminalModesConfigured) return;
    try {
      if (stdin.hasTerminal) {
        _originalLineMode = stdin.lineMode;
        _originalEchoMode = stdin.echoMode;
        stdin.lineMode = false;
        stdin.echoMode = false;
        _terminalModesConfigured = true;
        if (enableAnsi) {
          _output.write('\x1b[?2004h');
        }
      }
    } catch (_) {}
  }

  void _restoreTerminalMode() {
    if (!isTerminal || !_terminalModesConfigured) return;
    try {
      if (stdin.hasTerminal) {
        if (enableAnsi) {
          _output.write('\x1b[?2004l');
        }
        stdin.lineMode = _originalLineMode;
        stdin.echoMode = _originalEchoMode;
        _terminalModesConfigured = false;
      }
    } catch (_) {}
  }

  void _onStringChunk(String chunk) {
    _pendingBuffer += chunk;
    _parsePendingKeys();
  }

  void _parsePendingKeys() {
    while (_pendingBuffer.isNotEmpty) {
      final code = _pendingBuffer.codeUnitAt(0);

      // 1. Bracketed paste mode handling
      if (_isInBracketedPaste) {
        if (_pendingBuffer.startsWith('\x1b[201~')) {
          _isInBracketedPaste = false;
          _pendingBuffer = _pendingBuffer.substring(6);
          continue;
        }
        if (_pendingBuffer.startsWith('\x1b') && _pendingBuffer.length < 6) {
          // Incomplete paste end escape sequence: wait for remaining bytes
          break;
        }
        if (code == 13) {
          _enqueue(const KeyStroke(KeyType.char, '\n'));
          if (_pendingBuffer.length > 1 && _pendingBuffer.codeUnitAt(1) == 10) {
            _pendingBuffer = _pendingBuffer.substring(2);
          } else {
            _pendingBuffer = _pendingBuffer.substring(1);
          }
          continue;
        }
        if (code == 10) {
          _enqueue(const KeyStroke(KeyType.char, '\n'));
          _pendingBuffer = _pendingBuffer.substring(1);
          continue;
        }
        final char = _pendingBuffer.substring(0, 1);
        _enqueue(KeyStroke(KeyType.char, char));
        _pendingBuffer = _pendingBuffer.substring(1);
        continue;
      }

      // 2. Escape sequences
      if (code == 27) {
        if (_pendingBuffer.length == 1) {
          // Incomplete escape sequence: wait for more characters
          break;
        }

        if (_pendingBuffer.length >= 2 && _pendingBuffer[1] == '[') {
          if (_pendingBuffer.length < 3) {
            break;
          }

          // Bracketed paste markers
          if (_pendingBuffer.startsWith('\x1b[200~')) {
            _isInBracketedPaste = true;
            _pendingBuffer = _pendingBuffer.substring(6);
            continue;
          }
          if (_pendingBuffer.startsWith('\x1b[201~')) {
            _isInBracketedPaste = false;
            _pendingBuffer = _pendingBuffer.substring(6);
            continue;
          }
          if (_pendingBuffer.length < 6 &&
              (_pendingBuffer.startsWith('\x1b[200') ||
                  _pendingBuffer.startsWith('\x1b[20') ||
                  _pendingBuffer.startsWith('\x1b[2'))) {
            break;
          }

          final third = _pendingBuffer[2];
          if (third == 'A') {
            _lastWasCr = false;
            _enqueue(const KeyStroke(KeyType.up));
            _pendingBuffer = _pendingBuffer.substring(3);
            continue;
          } else if (third == 'B') {
            _lastWasCr = false;
            _enqueue(const KeyStroke(KeyType.down));
            _pendingBuffer = _pendingBuffer.substring(3);
            continue;
          } else if (third == 'C') {
            _lastWasCr = false;
            _enqueue(const KeyStroke(KeyType.right));
            _pendingBuffer = _pendingBuffer.substring(3);
            continue;
          } else if (third == 'D') {
            _lastWasCr = false;
            _enqueue(const KeyStroke(KeyType.left));
            _pendingBuffer = _pendingBuffer.substring(3);
            continue;
          } else if (third == 'H') {
            _lastWasCr = false;
            _enqueue(const KeyStroke(KeyType.home));
            _pendingBuffer = _pendingBuffer.substring(3);
            continue;
          } else if (third == 'F') {
            _lastWasCr = false;
            _enqueue(const KeyStroke(KeyType.end));
            _pendingBuffer = _pendingBuffer.substring(3);
            continue;
          } else if (third == '3') {
            if (_pendingBuffer.length < 4) break;
            if (_pendingBuffer[3] == '~') {
              _lastWasCr = false;
              _enqueue(const KeyStroke(KeyType.delete));
              _pendingBuffer = _pendingBuffer.substring(4);
              continue;
            }
          } else if (third == '1') {
            if (_pendingBuffer.length < 4) break;
            if (_pendingBuffer[3] == '~') {
              _lastWasCr = false;
              _enqueue(const KeyStroke(KeyType.home));
              _pendingBuffer = _pendingBuffer.substring(4);
              continue;
            }
          } else if (third == '4') {
            if (_pendingBuffer.length < 4) break;
            if (_pendingBuffer[3] == '~') {
              _lastWasCr = false;
              _enqueue(const KeyStroke(KeyType.end));
              _pendingBuffer = _pendingBuffer.substring(4);
              continue;
            }
          }

          // Variable-length CSI sequence termination check (terminate on ASCII 64..126)
          int end = 2;
          while (end < _pendingBuffer.length) {
            final c = _pendingBuffer.codeUnitAt(end);
            if (c >= 64 && c <= 126) {
              end++;
              break;
            }
            end++;
          }
          _pendingBuffer = _pendingBuffer.substring(end);
          _lastWasCr = false;
          continue;
        }

        // Unknown escape sequence: consume the ESC byte
        _pendingBuffer = _pendingBuffer.substring(1);
        _lastWasCr = false;
        continue;
      }

      // 3. Control characters and Enter
      if (code == 13) {
        _lastWasCr = true;
        _enqueue(const KeyStroke(KeyType.enter));
        _pendingBuffer = _pendingBuffer.substring(1);
        continue;
      }
      if (code == 10) {
        if (_lastWasCr) {
          _lastWasCr = false;
          _pendingBuffer = _pendingBuffer.substring(1);
          continue; // Discard \n immediately following \r
        }
        _lastWasCr = false;
        _enqueue(const KeyStroke(KeyType.enter));
        _pendingBuffer = _pendingBuffer.substring(1);
        continue;
      }
      _lastWasCr = false;

      if (code == 127 || code == 8) {
        _enqueue(const KeyStroke(KeyType.backspace));
      } else if (code == 3) {
        _enqueue(const KeyStroke(KeyType.ctrlC));
      } else if (code == 4) {
        _enqueue(const KeyStroke(KeyType.ctrlD));
      } else if (code == 1) {
        _enqueue(const KeyStroke(KeyType.home));
      } else if (code == 5) {
        _enqueue(const KeyStroke(KeyType.end));
      } else if (code == 21) {
        _enqueue(const KeyStroke(KeyType.ctrlU));
      } else if (code == 11) {
        _enqueue(const KeyStroke(KeyType.ctrlK));
      } else if (code == 12) {
        _enqueue(const KeyStroke(KeyType.ctrlL));
      } else {
        // Regular character (or multi-byte UTF-16 code point)
        final char = _pendingBuffer.substring(0, 1);
        _enqueue(KeyStroke(KeyType.char, char));
      }
      _pendingBuffer = _pendingBuffer.substring(1);
    }
  }

  void _enqueue(KeyStroke stroke) {
    if (_waiters.isNotEmpty) {
      final waiter = _waiters.removeAt(0);
      waiter.complete(stroke);
    } else {
      _keyQueue.add(stroke);
    }
  }

  void _onEof() {
    _enqueue(const KeyStroke(KeyType.eof));
  }

  Future<KeyStroke> _nextKey() {
    if (_keyQueue.isNotEmpty) {
      return Future.value(_keyQueue.removeAt(0));
    }
    final completer = Completer<KeyStroke>();
    _waiters.add(completer);
    return completer.future;
  }

  @override
  Future<String?> readLine({String prompt = ''}) async {
    if (_isDisposed) return null;

    _configureTerminalRawMode();
    final multiLineSegments = <String>[];
    String currentPrompt = prompt;

    while (true) {
      final lineResult = await _readSingleBufferLine(currentPrompt);
      if (lineResult == null) {
        return multiLineSegments.isEmpty ? null : multiLineSegments.join('\n');
      }

      // Check if line ends with a continuation backslash `\`
      if (lineResult.endsWith('\\')) {
        final content = lineResult
            .substring(0, lineResult.length - 1)
            .trimRight();
        multiLineSegments.add(content);
        currentPrompt = enableAnsi ? '\x1b[90m... \x1b[0m' : '... ';
        continue;
      }

      multiLineSegments.add(lineResult);
      break;
    }

    return multiLineSegments.join('\n');
  }

  Future<String?> _readSingleBufferLine(String prompt) async {
    final buffer = <String>[];
    int cursor = 0;

    _output.write(prompt);

    void redraw() {
      if (!enableAnsi) return;
      final text = buffer.join();
      if (text.contains('\n')) {
        final beforeCursor = buffer.sublist(0, cursor).join();
        final lineIndex = '\n'.allMatches(beforeCursor).length;
        final lines = text.split('\n');
        final currentLine = lineIndex < lines.length ? lines[lineIndex] : '';
        final linePrefix = lineIndex == 0 ? prompt : '\x1b[90m... \x1b[0m';
        _output.write('\r\x1b[K$linePrefix$currentLine');
        return;
      }
      // Move to start of line, clear to end of line, re-print prompt and text
      _output.write('\r\x1b[K$prompt$text');
      // If cursor is not at the end, move it backward to proper position
      final delta = buffer.length - cursor;
      if (delta > 0) {
        _output.write('\x1b[${delta}D');
      }
    }

    while (true) {
      final key = await _nextKey();

      switch (key.type) {
        case KeyType.enter:
          _output.writeln();
          return buffer.join();

        case KeyType.eof:
          if (buffer.isEmpty) {
            return null;
          }
          _output.writeln();
          return buffer.join();

        case KeyType.ctrlD:
          if (buffer.isEmpty) {
            _output.writeln();
            return null;
          }
          if (cursor < buffer.length) {
            buffer.removeAt(cursor);
            redraw();
          }
          break;

        case KeyType.ctrlC:
          _output.writeln('^C');
          buffer.clear();
          cursor = 0;
          return '';

        case KeyType.backspace:
          if (cursor > 0) {
            final wasAtEnd = (cursor == buffer.length);
            cursor--;
            buffer.removeAt(cursor);
            if (wasAtEnd) {
              _output.write('\b \b');
            } else {
              redraw();
            }
          }
          break;

        case KeyType.delete:
          if (cursor < buffer.length) {
            buffer.removeAt(cursor);
            redraw();
          }
          break;

        case KeyType.left:
          if (cursor > 0) {
            cursor--;
            if (enableAnsi) {
              _output.write('\x1b[1D');
            } else {
              _output.write('\b');
            }
          }
          break;

        case KeyType.right:
          if (cursor < buffer.length) {
            cursor++;
            if (enableAnsi) {
              _output.write('\x1b[1C');
            }
          }
          break;

        case KeyType.home:
          cursor = 0;
          redraw();
          break;

        case KeyType.end:
          cursor = buffer.length;
          redraw();
          break;

        case KeyType.up:
          final previousEntry = history.previous(buffer.join());
          if (previousEntry != null) {
            buffer.clear();
            buffer.addAll(previousEntry.split(''));
            cursor = buffer.length;
            redraw();
          }
          break;

        case KeyType.down:
          final nextEntry = history.next();
          if (nextEntry != null) {
            buffer.clear();
            buffer.addAll(nextEntry.split(''));
            cursor = buffer.length;
            redraw();
          }
          break;

        case KeyType.ctrlU:
          // Kill line from start to cursor
          if (cursor > 0) {
            buffer.removeRange(0, cursor);
            cursor = 0;
            redraw();
          }
          break;

        case KeyType.ctrlK:
          // Kill line from cursor to end
          if (cursor < buffer.length) {
            buffer.removeRange(cursor, buffer.length);
            redraw();
          }
          break;

        case KeyType.ctrlL:
          // Clear screen and redraw
          if (enableAnsi) {
            _output.write('\x1b[2J\x1b[H');
          }
          redraw();
          break;

        case KeyType.char:
          if (key.char == '\n') {
            buffer.insert(cursor, '\n');
            cursor++;
            if (enableAnsi) {
              _output.write('\n\x1b[90m... \x1b[0m');
            } else {
              _output.write('\n... ');
            }
          } else if (cursor == buffer.length) {
            buffer.add(key.char);
            cursor++;
            _output.write(key.char);
          } else {
            buffer.insert(cursor, key.char);
            cursor++;
            redraw();
          }
          break;
      }
    }
  }

  @override
  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;
    _restoreTerminalMode();
    await _inputSub?.cancel();
    _inputSub = null;
    for (final waiter in _waiters) {
      if (!waiter.isCompleted) {
        waiter.complete(const KeyStroke(KeyType.eof));
      }
    }
    _waiters.clear();
  }

  @override
  Future<int> selectOption({
    required String title,
    required List<String> options,
    int defaultIndex = 0,
    Map<String, int>? shortcutMap,
  }) async {
    if (options.isEmpty) return 0;
    var selectedIndex = defaultIndex.clamp(0, options.length - 1);

    if (!isTerminal || !enableAnsi) {
      _output.writeln(title);
      for (int i = 0; i < options.length; i++) {
        _output.writeln('  ${i + 1}. ${options[i]}');
      }
      while (true) {
        final prompt =
            'Select [1-${options.length}] (default: ${defaultIndex + 1}): ';
        final input = await readLine(prompt: prompt);
        if (input == null || input.trim().isEmpty) return defaultIndex;
        final trimmed = input.trim().toLowerCase();
        if (shortcutMap != null && shortcutMap.containsKey(trimmed)) {
          return shortcutMap[trimmed]!;
        }
        final parsed = int.tryParse(trimmed);
        if (parsed != null && parsed >= 1 && parsed <= options.length) {
          return parsed - 1;
        }
        _output.writeln('Invalid choice.');
      }
    }

    _output.writeln(title);

    // Hide cursor during arrow selection like setup
    _output.write('\x1b[?25l');

    void render() {
      _output.write('\r');
      for (int i = 0; i < options.length; i++) {
        _output.write('\x1b[F\x1b[K');
      }
      for (int i = 0; i < options.length; i++) {
        if (i == selectedIndex) {
          _output.writeln('\x1b[36m➔ \x1b[1m${options[i]}\x1b[0m');
        } else {
          _output.writeln('  ${options[i]}');
        }
      }
    }

    // Allocate blank lines for options
    for (int i = 0; i < options.length; i++) {
      _output.writeln();
    }
    render();

    try {
      while (true) {
        final key = await _nextKey();
        if (key.type == KeyType.enter) {
          break;
        } else if (key.type == KeyType.up) {
          if (selectedIndex > 0) {
            selectedIndex--;
            render();
          }
        } else if (key.type == KeyType.down) {
          if (selectedIndex < options.length - 1) {
            selectedIndex++;
            render();
          }
        } else if (key.type == KeyType.char) {
          final charLower = key.char.toLowerCase();
          if (shortcutMap != null && shortcutMap.containsKey(charLower)) {
            selectedIndex = shortcutMap[charLower]!;
            render();
            break;
          }
          final num = int.tryParse(key.char);
          if (num != null && num >= 1 && num <= options.length) {
            selectedIndex = num - 1;
            render();
            break;
          }
        } else if (key.type == KeyType.ctrlC ||
            key.type == KeyType.eof ||
            key.type == KeyType.ctrlD) {
          break;
        }
      }
    } finally {
      // Restore cursor
      _output.write('\x1b[?25h');
    }

    return selectedIndex;
  }
}

/// Mock line reader for testing interactive sessions deterministically.
class MockReplLineReader implements ReplLineReader {
  final List<String?> responses;
  final List<String> promptsShown = [];
  final ReplHistory history;
  int _index = 0;
  String? _lastCustomInput;

  MockReplLineReader(this.responses, {ReplHistory? history})
    : history = history ?? ReplHistory();

  @override
  String? get lastCustomInput => _lastCustomInput;

  @override
  void flush() {}

  @override
  Future<String?> readLine({String prompt = ''}) async {
    promptsShown.add(prompt);
    if (_index < responses.length) {
      return responses[_index++];
    }
    return null;
  }

  @override
  Future<int> selectOption({
    required String title,
    required List<String> options,
    int defaultIndex = 0,
    Map<String, int>? shortcutMap,
  }) async {
    promptsShown.add(title);
    if (_index < responses.length) {
      final rawResp = responses[_index++] ?? '';
      final resp = rawResp.trim().toLowerCase();
      if (shortcutMap != null && shortcutMap.containsKey(resp)) {
        return shortcutMap[resp]!;
      }
      final parsed = int.tryParse(resp);
      if (parsed != null && parsed >= 1 && parsed <= options.length) {
        return parsed - 1;
      }
      _lastCustomInput = rawResp;
      return -1;
    }
    return defaultIndex;
  }

  @override
  Future<void> dispose() async {}
}
