/// Hosted dictation channel: the daemon end of the relay wire contract.
///
/// It implements the same [DictationChannel] the local WebSocket uses, so the
/// session, the lease, the engine, and the event vocabulary are the one
/// implementation in `dictation_service.dart`. Only framing differs: audio
/// arrives as `dictation_audio` frames with a monotonic `seq`, `stop`/`cancel`
/// arrive as the ordered `dictation_end` control, and every produced event is
/// handed back to the relay for an origin-scoped delivery envelope.
///
/// This file owns no socket. The gateway platform attaches the listeners and
/// closes the shared socket on its own schedule; the channel is inert after
/// [close].
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:logging/logging.dart';

import 'dictation_session.dart';

/// Relay limits this daemon accepts, mirrored from the public wire contract
/// (`docs/technical/dictation_transport_protocol.md` §2 and §6.5).
class DictationRelayLimits {
  const DictationRelayLimits({
    this.version = 1,
    this.encoding = 'pcm16le',
    this.sampleRate = 16000,
    this.channels = 1,
    this.maxSessionSeconds = 300,
    this.maxFrameBytes = 32768,
    this.maxSessionBytes = 12582912,
    this.producerDeadline = const Duration(seconds: 3600),
  });

  final int version;
  final String encoding;
  final int sampleRate;
  final int channels;
  final int maxSessionSeconds;
  final int maxFrameBytes;
  final int maxSessionBytes;

  /// Longest a hosted producer may keep emitting after the last admitted
  /// activity. It matches the Gateway's origin-route TTL, so a retired claim can
  /// never receive a late control, progress, or transcript event.
  final Duration producerDeadline;

  Map<String, dynamic> toCapability() => {
    'version': version,
    'audio': {
      'encoding': encoding,
      'sample_rate': sampleRate,
      'channels': channels,
    },
    'max_session_seconds': maxSessionSeconds,
    'max_frame_bytes': maxFrameBytes,
    'max_session_bytes': maxSessionBytes,
  };
}

/// Composes and delivers one canonical daemon event to the origin claim.
typedef HostedDictationEmit =
    void Function(String event, Map<String, dynamic> payload);

class HostedDictationChannel implements DictationChannel {
  HostedDictationChannel({
    required this.dictationId,
    required this.requestId,
    required this.deviceId,
    required HostedDictationEmit emit,
    this.limits = const DictationRelayLimits(),
    DateTime Function()? clock,
    void Function()? onClosed,
    Timer Function(Duration, void Function())? timerFactory,
  }) : _emit = emit,
       _clock = clock ?? DateTime.now,
       _onClosed = onClosed,
       _timerFactory = timerFactory ?? _defaultTimer {
    _lastActivity = _clock();
  }

  static Timer _defaultTimer(Duration duration, void Function() callback) =>
      Timer(duration, callback);

  final String dictationId;
  final String requestId;
  final String deviceId;
  final DictationRelayLimits limits;

  final HostedDictationEmit _emit;
  final DateTime Function() _clock;
  final void Function()? _onClosed;
  final Timer Function(Duration, void Function()) _timerFactory;

  final Logger _logger = Logger('HostedDictationChannel');

  final StreamController<Uint8List> _audio =
      StreamController<Uint8List>.broadcast();

  /// Single-subscription on purpose: the session subscribes exactly once, and a
  /// start issued while the service is still attaching is buffered instead of
  /// dropped. A broadcast controller would silently lose it.
  final StreamController<DictationMessage> _commands =
      StreamController<DictationMessage>();

  late DateTime _lastActivity;
  Timer? _deadlineTimer;
  bool _started = false;
  int _expectedSeq = 0;
  int _acceptedBytes = 0;
  int _droppedFrames = 0;
  bool _closed = false;
  bool _audioRejected = false;

  @override
  Stream<Uint8List> get audio => _audio.stream;

  @override
  Stream<DictationMessage> get commands => _commands.stream;

  @override
  int get droppedFrames => _droppedFrames;

  bool get isClosed => _closed;

  /// True once the hosted producer has asked this channel to start a session.
  bool get isStarted => _started;

  /// Starts the daemon session this channel represents.
  ///
  /// It is an explicit seam because the relay composes the channel and then hands
  /// it to the one service: no second session path exists, and the service still
  /// starts the engine only from [DictationCommand.start]. The command is buffered
  /// until the service subscribes, so a start issued during attachment is never
  /// lost.
  void beginSession() {
    if (_closed || _started) return;
    _started = true;
    _armDeadline();
    if (!_commands.isClosed) {
      _commands.add(const DictationMessage(DictationCommand.start, {}));
    }
  }

  /// True once this producer may no longer emit for its origin claim.
  bool get isExpired => _clock().difference(_lastActivity) > limits.producerDeadline;

  int get droppedFrameCount => _droppedFrames;
  int get acceptedBytes => _acceptedBytes;

