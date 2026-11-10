import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:logging/logging.dart';
import 'package:sanad_client/features/dictation/domain/dictation_audio_capture.dart';
import 'package:sanad_client/features/dictation/domain/dictation_identity.dart';
import 'package:sanad_client/features/dictation/domain/dictation_transport.dart';
import 'package:sanad_client/features/dictation/domain/dictation_transport_resolver.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';

import 'dictation_state.dart';

/// Drives one dictation session against the daemon.
///
/// Ownership: capture + transport plumbing only. Transcription happens in the
/// daemon; this cubit never fabricates or edits transcript text, and it logs
/// counts and codes, never audio or transcript content.
class DictationCubit extends Cubit<DictationState> {
  DictationCubit({
    required DictationResolver resolver,
    required DictationCapture capture,
    DictationPreviewPolicy previewPolicy = DictationPreviewPolicy.live,
    String Function()? sessionIdFactory,
    DateTime Function()? now,
    Future<void> Function(Duration)? delay,
  })  : _resolver = resolver,
        _capture = capture,
        _sessionIdFactory = sessionIdFactory ?? DictationIdentity.next,
        _now = now ?? DateTime.now,
        _delay = delay ?? _defaultDelay,
        super(DictationState(previewPolicy: previewPolicy));

  static Future<void> _defaultDelay(Duration duration) =>
      Future<void>.delayed(duration);

  static final _logger = Logger('DictationCubit');

  /// How long a daemon model projection stays usable.
  ///
  /// The daemon owns the selected model and nothing pushes a change to this
  /// Client, so an old answer is a guess: a press re-reads it instead.
  static const Duration modelProjectionMaxAge = Duration(seconds: 30);

  static const Duration _stopTimeout = Duration(seconds: 240);

  final DictationResolver _resolver;
  final DictationCapture _capture;
  final String Function() _sessionIdFactory;

  /// The Client's own clock, so a projection's age is testable.
  final DateTime Function() _now;

  /// How the post-disconnect recovery waits between attempts; injected so a
  /// test does not spend nine real seconds proving a bound.
  final Future<void> Function(Duration) _delay;

  /// Status replies seen, so a recovery attempt can tell an answer from a
  /// timeout without comparing timestamps (a fixed test clock makes those equal).
  int _statusReplies = 0;

  DictationTransport? _transport;

  /// The device [_transport] speaks to, and the last device that asked for a
  /// command.
  ///
  /// One transport carries one device's truth: reusing an open transport for a
  /// different device is what made A→B→A answer A's press with B's
  /// `model_not_installed`, because the resolver was only consulted once the
  /// previous socket had closed.
  String? _transportDeviceId;
  DeviceConfig? _lastCommandDevice;

  DeviceConfig? _device;
  String? _sessionId;
  StreamSubscription<Map<String, dynamic>>? _eventSubscription;
  DictationTransport? _eventTransport;
  StreamSubscription<List<int>>? _audioSubscription;
  Timer? _stopTimer;
  final Stopwatch _clock = Stopwatch();
  bool _closing = false;
  bool _limitReached = false;
  bool _capturing = false;
  int _lastLevelMs = 0;
  double _lastLevel = 0;

  /// Metadata counters for the audio path: the level bars prove frames are
  /// captured, these prove whether the same frames left the client.
  int _sentChunks = 0;

  /// Completes when the recorder's own stream is done, so stop() can wait for
  /// the last frames to reach the daemon before asking it to decode.
  Completer<void>? _captureDrained;

  Completer<void>? _statusCompleter;
  Completer<void>? _idle;

  /// Events this session consumed, republished for the driver probe.
  ///
  /// A local dictation session never reaches `SanadSocketService.events` — it
  /// arrives on the separate dictation WebSocket — so the probe cannot evidence
  /// a local leg from the main socket alone. The cubit already listens to the
  /// transport, so it republishes the same maps here: no second subscription on
  /// the daemon side, and nothing above the transport learns the channel.
  final StreamController<Map<String, dynamic>> _lifecycle =
      StreamController<Map<String, dynamic>>.broadcast();

  /// Daemon events this cubit consumed (`stt_status`, `dictation_partial`, …).
  Stream<Map<String, dynamic>> get lifecycleEvents => _lifecycle.stream;

