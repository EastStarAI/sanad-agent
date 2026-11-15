/// `session.stream_state` is the narrow repair query for one running stream.
///
/// It must answer from the in-memory in-flight projection alone: no history
/// page, no row projection, no cursor. A consumer that lost or misordered deltas
/// asks this instead of reloading a conversation, so the answer is either that
/// one snapshot or an explicit `absent`, and a malformed request fails typed
/// rather than silently returning an empty stream.
library;

import 'package:mockito/mockito.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/evolution/models/session_state.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_command_translator.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/sanad_protocol_bridge.dart';
import 'package:test/test.dart';

import '../support/in_memory_auth_manager.dart';
import 'interfaces_test.mocks.dart';

void main() {
  late MockSessionManager sessions;
  late SanadProtocolBridge bridge;
  late List<Map<String, dynamic>> envelopes;

  SessionState sessionState(String sessionId) => SessionState(
    sessionId: sessionId,
    model: 'sanad-agent',
    createdAt: DateTime.utc(2026, 1, 1),
    updatedAt: DateTime.utc(2026, 1, 1),
  );

  setUp(() {
    getIt.reset();
    getIt.allowReassignment = true;
    registerInMemoryAuthManager();

    sessions = MockSessionManager();
    when(sessions.db).thenReturn(MockSessionDB());
    getIt.registerSingleton<SessionManager>(sessions);
    bridge = SanadProtocolBridge();
    envelopes = <Map<String, dynamic>>[];
  });

  tearDown(() async {
    await getIt.reset();
  });

  Future<bool> send(Map<String, dynamic> command) => bridge.handleCommand(
    command,
    (envelope) async => envelopes.add(envelope),
  );

  Map<String, dynamic> onlyEnvelope() {
    expect(envelopes, hasLength(1));
    return envelopes.single;
  }

  Map<String, dynamic> payloadOf(Map<String, dynamic> envelope) =>
      envelope['payload'] as Map<String, dynamic>;

  test('the command translates to its own canonical query event', () {
    final event = CanonicalCommandTranslator.translate({
      'command': CanonicalEventTypes.sessionStreamState,
      'payload': {'request_id': 'req-1', 'session_id': 'session-1'},
    });

    expect(event, isNotNull);
    expect(event!.type, CanonicalEventTypes.sessionStreamState);
    expect(event.sessionId, 'session-1');
    expect(event.payload['request_id'], 'req-1');
  });

  test('an unknown command is still rejected', () async {
    expect(
      await send({
        'command': 'session.stream_state_bogus',
        'payload': {'session_id': 'session-1'},
      }),
      isFalse,
    );
    expect(envelopes, isEmpty);
  });

  test('a running stream returns its snapshot and never project history',
      () async {
    when(sessions.getSession('session-1')).thenReturn(sessionState('session-1'));
    when(sessions.getInFlightSnapshot('session-1')).thenReturn({
      'type': 'thought_stream',
      'status': 'running',
      'session_id': 'session-1',
      'run_id': 'run-1',
      'turn_id': 'turn-1',
      'model_step_id': 'model_step_1',
      'content': 'partial answer',
      'stream_seq': 4,
      'snapshot': true,
    });

    expect(
      await send({
        'command': CanonicalEventTypes.sessionStreamState,
        'payload': {'request_id': 'req-1', 'session_id': 'session-1'},
      }),
      isTrue,
    );

    final envelope = onlyEnvelope();
    expect(envelope['event'], CanonicalEventTypes.sessionStreamStateResult);
    expect(envelope['session_id'], 'session-1');
    expect(envelope['request_id'], 'req-1');

    final payload = payloadOf(envelope);
    expect(payload['state'], 'streaming');
    expect(payload['stream'], isA<Map<String, dynamic>>());
    final stream = payload['stream'] as Map<String, dynamic>;
    expect(stream['content'], 'partial answer');
    expect(stream['stream_seq'], 4);
    expect(stream['snapshot'], isTrue);
    expect(payload.containsKey('messages'), isFalse);
    expect(payload.containsKey('next_cursor'), isFalse);

    verifyNever(sessions.getMessages(any));
    verify(sessions.getInFlightSnapshot('session-1')).called(1);
  });

  test('an idle session answers absent instead of an empty stream', () async {
    when(sessions.getSession('session-1')).thenReturn(sessionState('session-1'));
    when(sessions.getInFlightSnapshot('session-1')).thenReturn(null);

    await send({
      'command': CanonicalEventTypes.sessionStreamState,
      'payload': {'request_id': 'req-2', 'session_id': 'session-1'},
    });

    final payload = payloadOf(onlyEnvelope());
    expect(payload['state'], 'absent');
    expect(payload['reason'], 'idle');
    expect(payload.containsKey('stream'), isFalse);
    expect(payload['request_id'], 'req-2');
  });

  test('a session this daemon does not own answers absent', () async {
    when(sessions.getSession('foreign-session')).thenReturn(null);

    await send({
      'command': CanonicalEventTypes.sessionStreamState,
      'payload': {'request_id': 'req-3', 'session_id': 'foreign-session'},
    });

    final payload = payloadOf(onlyEnvelope());
    expect(payload['state'], 'absent');
    expect(payload['reason'], 'unknown_session');
    expect(payload['session_id'], 'foreign-session');
    verifyNever(sessions.getInFlightSnapshot(any));
  });

  test('a request without a session identity fails typed', () async {
    await send({
      'command': CanonicalEventTypes.sessionStreamState,
      'payload': {'request_id': 'req-4'},
    });

    final envelope = onlyEnvelope();
    expect(envelope['event'], CanonicalEventTypes.sessionStreamStateResult);
    expect(envelope.containsKey('session_id'), isFalse);
    final payload = payloadOf(envelope);
    expect(payload['state'], isNull);
    final error = payload['error'] as Map<String, dynamic>;
    expect(error['code'], 'invalid_request');
    expect(payload['request_id'], 'req-4');
    verifyNever(sessions.getInFlightSnapshot(any));
  });

  test('a blank session identity fails typed', () async {
    await send({
      'command': CanonicalEventTypes.sessionStreamState,
      'payload': {'request_id': 'req-5', 'session_id': '   '},
    });

    final payload = payloadOf(onlyEnvelope());
    expect((payload['error'] as Map<String, dynamic>)['code'], 'invalid_request');
  });
}
