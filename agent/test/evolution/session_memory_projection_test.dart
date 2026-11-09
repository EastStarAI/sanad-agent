/// The daemon's in-memory session projections must stay bounded.
///
/// `SessionManager` owns two process-lifetime projections:
///
/// * the per-session in-flight partial answer a reconnecting Client restores,
///   accumulated from stream deltas; and
/// * a small cache of recently read histories.
///
/// Both used to grow without a retained-size bound: the partial answer was
/// rebuilt as one string per delta (a full copy of everything streamed so far),
/// and the history cache was bounded by session count only, so eight long
/// sessions could pin hundreds of megabytes for the life of the daemon. These
/// tests pin the owner-level contract: deltas accumulate without re-copying, the
/// projection still materializes the whole partial answer on read, and the cache
/// evicts by retained text.
library;

import 'dart:io';

import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late AgentStateDatabase state;
  late SessionManager sessions;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('session_projection_');
    Directory('${tempDir.path}/memories').createSync(recursive: true);
    setSanadHomeOverride(tempDir.path);
    SessionManager.resetForTesting();
    getIt.allowReassignment = true;
    state = AgentStateDatabase.atPath(tempDir.path);
    getIt.registerSingleton<AgentStateDatabase>(state);
    sessions = SessionManager();
    getIt.registerSingleton<SessionManager>(sessions);
  });

  tearDown(() {
    SessionManager.resetForTesting();
    if (getIt.isRegistered<SessionManager>()) {
      getIt.unregister<SessionManager>();
    }
    state.dispose();
    setSanadHomeOverride(null);
    if (tempDir.existsSync()) {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  Message userMessage(String content) =>
      Message(role: MessageRole.user, content: content);

  group('in-flight projection', () {
    test('accumulates deltas of one stream into the whole partial answer',
        () {
      for (final delta in ['Hel', 'lo ', 'wor', 'ld']) {
        sessions.appendInFlightDelta(
          sessionId: 's-1',
          runId: 'run-1',
          turnId: 'turn-1',
          modelStepId: 'step-1',
          type: 'thought_stream',
          delta: delta,
        );
      }

      final snapshot = sessions.getInFlightSnapshot('s-1');
      expect(snapshot, isNotNull);
      expect(snapshot!['content'], 'Hello world');
      expect(snapshot['type'], 'thought_stream');
      expect(snapshot['status'], 'running');
      expect(snapshot['session_id'], 's-1');
      expect(snapshot['run_id'], 'run-1');
      expect(snapshot['turn_id'], 'turn-1');
      expect(snapshot['model_step_id'], 'step-1');
      expect(snapshot['timestamp'], isA<int>());
      expect(snapshot['updated_at'], snapshot['timestamp']);
    });

    test('a new run, turn, step, or stream type starts a fresh projection', () {
      void append({
        String runId = 'run-1',
        String? turnId = 'turn-1',
        String? modelStepId = 'step-1',
        String type = 'thought_stream',
        required String delta,
      }) =>
          sessions.appendInFlightDelta(
            sessionId: 's-1',
            runId: runId,
            turnId: turnId,
            modelStepId: modelStepId,
            type: type,
            delta: delta,
          );

      append(delta: 'first');
      append(runId: 'run-2', delta: 'second');
      expect(sessions.getInFlightSnapshot('s-1')!['content'], 'second');

      append(runId: 'run-2', turnId: 'turn-2', delta: 'third');
      expect(sessions.getInFlightSnapshot('s-1')!['content'], 'third');

      append(
        runId: 'run-2',
        turnId: 'turn-2',
        modelStepId: 'step-2',
        delta: 'fourth',
      );
      expect(sessions.getInFlightSnapshot('s-1')!['content'], 'fourth');

      append(
        runId: 'run-2',
        turnId: 'turn-2',
        modelStepId: 'step-2',
        type: 'reasoning_stream',
        delta: 'fifth',
      );
      final snapshot = sessions.getInFlightSnapshot('s-1')!;
      expect(snapshot['content'], 'fifth');
      expect(snapshot['type'], 'reasoning_stream');
    });

    test('a whole snapshot seeded for the same stream continues, else resets',
        () {
      sessions.saveInFlightSnapshot('s-1', {
        'type': 'thought_stream',
        'status': 'running',
        'session_id': 's-1',
        'run_id': 'run-1',
        'turn_id': 'turn-1',
        'model_step_id': 'step-1',
        'content': 'seed',
        'timestamp': 1,
        'updated_at': 1,
      });
      sessions.appendInFlightDelta(
        sessionId: 's-1',
        runId: 'run-1',
        turnId: 'turn-1',
        modelStepId: 'step-1',
        type: 'thought_stream',
        delta: '-continued',
      );
      expect(sessions.getInFlightSnapshot('s-1')!['content'], 'seed-continued');

      sessions.saveInFlightSnapshot('s-2', {
        'type': 'thought_stream',
        'status': 'running',
        'session_id': 's-2',
        'run_id': 'run-1',
        'turn_id': 'turn-1',
        'model_step_id': 'step-1',
        'content': 'seed',
        'timestamp': 1,
        'updated_at': 1,
      });
      sessions.appendInFlightDelta(
        sessionId: 's-2',
        runId: 'run-2',
        turnId: 'turn-1',
        modelStepId: 'step-1',
        type: 'thought_stream',
        delta: 'replacement',
      );
      expect(sessions.getInFlightSnapshot('s-2')!['content'], 'replacement');
    });

    test('identity reads never materialize the accumulated text', () {
      for (var i = 0; i < 64; i++) {
        sessions.appendInFlightDelta(
          sessionId: 's-1',
          runId: 'run-1',
          turnId: null,
          modelStepId: 'step-1',
          type: 'thought_stream',
          delta: 'x' * 1024,
        );
      }
      expect(sessions.hasInFlightSnapshot('s-1'), isTrue);
      expect(sessions.inFlightRunId('s-1'), 'run-1');
      expect(sessions.hasInFlightSnapshot('s-other'), isFalse);
      expect(sessions.inFlightRunId('s-other'), isNull);
      // The materialized projection is still the complete stream.
      expect(
        (sessions.getInFlightSnapshot('s-1')!['content'] as String).length,
        64 * 1024,
      );
    });

    test('clearing releases the projection', () {
      sessions.appendInFlightDelta(
        sessionId: 's-1',
        runId: 'run-1',
        turnId: null,
        modelStepId: null,
        type: 'thought_stream',
        delta: 'partial',
      );
      sessions.clearInFlightSnapshot('s-1');
      expect(sessions.getInFlightSnapshot('s-1'), isNull);
      expect(sessions.hasInFlightSnapshot('s-1'), isFalse);
      expect(sessions.inFlightRunId('s-1'), isNull);
    });

    test('a whole snapshot saved by a caller still reads back unchanged', () {
      final snapshot = <String, dynamic>{
        'type': 'thought_stream',
        'status': 'running',
        'content': 'seeded',
      };
      sessions.saveInFlightSnapshot('s-1', snapshot);
      expect(sessions.getInFlightSnapshot('s-1'), same(snapshot));
      expect(sessions.hasInFlightSnapshot('s-1'), isTrue);
    });
  });

  group('history snapshot cache', () {
    List<Message> historyOf(String content, {int messages = 1}) => [
          for (var i = 0; i < messages; i++) userMessage(content),
        ];

    test('keeps the newest eight sessions', () {
      for (var i = 0; i < 12; i++) {
        sessions.cacheHistoryForTesting('s-$i', 1, historyOf('m$i'));
      }
      expect(sessions.historySnapshotCount, 8);
      expect(sessions.hasHistorySnapshot('s-3'), isFalse);
      expect(sessions.hasHistorySnapshot('s-4'), isTrue);
      expect(sessions.hasHistorySnapshot('s-11'), isTrue);
    });

    test('evicts by retained text, keeping the newest history', () {
      // Four sessions of 12 MiB each exceed the 32 MiB budget.
      const contentChars = 12 * 1024 * 1024;
      for (var i = 0; i < 4; i++) {
        sessions.cacheHistoryForTesting(
          's-$i',
          1,
          historyOf('a' * contentChars),
        );
      }
      expect(
        sessions.historySnapshotChars,
        lessThanOrEqualTo(32 * 1024 * 1024),
      );
      expect(sessions.historySnapshotCount, lessThan(4));
      expect(
        sessions.hasHistorySnapshot('s-3'),
        isTrue,
        reason: 'the newest history is never evicted for a budget miss',
      );
      expect(sessions.hasHistorySnapshot('s-0'), isFalse);
    });

    test('a re-cached history replaces its own accounting', () {
      sessions.cacheHistoryForTesting('s-1', 1, historyOf('a' * 1000));
      expect(sessions.historySnapshotChars, 1000);
      sessions.cacheHistoryForTesting('s-1', 2, historyOf('a' * 10));
      expect(sessions.historySnapshotChars, 10);
      expect(sessions.historySnapshotCount, 1);
    });
  });
}