  /// Pending "send after dictation" wait; see [sendWhenSettled].
  Completer<bool>? _sendWaiter;

  /// Transcript captured when the daemon finished, held so the pending send can
  /// be resolved after the reset clears the visible state.
  String _settledText = '';

  /// Ceiling for one utterance: five minutes of audio is held in the daemon
  /// until the user stops, so the cap is a real memory bound, not a UX hint.
  static const Duration sessionLimit = Duration(minutes: 5);

  void setPreviewPolicy(DictationPreviewPolicy policy) {
    if (state.previewPolicy == policy) return;
    emit(state.copyWith(previewPolicy: policy));
  }

  /// True when the daemon's model projection is old enough to re-read.
  ///
  /// A ready device with an old answer is exactly the state in which another
  /// Client's model change stays invisible (`live-3`, N5).
  bool get modelProjectionIsStale =>
      state.model.projectionOlderThan(modelProjectionMaxAge, now: _now());

  Future<void> start(DeviceConfig device) async {
    if (state.isActive || _device != null) return;
    _device = device;
    _sessionId = _sessionIdFactory();
    _closing = false;
    emit(
      state.copyWith(
        status: DictationStatus.preparing,
        clearError: true,
        segments: const [],
        clearPartialSeq: true,
        partialText: '',
        discardText: false,
      ),
    );

    try {
      // One connection per session: status refreshes and the session itself share
      // the transport, so a press never opens a second socket.
      final transport = await _ensureTransport(device);
      if (transport == null) {
        await _reset(clearText: true, errorCode: state.errorCode ?? 'connect_failed');
        return;
      }
      _capturing = false;
      transport.sendCommand('start');
      // Capture waits for `dictation_ready`: the daemon drops audio that
      // arrives before the recognizer exists, so speaking during the load
      // would silently lose the first words.
      _clock..reset()..start();
    } on DictationTransportUnavailable catch (error) {
      _logger.info('dictation transport unavailable: ${error.reason}');
      await _reset(clearText: true, errorCode: error.reason);
    } on Object catch (error) {
      _logger.warning('dictation start failed: ${error.runtimeType}');
      await _reset(clearText: true, errorCode: 'start_failed');
    }
  }

  Future<void> _startCapture(DictationTransport transport) async {
    if (_capturing) return;
    _capturing = true;
    _captureDrained = Completer<void>();
    _sentChunks = 0;
    final Stream<List<int>> stream;
    try {
      stream = await _capture.start();
    } on DictationMicrophoneDenied {
      // Capture starts when the daemon is ready, which is after `start` returned:
      // a denied microphone has to terminate the session from here.
      _capturing = false;
      _fail('microphone_denied');
      return;
    } on Object catch (error) {
      _capturing = false;
      _logger.warning('dictation capture failed: ${error.runtimeType}');
      _fail('microphone_error');
      return;
    }
    _audioSubscription = stream.listen(
      (chunk) {
        // The cap is measured on the audio path, so it needs no timer: a
        // session that sends no audio can grow nothing.
        if (_clock.elapsed > sessionLimit) {
          unawaited(stopForLimit());
          return;
        }
        _sentChunks++;
        if (_sentChunks == 1) {
          _logger.info(
            'dictation audio out: first chunk bytes=${chunk.length} '
            'open=${transport.isOpen}',
          );
        }
        transport.sendAudio(chunk);
        _publishLevel(chunk);
      },
      onError: (Object _) => _fail('microphone_error'),
      // The recorder closes this stream when it stops, which is the signal that
      // the last frames have been handed over.
      onDone: () {
        final drained = _captureDrained;
        if (drained != null && !drained.isCompleted) drained.complete();
      },
      cancelOnError: true,
    );
  }

