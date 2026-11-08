/// One dictation session: client transport in, local transcripts out.
///
/// The client only carries microphone PCM and receives transcript events. All
/// recognition happens here, in the daemon.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:logging/logging.dart';

import 'stt_engine.dart';
import 'stt_types.dart';

/// Commands a client may send over the dictation socket.
enum DictationCommand {
  start,
  stop,
  cancel,
  status,
  install,
  select,
  prepareRuntime;

  static DictationCommand? parse(String? name) {
    for (final command in DictationCommand.values) {
      if (command.name == name) return command;
    }
    return null;
  }
}

class DictationMessage {
  const DictationMessage(this.command, this.payload);
  final DictationCommand command;
  final Map<String, dynamic> payload;

  String? get modelId {
    final value = payload['model_id'];
    return value is String && value.isNotEmpty ? value : null;
  }
}

/// The transport contract a dictation session depends on.
///
/// Abstracted so the session can be exercised without a real socket; the
/// production implementation is [WebSocketDictationChannel].
abstract class DictationChannel {
  Stream<Uint8List> get audio;
  Stream<DictationMessage> get commands;
  void send(String event, [Map<String, dynamic> payload = const {}]);
  Future<void> close();

  /// Frames this channel dropped before they reached the engine.
  ///
  /// The local channel forwards what the socket delivered, so it drops nothing;
  /// the hosted channel drops duplicates and reports them in `dictation_done`
  /// exactly like the engine's own counted drops.
  int get droppedFrames => 0;
}

/// Binary frames are microphone audio; text frames are JSON commands.
class WebSocketDictationChannel implements DictationChannel {
  WebSocketDictationChannel(this._socket) {
    _subscription = _socket.listen(
      (message) {
        if (message is List<int>) {
          _audio.add(
            message is Uint8List ? message : Uint8List.fromList(message),
          );
          return;
        }
        if (message is String) {
          try {
            final decoded = jsonDecode(message);
            if (decoded is! Map) return;
            final command = DictationCommand.parse(decoded['event'] as String?);
            if (command == null) return;
            _commands.add(
              DictationMessage(
                command,
                Map<String, dynamic>.from(decoded)..remove('event'),
              ),
            );
          } on FormatException {
            // Malformed control frames never reach the engine.
          }
        }
      },
      onDone: () {
        _audio.close();
        _commands.close();
      },
      onError: (Object error) {
        _audio.addError(error);
        _commands.addError(error);
      },
      cancelOnError: false,
    );
  }

  final WebSocket _socket;
  final StreamController<Uint8List> _audio =
      StreamController<Uint8List>.broadcast();
  final StreamController<DictationMessage> _commands =
      StreamController<DictationMessage>.broadcast();
  late final StreamSubscription _subscription;
  bool _closed = false;

  @override
  int get droppedFrames => 0;

  @override
  Stream<Uint8List> get audio => _audio.stream;

  @override
  Stream<DictationMessage> get commands => _commands.stream;

  @override
  void send(String event, [Map<String, dynamic> payload = const {}]) {
    if (_closed) return;
    _socket.add(jsonEncode({'event': event, ...payload}));
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _subscription.cancel();
    await _audio.close();
    await _commands.close();
    try {
      await _socket.close();
    } on Object {
      // The peer may already be gone.
    }
  }
}

/// Binds one transport to one engine session.
class DictationSession {
  DictationSession({
    required this.transport,
    required this.engine,
    required this.modelId,
    this.maxSessionDuration = const Duration(minutes: 5),
    this.onRelease,
  });

  final DictationChannel transport;
  final SttEngine engine;
  final String modelId;
  final Duration maxSessionDuration;

  /// Called instead of disposing the engine when the session ends.
  ///
  /// The service parks the recogniser for a while so the next session does not
  /// pay the model load (Metal shader compilation alone is seconds). When null
  /// the session owns the engine and frees it, which is the old behaviour.
  final Future<void> Function(SttEngine engine)? onRelease;

  final Logger _logger = Logger('DictationSession');

