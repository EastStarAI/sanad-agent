/// The in-flight projection reports how much of a stream its text covers, and
/// nothing about that flows into durable rows.
///
/// The projection is the repair anchor a consumer adopts when it lost or
/// misordered deltas: without the watermark it cannot tell a delta that is
/// already contained from one that is genuinely newer. Keeping it in-memory and
/// out of the message schema is the other half of the contract.
library;

import 'dart:io';

import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/message_history_identity.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late AgentStateDatabase state;
  late SessionManager sessions;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('in_flight_watermark_');
    Directory('${tempDir.path}/memories').createSync(recursive: true);
    setSanadHomeOverride(tempDir.path);
    SessionManager.resetForTesting();
    state = AgentStateDatabase.atPath(tempDir.path);
    sessions = SessionManager();
  });

  tearDown(() {
    SessionManager.resetForTesting();
    state.dispose();
    setSanadHomeOverride(null);
    if (tempDir.existsSync()) {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  void append({
    required String delta,
    String type = 'thought_stream',
    String modelStepId = 'model_step_1',
    int? seq,
  }) {
    sessions.appendInFlightDelta(
      sessionId: 'session-1',
      runId: 'run-1',
      turnId: 'turn-1',
      modelStepId: modelStepId,
      type: type,
      delta: delta,
      seq: seq,
    );
  }

  test('the projection states the sequence its whole text covers', () {
    append(delta: 'Hel', seq: 1);
    append(delta: 'lo', seq: 2);

    final snapshot = sessions.getInFlightSnapshot('session-1')!;
    expect(snapshot['content'], 'Hello');
    expect(snapshot['stream_seq'], 2);
    expect(snapshot['snapshot'], isTrue);
    expect(snapshot['status'], 'running');
    expect(snapshot['type'], 'thought_stream');
    expect(snapshot['run_id'], 'run-1');
    expect(snapshot['turn_id'], 'turn-1');
    expect(snapshot['model_step_id'], 'model_step_1');
  });

  test('a legacy delta without a sequence never invents a watermark', () {
    append(delta: 'plain');

    final snapshot = sessions.getInFlightSnapshot('session-1')!;
    expect(snapshot['content'], 'plain');
    expect(
      snapshot.containsKey('stream_seq'),
      isFalse,
      reason: 'an unsequenced producer must not advertise a sequence',
    );
    expect(snapshot['snapshot'], isTrue);
  });

  test('a new stream type starts its own projection and watermark', () {
    append(delta: 'answer', seq: 3);
    append(delta: 'why', type: 'reasoning_stream', seq: 1);

    final snapshot = sessions.getInFlightSnapshot('session-1')!;
    expect(snapshot['type'], 'reasoning_stream');
    expect(snapshot['content'], 'why');
    expect(snapshot['stream_seq'], 1);
  });

  test('a new model step restarts the watermark with its own key', () {
    append(delta: 'one', seq: 1);
    append(delta: 'two', seq: 2);
    append(delta: 'next', modelStepId: 'model_step_2', seq: 1);

    final snapshot = sessions.getInFlightSnapshot('session-1')!;
    expect(snapshot['content'], 'next');
    expect(snapshot['stream_seq'], 1);
    expect(snapshot['model_step_id'], 'model_step_2');
  });

  test('clearing the projection removes the watermark with it', () {
    append(delta: 'gone', seq: 1);
    sessions.clearInFlightSnapshot('session-1');

    expect(sessions.getInFlightSnapshot('session-1'), isNull);
  });

  test('no durable message column carries stream sequence metadata', () {
    final columns = state.db.select('PRAGMA table_info(messages)');
    final names = columns.map((row) => row['name']?.toString()).toSet();

    expect(names, isNotEmpty, reason: 'the message table must exist');
    expect(names, isNot(contains('stream_seq')));
    expect(names, isNot(contains('stream_snapshot')));
  });

  test('assistant wire identity never carries stream sequence metadata', () {
    final message = Message(
      role: MessageRole.assistant,
      content: 'final',
      metadata: {'run_id': 'run-1', 'model_step_id': 'model_step_1'},
    );

    final fields = MessageHistoryIdentity.wireFields(message);
    expect(fields.keys, isNot(contains('stream_seq')));
    expect(fields.keys, isNot(contains('snapshot')));
  });
}
