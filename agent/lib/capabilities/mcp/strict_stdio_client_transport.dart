import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:mcp_client/mcp_client.dart';

/// STDIO MCP transport whose child receives exactly the supplied environment.
///
/// `StdioClientTransport.create` spawns with Dart's default
/// `includeParentEnvironment: true`, which merges the whole daemon
/// environment (and its credentials) into every server. This transport keeps
/// the same newline-delimited JSON framing but never inherits.
class StrictStdioClientTransport implements ClientTransport {
  StrictStdioClientTransport._(this._process) {
    _subscriptions
      ..add(
        _process.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .where((line) => line.isNotEmpty)
            .listen(
              (line) {
                final Object? message;
                try {
                  message = jsonDecode(line);
                } on FormatException {
                  return;
                }
                if (!_messages.isClosed) _messages.add(message);
              },
              onError: _fail,
              onDone: _closed,
            ),
      )
      ..add(_process.stderr.drain<void>().asStream().listen((_) {}));
    unawaited(_process.exitCode.then((_) => _closed()));
    unawaited(_process.stdin.done.catchError((_) {}));
  }

  /// Starts [command] with exactly [environment].
  static Future<StrictStdioClientTransport> start({
    required String command,
    List<String> arguments = const [],
    required Map<String, String> environment,
    String? workingDirectory,
  }) async {
    final process = await Process.start(
      command,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      includeParentEnvironment: false,
    );
    return StrictStdioClientTransport._(process);
  }

  final Process _process;
  final _messages = StreamController<dynamic>.broadcast();
  final _closeCompleter = Completer<void>();
  final _subscriptions = <StreamSubscription<dynamic>>[];
  final _queue = Queue<String>();
  bool _sending = false;

  @override
  Stream<dynamic> get onMessage => _messages.stream;

  @override
  Future<void> get onClose => _closeCompleter.future;

  @override
  void send(dynamic message) {
    _queue.add(jsonEncode(message));
    if (_sending) return;
    _sending = true;
    _drain();
  }

  void _drain() {
    if (_queue.isEmpty) {
      _sending = false;
      return;
    }
    try {
      _process.stdin.writeln(_queue.removeFirst());
    } catch (error) {
      _sending = false;
      _fail(error);
      return;
    }
    Timer(const Duration(milliseconds: 10), _drain);
  }

  void _fail(Object error) {
    if (!_closeCompleter.isCompleted) _closeCompleter.completeError(error);
    _cleanup();
  }

  void _closed() {
    if (!_closeCompleter.isCompleted) _closeCompleter.complete();
    _cleanup();
  }

  void _cleanup() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    if (!_messages.isClosed) unawaited(_messages.close());
    _process.kill();
  }

  @override
  void close() => _cleanup();
}
