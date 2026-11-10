import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
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
/// A route that already failed is **not** the opposite case. It admits nothing
/// further, but the Gateway's own route may still be live, and only this packet
/// (or a Gateway error, or a disconnect) retires it. Skipping the end on failure
/// therefore held the device for a minute after one refused press
/// (`dictation-download-live-20261110/RESULT.md`, D3).
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

  test('a failed route still ends its Gateway route, exactly once', () async {
    final transport = openTransport();
    transport.sendCommand('start');

    await failRoute('forbidden');

    // Nothing is written while the route is failed: no frame, no command.
    expect(ends(), isEmpty);
    transport.sendAudio(const [1, 2, 3]);
    transport.sendCommand('stop');
    expect(ends(), isEmpty);
    expect(commandCancels(), isEmpty);

    await transport.close();

    // The Gateway may still hold this route — only the ordered end retires it —
    // so the teardown sends it even though the local route already failed.
    expect(ends(), hasLength(1));
    expect(ends().single['reason'], 'cancelled');
    expect(commandCancels(), isEmpty);

    // Closing again is never a second end.
    await transport.close();
    expect(ends(), hasLength(1));
  });

  test('a local byte cap is diagnosed with its reason and counters', () async {
    final records = <String>[];
    final subscription = Logger('HostedDictationTransport').onRecord.listen(
      (record) => records.add(record.message),
    );
    addTearDown(subscription.cancel);

    // A 1 KiB cap makes the first frame trip it: the point is the diagnostic,
    // not the size.
    final transport = HostedDictationTransport.connect(
      socket: socket,
      deviceId: 'account-device-9',
      dictationId: 'dict-1',
      maxFrameBytes: 8192,
      maxSessionBytes: 1024,
    );
    transport.sendCommand('start');
    transport.sendAudio(List<int>.filled(2048, 0));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    // One line, and it says which bound fired: `session_limit` alone covered a
    // client byte cap, a client duration cap, and a Gateway size refusal.
    expect(records, hasLength(1));
    expect(records.single, contains('code=session_limit'));
    expect(records.single, contains('reason=bytes'));
    expect(records.single, contains('sent=0'));
    expect(records.single, contains('cap=1024'));
    expect(records.single, isNot(contains('gateway=')));

    await transport.close();
    // The failure is terminal for the transport but not for the route.
    expect(ends(), hasLength(1));
  });

  test('a local duration cap reports the duration bound, not the byte one',
      () async {
    final records = <String>[];
    final subscription = Logger('HostedDictationTransport').onRecord.listen(
      (record) => records.add(record.message),
    );
    addTearDown(subscription.cancel);

    var now = DateTime(2026, 11, 10, 12);
    final transport = HostedDictationTransport.connect(
      socket: socket,
      deviceId: 'account-device-9',
      dictationId: 'dict-1',
      maxFrameBytes: 8192,
      maxSessionSeconds: 30,
      clock: () => now,
    );
    transport.sendCommand('start');
    now = now.add(const Duration(seconds: 31));
    transport.sendAudio(const [1, 2, 3]);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(records, hasLength(1));
    expect(records.single, contains('code=session_limit'));
    expect(records.single, contains('reason=duration'));
    expect(records.single, contains('sent=0'));
    expect(records.single, contains('cap=30'));

    await transport.close();
  });

  test('the duration budget starts with the session, not the transport',
      () async {
    // D9: the same transport answers `status` (and every other control command)
    // long before a session exists. Anchoring the budget at construction made a
    // press minutes later fail `session_limit reason=duration sent=0` on a fresh
    // session, which blocked dictation during an active turn.
    final records = <String>[];
    final subscription = Logger('HostedDictationTransport').onRecord.listen(
      (record) => records.add(record.message),
    );
    addTearDown(subscription.cancel);

    var now = DateTime(2026, 11, 10, 12);
    final transport = HostedDictationTransport.connect(
      socket: socket,
      deviceId: 'account-device-9',
      dictationId: 'dict-1',
      maxFrameBytes: 8192,
      maxSessionSeconds: 30,
      clock: () => now,
    );

    // A model-sheet refresh on this transport, five minutes before the press.
    await Future<void>.delayed(const Duration(milliseconds: 20));
    now = now.add(const Duration(minutes: 5));

    transport.sendCommand('start');
    transport.sendAudio(const [1, 2, 3]);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(records.where((line) => line.contains('session_limit')), isEmpty);
    expect(transport.isOpen, isTrue);
    expect(ends(), isEmpty);

    // The session's own budget still bounds it: 31 s into the route, the next
    // frame is refused with the reason and the counters.
    now = now.add(const Duration(seconds: 31));
    transport.sendAudio(const [4, 5, 6]);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(records, hasLength(1));
    expect(records.single, contains('code=session_limit'));
    expect(records.single, contains('reason=duration'));
    expect(records.single, contains('cap=30'));

    await transport.close();
    expect(ends(), hasLength(1));
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
