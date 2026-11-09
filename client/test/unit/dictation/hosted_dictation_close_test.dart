import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/dictation/domain/hosted_dictation_transport.dart';

import '../../helpers/fake_socket.dart';

/// A hosted session the Client abandons must not keep the daemon's engine
/// leased. The route control (`dictation_end`) is unusable after a route
/// failure, so the cancel travels on the `dictation` **command** path, which
/// still works: the route died, not the claim.
///
/// Without it the daemon kept the engine until the Gateway's 300 s idle route
/// TTL, and every press in that window was answered `dictation_busy`
/// (`live-3/RESULT.md`, 03:50:17 → 03:55:47).
void main() {
  late FakeSanadSocketService socket;

  setUp(() {
    socket = FakeSanadSocketService(hardwareId: 'this-mac')..setConnected(true);
  });

  tearDown(() => socket.dispose());

  HostedDictationTransport openTransport() => HostedDictationTransport.connect(
    socket: socket,
    deviceId: 'account-device-9',
    dictationId: 'dict-1',
    maxFrameBytes: 8192,
  );

  List<Map<String, dynamic>> cancelCommands() => [
    for (final entry in socket.capturedCommands)
      if (entry['command'] == 'dictation' &&
          (entry['payload'] as Map?)?['op'] == 'cancel')
        entry['payload'] as Map<String, dynamic>,
  ];

  Future<void> failRoute(String errorCode) async {
    socket.debugEmitEvent({
      'event': 'dictation_route_error',
      'payload': {'dictation_id': 'dict-1', 'error_code': errorCode},
    });
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }

  test('a failed route cancels the daemon session on the command path', () async {
    final transport = openTransport();
    transport.sendCommand('start');

    await failRoute('forbidden');

    final cancels = cancelCommands();
    expect(cancels, hasLength(1));
    expect(cancels.single, {
      'version': 'v1',
      'dictation_id': 'dict-1',
      'request_id': 'dict-1',
      'op': 'cancel',
    });

    await transport.close();
  });

  test('closing a started session cancels it exactly once', () async {
    final transport = openTransport();
    transport.sendCommand('start');

    await transport.close();

    expect(cancelCommands(), hasLength(1));
  });

  test('a session that already sent route control is not cancelled again', () async {
    final transport = openTransport();
    transport.sendCommand('start');
    // `cancel` already travels as the ordered `dictation_end` control; a second
    // cancel would be two carriers for one intent.
    transport.sendCommand('cancel');

    await transport.close();

    expect(cancelCommands(), isEmpty);
  });

  test('a transport that never opened a route cancels nothing', () async {
    final transport = openTransport();

    await transport.close();

    expect(cancelCommands(), isEmpty);
  });

  test('a failed route is not a reusable transport', () async {
    final transport = openTransport();
    transport.sendCommand('start');
    expect(transport.isOpen, isTrue);

    await failRoute('forbidden');

    // The socket is healthy but this session is not: `sendCommand` refuses to
    // write, so reporting it as open made the cubit reuse a dead transport and
    // the cloud path looked permanently wedged.
    expect(transport.isOpen, isFalse);

    await transport.close();
  });
}
