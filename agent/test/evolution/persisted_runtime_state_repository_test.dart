// ignore_for_file: deprecated_member_use
// The legacy `session_suspended_runs` and `session_pending_runs` APIs are
// kept as `@Deprecated` on the repository to prevent new production calls.
// This test file intentionally exercises those APIs to keep migration
// coverage stable while the legacy tables remain in the schema.

import 'dart:io';

import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/persisted_runtime_state_repository.dart';
import 'package:sanad_agent/evolution/db/runtime/session_execution_state_coordinator.dart';
import 'package:sanad_agent/evolution/db/session_db.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import '../support/isolated_sanad_test_home.dart';

void main() {
  useIsolatedSanadStateRoot();
  late PersistedRuntimeStateRepository repo;
  late AgentStateDatabase db;

  setUp(() {
    db = AgentStateDatabase.inMemory();
    repo = PersistedRuntimeStateRepository(db.db);
  });

  tearDown(() => db.dispose());

  group('Suspended runs', () {
    test('upsert + find + delete', () {
      repo.upsertSuspendedRun(
        sessionId: 'sess-1',
        requestId: 'req-1',
        runId: 'run-1',
        message: 'Hello',
        eventMetadata: {'source': 'test'},
        workspaceId: 'ws-1',
        providerInstanceId: 'prov-1',
        modelId: 'gpt-4',
      );

      final found = repo.findSuspendedRun('sess-1');
      expect(found, isNotNull);
      expect(found!.message, 'Hello');
      expect(found.requestId, 'req-1');
      expect(found.providerInstanceId, 'prov-1');
      expect(found.modelId, 'gpt-4');
      expect(found.eventMetadata['source'], 'test');

      // Upsert replaces.
      repo.upsertSuspendedRun(sessionId: 'sess-1', message: 'Updated');
      expect(repo.findSuspendedRun('sess-1')!.message, 'Updated');

      repo.deleteSuspendedRun('sess-1');
      expect(repo.findSuspendedRun('sess-1'), isNull);
    });

    test('findAllSuspendedRuns returns all', () {
      repo.upsertSuspendedRun(sessionId: 's1', message: 'A');
      repo.upsertSuspendedRun(sessionId: 's2', message: 'B');
      final all = repo.findAllSuspendedRuns();
      expect(all.length, 2);
    });
  });

  group('Pending runs (queue)', () {
    test('append + find (FIFO order) + pop', () {
      repo.appendPendingRun(sessionId: 'sess-1', message: 'First');
      repo.appendPendingRun(sessionId: 'sess-1', message: 'Second');
      repo.appendPendingRun(sessionId: 'sess-1', message: 'Third');

      final queue = repo.findPendingRuns('sess-1');
      expect(queue.length, 3);
      expect(queue[0].message, 'First');
      expect(queue[1].message, 'Second');
      expect(queue[2].message, 'Third');

      final popped = repo.popFirstPendingRun('sess-1');
      expect(popped!.message, 'First');

      final remaining = repo.findPendingRuns('sess-1');
      expect(remaining.length, 2);
      expect(remaining[0].message, 'Second');
    });

    test('findAllPendingRuns groups by session', () {
      repo.appendPendingRun(sessionId: 's1', message: 'A');
      repo.appendPendingRun(sessionId: 's2', message: 'B');
      repo.appendPendingRun(sessionId: 's1', message: 'C');

      final all = repo.findAllPendingRuns();
      expect(all['s1']!.length, 2);
      expect(all['s2']!.length, 1);
    });

    test('rewritePendingRoute updates all entries', () {
      repo.appendPendingRun(
        sessionId: 'sess-1',
        message: 'M1',
        providerInstanceId: 'old',
        modelId: 'old-model',
      );
      repo.appendPendingRun(
        sessionId: 'sess-1',
        message: 'M2',
        providerInstanceId: 'old',
        modelId: 'old-model',
      );

      repo.rewritePendingRoute(
        'sess-1',
        providerInstanceId: 'new',
        modelId: 'new-model',
      );

      final queue = repo.findPendingRuns('sess-1');
      expect(queue.every((r) => r.providerInstanceId == 'new'), isTrue);
      expect(queue.every((r) => r.modelId == 'new-model'), isTrue);
    });

    test('deleteAllPendingRuns clears queue', () {
      repo.appendPendingRun(sessionId: 's1', message: 'A');
      repo.appendPendingRun(sessionId: 's1', message: 'B');
      repo.deleteAllPendingRuns('s1');
      expect(repo.findPendingRuns('s1'), isEmpty);
    });
  });

  group('Runtime notices', () {
    test('upsert + find + delete', () {
      repo.upsertNotice(
        sessionId: 'sess-1',
        requestId: 'req-1',
        status: 'blocked',
        reason: 'unknown',
        title: 'Error',
        message: 'Something went wrong',
        providerInstanceId: 'prov-1',
        providerDisplayName: 'Test Provider',
        actions: ['stop', 'retry'],
      );

      final notice = repo.findNotice('sess-1');
      expect(notice, isNotNull);
      expect(notice!.status, 'blocked');
      expect(notice.reason, 'unknown');
      expect(notice.actions, ['stop', 'retry']);

      final payload = notice.toPayload();
      expect(payload['status'], 'blocked');
      expect(payload['actions'], ['stop', 'retry']);

      repo.deleteNotice('sess-1');
      expect(repo.findNotice('sess-1'), isNull);
    });

    test('findAllNotices returns all', () {
      repo.upsertNotice(
        sessionId: 's1',
        status: 'waiting',
        reason: 'rate_limit',
        title: 'A',
        message: 'M',
      );
      repo.upsertNotice(
        sessionId: 's2',
        status: 'blocked',
        reason: 'auth',
        title: 'B',
        message: 'M',
      );
      final all = repo.findAllNotices();
      expect(all.length, 2);
      expect(all['s1']!.status, 'waiting');
    });
  });

  group('clearAllForSession', () {
    test('removes suspended + pending + notice', () {
      repo.upsertSuspendedRun(sessionId: 's1', message: 'M');
      repo.appendPendingRun(sessionId: 's1', message: 'Q');
      repo.upsertNotice(
        sessionId: 's1',
        status: 'blocked',
        reason: 'unknown',
        title: 'T',
        message: 'M',
      );

      repo.clearAllForSession('s1');

      expect(repo.findSuspendedRun('s1'), isNull);
      expect(repo.findPendingRuns('s1'), isEmpty);
      expect(repo.findNotice('s1'), isNull);
    });

    test('cancels active and queued durable work items for the session', () {
      db.db.execute(
        "INSERT INTO sessions (session_id, model, created_at, updated_at) VALUES ('s-work', 'gpt-4o', '2026-07-11', '2026-07-11')",
      );
      final now = DateTime.now();
      repo.insertWorkItem(
        SessionWorkItem(
          workItemId: 'w-running',
          sessionId: 's-work',
          requestId: 'req-running',
          sequence: 0,
          state: SessionWorkState.running,
          attempt: 0,
          createdAt: now,
          updatedAt: now,
        ),
      );
      repo.insertWorkItem(
        SessionWorkItem(
          workItemId: 'w-queued',
          sessionId: 's-work',
          requestId: 'req-queued',
          sequence: 1,
          state: SessionWorkState.queued,
          attempt: 0,
          createdAt: now,
          updatedAt: now,
        ),
      );

      repo.clearAllForSession('s-work');

      expect(
        repo.findWorkItem('w-running')?.state,
        equals(SessionWorkState.cancelled),
      );
      expect(
        repo.findWorkItem('w-queued')?.state,
        equals(SessionWorkState.cancelled),
      );
    });
  });

  group('SessionWorkItem (Gate C.4)', () {
    test('atomic admission queues behind durable active work', () {
      db.db.execute(
        "INSERT INTO sessions (session_id, model, created_at, updated_at) VALUES ('s-admit', 'gpt-4o', '2026-07-11', '2026-07-11')",
      );

      final first = repo.admitWorkItem(
        workItemId: 'w-admit-1',
        sessionId: 's-admit',
        requestId: 'req-admit-1',
      );
      expect(first.state, SessionWorkState.running);
      repo.transitionWorkItemState(
        workItemId: first.workItemId,
        fromState: SessionWorkState.running,
        toState: SessionWorkState.waiting,
      );

      final second = repo.admitWorkItem(
        workItemId: 'w-admit-2',
        sessionId: 's-admit',
        requestId: 'req-admit-2',
      );

      expect(second.state, SessionWorkState.queued);
      expect(repo.findActiveWorkItem('s-admit')?.workItemId, 'w-admit-1');
      expect(
        repo.findQueuedWorkItems('s-admit').single.workItemId,
        'w-admit-2',
      );
    });

    test('terminal commit persists one owned result before completing', () {
      db.db.execute(
        "INSERT INTO sessions (session_id, model, created_at, updated_at) VALUES ('s-terminal', 'gpt-4o', '2026-07-11', '2026-07-11')",
      );
      final item = repo.admitWorkItem(
        workItemId: 'w-terminal',
        sessionId: 's-terminal',
        requestId: 'req-terminal',
      );
      expect(
        repo.bindRunOwnership(
          sessionId: item.sessionId,
          workItemId: item.workItemId,
          runId: 'run-terminal',
          generation: 7,
        ),
        isTrue,
      );
      SessionDB.fromState(db).replaceMessages('s-terminal', [
        Message(
          role: MessageRole.assistant,
          content: 'saved answer',
          metadata: const {'run_id': 'run-terminal'},
        ),
      ]);

      final outcome = repo.commitTerminal(
        sessionId: item.sessionId,
        workItemId: item.workItemId,
        runId: 'run-terminal',
        generation: 7,
        assistantResult: Message(
          role: MessageRole.assistant,
          content: 'saved answer',
          metadata: const {'model': 'gpt-4o'},
        ),
      );

      expect(outcome, TerminalCommitOutcome.committed);
      expect(
        repo.findWorkItem(item.workItemId)?.state,
        SessionWorkState.completed,
      );
      final messages = SessionDB.fromState(db).getMessages('s-terminal');
      expect(messages, hasLength(1));
      expect(messages.single.content, 'saved answer');
      expect(
        messages.single.metadata?['terminal_work_item_id'],
        item.workItemId,
      );
      expect(messages.single.metadata?['terminal_generation'], 7);
    });

    for (final recoveryState in [
      SessionWorkState.waiting,
      SessionWorkState.blocked,
    ]) {
      test('terminal commit does not close $recoveryState recovery state', () {
        final sessionId = 's-terminal-${recoveryState.name}';
        db.db.execute(
          'INSERT INTO sessions (session_id, model, created_at, updated_at) VALUES (?, ?, ?, ?)',
          [sessionId, 'gpt-4o', '2026-07-11', '2026-07-11'],
        );
        final item = repo.admitWorkItem(
          workItemId: 'w-${recoveryState.name}',
          sessionId: sessionId,
          requestId: 'req-${recoveryState.name}',
        );
        repo.bindRunOwnership(
          sessionId: sessionId,
          workItemId: item.workItemId,
          runId: 'run-${recoveryState.name}',
          generation: 1,
        );
        repo.transitionWorkItemState(
          workItemId: item.workItemId,
          fromState: SessionWorkState.running,
          toState: recoveryState,
        );

        final outcome = repo.commitTerminal(
          sessionId: sessionId,
          workItemId: item.workItemId,
          runId: 'run-${recoveryState.name}',
          generation: 1,
          assistantResult: Message(
            role: MessageRole.assistant,
            content: 'must not be terminal',
          ),
        );

        expect(outcome, TerminalCommitOutcome.recoveryOwnsState);
        expect(repo.findWorkItem(item.workItemId)?.state, recoveryState);
        expect(SessionDB.fromState(db).getMessages(sessionId), isEmpty);
      });
    }

    test('stale run identity cannot commit a newer owner result', () {
      db.db.execute(
        "INSERT INTO sessions (session_id, model, created_at, updated_at) VALUES ('s-stale-owner', 'gpt-4o', '2026-07-11', '2026-07-11')",
      );
      final item = repo.admitWorkItem(
        workItemId: 'w-stale-owner',
        sessionId: 's-stale-owner',
        requestId: 'req-stale-owner',
      );
      repo.bindRunOwnership(
        sessionId: item.sessionId,
        workItemId: item.workItemId,
        runId: 'run-current',
        generation: 2,
      );

      final outcome = repo.commitTerminal(
        sessionId: item.sessionId,
        workItemId: item.workItemId,
        runId: 'run-old',
        generation: 1,
        assistantResult: Message(
          role: MessageRole.assistant,
          content: 'stale answer',
        ),
      );

      expect(outcome, TerminalCommitOutcome.staleOwner);
      expect(
        repo.findWorkItem(item.workItemId)?.state,
        SessionWorkState.running,
      );
      expect(SessionDB.fromState(db).getMessages(item.sessionId), isEmpty);
    });

    test('terminal persistence failure leaves owned work recoverable', () {
      db.db.execute(
        "INSERT INTO sessions (session_id, model, created_at, updated_at) VALUES ('s-terminal-failure', 'gpt-4o', '2026-07-11', '2026-07-11')",
      );
      final item = repo.admitWorkItem(
        workItemId: 'w-terminal-failure',
        sessionId: 's-terminal-failure',
        requestId: 'req-terminal-failure',
      );
      repo.bindRunOwnership(
        sessionId: item.sessionId,
        workItemId: item.workItemId,
        runId: 'run-terminal-failure',
        generation: 1,
      );
      db.db.execute('DROP TABLE messages');

      final outcome = repo.commitTerminal(
        sessionId: item.sessionId,
        workItemId: item.workItemId,
        runId: 'run-terminal-failure',
        generation: 1,
        assistantResult: Message(
          role: MessageRole.assistant,
          content: 'cannot persist',
        ),
      );

      expect(outcome, TerminalCommitOutcome.persistenceFailed);
      expect(
        repo.findWorkItem(item.workItemId)?.state,
        SessionWorkState.running,
      );
      expect(
        repo.findActiveWorkItem(item.sessionId)?.workItemId,
        item.workItemId,
      );
    });

    test('insert, find, transition state, delete', () {
      final now = DateTime.now();
      final item = SessionWorkItem(
        workItemId: 'w-1',
        sessionId: 's-1',
        requestId: 'req-1',
        sequence: 1,
        providerInstanceId: 'prov-1',
        modelId: 'gpt-4o',
        workspaceId: 'ws-1',
        payload: const {'msg': 'hi'},
        attempt: 0,
        state: SessionWorkState.queued,
        continuationMetadata: const {'key': 'val'},
        createdAt: now,
        updatedAt: now,
      );

      // We must insert a session first due to FOREIGN KEY (session_id) REFERENCES sessions (session_id)
      db.db.execute(
        "INSERT INTO sessions (session_id, model, created_at, updated_at) VALUES ('s-1', 'gpt-4o', '2026-07-11', '2026-07-11')",
      );

      repo.insertWorkItem(item);

      final found = repo.findWorkItem('w-1');
      expect(found, isNotNull);
      expect(found!.workItemId, equals('w-1'));
      expect(found.state, equals(SessionWorkState.queued));
      expect(found.payload['msg'], equals('hi'));

      // Valid transition queued -> running
      repo.transitionWorkItemState(
        workItemId: 'w-1',
        fromState: SessionWorkState.queued,
        toState: SessionWorkState.running,
        attempt: 1,
      );

      final running = repo.findWorkItem('w-1');
      expect(running!.state, equals(SessionWorkState.running));
      expect(running.attempt, equals(1));

      // Invalid transition from queued to completed (must throw exception)
      expect(
        () => repo.transitionWorkItemState(
          workItemId: 'w-1',
          fromState: SessionWorkState.queued,
          toState: SessionWorkState.completed,
        ),
        throwsException,
      );

      repo.transitionWorkItemState(
        workItemId: 'w-1',
        fromState: SessionWorkState.running,
        toState: SessionWorkState.blocked,
      );
      expect(
        () => repo.transitionWorkItemState(
          workItemId: 'w-1',
          fromState: SessionWorkState.blocked,
          toState: SessionWorkState.running,
        ),
        throwsException,
      );

      // Active invariant: cannot have two active work items in s-1
      final item2 = SessionWorkItem(
        workItemId: 'w-2',
        sessionId: 's-1',
        requestId: 'req-2',
        sequence: 2,
        providerInstanceId: 'prov-1',
        modelId: 'gpt-4o',
        state: SessionWorkState.running, // Active state
        attempt: 0,
        createdAt: now,
        updatedAt: now,
      );
      expect(() => repo.insertWorkItem(item2), throwsException);

      // Uniqueness constraint: cannot have two work items with same request_id in session s-1
      final item3 = SessionWorkItem(
        workItemId: 'w-3',
        sessionId: 's-1',
        requestId: 'req-1', // Duplicate request_id
        sequence: 3,
        providerInstanceId: 'prov-1',
        modelId: 'gpt-4o',
        state: SessionWorkState
            .queued, // Non-active state, so doesn't trigger active invariant
        attempt: 0,
        createdAt: now,
        updatedAt: now,
      );
      expect(() => repo.insertWorkItem(item3), throwsException);

      repo.deleteWorkItem('w-1');
      expect(repo.findWorkItem('w-1'), isNull);
    });

    test(
      'claimNextQueuedWorkItem returns null while another active item exists',
      () {
        final now = DateTime.now();
        db.db.execute(
          "INSERT INTO sessions (session_id, model, created_at, updated_at) VALUES ('s-claim-guard', 'gpt-4o', '2026-07-11', '2026-07-11')",
        );

        repo.insertWorkItem(
          SessionWorkItem(
            workItemId: 'w-active',
            sessionId: 's-claim-guard',
            requestId: 'req-active',
            sequence: 0,
            state: SessionWorkState.running,
            attempt: 0,
            createdAt: now,
            updatedAt: now,
          ),
        );
        repo.insertWorkItem(
          SessionWorkItem(
            workItemId: 'w-queued',
            sessionId: 's-claim-guard',
            requestId: 'req-queued',
            sequence: 1,
            state: SessionWorkState.queued,
            attempt: 0,
            createdAt: now,
            updatedAt: now,
          ),
        );

        final claimed = repo.claimNextQueuedWorkItem('s-claim-guard');

        expect(claimed, isNull);
        expect(
          repo.findWorkItem('w-queued')?.state,
          equals(SessionWorkState.queued),
        );
      },
    );

    test('FIFO sequence ordering and find active/queued', () {
      db.db.execute(
        "INSERT INTO sessions (session_id, model, created_at, updated_at) VALUES ('s-2', 'gpt-4o', '2026-07-11', '2026-07-11')",
      );

      final now = DateTime.now();
      repo.insertWorkItem(
        SessionWorkItem(
          workItemId: 'w-a',
          sessionId: 's-2',
          requestId: 'req-a',
          sequence: 10,
          state: SessionWorkState.queued,
          attempt: 0,
          createdAt: now,
          updatedAt: now,
        ),
      );
      repo.insertWorkItem(
        SessionWorkItem(
          workItemId: 'w-b',
          sessionId: 's-2',
          requestId: 'req-b',
          sequence: 5, // Lower sequence number -> first in FIFO
          state: SessionWorkState.queued,
          attempt: 0,
          createdAt: now,
          updatedAt: now,
        ),
      );

      final queued = repo.findQueuedWorkItems('s-2');
      expect(queued.length, equals(2));
      expect(queued[0].workItemId, equals('w-b')); // 'w-b' has sequence 5
      expect(queued[1].workItemId, equals('w-a')); // 'w-a' has sequence 10

      // Claiming w-b as active
      repo.transitionWorkItemState(
        workItemId: 'w-b',
        fromState: SessionWorkState.queued,
        toState: SessionWorkState.running,
      );

      final active = repo.findActiveWorkItem('s-2');
      expect(active, isNotNull);
      expect(active!.workItemId, equals('w-b'));
    });

    test(
      'enqueueWorkItem assigns sequence atomically and claimNextQueuedWorkItem claims oldest item',
      () {
        db.db.execute(
          "INSERT INTO sessions (session_id, model, created_at, updated_at) VALUES ('s-claim', 'gpt-4o', '2026-07-11', '2026-07-11')",
        );

        final first = repo.enqueueWorkItem(
          workItemId: 'w-claim-1',
          sessionId: 's-claim',
          requestId: 'req-1',
          payload: const {'message': 'first'},
        );
        final second = repo.enqueueWorkItem(
          workItemId: 'w-claim-2',
          sessionId: 's-claim',
          requestId: 'req-2',
          payload: const {'message': 'second'},
        );

        expect(first.sequence, equals(0));
        expect(second.sequence, equals(1));

        final claimed = repo.claimNextQueuedWorkItem('s-claim');
        expect(claimed, isNotNull);
        expect(claimed!.workItemId, equals('w-claim-1'));
        expect(claimed.state, equals(SessionWorkState.running));

        final queued = repo.findQueuedWorkItems('s-claim');
        expect(queued.map((item) => item.workItemId), equals(['w-claim-2']));
      },
    );

    test(
      'cleanupOrphanedWorkItems deletes rows whose session no longer exists',
      () {
        final now = DateTime.now();
        db.db.execute(
          "INSERT INTO sessions (session_id, model, created_at, updated_at) VALUES ('s-live', 'gpt-4o', '2026-07-11', '2026-07-11')",
        );
        repo.insertWorkItem(
          SessionWorkItem(
            workItemId: 'w-live',
            sessionId: 's-live',
            requestId: 'req-live',
            sequence: 0,
            state: SessionWorkState.queued,
            attempt: 0,
            createdAt: now,
            updatedAt: now,
          ),
        );

        db.db.execute('PRAGMA foreign_keys = OFF');
        db.db.execute("""
        INSERT INTO session_work_items (
          work_item_id, session_id, request_id, sequence,
          payload_json, attempt, state, continuation_metadata,
          created_at, updated_at
        ) VALUES (
          'w-orphan', 'missing-session', 'req-orphan', 0,
          '{}', 0, 'queued', '{}', '2026-07-11', '2026-07-11'
        )
        """);
        db.db.execute('PRAGMA foreign_keys = ON');

        final removed = repo.cleanupOrphanedWorkItems();
        expect(removed, equals(1));
        expect(repo.findWorkItem('w-orphan'), isNull);
        expect(repo.findWorkItem('w-live'), isNotNull);
      },
    );

    test('foreign key cascade deletes work items on session delete', () {
      db.db.execute(
        "INSERT INTO sessions (session_id, model, created_at, updated_at) VALUES ('s-3', 'gpt-4o', '2026-07-11', '2026-07-11')",
      );
      final now = DateTime.now();
      repo.insertWorkItem(
        SessionWorkItem(
          workItemId: 'w-x',
          sessionId: 's-3',
          sequence: 1,
          state: SessionWorkState.queued,
          attempt: 0,
          createdAt: now,
          updatedAt: now,
        ),
      );

      expect(repo.findWorkItem('w-x'), isNotNull);

      db.db.execute("DELETE FROM sessions WHERE session_id = 's-3'");
      expect(repo.findWorkItem('w-x'), isNull);
    });
  });

  group('Gate C.4 — Restart fidelity with real temporary SQLite', () {
    late Directory tempDir;
    String stateHome() => p.join(tempDir.path, 'state');

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('sanad-gate-c-restart-');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test(
      'FIFO order survives a daemon restart through a real on-disk state.db',
      () {
        // 1. First "daemon" run: enqueue 5 items, then close.
        final firstDb = AgentStateDatabase.atPath(stateHome());
        final firstRepo = PersistedRuntimeStateRepository(firstDb.db);
        firstDb.db.execute(
          "INSERT INTO sessions (session_id, model, created_at, updated_at) "
          "VALUES ('sess-restart', 'gpt-4o', '2026-07-11', '2026-07-11')",
        );

        for (var i = 0; i < 5; i++) {
          firstRepo.enqueueWorkItem(
            workItemId: 'w-restart-$i',
            sessionId: 'sess-restart',
            requestId: 'req-restart-$i',
            payload: {'message': 'msg-$i'},
          );
        }
        firstDb.dispose();

        // 2. Second "daemon" run: reopen the same file and read the queue.
        final secondDb = AgentStateDatabase.atPath(stateHome());
        final secondRepo = PersistedRuntimeStateRepository(secondDb.db);
        try {
          final queued = secondRepo.findQueuedWorkItems('sess-restart');
          expect(queued, hasLength(5));
          for (var i = 0; i < 5; i++) {
            expect(
              queued[i].workItemId,
              equals('w-restart-$i'),
              reason: 'FIFO order must be preserved after restart',
            );
            expect(queued[i].sequence, equals(i));
            expect(queued[i].payload['message'], equals('msg-$i'));
          }

          // 3. Claiming the oldest item must return sequence 0.
          final claimed = secondRepo.claimNextQueuedWorkItem('sess-restart');
          expect(claimed, isNotNull);
          expect(claimed!.workItemId, equals('w-restart-0'));
          expect(claimed.state, equals(SessionWorkState.running));
        } finally {
          secondDb.dispose();
        }
      },
    );

    test(
      'active invariant is enforced by a partial unique index on a real on-disk state.db',
      () {
        final db = AgentStateDatabase.atPath(stateHome());
        final repo = PersistedRuntimeStateRepository(db.db);
        try {
          db.db.execute(
            "INSERT INTO sessions (session_id, model, created_at, updated_at) "
            "VALUES ('sess-inv', 'gpt-4o', '2026-07-11', '2026-07-11')",
          );
          final now = DateTime.now();
          repo.insertWorkItem(
            SessionWorkItem(
              workItemId: 'w-inv-1',
              sessionId: 'sess-inv',
              requestId: 'req-inv-1',
              sequence: 0,
              state: SessionWorkState.running,
              attempt: 0,
              createdAt: now,
              updatedAt: now,
            ),
          );
          expect(
            () => repo.insertWorkItem(
              SessionWorkItem(
                workItemId: 'w-inv-2',
                sessionId: 'sess-inv',
                requestId: 'req-inv-2',
                sequence: 1,
                state: SessionWorkState.running,
                attempt: 0,
                createdAt: now,
                updatedAt: now,
              ),
            ),
            throwsA(anything),
            reason:
                'partial unique index must reject a second active work item '
                'in the same session',
          );
        } finally {
          db.dispose();
        }
      },
    );

    test(
      'cleanupOrphanedWorkItems still works after a restart (orphan session rows are removed)',
      () {
        final db = AgentStateDatabase.atPath(stateHome());
        final repo = PersistedRuntimeStateRepository(db.db);
        try {
          db.db.execute(
            "INSERT INTO sessions (session_id, model, created_at, updated_at) "
            "VALUES ('sess-live', 'gpt-4o', '2026-07-11', '2026-07-11')",
          );
          final now = DateTime.now();
          repo.insertWorkItem(
            SessionWorkItem(
              workItemId: 'w-live',
              sessionId: 'sess-live',
              requestId: 'req-live',
              sequence: 0,
              state: SessionWorkState.queued,
              attempt: 0,
              createdAt: now,
              updatedAt: now,
            ),
          );

          // Insert an orphan row that points at a missing session.
          db.db.execute('PRAGMA foreign_keys = OFF');
          db.db.execute("""
            INSERT INTO session_work_items (
              work_item_id, session_id, request_id, sequence,
              payload_json, attempt, state, continuation_metadata,
              created_at, updated_at
            ) VALUES (
              'w-orphan', 'missing-session', 'req-orphan', 0,
              '{}', 0, 'queued', '{}', '2026-07-11', '2026-07-11'
            )
            """);
          db.db.execute('PRAGMA foreign_keys = ON');

          final removed = repo.cleanupOrphanedWorkItems();
          expect(removed, equals(1));
          expect(repo.findWorkItem('w-orphan'), isNull);
          expect(repo.findWorkItem('w-live'), isNotNull);
        } finally {
          db.dispose();
        }
      },
    );

    test('Gate C.3 migration safety: a database that pre-dates '
        'session_work_items opens cleanly and the new table is usable', () {
      // Simulate a pre-Gate-C database: open with raw sqlite3, build the
      // legacy schema (sessions + messages + the now-legacy pending/
      // suspended/notice tables) WITHOUT creating session_work_items.
      // Then close and reopen with the current AgentStateDatabase code
      // and verify:
      //   (a) opening does not throw
      //   (b) session_work_items is now present and writeable
      //   (c) the legacy rows are still accessible for cleanup
      //   (d) the new repository can read+write work items
      final home = stateHome();
      Directory(home).createSync(recursive: true);
      final dbPath = p.join(home, 'state.db');
      var legacyDb = sqlite3.open(dbPath);
      legacyDb.execute('''
          CREATE TABLE sessions (
            session_id TEXT PRIMARY KEY,
            model TEXT NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
          )
        ''');
      legacyDb.execute('''
          CREATE TABLE session_suspended_runs (
            session_id TEXT PRIMARY KEY,
            request_id TEXT,
            run_id TEXT,
            message TEXT,
            event_metadata TEXT NOT NULL DEFAULT '{}',
            workspace_id TEXT,
            provider_instance_id TEXT,
            model_id TEXT,
            thinking_mode TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
          )
        ''');
      legacyDb.execute('''
          CREATE TABLE session_pending_runs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id TEXT NOT NULL,
            message TEXT,
            seq INTEGER NOT NULL,
            created_at TEXT NOT NULL
          )
        ''');
      legacyDb.execute('''
          CREATE TABLE session_runtime_notices (
            session_id TEXT PRIMARY KEY,
            status TEXT NOT NULL,
            reason TEXT NOT NULL,
            title TEXT NOT NULL,
            message TEXT NOT NULL,
            actions TEXT NOT NULL DEFAULT '[]',
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
          )
        ''');
      legacyDb.execute(
        "INSERT INTO sessions (session_id, model, created_at, updated_at) "
        "VALUES ('legacy-sess', 'gpt-4o', '2026-01-01', '2026-01-01')",
      );
      legacyDb.execute(
        "INSERT INTO session_pending_runs (session_id, message, seq, created_at) "
        "VALUES ('legacy-sess', 'pre-gate-c message', 0, '2026-01-01')",
      );
      legacyDb.execute(
        "INSERT INTO session_suspended_runs ("
        "  session_id, request_id, message, created_at, updated_at"
        ") VALUES ('legacy-sess', 'req-legacy', 'legacy suspended', '2026-01-01', '2026-01-01')",
      );
      legacyDb.execute(
        "INSERT INTO session_runtime_notices ("
        "  session_id, status, reason, title, message, created_at, updated_at"
        ") VALUES ('legacy-sess', 'blocked', 'unknown', 'Old', 'Old notice', '2026-01-01', '2026-01-01')",
      );
      legacyDb.dispose();

      // (a) Open with the current code — must not throw.
      final upgraded = AgentStateDatabase.atPath(home);
      final repo = PersistedRuntimeStateRepository(upgraded.db);
      try {
        // (b) session_work_items is present and writeable.
        repo.enqueueWorkItem(
          workItemId: 'w-after-upgrade',
          sessionId: 'legacy-sess',
          requestId: 'req-after-upgrade',
          payload: const {'message': 'post-upgrade'},
        );
        expect(
          repo.findWorkItem('w-after-upgrade'),
          isNotNull,
          reason: 'session_work_items must be created on first open',
        );

        // (c) Legacy rows are still readable for cleanup/migration.
        final legacyPending = upgraded.db.select(
          "SELECT message FROM session_pending_runs WHERE session_id = 'legacy-sess'",
        );
        expect(legacyPending, hasLength(1));
        expect(legacyPending.first['message'], equals('pre-gate-c message'));

        // (d) clearAllForSession wipes both legacy and new rows in a
        // single call, so a daemon upgrade can converge old state.
        repo.clearAllForSession('legacy-sess');
        // session_work_items is moved to 'cancelled' (terminal), not
        // physically deleted, so the row remains but is no longer
        // "active" and can never be claimed again.
        expect(
          repo.findWorkItem('w-after-upgrade')?.state,
          equals(SessionWorkState.cancelled),
          reason:
              'clearAllForSession must move work items to a terminal '
              'cancelled state, not leave them in queued/running',
        );
        expect(repo.findActiveWorkItem('legacy-sess'), isNull);
        final pendingAfter = upgraded.db.select(
          "SELECT 1 FROM session_pending_runs WHERE session_id = 'legacy-sess'",
        );
        expect(pendingAfter, isEmpty);
      } finally {
        upgraded.dispose();
      }
    });
  });

  group('Gate C.4 — Crash between claim and execution', () {
    test(
      'a claimed but never-completed work item is recoverable as queued on restart',
      () {
        // 1. Simulate the orchestrator claiming the oldest item and persisting
        //    it as `running`.
        final db = AgentStateDatabase.inMemory();
        final repo = PersistedRuntimeStateRepository(db.db);
        db.db.execute(
          "INSERT INTO sessions (session_id, model, created_at, updated_at) "
          "VALUES ('sess-crash', 'gpt-4o', '2026-07-11', '2026-07-11')",
        );
        repo.enqueueWorkItem(
          workItemId: 'w-claim',
          sessionId: 'sess-crash',
          requestId: 'req-claim',
          payload: const {'message': 'first'},
        );
        repo.enqueueWorkItem(
          workItemId: 'w-waiting',
          sessionId: 'sess-crash',
          requestId: 'req-waiting',
          payload: const {'message': 'second'},
        );

        final claimed = repo.claimNextQueuedWorkItem('sess-crash');
        expect(claimed, isNotNull);
        expect(claimed!.workItemId, equals('w-claim'));
        expect(claimed.state, equals(SessionWorkState.running));

        // 2. Simulate a daemon crash: the orchestrator never finished
        //    executing `w-claim`, so it stays in `running` and the second
        //    item remains queued. Nothing was lost.
        expect(repo.findQueuedWorkItems('sess-crash'), hasLength(1));
        final running = repo.findActiveWorkItem('sess-crash');
        expect(running, isNotNull);
        expect(running!.workItemId, equals('w-claim'));

        // 3. The crash-recovery path may decide the work item is idempotent
        //    and re-queue it, or block it. Either way the data is preserved
        //    and never duplicated: exactly one active row exists at any time.
        repo.transitionWorkItemState(
          workItemId: 'w-claim',
          fromState: SessionWorkState.running,
          toState: SessionWorkState.queued,
        );
        final queuedAfter = repo.findQueuedWorkItems('sess-crash');
        expect(queuedAfter, hasLength(2));
        expect(
          queuedAfter.map((w) => w.workItemId).toList(),
          equals(['w-claim', 'w-waiting']),
          reason:
              'no duplication; requeued item sits before the original second item',
        );
        expect(repo.findActiveWorkItem('sess-crash'), isNull);

        // 4. The next claim must be FIFO and never silently drop the second
        //    message just because the first crashed.
        final next = repo.claimNextQueuedWorkItem('sess-crash');
        expect(next!.workItemId, equals('w-claim'));
        final finalQueue = repo.findQueuedWorkItems('sess-crash');
        expect(finalQueue.single.workItemId, equals('w-waiting'));
      },
    );

    test(
      'a non-idempotent crashed work item is moved to blocked, never lost, and never duplicated',
      () {
        final db = AgentStateDatabase.inMemory();
        final repo = PersistedRuntimeStateRepository(db.db);
        db.db.execute(
          "INSERT INTO sessions (session_id, model, created_at, updated_at) "
          "VALUES ('sess-nonid', 'gpt-4o', '2026-07-11', '2026-07-11')",
        );
        final now = DateTime.now();
        repo.insertWorkItem(
          SessionWorkItem(
            workItemId: 'w-side-effect',
            sessionId: 'sess-nonid',
            requestId: 'req-side-effect',
            sequence: 0,
            state: SessionWorkState.running,
            attempt: 0,
            payload: const {'message': 'post a message', 'eventMetadata': {}},
            continuationMetadata: const {
              'currently_executing_tools': ['call-post'],
              'tool_replay_safety': {'call-post': false},
            },
            createdAt: now,
            updatedAt: now,
          ),
        );

        // Simulate the post-crash recovery decision: non-idempotent -> blocked
        repo.transitionWorkItemState(
          workItemId: 'w-side-effect',
          fromState: SessionWorkState.running,
          toState: SessionWorkState.blocked,
        );

        final blocked = repo.findActiveWorkItem('sess-nonid');
        expect(blocked, isNotNull);
        expect(blocked!.state, equals(SessionWorkState.blocked));
        // Blocked IS still in findActiveWorkItem() by design (active invariant
        // covers it) — it just cannot be silently re-claimed into `running`.
        expect(
          () => repo.claimNextQueuedWorkItem('sess-nonid'),
          returnsNormally,
          reason: 'no queued items to claim; must not invent one',
        );
        expect(repo.findQueuedWorkItems('sess-nonid'), isEmpty);
        expect(repo.findWorkItem('w-side-effect'), isNotNull);
      },
    );
  });
}