  /// Publishes loudness for the visualization, at most sixteen times a second.
  void _publishLevel(List<int> chunk) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastLevelMs < 60) return;
    _lastLevelMs = now;
    if (chunk.length < 2) return;
    var sum = 0.0;
    final count = chunk.length ~/ 2;
    for (var i = 0; i < count; i++) {
      final sample = (chunk[i * 2] | (chunk[i * 2 + 1] << 8)).toSigned(16);
      final value = sample / 32768.0;
      sum += value * value;
    }
    final meanSquare = count == 0 ? 0.0 : (sum / count).abs();
    final rms = math.sqrt(meanSquare);
    // A room's noise floor sits around -55 dBFS on this microphone and speech
    // starts around -50, so everything below -50 is gated out and the meter
    // spans -50..-25 dB: idle silence stays flat, speech fills it.
    final db = 20 * (math.log(rms <= 1e-8 ? 1e-8 : rms) / math.ln10);
    final instant = ((db + 50) / 25).clamp(0.0, 1.0);
    // Fast attack, slow release: the bars jump with a syllable and settle
    // instead of flickering on every noise sample.
    final level = instant >= _lastLevel
        ? instant
        : (_lastLevel * 0.55) + (instant * 0.45);
    _lastLevel = level;
    if (!isClosed) emit(state.copyWith(level: level.toDouble()));
  }

  /// Stops capture, asks the daemon to drain, and keeps the finalized text.
  ///
  /// Order matters: the recorder is stopped *first* and its stream is allowed
  /// to close, so the frames the user just spoke still reach the daemon before
  /// the stop command tells it to decode.
  Future<void> stop() async {
    if (!state.isActive) return;
    _lastLevel = 0;
    emit(state.copyWith(status: DictationStatus.finalizing, level: 0));
    _capturing = false;
    await _capture.stop();
    final drained = _captureDrained;
    if (drained != null) {
      await drained.future.timeout(
        const Duration(milliseconds: 800),
        onTimeout: () {},
      );
    }
    await _audioSubscription?.cancel();
    _audioSubscription = null;
    _transport?.sendCommand('stop');
    _stopTimer = Timer(_stopTimeout, () {
      _logger.warning('dictation stop timed out');
      unawaited(_reset(clearText: false));
    });
  }

  /// Stops the session and completes once the transcript has landed.
  ///
  /// The send path uses this: dispatching while the daemon is still decoding
  /// would post the text that existed *before* the user spoke.
  Future<void> stopAndWait({
    Duration timeout = const Duration(minutes: 3),
  }) async {
    if (!state.isActive) return;
    final idle = _idle ??= Completer<void>();
    await stop();
    await idle.future.timeout(timeout, onTimeout: () {});
  }

  /// Stops the session and reports whether a transcript is worth sending.
  ///
  /// True only when the session ended with text in the composer: a session that
  /// recognised nothing, failed, or was cancelled by the user resolves false so
  /// the caller sends nothing. The wait is bounded, so a daemon that never
  /// answers cannot leave the send button spinning forever — the transcript
  /// still lands in the composer whenever it finally arrives, it is simply not
  /// sent automatically.
  Future<bool> sendWhenSettled({
    Duration timeout = const Duration(seconds: 60),
  }) async {
    if (!state.isActive) return state.visibleText.trim().isNotEmpty;
    if (_sendWaiter != null) return false;
    final waiter = Completer<bool>();
    _sendWaiter = waiter;
    emit(state.copyWith(awaitingSend: true));
    final timer = Timer(timeout, () => _settleSend(false));
    await stop();
    final settled = await waiter.future;
    timer.cancel();
    _sendWaiter = null;
    if (!isClosed && state.awaitingSend) {
      emit(state.copyWith(awaitingSend: false));
    }
    return settled;
  }

  /// Abandons a pending send without discarding the session's text.
  ///
  /// The session keeps finishing in the background, so whatever was spoken is
  /// still inserted into the composer; it just stops being sent on its own.
  void cancelPendingSend() => _settleSend(false);

  void _settleSend(bool settled) {
    final waiter = _sendWaiter;
    _sendWaiter = null;
    if (waiter != null && !waiter.isCompleted) waiter.complete(settled);
  }

  /// Stops the session because the client-side cap was reached.
  Future<void> stopForLimit() async {
    if (!state.isActive) return;
    _limitReached = true;
    await stop();
  }

  /// Abandons the session and drops everything it produced.
  Future<void> cancel() async {
    if (!state.isActive) return;
    _transport?.sendCommand('cancel');
    await _reset(clearText: true);
  }

  /// Starts (or joins) the model download; the daemon owns its lifetime.
  ///
  /// The local state is a seed, not the truth: the daemon reports the real
  /// install on every `stt_status`, so a press that races a running download is
  /// answered with that truth instead of a second writer.
  Future<void> installModel(String modelId, {required DeviceConfig device}) async {
    if (state.model.installingModelId == modelId) return;
    final transport = await _ensureTransport(device);
    if (transport == null) return;
    emit(
      state.copyWith(
        model: state.model.copyWith(
          installingModelId: modelId,
          downloadProgress: state.model.installingModelId == null ? 0 : null,
        ),
        clearError: true,
      ),
    );
    transport.sendCommand('install', {'model_id': modelId});
  }

  /// Abandons a running install. It is the only thing that stops one: closing
  /// the sheet, switching device, or dropping the socket never does.
  Future<void> cancelInstallModel({required DeviceConfig device}) async {
    final transport = await _ensureTransport(device);
    if (transport == null) return;
    transport.sendCommand('cancelInstall');
  }

  /// Asks the daemon for the current status/catalog and waits for the reply.
  ///
  /// The reply is what tells the caller whether a model is installed, so the
  /// button decides "start recording vs open the sheet" from fresh data rather
  /// than from an empty state; the wait is bounded.
  Future<void> refreshStatus(
    DeviceConfig device, {
    Duration timeout = const Duration(seconds: 4),
    bool silent = false,
  }) async {
    final transport = await _ensureTransport(device, silent: silent);
    if (transport == null) return;
    final completer = Completer<void>();
    _statusCompleter = completer;
    transport.sendCommand('status');
    try {
      await completer.future.timeout(timeout);
    } on TimeoutException {
      _logger.info('dictation status reply timed out');
    } finally {
      if (identical(_statusCompleter, completer)) _statusCompleter = null;
    }
  }

  Future<void> selectModel(String modelId, {required DeviceConfig device}) async {
    final transport = await _ensureTransport(device);
    if (transport == null) return;
    transport.sendCommand('select', {'model_id': modelId});
  }

  /// Asks the daemon to (re)prepare the native dictation runtime.
  ///
  /// The build/download runs detached on the daemon, so this only kicks it off
  /// and then refreshes the status the sheet renders.
  Future<void> prepareRuntime(DeviceConfig device) async {
    final transport = await _ensureTransport(device);
    if (transport == null) return;
    transport.sendCommand('prepareRuntime');
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await refreshStatus(device);
  }

  Future<DictationTransport?> _ensureTransport(
    DeviceConfig device, {
    bool silent = false,
  }) async {
    _lastCommandDevice = device;
    final existing = _transport;
    final sameDevice = _transportDeviceId == device.id;
    if (existing != null && existing.isOpen && sameDevice) return existing;
    if (existing != null) {
      // A replacement closes the previous connection: an orphaned socket keeps a
      // daemon connection (and eventually its lease) alive with no owner.
      await _detachTransport(existing);
    }
    if (!sameDevice) {
      // A projection — including an install — that answered another device is
      // not a guess about this one. The status this call returns rebuilds it.
      emit(state.copyWith(model: const DictationModelStatus()));
    }
    _sessionId = _sessionIdFactory();
    try {
      final transport = await _resolver.resolve(
        device: device,
        sessionId: _sessionId!,
      );
      _transport = transport;
      _transportDeviceId = device.id;
      _attachEvents(transport);
      return transport;
    } on DictationTransportUnavailable catch (error) {
      if (!silent) emit(state.copyWith(errorCode: error.reason));
      return null;
    } on Object catch (error) {
      _logger.warning('dictation connect failed: ${error.runtimeType}');
      if (!silent) emit(state.copyWith(errorCode: 'connect_failed'));
      return null;
    }
  }

  /// Stops listening to [transport] and closes it, without touching a newer one.
  Future<void> _detachTransport(DictationTransport transport) async {
    if (identical(_eventTransport, transport)) {
      await _eventSubscription?.cancel();
      _eventSubscription = null;
      _eventTransport = null;
    }
    await transport.close();
    if (identical(_transport, transport)) {
      _transport = null;
      _transportDeviceId = null;
    }
  }

  /// Listens to the transport exactly once: status refreshes and a later
  /// session share one connection, so re-listening would double every event
  /// (and duplicate transcript text).
  void _attachEvents(DictationTransport transport) {
    if (identical(_eventTransport, transport) && _eventSubscription != null) {
      return;
    }
    unawaited(_eventSubscription?.cancel());
    _eventTransport = transport;
    _eventSubscription = transport.events.listen(
      _handleEvent,
      onError: (Object error) => _fail('transport_error'),
      onDone: _onTransportClosed,
    );
  }

  void _handleEvent(Map<String, dynamic> event) {
    if (!_lifecycle.isClosed) _lifecycle.add(event);
    switch (event['event']) {
      case 'stt_status':
        _statusReplies++;
        _statusCompleter?.complete();
        // The status is the daemon's whole answer, install included: it is
        // reconstructed here rather than merged into the previous projection, so
        // a refresh can neither erase a running download nor invent one.
        final status = _modelFromStatus(event);
        emit(
          state.copyWith(
            model: status.copyWith(
              // The projection is only ever as good as the moment the daemon
              // answered it, and a press decides from that age whether to ask
              // again (another Client can change the selection at any time).
              fetchedAt: _now(),
            ),
          ),
        );
      case 'stt_download_progress':
        final received = (event['received_bytes'] as num?)?.toInt() ?? 0;
        final total = (event['total_bytes'] as num?)?.toInt() ?? 0;
        final phase = event['phase'] as String?;
        emit(
          state.copyWith(
            model: state.model.copyWith(
              installingModelId: event['model_id'] as String?,
              downloadProgress: total <= 0 ? null : (received / total).clamp(0, 1),
              installReceivedBytes: received,
              installTotalBytes: total <= 0 ? null : total,
              installBytesPerSecond:
                  (event['bytes_per_second'] as num?)?.toInt(),
              installPhase: phase,
            ),
          ),
        );
      case 'dictation_ready':
        // The daemon names the model it actually loaded. That answer is
        // authoritative for the projection, so a selection another Client
        // changed is corrected here instead of surviving as a stale label.
        final readyModel = (event['model_id'] as String?)?.trim() ?? '';
        final runningModel =
            readyModel.isEmpty ? state.model.selectedModelId : readyModel;
        _logger.info(
          'dictation ready: model=$runningModel '
          'load_ms=${(event['load_ms'] as num?)?.toInt() ?? 0}',
        );
        emit(
          state.copyWith(
            model: state.model.copyWith(
              selectedModelId: readyModel.isEmpty ? null : readyModel,
              isReady: true,
              clearReadinessReason: true,
              fetchedAt: _now(),
            ),
            // The recognizer exists now, so the user can speak. Until this
            // event the mic shows a loading affordance.
            status: state.status == DictationStatus.preparing
                ? DictationStatus.listening
                : state.status,
          ),
        );
        final transport = _transport;
        if (transport != null && state.status == DictationStatus.listening) {
          unawaited(_startCapture(transport));
        }
      case 'dictation_partial':
        final text = (event['text'] as String?) ?? '';
        final seq = (event['seq'] as num?)?.toInt();
        // A partial never rewrites a segment the daemon already finalized: `seq`
        // is the replacement key of the open segment, so a late or repeated
        // partial for a closed slot would resurrect text that already landed.
        if (seq != null &&
            seq >= 0 &&
            seq < state.segments.length &&
            state.segments[seq].isNotEmpty) {
          return;
        }
        emit(
          state.copyWith(
            partialSeq: seq,
            partialText:
                state.previewPolicy == DictationPreviewPolicy.live ? text : '',
          ),
        );
      case 'dictation_final':
        // The daemon's `seq` is the replacement key of a segment: the final for
        // a seq **replaces** that segment's text (the partial previewed it), and
        // a repeated final for the same seq replaces it again instead of
        // appending a second copy. Batch engines send one final for the whole
        // utterance, streaming engines one per silence-closed segment, and both
        // land in their own slot here.
        final text = ((event['text'] as String?) ?? '').trim();
        final rawSeq = (event['seq'] as num?)?.toInt();
        // A malformed or absent seq falls back to the next free slot instead of
        // throwing: one bad event must never drop a recognized transcript.
        final seq = rawSeq == null || rawSeq < 0 ? state.nextSegmentSeq : rawSeq;
        final segments = List<String>.of(state.segments);
        while (segments.length <= seq) {
          segments.add('');
        }
        if (text.isNotEmpty) segments[seq] = text;
        emit(
          state.copyWith(
            segments: segments,
            partialText: '',
            clearPartialSeq: state.partialSeq == seq,
          ),
        );
      case 'dictation_done':
        final segments = (event['segments'] as num?)?.toInt() ?? 0;
        _logger.info('dictation drained: segments=$segments');
        final noSpeech = segments == 0 && state.committedText.isEmpty;
        // Hold the transcript: the reset below clears it from the state, but the
        // pending send still has to know whether anything was recognised.
        _settledText = noSpeech ? '' : state.committedText;
        unawaited(
          _reset(
            clearText: false,
            errorCode: noSpeech ? 'no_speech' : null,
          ),
        );
      case 'dictation_error':
        final code = (event['code'] as String?) ?? 'dictation_error';
        // `unavailable` is a wrapper: the specific reason (preparing vs missing
        // runtime) is what the user needs to see.
        final reason = event['reason'] as String?;
        final effective = code == 'unavailable' && reason != null ? reason : code;
        if (effective == 'install_in_progress') {
          // A press that races a running install is **state**, not a failure.
          // Treating it as one is what closed the socket and, on the local
          // channel, cancelled the real download with its partial bytes.
          _logger.info('dictation install already running on this device');
          final device = _lastCommandDevice;
          if (device != null) unawaited(refreshStatus(device));
          return;
        }
        if (state.model.installingModelId != null) {
          // The install died, not the session: the row is cleared and the code
          // is reported, but the transport stays open so the sheet can retry.
          emit(
            state.copyWith(
              model: state.model.copyWith(clearInstallingModel: true),
              errorCode: effective,
            ),
          );
          return;
        }
        _fail(effective);
      default:
        break;
    }
  }

  static DictationModelStatus _modelFromStatus(Map<String, dynamic> event) {
    final selected = event['selected'] as String?;
    final supported = event['supported'] != false;
    final rawModels = event['models'];
    final candidates = rawModels is List ? rawModels : const [];
    final models = <DictationModelOption>[];
    for (final entry in candidates) {
      if (entry is! Map) continue;
      final description = entry['description'];
      models.add(
        DictationModelOption(
          id: (entry['id'] as String?) ?? '',
          name: entry['name'] as String?,
          labelCode: entry['label_code'] as String?,
          // A locale map, so a model's own copy travels with the model and the
          // Client never has to grow a string per catalog entry.
          description: description is Map
              ? {
                  for (final item in description.entries)
                    if (item.key is String && item.value is String)
                      item.key as String: item.value as String,
                }
              : const {},
          badge: entry['badge'] as String?,
          speedTier: (entry['speed_tier'] as num?)?.toInt(),
          sizeBytes: (entry['size_bytes'] as num?)?.toInt(),
          streaming: entry['streaming'] == true,
          location: (entry['location'] as String?) ?? 'local',
          hosted: entry['hosted'] == true,
          installed: entry['installed'] == true,
        ),
      );
    }
    // The daemon states the running install in its status. Absent means nothing
    // is in flight, which is the only honest way for a reopened sheet, a device
    // switch, or a reconnect to know that a download ended.
    final install = event['install'];
    final installFields = install is Map ? install : const {};
    final installModelId = installFields['model_id'] as String?;
    final installReceived = (installFields['received_bytes'] as num?)?.toInt();
    final installTotal = (installFields['total_bytes'] as num?)?.toInt();
    final installRate = (installFields['bytes_per_second'] as num?)?.toInt();
    final installPhase = installFields['phase'] as String?;
    final selectedEntry = models.where((m) => m.id == selected).firstOrNull;
    // `ready` is authoritative; the installed flag is only a catalog echo and is
    // absent for an override model that is on disk but not in the catalog.
    final readyFlag = event['ready'];
    final reason = event['reason'] as String?;
    return DictationModelStatus(
      selectedModelId: selected,
      isReady:
          readyFlag is bool ? readyFlag : (selectedEntry?.installed ?? false),
      installedBytes: selectedEntry?.sizeBytes,
      // Same field, two meanings: unsupported is a platform verdict, while a
      // supported-but-not-ready device (native runtime missing or preparing)
      // must keep its reason so the sheet can offer the prepare action.
      unavailableReason: supported ? null : reason,
      readinessReason: supported ? reason : null,
      isPlatformSupported: supported,
      busy: event['busy'] == true,
      models: models,
      installingModelId: installModelId,
      downloadProgress: installTotal != null &&
              installTotal > 0 &&
              installReceived != null
          ? (installReceived / installTotal).clamp(0.0, 1.0)
          : null,
      installReceivedBytes: installReceived,
      installTotalBytes: installTotal,
      installBytesPerSecond: installRate,
      installPhase: installPhase,
    );
  }

  void _fail(String code) {
    _logger.info('dictation error code=$code');
    unawaited(_reset(clearText: code == 'model_not_installed', errorCode: code));
  }

  void _onTransportClosed() {
    if (_closing) return;
    final device = _device ?? _lastCommandDevice;
    final lostInstall = state.model.installingModelId != null;
    unawaited(_reset(clearText: false));
    if (!lostInstall) return;
    // A closed socket does not end an install — the download is daemon-scoped —
    // but it cannot report one either. Keeping the row left a dead Cancel at a
    // stale percentage after a hard Agent restart, and the install it pointed at
    // no longer exists (the process died). Drop the row and ask the device for
    // the truth, a bounded number of times: the live restart was back in ~8 s.
    emit(state.copyWith(model: state.model.copyWith(clearInstallingModel: true)));
    if (device != null) unawaited(_recoverModelTruth(device));
  }

  /// Re-asks [device] for its model truth after the socket was lost.
  ///
  /// Bounded on purpose: three attempts, three seconds apart, and it stops the
  /// moment a reply arrives, a session starts, or the device is gone. A silent
  /// attempt never raises `connect_failed` — a recovery probe is not a user
  /// action and must not paint an error over the composer.
  Future<void> _recoverModelTruth(DeviceConfig device) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      await _delay(const Duration(seconds: 3));
      if (isClosed || state.isActive) return;
      if (state.model.installingModelId != null) return;
      if (_device != null) return;
      final replies = _statusReplies;
      await refreshStatus(device, silent: true);
      if (_statusReplies != replies) return;
    }
  }

  Future<void> _reset({required bool clearText, String? errorCode}) async {
    if (_closing) return;
    _closing = true;
    _clock.stop();
    _lastLevel = 0;
    _capturing = false;
    final limitReached = _limitReached;
    _limitReached = false;
    _stopTimer?.cancel();
    _stopTimer = null;
    await _audioSubscription?.cancel();
    _audioSubscription = null;
    await _capture.stop();
    final transport = _transport;
    if (transport != null) await _detachTransport(transport);
    final device = _device;
    _device = null;
    _sessionId = null;
    emit(
      state.copyWith(
        status: DictationStatus.idle,
        // The dictated text belongs to one session and was already inserted
        // into the composer; keeping it here would duplicate it next time.
        segments: const [],
        clearPartialSeq: true,
        partialText: '',
        discardText: clearText,
        level: 0,
        // A session that ends any other way (error, cancel, stop timeout) must
        // also release the send button, never leave it spinning.
        awaitingSend: false,
        errorCode: errorCode ?? (limitReached ? 'session_limit' : null),
        clearError: errorCode == null && !limitReached,
        sessionNeedsFirstUseSheet: errorCode == 'model_not_installed',
      ),
    );
    _closing = false;
    if (device != null) _logger.info('dictation session closed');
    // Resolve the wait only now: the caller may read the composer as soon as it
    // returns, so the session must be idle first.
    _settleSend(!clearText && _settledText.trim().isNotEmpty);
    _settledText = '';
    final idle = _idle;
    _idle = null;
    if (idle != null && !idle.isCompleted) idle.complete();
  }

  @override
  Future<void> close() async {
    _closing = true;
    _stopTimer?.cancel();
    _clock.stop();
    await _audioSubscription?.cancel();
    await _capture.dispose();
    await _eventSubscription?.cancel();
    await _transport?.close();
    await _lifecycle.close();
    return super.close();
  }
}
