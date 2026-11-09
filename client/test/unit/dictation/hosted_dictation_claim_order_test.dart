import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/dictation/domain/hosted_dictation_transport.dart';

import '../../helpers/fake_socket.dart';

/// Canonical §6.1: "a route never exists without a claim, and a claim is never
/// created by a route packet". The Client therefore has to dispatch the
/// `dictation` claim command **before** the route packet, and it has to open that
/// route exactly once per session.
///
/// The transport used to do neither: `connect()` emitted `dictation_start`
/// before anything had created the claim, and `sendCommand('start')` emitted it
/// again because `_openRoute()` never recorded that it had run. The Gateway
/// answered the premature packet `forbidden`, the Client abandoned the session,
/// and the daemon kept the engine the claim command had already started.
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

  /// Socket packets in the order the transport handed them over.
  List<String> wireOrder() => [
    for (final entry in socket.capturedCommands)
      (entry['event'] ?? entry['command']) as String,
  ];

  List<Map<String, dynamic>> routes() => [
    for (final entry in socket.capturedCommands)
      if (entry['event'] == 'dictation_start') entry['data'] as Map<String, dynamic>,
  ];

  test('constructing a transport sends nothing', () async {
    final transport = openTransport();

    // A route packet at construction time cannot be claimed yet: the claim is
    // minted by the `dictation` command, which the caller sends on start.
    expect(wireOrder(), isEmpty);

    await transport.close();
  });

  test('start claims first and opens exactly one route', () async {
    final transport = openTransport();

    transport.sendCommand('start');

    // Two packets, in this order: the claim command, then the route it admits.
    expect(wireOrder(), ['dictation', 'dictation_start']);
    expect(socket.capturedCommands.first['payload'], {
      'version': 'v1',
      'dictation_id': 'dict-1',
      'request_id': 'dict-1',
      'op': 'start',
    });
    expect(routes().single, {
      'version': 'v1',
      'dictation_id': 'dict-1',
      'device_id': 'account-device-9',
      'request_id': 'dict-1',
      'audio': {'encoding': 'pcm16le', 'sample_rate': 16000, 'channels': 1},
      'max_bytes': 12582912,
    });

    await transport.close();
  });

  test('a repeated start opens no second route', () async {
    final transport = openTransport();

    transport.sendCommand('start');
    transport.sendCommand('start');

    // The route carries the session identity: a second packet can only be a
    // duplicate for the Gateway to referee.
    expect(routes(), hasLength(1));

    await transport.close();
  });

  test('the audio route is opened only by start, never by a status refresh', () async {
    final transport = openTransport();

    transport.sendCommand('status');

    expect(routes(), isEmpty);
    expect(wireOrder(), ['dictation']);

    await transport.close();
  });
}
