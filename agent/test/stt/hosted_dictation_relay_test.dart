import 'dart:async';
import 'dart:io';

import 'package:sanad_agent/infrastructure/stt/dictation_service.dart';
import 'package:sanad_agent/infrastructure/stt/dictation_session.dart';
import 'package:sanad_agent/infrastructure/stt/stt_types.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/hosted_dictation_relay.dart';
import 'package:test/test.dart';

import 'support/fake_dictation_channel.dart';

Future<void> until(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 5),
  String reason = 'condition',
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting for $reason');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  late Directory home;
  late Directory modelDir;
  late List<(Map<String, dynamic>, String?)> envelopes;
  late DictationService service;
  late FakeSttEngine engine;
  late HostedDictationRelay relay;

  setUp(() {
    home = Directory.systemTemp.createTempSync('hosted-dictation-');
    modelDir = Directory('${home.path}/manual-model')..createSync();
    File('${modelDir.path}/ggml-tiny.bin').writeAsBytesSync(const [1, 2, 3]);
    File('${home.path}/config.yaml').writeAsStringSync('''
stt:
  model_path: ${modelDir.path}
  model_idle_minutes: 0
''');
    engine = FakeSttEngine();
    service = DictationService(
      sanadHome: home.path,
      platformSupported: true,
      engineFor: (_) => engine,
    );
    envelopes = <(Map<String, dynamic>, String?)>[];
    relay = HostedDictationRelay(
      service: service,
      registeredDeviceId: () => 'device-1',
      emitDeviceEvent: (envelope, {clientTag}) =>
          envelopes.add((envelope, clientTag)),
    );
  });

  tearDown(() async {
    await relay.closeAll();
    if (home.existsSync()) home.deleteSync(recursive: true);
  });

  Map<String, dynamic> command({
    required String op,
    String dictationId = 'dict-1',
    String? requestId,
    String deviceId = 'device-1',
    String version = 'v1',
    String? modelId,
  }) {
    return {
      'device_id': deviceId,
      'command': 'dictation',
      'request_id': requestId ?? dictationId,
      'payload': {
        'version': version,
        'dictation_id': dictationId,
        'request_id': requestId ?? dictationId,
        'op': op,
        'model_id': ?modelId,
      },
    };
  }

  List<Map<String, dynamic>> payloadsOf(String type) => [
    for (final entry in envelopes)
      if ((entry.$1['payload'] as Map)['type'] == type)
        Map<String, dynamic>.from(entry.$1['payload'] as Map),
  ];

  group('hosted dictation command admission', () {
    test('a status command answers on the origin claim only', () async {
      await relay.handleCommand(command(op: 'status'), clientTag: 'client#1');

      expect(envelopes, hasLength(1));
      final envelope = envelopes.single.$1;
      expect(envelope['event'], 'dictation_event');
      expect(envelope['type'], 'device_event');
      expect((envelope['event_id'] as String).isNotEmpty, isTrue);
      expect(envelope['request_id'], 'dict-1');
      expect(envelope['delivery'], {'scope': 'origin', 'request_id': 'dict-1'});
      expect(envelope.containsKey('session_id'), isFalse);
      final payload = payloadOfStatus(envelope);
      expect(payload['type'], 'stt_status');
      expect(payload['dictation_id'], 'dict-1');
      // A host filesystem path never crosses the relay; the projection is
      // transport-neutral and only says an override exists.
      expect(payload.containsKey('model_path'), isFalse);
      expect(payload['has_model_path'], isTrue);
      final rows = (payload['models'] as List).cast<Map<String, dynamic>>();
      for (final row in rows) {
        expect(row['note'], isNot(contains(home.path)));
      }
      // A dictation command never belongs to a conversation.
      expect(service.isBusy, isFalse);
    });

    test('a command for another device is never forwarded nor answered', () async {
      await relay.handleCommand(command(op: 'status', deviceId: 'device-2'));
      expect(envelopes, isEmpty);
    });

    test('request identity must equal the session identity', () async {
      await relay.handleCommand(
        command(op: 'status', requestId: 'other-request'),
      );
      expect(payloadsOf('dictation_error').single['code'], 'invalid_request');
    });

    test('a missing identity is refused with invalid_request', () async {
      await relay.handleCommand({
        'device_id': 'device-1',
        'command': 'dictation',
        'request_id': 'dict-1',
        'payload': {'op': 'status'},
      });
      expect(payloadsOf('dictation_error').single['code'], 'invalid_request');
    });

    test('an unsupported version fails closed as incompatible', () async {
      await relay.handleCommand(command(op: 'status', version: 'v2'));
      expect(payloadsOf('dictation_error').single['code'], 'incompatible');
    });

    test('an unknown op is a typed error, never a silent drop', () async {
      await relay.handleCommand(command(op: 'install_anything'));
      expect(payloadsOf('dictation_error').single['code'], 'invalid_request');
    });

    test('stop and cancel are refused on the control path', () async {
      await relay.handleCommand(command(op: 'stop'));
      expect(payloadsOf('dictation_error').single['code'], 'invalid_request');
    });

    test('a model command reports a typed failure to the origin', () async {
      await relay.handleCommand(command(op: 'select', modelId: 'nope'));
      expect(payloadsOf('dictation_error').single['code'], 'model_unknown');
      expect(relay.hasSession, isFalse);
    });
  });

  group('hosted dictation session lifecycle', () {
    test('start opens one session and a second start is busy', () async {
      await relay.handleCommand(command(op: 'start'));
      await until(() => relay.hasSession, reason: 'hosted session');
      // The recognizer announces readiness once its model is loaded; the session
      // re-emits that as `dictation_ready`, and only then may the client capture.
      engine.emit(const SttReadyEvent(loadMs: 100, modelId: 'test-model'));
      // The relay composes the channel and the one service starts the session
      // from the buffered start command; without it nothing loads.
      await until(
        () => payloadsOf('dictation_ready').isNotEmpty,
        reason: 'dictation_ready',
      );
      await until(() => service.isBusy, reason: 'session lease');
      expect(
        payloadsOf('dictation_ready').single['dictation_id'],
        'dict-1',
        reason: 'the client may only capture after ready',
      );

      await relay.handleCommand(command(op: 'start', dictationId: 'dict-2'));
      expect(payloadsOf('dictation_error').single['code'], 'dictation_busy');
    });

    test('a repeated start for the same session answers with status', () async {
      await relay.handleCommand(command(op: 'start'));
      await until(() => relay.hasSession, reason: 'hosted session');
      final before = payloadsOf('stt_status').length;

      await relay.handleCommand(command(op: 'start'));
      expect(payloadsOf('stt_status').length, greaterThan(before));
      expect(payloadsOf('dictation_error'), isEmpty);
    });

    test('audio for a foreign session never reaches the engine', () async {
      await relay.handleCommand(command(op: 'start'));
      await until(() => relay.hasSession, reason: 'hosted session');

      relay.onAudioFrame({
        'dictation_id': 'dict-2',
        'request_id': 'dict-2',
        'seq': 0,
        'data': const [1, 2, 3, 4],
      });
      relay.onAudioFrame({
        'dictation_id': 'dict-1',
        'request_id': 'dict-1',
        'seq': 0,
        'data': const [1, 2, 3, 4],
      });
      await until(
        () => engine.audioLengths.isNotEmpty,
        reason: 'own frame forwarded',
      );
      expect(engine.audioLengths, [4]);
    });

    test('an ordered end drives the daemon stop/cancel', () async {
      await relay.handleCommand(command(op: 'start'));
      await until(() => relay.hasSession, reason: 'hosted session');

      relay.onOrderedControl({
        'dictation_id': 'dict-1',
        'request_id': 'dict-1',
        'reason': 'stopped',
      });
      await until(() => engine.finishCalled, reason: 'drain');
      await until(() => !relay.hasSession, reason: 'session closed');
      expect(service.isBusy, isFalse);
    });

    test('an ordered end without a session answers unavailable', () async {
      relay.onOrderedControl({
        'dictation_id': 'dict-1',
        'request_id': 'dict-1',
        'reason': 'stopped',
      });
      expect(payloadsOf('dictation_error').single['code'], 'unavailable');
    });

    test('abort cancels the live session', () async {
      await relay.handleCommand(command(op: 'start'));
      await until(() => relay.hasSession, reason: 'hosted session');

      relay.onAbort({
        'dictation_id': 'dict-1',
        'request_id': 'dict-1',
        'reason': 'client_disconnect',
      });
      await until(() => engine.cancelCalled, reason: 'cancel');
      await until(() => !relay.hasSession, reason: 'session closed');
      expect(service.isBusy, isFalse);
    });

    test('a socket disconnect releases the session and the lease', () async {
      await relay.handleCommand(command(op: 'start'));
      await until(() => relay.hasSession, reason: 'hosted session');

      await relay.closeAll();
      await until(() => !service.isBusy, reason: 'lease released');
      expect(relay.hasSession, isFalse);
    });

    test('the canonical vocabulary is identical to the local channel', () async {
      await relay.handleCommand(command(op: 'start'));
      await until(() => relay.hasSession, reason: 'hosted session');

      // Same event names and fields as the local socket channel; only the
      // carrier differs.
      final status = payloadsOf('stt_status').single;
      expect(
        status.keys.toSet(),
        containsAll(<String>{
          'supported',
          'ready',
          'busy',
          'selected',
          'models',
        }),
      );
      expect(
        DictationCommand.values.map((command) => command.name),
        containsAll(<String>['start', 'stop', 'cancel', 'status']),
      );
    });
  });
}

Map<String, dynamic> payloadOfStatus(Map<String, dynamic> envelope) =>
    Map<String, dynamic>.from(envelope['payload'] as Map);
