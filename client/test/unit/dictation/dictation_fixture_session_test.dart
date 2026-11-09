import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/driver/dictation_capture_fixture.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/dictation/domain/dictation_transport.dart';
import 'package:sanad_client/features/dictation/domain/dictation_transport_resolver.dart';
import 'package:sanad_client/features/dictation/presentation/bloc/dictation_cubit.dart';
import 'package:sanad_client/features/dictation/presentation/bloc/dictation_state.dart';

/// A transport that behaves like the daemon for the only two things this seam
/// must prove: it answers `start` with `dictation_ready`, and it records exactly
/// the audio the cubit handed it.
class _ScriptedTransport implements DictationTransport {
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  final commands = <String>[];
  final audio = <List<int>>[];
  bool closed = false;

  @override
  Stream<Map<String, dynamic>> get events => _events.stream;

  @override
  bool get isOpen => !closed;

  @override
  void sendCommand(String event, [Map<String, dynamic> payload = const {}]) {
    commands.add(event);
    if (event == 'start') {
      scheduleMicrotask(() {
        if (!_events.isClosed) _events.add({'event': 'dictation_ready'});
      });
    }
  }

  @override
  void sendAudio(List<int> pcm16) => audio.add(pcm16);

  @override
  Future<void> close() async {
    closed = true;
    if (!_events.isClosed) await _events.close();
  }
}

class _FixedResolver implements DictationResolver {
  _FixedResolver(this.transport);

  final DictationTransport transport;

  @override
  Future<DictationTransport> resolve({
    required DeviceConfig device,
    required String sessionId,
  }) async =>
      transport;
}

Future<void> _until(bool Function() condition, {String? reason}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail(reason ?? 'condition not met before the deadline');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

List<int> _pcm(int bytes) => List<int>.generate(bytes, (index) => index % 256);

void main() {
  final device = DeviceConfig(
    id: 'agent-1',
    name: 'Studio Mac',
    hardwareId: 'studio-mac',
  );

  late DriverDictationCapture capture;
  late _ScriptedTransport transport;
  late DictationCubit cubit;

  setUp(() {
    capture = DriverDictationCapture(
      realCapture: () => throw StateError('the microphone must stay closed'),
    );
    transport = _ScriptedTransport();
    cubit = DictationCubit(
      resolver: _FixedResolver(transport),
      capture: capture,
    );
  });

  tearDown(() async {
    await cubit.close();
    await transport.close();
  });

  test('an armed fixture runs the normal ready/start/stop path', () async {
    capture.arm(DictationPcmFixture(
      pcm16le: _pcm(640),
      chunkBytes: 320,
      chunkInterval: const Duration(milliseconds: 10),
    ));

    await cubit.start(device);
    await _until(() => transport.audio.length == 2, reason: 'fixture chunks');
    await _until(() => !capture.isSessionActive, reason: 'fixture drained');

    expect(transport.commands, contains('start'));
    expect(transport.audio.expand((chunk) => chunk).length, 640);

    await cubit.stop();

    expect(transport.commands, containsAllInOrder(['start', 'stop']));
    expect(cubit.state.status, DictationStatus.finalizing);
  });

  test('cancel ends capture and no later chunk reaches the transport',
      () async {
    capture.arm(DictationPcmFixture(
      pcm16le: _pcm(6400),
      chunkBytes: 320,
      chunkInterval: const Duration(milliseconds: 10),
    ));

    await cubit.start(device);
    await _until(() => transport.audio.isNotEmpty, reason: 'first fixture chunk');
    await cubit.cancel();
    final afterCancel = transport.audio.length;
    expect(capture.isSessionActive, isFalse);

    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(transport.audio.length, afterCancel);
    expect(transport.commands, contains('cancel'));
    expect(cubit.state.status, DictationStatus.idle);
  });

  test('a capture failure resets without sending audio', () async {
    final withoutFixture = DriverDictationCapture(
      realCapture: () => throw StateError('microphone must stay closed'),
    );
    final localCubit = DictationCubit(
      resolver: _FixedResolver(transport),
      capture: withoutFixture,
    );
    addTearDown(localCubit.close);

    // `dictation_ready` arrives, capture start throws, and the cubit ends with a
    // localized generic code instead of a half-open session.
    await localCubit.start(device);
    await _until(
      () => localCubit.state.errorCode != null,
      reason: 'capture failure reported',
    );

    expect(localCubit.state.errorCode, 'microphone_error');
    expect(transport.audio, isEmpty);
  });
}
