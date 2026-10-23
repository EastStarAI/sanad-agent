/// The steer acknowledgement path, exercised through the real client.
///
/// `LocalGatewayCliClient.steerAndAwaitAck` classifies whatever the gateway
/// publishes for exactly one message id. The CLI tests inject a finished ack
/// map, so these tests drive the actual frame → classification path over a
/// scripted socket: the payload the client sends, the acknowledgement it
/// accepts, and the typed rejection it turns into [CliClientException].
library;

import 'dart:convert';

import 'package:sanad_agent/cli/client/local_gateway_cli_client.dart';
import 'package:test/test.dart';

import '../support/isolated_sanad_test_home.dart';
import '../support/mock_gateway_websocket.dart';

void main() {
  useIsolatedSanadTestHome();

  late MockGatewayWebSocket socket;
  late LocalGatewayCliClient client;

  LocalGatewayCliClient buildClient({
    Duration requestTimeout = const Duration(seconds: 2),
  }) {
    socket = MockGatewayWebSocket();
    return LocalGatewayCliClient(
      gatewayUri: Uri.parse('ws://127.0.0.1:58085/gateway'),
      token: 'test-token',
      autoReconnect: false,
      connectTimeout: const Duration(seconds: 2),
      requestTimeout: requestTimeout,
      connector: (uri, {headers, timeout}) async => socket,
    );
  }

  Map<String, dynamic> sentSteer() {
    final steer = socket.sentMessages
        .map((raw) => jsonDecode(raw) as Map<String, dynamic>)
        .firstWhere((command) => command['command'] == 'steer');
    return steer;
  }

  /// Publishes one canonical frame exactly as `SanadProtocolBridge` does.
  void emitCanonical(
    String type,
    Map<String, dynamic> payload, {
    String sessionId = 'sess-steer',
  }) {
    socket.emitFromServer(
      jsonEncode({
        'type': 'event',
        'event': type,
        'session_id': sessionId,
        if (payload['request_id'] != null) 'request_id': payload['request_id'],
        'payload': payload,
      }),
    );
  }

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 20));

  setUp(() async {
    client = buildClient();
    await client.connect();
  });

  tearDown(() async {
    await client.dispose();
  });

  test('dispatches steer_only and accepts the daemon classification', () async {
    final ackFuture = client.steerAndAwaitAck(
      sessionId: 'sess-steer',
      message: 'Add an audit trail',
      requestId: 'req-steer-1',
      steerOnly: true,
    );
    await settle();

    final sent = sentSteer();
    expect(sent['request_id'], 'req-steer-1');
    expect((sent['payload'] as Map)['session_id'], 'sess-steer');
    expect((sent['payload'] as Map)['message'], 'Add an audit trail');
    expect(
      (sent['payload'] as Map)['steer_only'],
      isTrue,
      reason: 'the flag is what stops the daemon admitting the text as a turn',
    );

    emitCanonical('session.message_classified', {
      'session_id': 'sess-steer',
      'request_id': 'req-steer-1',
      'classification': 'steer',
    });

    final ack = await ackFuture;
    expect(ack['classification'], 'steer');
    expect(ack['request_id'], 'req-steer-1');
    expect(ack['event'], 'session.message_classified');
  });

  test('omits steer_only when the caller does not opt in', () async {
    final ackFuture = client.steerAndAwaitAck(
      sessionId: 'sess-steer',
      message: 'Add an audit trail',
      requestId: 'req-legacy-1',
    );
    await settle();

    expect(
      (sentSteer()['payload'] as Map).containsKey('steer_only'),
      isFalse,
      reason: 'a client that omits the flag keeps the legacy behaviour',
    );

    emitCanonical('session.message_classified', {
      'session_id': 'sess-steer',
      'request_id': 'req-legacy-1',
      'classification': 'think',
    });

    final ack = await ackFuture;
    expect(ack['classification'], 'think');
  });

  test('turns a correlated daemon rejection into a typed exception', () async {
    final ackFuture = client.steerAndAwaitAck(
      sessionId: 'sess-steer',
      message: 'Add an audit trail',
      requestId: 'req-steer-rejected',
      steerOnly: true,
    );
    await settle();

    emitCanonical('error', {
      'session_id': 'sess-steer',
      'request_id': 'req-steer-rejected',
      'code': 'no_active_turn',
      'message': 'No run currently owns session sess-steer, so the steer was '
          'rejected. No turn was started and the text was not queued.',
      'is_fatal': false,
    });

    await expectLater(
      ackFuture,
      throwsA(
        isA<CliClientException>().having(
          (e) => e.code,
          'code',
          'no_active_turn',
        ),
      ),
    );
  });

  test('ignores a rejection that belongs to another request id', () async {
    final ackFuture = client.steerAndAwaitAck(
      sessionId: 'sess-steer',
      message: 'Add an audit trail',
      requestId: 'req-mine',
      steerOnly: true,
    );
    await settle();

    emitCanonical('error', {
      'session_id': 'sess-steer',
      'request_id': 'req-someone-else',
      'code': 'no_active_turn',
      'message': 'unrelated',
    });
    await settle();

    emitCanonical('session.message_classified', {
      'session_id': 'sess-steer',
      'request_id': 'req-mine',
      'classification': 'steer',
    });

    final ack = await ackFuture;
    expect(ack['request_id'], 'req-mine');
    expect(ack['classification'], 'steer');
  });

  test('accepts only a pending-or-later pending_steer record as a steer', () async {
    final accepted = client.steerAndAwaitAck(
      sessionId: 'sess-steer',
      message: 'Add an audit trail',
      requestId: 'req-pending',
      steerOnly: true,
    );
    await settle();
    emitCanonical('session.pending_steer_changed', {
      'session_id': 'sess-steer',
      'request_id': 'req-pending',
      'state': 'pending',
    });
    final ack = await accepted;
    expect(ack['classification'], 'steer');
    expect(ack['state'], 'pending');

    final cancelled = client.steerAndAwaitAck(
      sessionId: 'sess-steer',
      message: 'Add an audit trail',
      requestId: 'req-cancelled',
      steerOnly: true,
    );
    await settle();
    emitCanonical('session.pending_steer_changed', {
      'session_id': 'sess-steer',
      'request_id': 'req-cancelled',
      'state': 'cancelled',
    });
    final cancelledAck = await cancelled;
    expect(
      cancelledAck['classification'],
      isNull,
      reason: 'a cancelled record never became a steer',
    );
    expect(cancelledAck['state'], 'cancelled');
  });

  test('reports an unacknowledged steer instead of claiming it was sent', () async {
    await expectLater(
      client.steerAndAwaitAck(
        sessionId: 'sess-steer',
        message: 'Add an audit trail',
        requestId: 'req-silent',
        steerOnly: true,
        timeout: const Duration(milliseconds: 50),
      ),
      throwsA(
        isA<CliClientException>().having(
          (e) => e.code,
          'code',
          'steer_unacknowledged',
        ),
      ),
    );
  });

  test('a canonical error frame is a typed failure of the session read', () async {
    final history = client.getSessionHistory(sessionId: 'sess-steer');
    await settle();

    final request = socket.sentMessages
        .map((raw) => jsonDecode(raw) as Map<String, dynamic>)
        .firstWhere((command) => command['command'] == 'get_session_history');

    // Exactly the shape `SanadProtocolBridge` publishes for a failed query.
    socket.emitFromServer(
      jsonEncode({
        'type': 'event',
        'event': 'error',
        'request_id': request['request_id'],
        'payload': {
          'request_id': request['request_id'],
          'code': 'invalid_cursor',
          'message': 'cursor is not valid for this session',
        },
      }),
    );

    await expectLater(
      history,
      throwsA(
        isA<CliClientException>()
            .having((e) => e.code, 'code', 'invalid_cursor')
            .having((e) => e.message, 'message', contains('not valid')),
      ),
    );
  });
}