  StreamSubscription<Uint8List>? _audioSubscription;
  StreamSubscription<DictationMessage>? _commandSubscription;
  StreamSubscription<SttEvent>? _eventSubscription;
  final Stopwatch _sessionClock = Stopwatch();

  bool _started = false;
  bool _closing = false;
  int _segments = 0;

  /// The in-flight termination.
  ///
  /// A second `close()` (socket teardown racing a `stop` command) must observe
  /// the same termination instead of returning early, so a caller that awaits it
  /// releases the lease only after the engine really finished draining.
  Future<void>? _termination;

  /// Starts forwarding audio and publishing transcript events.
  Future<void> start() async {
    if (_started || _closing) return;
    _started = true;
    _sessionClock.start();

    // Replay readiness: the recognizer is loaded before this session attached
    // its listener, so the client's loading state would otherwise never end.
    final alreadyReady = engine.ready;
    if (alreadyReady != null) {
      transport.send('dictation_ready', {
        'model_id': alreadyReady.modelId,
        'load_ms': alreadyReady.loadMs,
      });
    }

    _eventSubscription = engine.events.listen((event) {
      switch (event) {
        case SttReadyEvent():
          transport.send('dictation_ready', {
            'model_id': event.modelId,
            'load_ms': event.loadMs,
          });
        case SttPartialEvent():
          transport.send('dictation_partial', {
            'seq': event.seq,
            'text': event.text,
          });
        case SttFinalEvent():
          _segments++;
          _logger.info(
            'dictation final: audio_ms=${event.audioMs} '
            'decode_ms=${event.decodeMs} model=$modelId',
          );
          transport.send('dictation_final', {
            'seq': event.seq,
            'text': event.text,
            'audio_ms': event.audioMs,
            'decode_ms': event.decodeMs,
          });
        case SttDoneEvent():
          final dropped = event.droppedChunks + transport.droppedFrames;
          _logger.info(
            'dictation drained: segments=$_segments '
            'dropped=$dropped model=$modelId',
          );
          transport.send('dictation_done', {
            'segments': _segments,
            'dropped_chunks': dropped,
          });
        case SttErrorEvent():
          // Codes and counts only: never transcript text or audio.
          _logger.warning(
            'dictation error code=${event.error.code} model=$modelId',
          );
          transport.send('dictation_error', {
            'code': event.error.code,
            'message': event.error.message,
          });
      }
    });

    _audioSubscription = transport.audio.listen(
      (pcm16) {
        if (_closing) return;
        if (_sessionClock.elapsed > maxSessionDuration) {
          unawaited(_stopWithLimit());
          return;
        }
        engine.acceptAudio(pcm16);
      },
      onError: (Object error) {
        _logger.warning('dictation audio stream error: $error');
      },
    );

    _commandSubscription = transport.commands.listen((message) {
      switch (message.command) {
        case DictationCommand.stop:
          unawaited(_stop(drain: true));
        case DictationCommand.cancel:
          unawaited(_stop(drain: false));
        default:
          // start/install/select are owned by the caller's service layer.
          break;
      }
    });
  }

  Future<void> _stopWithLimit() async {
    transport.send('dictation_error', {
      'code': 'session_limit',
      'message': 'dictation stopped at the ${maxSessionDuration.inMinutes} min limit',
    });
    await _stop(drain: false);
  }

  Future<void> _stop({required bool drain}) {
    final existing = _termination;
    if (existing != null) return existing;
    final termination = _stopOnce(drain: drain);
    _termination = termination;
    return termination;
  }

  Future<void> _stopOnce({required bool drain}) async {
    _closing = true;
    _sessionClock.stop();
    if (drain) {
      await engine.finish();
    } else {
      await engine.cancel();
    }
    await _audioSubscription?.cancel();
    _audioSubscription = null;
    await _commandSubscription?.cancel();
    _commandSubscription = null;
    final release = onRelease;
    if (release != null) {
      await release(engine);
    } else {
      await engine.dispose();
    }
    await _eventSubscription?.cancel();
    _eventSubscription = null;
    await transport.close();
  }

  Future<void> close() => _stop(drain: false);
}
