import 'dart:async';
import 'dart:math' as math;

import 'package:sanad_client/features/dictation/domain/dictation_audio_capture.dart';

/// Driver-only capture plumbing for real Client acceptance runs.
///
/// It is installed **only** from `driver_main.dart`, before `AppProviders` is
/// built, and it defaults to the production microphone capture. An acceptance
/// run may arm a bounded PCM fixture while no session is active; the fixture then
/// feeds the existing `DictationCapture` contract, so the same cubit, resolver,
/// transport, daemon, and insertion path run with no microphone input.
///
/// Nothing here logs, stores, or returns audio: the fixture holds caller-supplied
/// bytes in memory and the driver surface reports only counts and phases.
class DriverDictationCapture implements DictationCapture {
  DriverDictationCapture({DictationCapture Function()? realCapture})
      : _realFactory = realCapture ?? DictationAudioCapture.new;

  final DictationCapture Function() _realFactory;
  DictationCapture? _real;
  DictationPcmFixture? _armed;
  int _activeSessions = 0;

  /// The capture this session actually acquired.
  ///
  /// `stop()` must release only what `start()` took: a start that threw (no
  /// microphone, no permission) must not make the stop path acquire the device a
  /// second time, which is how a failed start turned into an escaping error
  /// instead of a reported one.
  DictationCapture? _sessionCapture;

  bool get isSessionActive => _activeSessions > 0;

  /// The fixture that is armed for the next session, or null when the real
  /// microphone is in use. Reading it is safe mid-session; arming is not.
  DictationPcmFixture? get armedFixture => _armed;

  /// Arms [fixture] for the next session. A session that is already running must
  /// finish first: swapping the source mid-utterance would mix two audio origins
  /// in one daemon decode.
  void arm(DictationPcmFixture fixture) {
    if (isSessionActive) {
      throw StateError('cannot arm a fixture during an active dictation session');
    }
    _armed = fixture;
  }

  /// Returns to the production microphone for the next session.
  void disarm() {
    if (isSessionActive) {
      throw StateError('cannot disarm during an active dictation session');
    }
    _armed = null;
  }

  DictationCapture get _delegate =>
      _armed?.capture ?? (_real ??= _realFactory());

  @override
  Future<bool> hasPermission() async {
    if (_armed != null) return true;
    return _delegate.hasPermission();
  }

  @override
  Future<Stream<List<int>>> start() async {
    final delegate = _delegate;
    _activeSessions++;
    _sessionCapture = delegate;
    final StreamSubscription<List<int>> subscription;
    try {
      final source = await delegate.start();
      late StreamController<List<int>> controller;
      StreamSubscription<List<int>>? attached;
      var settled = false;
      void settle() {
        if (settled) return;
        settled = true;
        _activeSessions = math.max(0, _activeSessions - 1);
      }

      controller = StreamController<List<int>>(
        onCancel: () {
          // Cancelling the cubit's subscription is the stop path for a fixture:
          // it must release the session and detach the source immediately so no
          // late chunk can be delivered into a closed session.
          settle();
          return attached?.cancel();
        },
      );
      subscription = source.listen(
        (chunk) {
          if (!controller.isClosed) controller.add(chunk);
        },
        onError: (Object error, StackTrace stackTrace) {
          settle();
          if (!controller.isClosed) controller.addError(error, stackTrace);
        },
        onDone: () {
          settle();
          if (!controller.isClosed) unawaited(controller.close());
        },
      );
      attached = subscription;
      return controller.stream;
    } on Object {
      _activeSessions = math.max(0, _activeSessions - 1);
      rethrow;
    }
  }

  @override
  Future<void> stop() async {
    final delegate = _sessionCapture;
    _sessionCapture = null;
    _activeSessions = 0;
    if (delegate == null) return;
    await delegate.stop();
  }

  @override
  Future<void> dispose() async {
    _activeSessions = 0;
    _sessionCapture = null;
    _armed = null;
    await _real?.dispose();
    _real = null;
  }
}

/// A deterministic, bounded 16 kHz mono PCM16LE stream.
/// The bytes are supplied by the driver caller, so an acceptance run can feed a
/// real speech sample through the production capture abstraction. Every bound is
/// derived from the existing session contract: 16 kHz mono PCM16 is 32 bytes per
/// millisecond, and this seam stops well below the five-minute utterance cap so
/// one leg can never reach the daemon's own limit.
class _FixtureCapture implements DictationCapture {
  _FixtureCapture(this._fixture);

