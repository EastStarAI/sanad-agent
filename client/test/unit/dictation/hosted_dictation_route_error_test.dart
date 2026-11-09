import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/dictation/domain/hosted_dictation_transport.dart';

import '../../helpers/fake_socket.dart';

/// Canonical §8 is the single authority for a route refusal. Every wire code the
/// Gateway may send maps to exactly one client code, and no code is invented on
/// this side.
void main() {
  late FakeSanadSocketService socket;

  setUp(() {
    socket = FakeSanadSocketService(hardwareId: 'this-mac')..setConnected(true);
  });

  tearDown(() {
    socket.dispose();
  });

  Future<String> mappedCodeFor(String wireCode) async {
    final transport = HostedDictationTransport.connect(
      socket: socket,
      deviceId: 'account-device-9',
      dictationId: 'dict-1',
      maxFrameBytes: 8192,
    );
    final failure = Completer<String>();
    final subscription = transport.events.listen((event) {
      if (event['event'] == 'dictation_error' && !failure.isCompleted) {
        failure.complete(event['code']?.toString() ?? '');
      }
    });
    socket.debugEmitEvent({
      'event': 'dictation_route_error',
      'payload': {'dictation_id': 'dict-1', 'error_code': wireCode},
    });
    final code = await failure.future.timeout(const Duration(seconds: 1));
    await subscription.cancel();
    await transport.close();
    return code;
  }

  test('every canonical route code maps to its single client outcome', () async {
    expect(await mappedCodeFor('busy'), 'dictation_busy');
    expect(await mappedCodeFor('size_limit'), 'session_limit');
    expect(await mappedCodeFor('rate_limited'), 'session_limit');

    // A malformed request is diagnosable and is not "retry later": the frame
    // this Client just built was refused, so it keeps its own code instead of
    // collapsing into the generic relay verdict.
    expect(await mappedCodeFor('invalid_request'), 'relay_invalid_request');

    // A version mismatch is a retry-later outcome; it is not promoted into an
    // "update required" verdict §8 never declared.
    for (final wireCode in const [
      'incompatible',
      'offline',
      'forbidden',
      'expired',
    ]) {
      expect(
        await mappedCodeFor(wireCode),
        'relay_unavailable',
        reason: '$wireCode must follow the canonical fallback',
      );
    }
  });

  test('a route error for another dictation session is ignored', () async {
    final transport = HostedDictationTransport.connect(
      socket: socket,
      deviceId: 'account-device-9',
      dictationId: 'dict-1',
      maxFrameBytes: 8192,
    );
    final received = <String>[];
    final subscription = transport.events.listen((event) {
      if (event['event'] == 'dictation_error') {
        received.add(event['code']?.toString() ?? '');
      }
    });

    socket.debugEmitEvent({
      'event': 'dictation_route_error',
      'payload': {'dictation_id': 'someone-else', 'error_code': 'busy'},
    });
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(received, isEmpty);
    await subscription.cancel();
    await transport.close();
  });
}
