import 'package:sanad_agent/evolution/models/session_state.dart';
import 'package:sanad_agent/interfaces/session_payload_builder.dart';
import 'package:test/test.dart';

void main() {
  SessionState session({String? thinkingMode}) {
    final now = DateTime.utc(2026, 7, 16);
    return SessionState(
      sessionId: 'session-1',
      model: 'model-1',
      thinkingMode: thinkingMode,
      createdAt: now,
      updatedAt: now,
    );
  }

  test('session payload writes canonical thinking_mode', () {
    final payload = buildSessionPayload(session: session(thinkingMode: 'deep'));

    expect(payload['thinking_mode'], 'deep');
    expect(payload['lineage_id'], 'session-1');
    expect(payload['fork_sequence'], 0);
  });

  test(
    'session payload reads canonical thinking_mode from persisted metadata',
    () {
      final payload = buildSessionPayload(
        session: session(),
        sessionMetadata: const {'thinking_mode': 'fast'},
      );

      expect(payload['thinking_mode'], 'fast');
      expect((payload['metadata'] as Map)['thinking_mode'], 'fast');
    },
  );
}