  final DictationPcmFixture _fixture;

  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<Stream<List<int>>> start() async => _fixture.start();

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}

class DictationPcmFixture {
  DictationPcmFixture({
    required List<int> pcm16le,
    this.chunkBytes = defaultChunkBytes,
    this.chunkInterval = defaultChunkInterval,
  }) : pcm16le = List<int>.unmodifiable(pcm16le) {
    if (this.pcm16le.isEmpty || this.pcm16le.length.isOdd) {
      throw ArgumentError('fixture audio must be non-empty PCM16LE (even bytes)');
    }
    if (this.pcm16le.length > maxBytes) {
      throw ArgumentError(
        'fixture audio exceeds the ${maxDuration.inSeconds}s acceptance bound',
      );
    }
    if (chunkBytes.isOdd ||
        chunkBytes < minChunkBytes ||
        chunkBytes > maxChunkBytes) {
      throw ArgumentError(
        'chunkBytes must be even and within $minChunkBytes..$maxChunkBytes',
      );
    }
    if (chunkInterval < minChunkInterval ||
        chunkInterval > maxChunkInterval) {
      throw ArgumentError(
        'chunkInterval must be within '
        '${minChunkInterval.inMilliseconds}..${maxChunkInterval.inMilliseconds}ms',
      );
    }
  }

  static const int sampleRate = 16000;
  static const int channels = 1;
  static const int bytesPerSample = 2;
  static const int bytesPerMillisecond = sampleRate * channels * bytesPerSample ~/ 1000;
  static const Duration maxDuration = Duration(seconds: 60);
  static const int maxBytes = 1920000;
  static const int minChunkBytes = 320;
  static const int maxChunkBytes = 32000;
  static const int defaultChunkBytes = 3200;
  static const Duration minChunkInterval = Duration(milliseconds: 10);
  static const Duration maxChunkInterval = Duration(milliseconds: 500);
  static const Duration defaultChunkInterval = Duration(milliseconds: 100);

  final List<int> pcm16le;
  final int chunkBytes;
  final Duration chunkInterval;

  bool _started = false;
  int _emittedBytes = 0;

  /// The capture adapter this fixture exposes to the production seam.
  ///
  /// The fixture is a bounded source, not a device: this adapter keeps the
  /// `DictationCapture` contract without pretending a microphone is present.
  late final DictationCapture capture = _FixtureCapture(this);

  /// Total audio this fixture will emit, so a caller can bound its wait.
  Duration get duration =>
      Duration(milliseconds: pcm16le.length ~/ bytesPerMillisecond);

  int get emittedBytes => _emittedBytes;

  bool get isFinished => _started && _emittedBytes >= pcm16le.length;

  /// Starts one pass over the fixture.
  ///
  /// A fixture is single-use: reusing it would replay the same utterance into a
  /// new dictation session, which is exactly the stale-frame case this seam must
  /// never create. Build a new fixture for the next leg.
  Stream<List<int>> start() {
    if (_started) {
      throw StateError('a fixture may only be started once');
    }
    _started = true;
    late StreamController<List<int>> controller;
    Timer? timer;
    var offset = 0;

    void emit() {
      if (controller.isClosed || offset >= pcm16le.length) {
        timer?.cancel();
        timer = null;
        if (!controller.isClosed) unawaited(controller.close());
        return;
      }
      final end = math.min(offset + chunkBytes, pcm16le.length);
      _emittedBytes = end;
      controller.add(pcm16le.sublist(offset, end));
      offset = end;
    }

    controller = StreamController<List<int>>(
      onListen: () {
        emit();
        timer = Timer.periodic(chunkInterval, (_) => emit());
      },
      onPause: () {
        timer?.cancel();
        timer = null;
      },
      onResume: () {
        timer?.cancel();
        timer = Timer.periodic(chunkInterval, (_) => emit());
      },
      onCancel: () {
        // Cancellation is the stop path: no timer may survive it, so no late
        // chunk can arrive after the daemon was told the session ended.
        timer?.cancel();
        timer = null;
      },
    );
    return controller.stream;
  }
}
