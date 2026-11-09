import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/driver/dictation_probe.dart';

/// The probe must evidence a **local** dictation leg.
///
/// It counted hosted-relay classes only, so a real local session reported
/// `total: 0` and the leg could not be evidenced at all. These tests pin the
/// local vocabulary, the phase transitions, and the identity rule: a local event
/// carries no identities, so it is never "foreign".
class _FakeSocket {
  final StreamController<Map<String, dynamic>> controller =
      StreamController<Map<String, dynamic>>.broadcast();

  Stream<Map<String, dynamic>> get events => controller.stream;

  void push(Map<String, dynamic> event) => controller.add(event);
}

void main() {
  late _FakeSocket socket;
  late DriverDictationProbe probe;

  setUp(() {
    socket = _FakeSocket();
    probe = DriverDictationProbe(
      events: socket.events,
      isConnected: () => true,
    );
  });

  tearDown(() async {
    probe.dispose();
    await socket.controller.close();
  });

  Future<void> emit(Map<String, dynamic> event) async {
    socket.push(event);
    await Future<void>.delayed(Duration.zero);
  }

  test('counts every local session event class', () async {
    await emit({
      'event': 'stt_status',
      'ready': true,
      'supported': true,
      'models': const [],
    });
    await emit({'event': 'dictation_ready', 'model_id': 'm1', 'load_ms': 12});
    await emit({'event': 'dictation_partial', 'seq': 1, 'text': 'hello'});
    await emit({'event': 'dictation_final', 'seq': 1, 'text': 'hello there'});
    await emit({'event': 'dictation_done', 'segments': 1});

    final snapshot = probe.snapshot();
    expect(snapshot['total'], 5);
    // No identity was expected, so every local event is matched, none foreign.
    expect(snapshot['matched'], 5);
    expect(snapshot['foreign'], 0);
    final byClass = snapshot['by_class'] as Map<String, int>;
    expect(byClass['stt_status'], 1);
    expect(byClass['dictation_ready'], 1);
    expect(byClass['dictation_partial'], 1);
    expect(byClass['dictation_final'], 1);
    expect(byClass['dictation_done'], 1);
    expect(snapshot['phase'], 'done');
  });

  test('a local refusal counts its code and sets the error phase', () async {
    await emit({
      'event': 'dictation_error',
      'code': 'model_not_installed',
      'message': 'install a dictation model first',
    });

    final snapshot = probe.snapshot();
    expect(snapshot['phase'], 'error');
    expect(
      (snapshot['error_codes'] as Map<String, int>)['model_not_installed'],
      1,
    );
    // Codes only: the daemon message is never stored or returned.
    expect(snapshot.toString(), isNot(contains('install a dictation model')));
  });

  test('a status reply only sets the phase before a session starts', () async {
    await emit({'event': 'stt_status', 'ready': false});
    expect(probe.snapshot()['phase'], 'not_ready');

    await emit({'event': 'dictation_ready', 'model_id': 'm1', 'load_ms': 1});
    await emit({'event': 'stt_status', 'ready': true});
    expect(
      probe.snapshot()['phase'],
      'listening',
      reason: 'a late status reply must not rewrite the session phase',
    );
  });

  test('a local event is never counted as foreign for another device', () async {
    probe.expect(deviceId: 'device-1');

    await emit({'event': 'dictation_final', 'seq': 1, 'text': 'hello'});

    final snapshot = probe.snapshot();
    expect(snapshot['matched'], 1);
    expect(snapshot['foreign'], 0);
  });

  test('a relay event for another device is still foreign', () async {
    probe.expect(deviceId: 'device-1');

    await emit({
      'event': 'dictation_event',
      'payload': {'origin_device_id': 'device-2', 'type': 'final'},
    });

    final snapshot = probe.snapshot();
    expect(snapshot['matched'], 0);
    expect(snapshot['foreign'], 1);
  });

  // The seam gap: a local session arrives on the separate dictation WebSocket,
  // never on the main socket, so the probe could not evidence it at all.
  group('the dictation transport stream', () {
    late StreamController<Map<String, dynamic>> transport;

    setUp(() {
      transport = StreamController<Map<String, dynamic>>.broadcast();
    });

    tearDown(() async {
      await transport.close();
    });

    test('counts a session that never reaches the main socket', () async {
      probe.attachTransport(transport.stream);

      transport.add({'event': 'stt_status', 'ready': true, 'supported': true});
      transport.add({'event': 'dictation_ready', 'model_id': 'm1', 'load_ms': 4});
      transport.add({'event': 'dictation_partial', 'seq': 0, 'text': 'hello'});
      transport.add({'event': 'dictation_final', 'seq': 0, 'text': 'hello there'});
      transport.add({'event': 'dictation_done', 'segments': 1});
      await Future<void>.delayed(Duration.zero);

      final snapshot = probe.snapshot();
      expect(snapshot['total'], 5);
      expect(snapshot['matched'], 5);
      expect(snapshot['foreign'], 0);
      expect(snapshot['phase'], 'done');
      expect(
        (snapshot['by_class'] as Map<String, int>)['dictation_final'],
        1,
      );
    });

    test('counting the transport twice is impossible', () async {
      probe.attachTransport(transport.stream);
      probe.attachTransport(transport.stream);

      transport.add({'event': 'dictation_final', 'seq': 0, 'text': 'once'});
      await Future<void>.delayed(Duration.zero);

      expect(probe.snapshot()['total'], 1);
    });

    test('replacing the transport stops counting the old one', () async {
      final other = StreamController<Map<String, dynamic>>.broadcast();
      probe.attachTransport(transport.stream);
      probe.attachTransport(other.stream);

      transport.add({'event': 'dictation_final', 'seq': 0, 'text': 'old'});
      other.add({'event': 'dictation_final', 'seq': 0, 'text': 'new'});
      await Future<void>.delayed(Duration.zero);

      expect(probe.snapshot()['total'], 1);
      await other.close();
    });
  });
}
