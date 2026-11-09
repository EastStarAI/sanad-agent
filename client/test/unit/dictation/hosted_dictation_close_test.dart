import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/dictation/domain/hosted_dictation_transport.dart';

import '../../helpers/fake_socket.dart';

/// Ending a hosted session is the documented ordered control and nothing else.
///
/// An abandoned session — the capture failed, the cubit aborted, the widget went
/// away — leaves a live daemon session behind. `/dictation-end` (§6.3) is the one
/// carrier that ends it: the Agent relay answers a `dictation` command `op: cancel`
/// with `invalid_request` **by design** ("stop and cancel travel on the ordered
/// `dictation_end` control", `hosted_dictation_relay.dart:179-186`), so the command
/// path released nothing at all.
///
/// Leaving the route open was worse than a wasted packet: the Gateway keeps the
/// device occupied until its idle route TTL, so every press on every client was
/// refused `busy` for **5 m 35 s** after one aborted press
/// (`live-4/RESULT.md`, 05:46:54 → 05:53:26).
///
/// A route that already failed is the opposite case: it admits nothing, so the
/// teardown sends **nothing** and the Agent's `firstAudioTimeout` watchdog is the
/// backstop that releases the engine.
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

  /// The ordered route control, `dictation_end`.
  List<Map<String, dynamic>> ends() => [
    for (final entry in socket.capturedCommands)
      if (entry['event'] == 'dictation_end') entry['data'] as Map<String, dynamic>,
  ];

  /// The command-path teardown this Agent refuses.
  List<Map<String, dynamic>> commandCancels() => [
    for (final entry in socket.capturedCommands)
      if (entry['command'] == 'dictation' &&
          (entry['payload'] as Map?)?['op'] == 'cancel')
        entry['payload'] as Map<String, dynamic>,
  ];

  List<Map<String, dynamic>> dictationCommands() => [
    for (final entry in socket.capturedCommands)
      if (entry['command'] == 'dictation') entry['payload'] as Map<String, dynamic>,
  ];

  Future<void> failRoute(String errorCode) async {
    socket.debugEmitEvent({
      'event': 'dictation_route_error',
      'payload': {'dictation_id': 'dict-1', 'error_code': errorCode},
    });
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }

  test('an abandoned session ends its route with the ordered control', () async {
    final transport = openTransport();
    transport.sendCommand('start');
    expect(ends(), isEmpty);

    // No `stop`/`cancel` was ever asked for: the capture failed, so the cubit
    // just closes the transport.
    await transport.close();

    expect(ends(), hasLength(1));
    expect(ends().single, {
      'version': 'v1',
      'dictation_id': 'dict-1',
      'reason': 'cancelled',
    });
  });

  test('the abort carries only the route control, never a command', () async {
    final transport = openTransport();
    transport.sendCommand('start');

    await transport.close();

    // This Agent refuses `op: cancel`, so the abort must not spend a packet on
    // it: the route control is the documented carrier and the only one.
    expect(commandCancels(), isEmpty);
    expect(
      [for (final command in dictationCommands()) command['op']],
      ['start'],
    );
  });

  test('a session that already ended sends no second end', () async {
    final transport = openTransport();
    transport.sendCommand('start');
    transport.sendCommand('stop');
    expect(ends(), hasLength(1));
    expect(ends().single['reason'], 'stopped');

    await transport.close();

    // The daemon session is already over; a second `dictation_end` for the same
    // route is a duplicate intent the Gateway would only have to referee.
    expect(ends(), hasLength(1));
  });

  test('a cancel already carried on the route is not repeated', () async {
    final transport = openTransport();
    transport.sendCommand('start');
    transport.sendCommand('cancel');
    expect(ends(), hasLength(1));
    expect(ends().single['reason'], 'cancelled');

    await transport.close();

    expect(ends(), hasLength(1));
    expect(commandCancels(), isEmpty);
  });

  test('a failed route sends nothing on the way out', () async {
    final transport = openTransport();
    transport.sendCommand('start');

    await failRoute('forbidden');

    // The route admits nothing, so there is no carrier left: the Agent's
    // first-audio watchdog releases the engine, and the Gateway retires the
    // route on its own.
    expect(ends(), isEmpty);
    expect(commandCancels(), isEmpty);

    await transport.close();

    expect(ends(), isEmpty);
    expect(commandCancels(), isEmpty);
  });

  test('a transport that never opened a route sends nothing', () async {
    final transport = openTransport();

    await transport.close();

    // No claim, no route, no session: nothing to end.
    expect(ends(), isEmpty);
    expect(commandCancels(), isEmpty);
    expect(dictationCommands(), isEmpty);
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
