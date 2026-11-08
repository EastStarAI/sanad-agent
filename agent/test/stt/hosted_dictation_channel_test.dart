import 'dart:async';
import 'dart:typed_data';

import 'package:sanad_agent/infrastructure/stt/dictation_session.dart';
import 'package:sanad_agent/infrastructure/stt/hosted_dictation_channel.dart';
import 'package:test/test.dart';

void main() {
  late List<(String, Map<String, dynamic>)> emitted;
  late DateTime now;
  late HostedDictationChannel channel;

  HostedDictationChannel build({
    Duration producerDeadline = const Duration(seconds: 3600),
  }) {
    emitted = <(String, Map<String, dynamic>)>[];
    now = DateTime.utc(2026, 11, 8, 12);
    return HostedDictationChannel(
      dictationId: 'dict-1',
      requestId: 'dict-1',
      deviceId: 'device-1',
      limits: DictationRelayLimits(producerDeadline: producerDeadline),
      clock: () => now,
      emit: (event, payload) => emitted.add((event, payload)),
    );
  }

  setUp(() {
    channel = build();
  });

  tearDown(() async {
    await channel.close();
  });

  Map<String, dynamic> frame(int seq, List<int> data) => {
    'dictation_id': 'dict-1',
    'request_id': 'dict-1',
    'device_id': 'device-1',
    'seq': seq,
    'data': data,
  };

  group('hosted dictation channel identity', () {
    test('a foreign session frame is never accepted', () async {
      final received = <int>[];
      channel.audio.listen((chunk) => received.add(chunk.length));

      channel.onAudioFrame(frame(0, [1, 2])..['dictation_id'] = 'dict-2');
      channel.onAudioFrame(frame(0, [1, 2])..['request_id'] = 'dict-2');
      channel.onAudioFrame(frame(0, [1, 2])..['device_id'] = 'device-2');
      await Future<void>.delayed(Duration.zero);

      expect(received, isEmpty);
      expect(emitted, isEmpty);
    });

    test('emitted events carry the session identity and version', () {
      channel.send('stt_status', {'busy': false});
      expect(emitted.single.$1, 'stt_status');
      expect(emitted.single.$2['version'], 'v1');
      expect(emitted.single.$2['dictation_id'], 'dict-1');
      expect(emitted.single.$2['busy'], false);
    });
  });

  group('hosted dictation audio ordering', () {
    test('contiguous frames reach the session in order', () async {
      final received = <Uint8List>[];
      channel.audio.listen(received.add);

      channel.onAudioFrame(frame(0, [1, 2]));
      channel.onAudioFrame(frame(1, [3, 4]));
      await Future<void>.delayed(Duration.zero);

      expect(received.map((chunk) => chunk.length), [2, 2]);
      expect(channel.acceptedBytes, 4);
      expect(channel.droppedFrames, 0);
    });

    test('a duplicate frame is counted, never replayed', () async {
      final received = <Uint8List>[];
      channel.audio.listen(received.add);

      channel.onAudioFrame(frame(0, [1, 2]));
      channel.onAudioFrame(frame(0, [9, 9]));
      await Future<void>.delayed(Duration.zero);

      expect(received, hasLength(1));
      expect(channel.droppedFrames, 1);
      expect(emitted, isEmpty, reason: 'a duplicate is not a failure');
    });

    test('a skipped sequence ends the session with audio_gap', () async {
      final commands = <DictationCommand>[];
      channel.commands.listen((message) => commands.add(message.command));

      channel.onAudioFrame(frame(0, [1, 2]));
      channel.onAudioFrame(frame(2, [3, 4]));
      await Future<void>.delayed(Duration.zero);

      expect(emitted.single.$1, 'dictation_error');
      expect(emitted.single.$2['code'], 'audio_gap');
      expect(commands, [DictationCommand.cancel]);
    });

    test('an oversized frame is refused instead of buffered', () async {
      channel.onAudioFrame(frame(0, List.filled(40000, 0)));
      expect(emitted.single.$2['code'], 'session_limit');
    });

    test('the session byte cap fails closed', () async {
      final small = HostedDictationChannel(
        dictationId: 'dict-1',
        requestId: 'dict-1',
        deviceId: 'device-1',
        limits: const DictationRelayLimits(maxSessionBytes: 4),
        clock: () => now,
        emit: (event, payload) => emitted.add((event, payload)),
      );
      final commands = <DictationCommand>[];
      small.commands.listen((message) => commands.add(message.command));

      small.onAudioFrame(frame(0, [1, 2]));
      small.onAudioFrame(frame(1, [3, 4]));
      small.onAudioFrame(frame(2, [5, 6]));
      await Future<void>.delayed(Duration.zero);

      expect(emitted.last.$2['code'], 'session_limit');
      expect(commands, [DictationCommand.cancel]);
      await small.close();
    });
  });

  group('hosted ordered control', () {
    test('stopped maps to the stop command', () async {
      final commands = <DictationCommand>[];
      channel.commands.listen((message) => commands.add(message.command));

      channel.onOrderedControl({
        'dictation_id': 'dict-1',
        'request_id': 'dict-1',
        'reason': 'stopped',
      });
      await Future<void>.delayed(Duration.zero);

      expect(commands, [DictationCommand.stop]);
    });

    test('cancelled and abort both cancel the session', () async {
      final commands = <DictationCommand>[];
      channel.commands.listen((message) => commands.add(message.command));

      channel.onOrderedControl({
        'dictation_id': 'dict-1',
        'request_id': 'dict-1',
        'reason': 'cancelled',
      });
      channel.onAbort('client_disconnect');
      await Future<void>.delayed(Duration.zero);

      expect(commands, [DictationCommand.cancel, DictationCommand.cancel]);
    });

    test('control for another session is ignored', () async {
      final commands = <DictationCommand>[];
      channel.commands.listen((message) => commands.add(message.command));

      channel.onOrderedControl({
        'dictation_id': 'dict-2',
        'request_id': 'dict-2',
        'reason': 'stopped',
      });
      await Future<void>.delayed(Duration.zero);

      expect(commands, isEmpty);
    });
  });

  group('hosted producer deadline', () {
    test('a producer stops emitting after the bounded interval', () async {
      final bounded = build(producerDeadline: const Duration(seconds: 30));
      bounded.send('stt_status', {'busy': false});
      expect(emitted, hasLength(1));

      // No admitted activity for longer than the deadline: the retired claim has
      // no recipient, so the daemon must stop producing instead of writing into
      // a route that no longer exists.
      now = now.add(const Duration(seconds: 31));
      bounded.send('dictation_final', {'seq': 0, 'text': 'x'});

      expect(emitted, hasLength(1));
      expect(bounded.isExpired, isTrue);
      await bounded.close();
    });

    test('admitted audio refreshes the deadline', () async {
      final bounded = build(producerDeadline: const Duration(seconds: 30));
      now = now.add(const Duration(seconds: 20));
      bounded.onAudioFrame(frame(0, [1, 2]));
      now = now.add(const Duration(seconds: 20));
      bounded.send('stt_status', {'busy': false});
      expect(emitted, hasLength(1));
      await bounded.close();
    });
  });

  group('hosted dictation channel start and deadline', () {
    test('a start issued before the service subscribes is buffered', () async {
      channel.beginSession();
      final commands = <DictationCommand>[];
      channel.commands.listen((message) => commands.add(message.command));
      await Future<void>.delayed(Duration.zero);

      expect(commands, [DictationCommand.start]);
      expect(channel.isStarted, isTrue);
    });

    test('begin session is idempotent and arms exactly one timer', () async {
      final timers = <_FakeTimer>[];
      final withTimers = HostedDictationChannel(
        dictationId: 'dict-1',
        requestId: 'dict-1',
        deviceId: 'device-1',
        limits: const DictationRelayLimits(),
        clock: () => now,
        emit: (event, payload) => emitted.add((event, payload)),
        timerFactory: (duration, callback) {
          final timer = _FakeTimer(callback);
          timers.add(timer);
          return timer;
        },
      );
      final commands = <DictationCommand>[];
      withTimers.commands.listen((message) => commands.add(message.command));

      withTimers.beginSession();
      withTimers.beginSession();
      await Future<void>.delayed(Duration.zero);

      expect(commands, [DictationCommand.start]);
      expect(timers, hasLength(1));
      await withTimers.close();
    });

    test('the real deadline cancels an idle session and releases it', () async {
      final timers = <_FakeTimer>[];
      final withTimers = HostedDictationChannel(
        dictationId: 'dict-1',
        requestId: 'dict-1',
        deviceId: 'device-1',
        limits: const DictationRelayLimits(),
        clock: () => now,
        emit: (event, payload) => emitted.add((event, payload)),
        timerFactory: (duration, callback) {
          final timer = _FakeTimer(callback);
          timers.add(timer);
          return timer;
        },
      );
      final commands = <DictationCommand>[];
      withTimers.commands.listen((message) => commands.add(message.command));
      withTimers.beginSession();

      timers.single.fire();
      await Future<void>.delayed(Duration.zero);

      expect(commands, [DictationCommand.start, DictationCommand.cancel]);
      expect(withTimers.isClosed, isTrue);
    });

    test('closing cancels the deadline and a late callback is inert', () async {
      final timers = <_FakeTimer>[];
      final withTimers = HostedDictationChannel(
        dictationId: 'dict-1',
        requestId: 'dict-1',
        deviceId: 'device-1',
        limits: const DictationRelayLimits(),
        clock: () => now,
        emit: (event, payload) => emitted.add((event, payload)),
        timerFactory: (duration, callback) {
          final timer = _FakeTimer(callback);
          timers.add(timer);
          return timer;
        },
      );
      final commands = <DictationCommand>[];
      withTimers.commands.listen((message) => commands.add(message.command));
      withTimers.beginSession();
      await withTimers.close();

      expect(timers.single.isActive, isFalse);
      timers.single.fire();
      await Future<void>.delayed(Duration.zero);

      expect(commands, [DictationCommand.start]);
    });
  });
}

class _FakeTimer implements Timer {
  _FakeTimer(this._callback);

  final void Function() _callback;
  bool _active = true;

  void fire() {
    if (!_active) return;
    _active = false;
    _callback();
  }

  @override
  void cancel() => _active = false;

  @override
  bool get isActive => _active;

  @override
  int get tick => 0;
}