  /// One `dictation_audio` frame from the relay.
  ///
  /// Identity, ordering, and bounds are enforced here as well as at the
  /// Gateway: a forwarded frame that skips a `seq` ends the session with
  /// `audio_gap` instead of producing a transcript with a hole in it, and a
  /// duplicate is counted, never replayed.
  void onAudioFrame(Map<String, dynamic> frame) {
    if (_closed) return;
    if (!_matchesIdentity(frame)) return;
    if (_audioRejected) return;
    final seq = frame['seq'];
    final data = frame['data'];
    if (seq is! int) {
      _reject('invalid_request', 'dictation_audio needs an integer seq');
      return;
    }
    if (data is! List<int>) {
      // Audio is raw bytes only: never base64, never a JSON string, never a
      // container.
      _reject('invalid_request', 'dictation_audio data must be raw bytes');
      return;
    }
    if (data.length > limits.maxFrameBytes) {
      _reject('session_limit', 'dictation_audio frame exceeds the frame bound');
      return;
    }
    if (seq < _expectedSeq) {
      // A repeated or regressed frame is a counted drop, not a replay.
      _droppedFrames++;
      return;
    }
    if (seq > _expectedSeq) {
      _reject('audio_gap', 'dictation_audio skipped a sequence value');
      return;
    }
    if (_acceptedBytes + data.length > limits.maxSessionBytes) {
      _reject('session_limit', 'dictation_audio exceeded the session byte cap');
      return;
    }
    _expectedSeq++;
    _acceptedBytes += data.length;
    _touch();
    if (!_audio.isClosed) {
      _audio.add(data is Uint8List ? data : Uint8List.fromList(data));
    }
  }

  /// The ordered `dictation_end` control: the hosted carrier for `stop`/`cancel`.
  void onOrderedControl(Map<String, dynamic> control) {
    if (_closed) return;
    if (!_matchesIdentity(control)) return;
    _touch();
    final reason = control['reason'];
    final command = reason == 'stopped'
        ? DictationCommand.stop
        : DictationCommand.cancel;
    if (!_commands.isClosed) {
      _commands.add(DictationMessage(command, const {}));
    }
  }

  /// `dictation_abort` is advisory-but-authoritative: the session cancels.
  void onAbort(String reason) {
    if (_closed) return;
    _logger.info('hosted dictation abort reason=$reason');
    _touch();
    if (!_commands.isClosed) {
      _commands.add(const DictationMessage(DictationCommand.cancel, {}));
    }
  }

  @override
  void send(String event, [Map<String, dynamic> payload = const {}]) {
    if (_closed) return;
    if (isExpired) {
      // A retired claim has no recipient. Stop producing instead of writing
      // into a route that no longer exists.
      _logger.info('hosted dictation producer expired: session=$dictationId');
      _expire();
      return;
    }
    _emit(event, {
      'version': 'v1',
      'dictation_id': dictationId,
      ...payload,
    });
    _touch();
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _deadlineTimer?.cancel();
    _deadlineTimer = null;
    if (!_audio.isClosed) await _audio.close();
    if (!_commands.isClosed) await _commands.close();
    _onClosed?.call();
  }

  /// Records admitted activity and re-arms the single producer deadline.
  ///
  /// The deadline is a real timer, not a lazy check: an idle hosted session must
  /// cancel itself and release the lease even if no further frame, control, or
  /// event ever arrives.
  void _touch() {
    _lastActivity = _clock();
    _armDeadline();
  }

  void _armDeadline() {
    _deadlineTimer?.cancel();
    _deadlineTimer = null;
    if (_closed) return;
    _deadlineTimer = _timerFactory(limits.producerDeadline, () {
      _deadlineTimer = null;
      // A timer that fires after this channel closed must never end a session
      // owned by someone else.
      if (_closed) return;
      _logger.info('hosted dictation producer deadline reached');
      _expire();
    });
  }

  bool _matchesIdentity(Map<String, dynamic> frame) {
    final frameId = frame['dictation_id'];
    if (frameId is String && frameId != dictationId) return false;
    final frameRequest = frame['request_id'];
    if (frameRequest is String && frameRequest != requestId) return false;
    final frameDevice = frame['device_id'];
    if (deviceId.isNotEmpty &&
        frameDevice is String &&
        frameDevice.isNotEmpty &&
        frameDevice != deviceId) {
      return false;
    }
    return true;
  }

  void _reject(String code, String message) {
    _audioRejected = true;
    send('dictation_error', {
      'code': code,
      'message': message,
    });
    // Fail closed once, at the owner of the text: the session ends instead of
    // decoding an incomplete stream.
    if (!_commands.isClosed) {
      _commands.add(const DictationMessage(DictationCommand.cancel, {}));
    }
  }

  void _expire() {
    _deadlineTimer?.cancel();
    _deadlineTimer = null;
    if (!_commands.isClosed) {
      _commands.add(const DictationMessage(DictationCommand.cancel, {}));
    }
    unawaited(close());
  }
}
