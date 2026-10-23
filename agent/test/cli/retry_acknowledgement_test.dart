/// The runtime retry acknowledgement path, exercised through the real client.
///
/// `LocalGatewayCliClient.retryRuntimeAndAwaitAck` dispatches
/// `session.runtime_retry` and reports the daemon's own recovery projection.
/// These tests drive the actual frame → acknowledgement path over a scripted
/// socket: the payload the client sends, the notice it accepts as accepted, the
/// correlated notice it turns into a typed rejection, and the unacknowledged
/// outcome it never reports as accepted.
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

  Map<String, dynamic> sentRetry() {
    final retry = socket.sentMessages
        .map((raw) => jsonDecode(raw) as Map<String, dynamic>)
        .firstWhere((command) => command['command'] == 'session.runtime_retry');
    return retry;
  }

  /// Publishes one canonical frame exactly as `SanadProtocolBridge` does.
  void emitCanonical(
    String type,
    Map<String, dynamic> payload, {
    String sessionId = 'sess-blocked',
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

  test('sends the command payload with the caller request id', () async {
    final ackFuture = client.retryRuntimeAndAwaitAck(
      sessionId: 'sess-blocked',
      requestId: 'req-retry-1',
    );
    await settle();

    final sent = sentRetry();
    final payload = Map<String, dynamic>.from(sent['payload'] as Map);
    expect(sent['request_id'], 'req-retry-1');
    expect(payload['session_id'], 'sess-blocked');
    expect(payload['request_id'], 'req-retry-1');
    expect(
      payload.containsKey('provider_instance_id'),
      isFalse,
      reason: 'a same-route retry sends no route override',
    );
    expect(payload.containsKey('model_id'), isFalse);

    emitCanonical('session.runtime_notice', {
      'session_id': 'sess-blocked',
      // The daemon resumes under the turn's request id, not the command's.
      'request_id': 'req-turn-9',
      'status': 'resuming',
      'reason': 'manual_retry',
      'title': 'Resuming...',
    });

    final ack = await ackFuture;
    expect(ack['status'], 'resuming');
    expect(ack['request_id'], 'req-retry-1');
    expect(ack['notice_request_id'], 'req-turn-9');
    expect(
      ack['correlated'],
      isFalse,
      reason: 'the resuming notice names the resumed turn, not the command',
    );
  });

  test('forwards the optional route override', () async {
    final ackFuture = client.retryRuntimeAndAwaitAck(
      sessionId: 'sess-blocked',
      requestId: 'req-retry-route',
      providerInstanceId: 'inst-openai-1',
      modelId: 'gpt-5.1',
    );
    await settle();

    final payload = Map<String, dynamic>.from(sentRetry()['payload'] as Map);
    expect(payload['provider_instance_id'], 'inst-openai-1');
    expect(payload['model_id'], 'gpt-5.1');

    emitCanonical('session.runtime_notice', {
      'session_id': 'sess-blocked',
      'request_id': 'req-retry-route',
      'status': 'resuming',
      'reason': 'manual_retry',
    });
    final ack = await ackFuture;
    expect(ack['correlated'], isTrue);
  });

  test('a correlated blocked notice is a typed rejection', () async {
    final ackFuture = client.retryRuntimeAndAwaitAck(
      sessionId: 'sess-blocked',
      requestId: 'req-retry-unsafe',
    );
    await settle();

    emitCanonical('session.runtime_notice', {
      'session_id': 'sess-blocked',
      'request_id': 'req-retry-unsafe',
      'status': 'blocked',
      'reason': 'unknown',
      'title': 'Saved work is not safe to retry',
      'message': 'The interrupted provider request has no recognized '
          'preceding checkpoint.',
    });

    await expectLater(
      ackFuture,
      throwsA(
        isA<CliClientException>()
            .having((e) => e.code, 'code', 'retry_rejected')
            .having((e) => e.message, 'message', contains('not safe to retry')),
      ),
    );
  });

  test('a correlated error frame is a typed rejection', () async {
    final ackFuture = client.retryRuntimeAndAwaitAck(
      sessionId: 'sess-blocked',
      requestId: 'req-retry-error',
    );
    await settle();

    emitCanonical('error', {
      'session_id': 'sess-blocked',
      'request_id': 'req-retry-error',
      'code': 'model_not_found',
      'message': 'The selected provider has no default model.',
      'is_fatal': false,
    });

    await expectLater(
      ackFuture,
      throwsA(
        isA<CliClientException>().having(
          (e) => e.code,
          'code',
          'model_not_found',
        ),
      ),
    );
  });

  test('ignores a rejection for another request id', () async {
    final ackFuture = client.retryRuntimeAndAwaitAck(
      sessionId: 'sess-blocked',
      requestId: 'req-mine',
    );
    await settle();

    emitCanonical('error', {
      'session_id': 'sess-blocked',
      'request_id': 'req-someone-else',
      'code': 'model_not_found',
      'message': 'unrelated',
    });
    emitCanonical('session.runtime_notice', {
      'session_id': 'sess-blocked',
      'request_id': 'req-someone-else',
      'status': 'blocked',
      'reason': 'unknown',
      'title': 'Unrelated',
    });
    await settle();

    emitCanonical('session.runtime_notice', {
      'session_id': 'sess-blocked',
      'request_id': 'req-turn-3',
      'status': 'resuming',
      'reason': 'manual_retry',
    });

    final ack = await ackFuture;
    expect(ack['request_id'], 'req-mine');
    expect(ack['status'], 'resuming');
  });

  test('ignores a resuming notice for another session', () async {
    final ackFuture = client.retryRuntimeAndAwaitAck(
      sessionId: 'sess-blocked',
      requestId: 'req-scoped',
    );
    await settle();

    emitCanonical(
      'session.runtime_notice',
      {
        'session_id': 'sess-other',
        'request_id': 'req-turn-5',
        'status': 'resuming',
        'reason': 'auto_resume',
      },
      sessionId: 'sess-other',
    );
    await settle();

    emitCanonical('session.runtime_notice', {
      'session_id': 'sess-blocked',
      'request_id': 'req-turn-6',
      'status': 'resuming',
      'reason': 'manual_retry',
    });

    final ack = await ackFuture;
    expect(ack['status'], 'resuming');
    expect(ack['notice_request_id'], 'req-turn-6');
  });

  test('reports an unacknowledged retry instead of claiming it was accepted',
      () async {
    await expectLater(
      client.retryRuntimeAndAwaitAck(
        sessionId: 'sess-blocked',
        requestId: 'req-silent',
        timeout: const Duration(milliseconds: 50),
      ),
      throwsA(
        isA<CliClientException>().having(
          (e) => e.code,
          'code',
          'retry_unacknowledged',
        ),
      ),
    );
  });
}
