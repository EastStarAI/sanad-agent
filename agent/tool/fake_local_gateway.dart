/// A throwaway Local Gateway that lets a compiled CLI finish a complete
/// discovery, WebSocket handshake, and command round trip.
///
/// The CLI regression guard must never point at the developer's daemon, the
/// real `SANAD_HOME`, or the default port. This fake binds an ephemeral
/// loopback port, answers `/health` plus the canonical `execute_command`
/// envelopes the CLI issues, and records the authentication header and
/// commands it received so a caller can prove the CLI used the throwaway
/// token and reached the gateway.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A session identity the fake gateway reports; callers assert on it.
const String fakeSessionId = 'fake-gateway-session';
const String fakeSessionTitle = 'Fake gateway session';
const String fakeSessionCreatedAt = '2026-01-01T00:00:00Z';
const String fakeFinalAnswer = 'fake gateway reply';
const String fakeRunId = 'fake-gateway-run';

class FakeLocalGateway {
  FakeLocalGateway._(this._server, this.homeId);

  final HttpServer _server;
  final List<WebSocket> _sockets = [];

  /// The Home identity this fake proves in `/health`, so a CLI that selected a
  /// `--home` accepts it. Null when the caller wants a legacy payload.
  final String? homeId;

  /// Every decoded frame the CLI sent, in arrival order.
  final List<Map<String, dynamic>> receivedFrames = [];

  /// The `x-sanad-local-token` header of every `/health` probe.
  final List<String> healthTokens = [];

  static Future<FakeLocalGateway> start({String? homeId}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final gateway = FakeLocalGateway._(server, homeId);
    server.listen(gateway._handle);
    return gateway;
  }

  int get port => _server.port;

  /// The endpoint `--gateway-url` accepts; the CLI derives `ws://` from it and
  /// probes `/health` on the same port.
  Uri get gatewayUrl => Uri.parse('http://127.0.0.1:$port/gateway');

  /// Commands the CLI issued, in arrival order.
  List<String> get commands => [
    for (final frame in receivedFrames)
      if (frame['command'] != null) frame['command'].toString(),
  ];

  Future<void> close() async {
    for (final socket in List<WebSocket>.of(_sockets)) {
      await socket.close();
    }
    _sockets.clear();
    await _server.close(force: true);
  }

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    if (path == '/health') {
      healthTokens.add(request.headers.value('x-sanad-local-token') ?? '');
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write(
          jsonEncode({'status': 'ok', if (homeId != null) 'home_id': homeId}),
        );
      await request.response.close();
      return;
    }
    if (path != '/gateway' && path != '/ws') {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    final socket = await WebSocketTransformer.upgrade(request);
    _sockets.add(socket);
    socket.listen(
      (data) => _onFrame(socket, data),
      onDone: () => _sockets.remove(socket),
      onError: (_) => _sockets.remove(socket),
      cancelOnError: true,
    );
  }

  void _onFrame(WebSocket socket, dynamic data) {
    final text = data is String ? data : utf8.decode(data as List<int>);
    final decoded = jsonDecode(text);
    if (decoded is! Map) return;
    final frame = Map<String, dynamic>.from(decoded);
    receivedFrames.add(frame);
    if (frame['type'] != 'execute_command') return;
    final command = frame['command']?.toString();
    if (command == null) return;
    final payload = frame['payload'] is Map
        ? Map<String, dynamic>.from(frame['payload'] as Map)
        : <String, dynamic>{};
    final requestId = (payload['request_id'] ?? frame['request_id'])
        ?.toString();
    final sessionId = payload['session_id']?.toString() ?? fakeSessionId;

    final reply = <String, dynamic>{
      'sessions': [
        {
          'session_id': fakeSessionId,
          'title': fakeSessionTitle,
          'model': 'fake-model',
        },
      ],
      'session_id': sessionId,
      'workspaces': const <dynamic>[],
      'messages': [
        {
          'type': 'user_message',
          'text': 'hello',
          'created_at': '2026-01-01T00:00:00Z',
        },
      ],
    };
    if (requestId != null) reply['request_id'] = requestId;
    reply.addAll(_commandExtras(command, sessionId));

    socket.add(
      jsonEncode({
        'type': 'response',
        'request_id': requestId,
        'payload': reply,
      }),
    );

    // A `think` is only complete when an answer arrives, so the fake gateway
    // publishes one for the caller's request instead of leaving the CLI and
    // the oneshot runner waiting for a turn that never ends.
    if (command == 'think') {
      socket.add(
        jsonEncode({
          'type': 'final_answer',
          'payload': {
            'request_id': requestId,
            'session_id': sessionId,
            'run_id': fakeRunId,
            'text': fakeFinalAnswer,
          },
        }),
      );
    }
  }

  Map<String, dynamic> _commandExtras(String command, String sessionId) {
    switch (command) {
      case 'get_session_history':
        // A known session is projected with its own identity fields; the daemon
        // omits them entirely when it does not know the id, which is how
        // `session show` tells a stopped turn from a missing session.
        return {
          'in_flight': null,
          'execution_snapshot': {'state': 'idle'},
          'history_revision': 1,
          'title': fakeSessionTitle,
          'created_at': fakeSessionCreatedAt,
          'updated_at': fakeSessionCreatedAt,
          'model': 'fake-model',
        };
      case 'stop_session':
        return {'status': 'stopped'};
      case 'think':
        return {'accepted': true};
      default:
        return const {};
    }
  }
}
