// ignore_for_file: deprecated_member_use
// Exercises the per-aggregate repositories introduced in Gate E directly
// (without going through the transitional `PersistedRuntimeStateRepository`
// facade) to keep migration coverage stable while the legacy tables remain
// in the schema, and to guard each repository's contract independently.

import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/persisted_runtime_state_repository.dart';
import 'package:sanad_agent/evolution/db/runtime/legacy_runtime_state_migrator.dart';
import 'package:sanad_agent/evolution/db/runtime/runtime_notice_repository.dart';
import 'package:sanad_agent/evolution/db/runtime/runtime_state_cleanup.dart';
import 'package:sanad_agent/evolution/db/runtime/session_execution_snapshot_repository.dart';
import 'package:sanad_agent/evolution/db/runtime/session_execution_state_coordinator.dart';
import 'package:sanad_agent/evolution/db/runtime/session_work_item_repository.dart';
import 'package:test/test.dart';

void main() {
  late AgentStateDatabase db;
  late SessionWorkItemRepository workItems;
  late RuntimeNoticeRepository notices;
  late LegacyRuntimeStateMigrator legacy;
  late RuntimeStateCleanup cleanup;

  setUp(() {
    db = AgentStateDatabase.inMemory();
    workItems = SessionWorkItemRepository(db);
    notices = RuntimeNoticeRepository(db.db);
    legacy = LegacyRuntimeStateMigrator(db.db);
    cleanup = RuntimeStateCleanup(
      noticeRepository: notices,
      executionStateCoordinator: SessionExecutionStateCoordinator(
        state: db,
        workItems: workItems,
        snapshots: SessionExecutionSnapshotRepository(db),
      ),
      legacyMigrator: legacy,
    );
  });

  tearDown(() => db.dispose());

  void seedSession(String sessionId) {
    db.db.execute(
      "INSERT INTO sessions (session_id, model, created_at, updated_at) "
      "VALUES ('$sessionId', 'gpt-4o', '2026-07-11', '2026-07-11')",
    );
  }

  group('SessionWorkItemRepository — direct (Gate E)', () {
    test('enqueueWorkItem assigns sequence atomically', () {
      seedSession('s-direct');
      final first = workItems.enqueueWorkItem(
        workItemId: 'w-1',
        sessionId: 's-direct',
        requestId: 'req-1',
        payload: const {'message': 'first'},
      );
      final second = workItems.enqueueWorkItem(
        workItemId: 'w-2',
        sessionId: 's-direct',
        requestId: 'req-2',
        payload: const {'message': 'second'},
      );
      expect(first.sequence, 0);
      expect(second.sequence, 1);

      final queued = workItems.findQueuedWorkItems('s-direct');
      expect(queued.map((w) => w.workItemId), equals(['w-1', 'w-2']));
    });

    test('claimNextQueuedWorkItem claims oldest with FIFO guard', () {
      seedSession('s-claim');
      workItems.enqueueWorkItem(
        workItemId: 'w-a',
        sessionId: 's-claim',
        requestId: 'req-a',
      );
      workItems.enqueueWorkItem(
        workItemId: 'w-b',
        sessionId: 's-claim',
        requestId: 'req-b',
      );

      final claimed = workItems.claimNextQueuedWorkItem('s-claim');
      expect(claimed, isNotNull);
      expect(claimed!.workItemId, 'w-a');
      expect(claimed.state, SessionWorkState.running);

      final remaining = workItems.findQueuedWorkItems('s-claim');
      expect(remaining.single.workItemId, 'w-b');
    });

    test('claimNextQueuedWorkItem rejects non-running/cancelled target', () {
      seedSession('s-reject');
      workItems.enqueueWorkItem(
        workItemId: 'w',
        sessionId: 's-reject',
        requestId: 'req',
      );
      expect(
        () => workItems.claimNextQueuedWorkItem(
          's-reject',
          toState: SessionWorkState.waiting,
        ),
        throwsException,
        reason: 'only queued -> running|cancelled is allowed by the claim',
      );
    });

    test('claimNextQueuedWorkItem returns null when queue is empty', () {
      seedSession('s-empty');
      expect(workItems.claimNextQueuedWorkItem('s-empty'), isNull);
    });

    test('transitionWorkItemState enforces allowed-transition graph', () {
      seedSession('s-trans');
      workItems.enqueueWorkItem(
        workItemId: 'w',
        sessionId: 's-trans',
        requestId: 'req',
      );

      workItems.transitionWorkItemState(
        workItemId: 'w',
        fromState: SessionWorkState.queued,
        toState: SessionWorkState.running,
      );
      expect(workItems.findWorkItem('w')!.state, SessionWorkState.running);

      // Invalid: running -> queued is allowed, but wrong source guard must throw.
      expect(
        () => workItems.transitionWorkItemState(
          workItemId: 'w',
          fromState: SessionWorkState.queued,
          toState: SessionWorkState.completed,
        ),
        throwsException,
        reason: 'source mismatch throws before reachability is checked',
      );

      // Disallowed target: queued was already invalid before, now run it from running.
      expect(
        () => workItems.transitionWorkItemState(
          workItemId: 'w',
          fromState: SessionWorkState.running,
          toState: SessionWorkState.queued,
        ),
        returnsNormally,
        reason: 'running -> queued is allowed by the graph',
      );
    });

    test(
      'transitionWorkItemState applies provider/model/continuationMetadata overrides',
      () {
        seedSession('s-meta');
        workItems.enqueueWorkItem(
          workItemId: 'w',
          sessionId: 's-meta',
          requestId: 'req',
          providerInstanceId: 'old',
          modelId: 'old-model',
        );
        workItems.transitionWorkItemState(
          workItemId: 'w',
          fromState: SessionWorkState.queued,
          toState: SessionWorkState.running,
          attempt: 3,
          continuationMetadata: const {'gate': 'e'},
          providerInstanceId: 'new',
          modelId: 'new-model',
        );
        final updated = workItems.findWorkItem('w')!;
        expect(updated.attempt, 3);
        expect(updated.providerInstanceId, 'new');
        expect(updated.modelId, 'new-model');
        expect(updated.continuationMetadata['gate'], 'e');
      },
    );

    test('findActiveWorkItem returns the single active item', () {
      seedSession('s-active');
      workItems.enqueueWorkItem(
        workItemId: 'w-active',
        sessionId: 's-active',
        requestId: 'req',
        state: SessionWorkState.running,
      );
      final active = workItems.findActiveWorkItem('s-active');
      expect(active, isNotNull);
      expect(active!.workItemId, 'w-active');
    });

    test(
      'cleanupOrphanedWorkItems deletes rows whose session no longer exists',
      () {
        seedSession('s-live');
        workItems.enqueueWorkItem(
          workItemId: 'w-live',
          sessionId: 's-live',
          requestId: 'req-live',
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

        final removed = workItems.cleanupOrphanedWorkItems();
        expect(removed, 1);
        expect(workItems.findWorkItem('w-orphan'), isNull);
        expect(workItems.findWorkItem('w-live'), isNotNull);
      },
    );

    test('findAllSessionIdsWithWorkItems returns distinct sessions', () {
      seedSession('s-1');
      seedSession('s-2');
      workItems.enqueueWorkItem(
        workItemId: 'w-1',
        sessionId: 's-1',
        requestId: 'req-1',
      );
      workItems.enqueueWorkItem(
        workItemId: 'w-2',
        sessionId: 's-1',
        requestId: 'req-2',
      );
      workItems.enqueueWorkItem(
        workItemId: 'w-3',
        sessionId: 's-2',
        requestId: 'req-3',
      );
      final ids = workItems.findAllSessionIdsWithWorkItems().toSet();
      expect(ids, containsAll(['s-1', 's-2']));
    });

    test('restart queries exclude terminal work history', () {
      seedSession('s-terminal');
      seedSession('s-restorable');
      workItems.enqueueWorkItem(
        workItemId: 'w-terminal',
        sessionId: 's-terminal',
        requestId: 'req-terminal',
        state: SessionWorkState.completed,
        continuationMetadata: const {'large_terminal_history': true},
      );
      workItems.enqueueWorkItem(
        workItemId: 'w-restorable',
        sessionId: 's-restorable',
        requestId: 'req-restorable',
        state: SessionWorkState.waiting,
      );

      expect(workItems.findSessionIdsWithRestorableWorkItems(), [
        's-restorable',
      ]);
      expect(
        workItems
            .findRestorableWorkItems('s-restorable')
            .map((item) => item.workItemId),
        ['w-restorable'],
      );
      expect(workItems.findRestorableWorkItems('s-terminal'), isEmpty);
      expect(workItems.findAllWorkItems('s-terminal'), hasLength(1));
    });

    test('cancelAllActiveAndQueuedWorkItems moves items to cancelled', () {
      seedSession('s-cancel');
      workItems.enqueueWorkItem(
        workItemId: 'w-1',
        sessionId: 's-cancel',
        requestId: 'req-1',
        state: SessionWorkState.running,
      );
      workItems.enqueueWorkItem(
        workItemId: 'w-2',
        sessionId: 's-cancel',
        requestId: 'req-2',
      );
      workItems.cancelAllActiveAndQueuedWorkItems('s-cancel');
      expect(workItems.findWorkItem('w-1')!.state, SessionWorkState.cancelled);
      expect(workItems.findWorkItem('w-2')!.state, SessionWorkState.cancelled);
    });

    test(
      'rewriteQueuedWorkItemRoute and rewriteAllNonTerminalWorkItemRoute scopes',
      () {
        seedSession('s-route');
        workItems.enqueueWorkItem(
          workItemId: 'w-queued',
          sessionId: 's-route',
          requestId: 'q',
          providerInstanceId: 'old',
          modelId: 'old-model',
        );
        workItems.enqueueWorkItem(
          workItemId: 'w-running',
          sessionId: 's-route',
          requestId: 'r',
          providerInstanceId: 'old',
          modelId: 'old-model',
          state: SessionWorkState.running,
        );

        // Queued-only rewrite leaves running item alone.
        workItems.rewriteQueuedWorkItemRoute(
          's-route',
          providerInstanceId: 'queued-new',
          modelId: 'queued-model',
        );
        expect(
          workItems.findWorkItem('w-queued')!.providerInstanceId,
          'queued-new',
        );
        expect(
          workItems.findWorkItem('w-running')!.providerInstanceId,
          'old',
          reason: 'queued-only rewrite must not touch running items',
        );

        // Gate E.2: non-terminal rewrite picks up running too.
        workItems.rewriteAllNonTerminalWorkItemRoute(
          's-route',
          providerInstanceId: 'all-new',
          modelId: 'all-model',
        );
        expect(
          workItems.findWorkItem('w-running')!.providerInstanceId,
          'all-new',
        );
        expect(workItems.findWorkItem('w-running')!.modelId, 'all-model');
      },
    );
  });

  group('RuntimeNoticeRepository — direct (Gate E)', () {
    test('upsertNotice + findNotice + deleteNotice', () {
      notices.upsertNotice(
        sessionId: 's-1',
        requestId: 'req',
        status: 'blocked',
        reason: 'auth',
        title: 'T',
        message: 'M',
        providerInstanceId: 'prov-1',
        providerDisplayName: 'Display',
        actions: const ['stop', 'retry'],
      );
      final notice = notices.findNotice('s-1');
      expect(notice, isNotNull);
      expect(notice!.status, 'blocked');
      expect(notice.actions, ['stop', 'retry']);
      expect(notice.providerDisplayName, 'Display');

      notices.deleteNotice('s-1');
      expect(notices.findNotice('s-1'), isNull);
    });

    test('findAllNotices groups by session', () {
      notices.upsertNotice(
        sessionId: 's-1',
        status: 'waiting',
        reason: 'rate_limit',
        title: 'A',
        message: 'M',
      );
      notices.upsertNotice(
        sessionId: 's-2',
        status: 'blocked',
        reason: 'auth',
        title: 'B',
        message: 'M',
      );
      final all = notices.findAllNotices();
      expect(all.length, 2);
      expect(all['s-1']!.status, 'waiting');
      expect(all['s-2']!.status, 'blocked');
    });

    test(
      'upsertNotice replaces previously stored rows for the same session',
      () {
        notices.upsertNotice(
          sessionId: 's-1',
          status: 'waiting',
          reason: 'rate_limit',
          title: 'A',
          message: 'old',
        );
        notices.upsertNotice(
          sessionId: 's-1',
          status: 'blocked',
          reason: 'auth',
          title: 'B',
          message: 'new',
        );
        final notice = notices.findNotice('s-1');
        expect(notice!.title, 'B');
        expect(notice.message, 'new');
      },
    );
  });

  group('LegacyRuntimeStateMigrator — direct (Gate E)', () {
    test('suspended runs upsert/find/delete roundtrip', () {
      legacy.upsertSuspendedRun(
        sessionId: 's-1',
        requestId: 'req',
        message: 'M',
        providerInstanceId: 'prov-1',
      );
      final found = legacy.findSuspendedRun('s-1');
      expect(found, isNotNull);
      expect(found!.message, 'M');

      legacy.upsertSuspendedRun(sessionId: 's-1', message: 'updated');
      expect(legacy.findSuspendedRun('s-1')!.message, 'updated');

      legacy.deleteSuspendedRun('s-1');
      expect(legacy.findSuspendedRun('s-1'), isNull);
    });

    test('pending runs FIFO + pop + deleteAll', () {
      legacy.appendPendingRun(sessionId: 's-1', message: 'A');
      legacy.appendPendingRun(sessionId: 's-1', message: 'B');
      expect(
        legacy.findPendingRuns('s-1').map((r) => r.message),
        equals(['A', 'B']),
      );

      final popped = legacy.popFirstPendingRun('s-1');
      expect(popped!.message, 'A');
      expect(legacy.findPendingRuns('s-1').single.message, 'B');

      legacy.deleteAllPendingRuns('s-1');
      expect(legacy.findPendingRuns('s-1'), isEmpty);
    });

    test('rewritePendingRoute updates all entries', () {
      legacy.appendPendingRun(
        sessionId: 's-1',
        message: 'A',
        providerInstanceId: 'old',
        modelId: 'old-model',
      );
      legacy.appendPendingRun(
        sessionId: 's-1',
        message: 'B',
        providerInstanceId: 'old',
        modelId: 'old-model',
      );
      legacy.rewritePendingRoute(
        's-1',
        providerInstanceId: 'new',
        modelId: 'new-model',
      );
      final queue = legacy.findPendingRuns('s-1');
      expect(queue.every((r) => r.providerInstanceId == 'new'), isTrue);
      expect(queue.every((r) => r.modelId == 'new-model'), isTrue);
    });

    test('purgeLegacy*ForSession survives missing table rows best-effort', () {
      // Empty table — purges must not throw and must not touch the new
      // work items table.
      seedSession('s-legacy');
      workItems.enqueueWorkItem(
        workItemId: 'w-live',
        sessionId: 's-legacy',
        requestId: 'req',
      );

      legacy.purgeLegacySuspendedRunsForSession('s-legacy');
      legacy.purgeLegacyPendingRunsForSession('s-legacy');

      expect(workItems.findWorkItem('w-live'), isNotNull);
    });
  });

  group('RuntimeStateCleanup — direct (Gate E)', () {
    test(
      'clearAllForSession removes notice + cancels work + purges legacy',
      () {
        seedSession('s-cleanup');
        workItems.enqueueWorkItem(
          workItemId: 'w-1',
          sessionId: 's-cleanup',
          requestId: 'req-1',
          state: SessionWorkState.running,
        );
        workItems.enqueueWorkItem(
          workItemId: 'w-2',
          sessionId: 's-cleanup',
          requestId: 'req-2',
        );
        notices.upsertNotice(
          sessionId: 's-cleanup',
          status: 'waiting',
          reason: 'rate_limit',
          title: 'T',
          message: 'M',
        );
        legacy.upsertSuspendedRun(sessionId: 's-cleanup', message: 'L');
        legacy.appendPendingRun(sessionId: 's-cleanup', message: 'P');

        cleanup.clearAllForSession('s-cleanup');

        expect(notices.findNotice('s-cleanup'), isNull);
        expect(
          workItems.findWorkItem('w-1')!.state,
          SessionWorkState.cancelled,
        );
        expect(
          workItems.findWorkItem('w-2')!.state,
          SessionWorkState.cancelled,
        );
        expect(legacy.findSuspendedRun('s-cleanup'), isNull);
        expect(legacy.findPendingRuns('s-cleanup'), isEmpty);
      },
    );
  });

  group('Facade composition — direct (Gate E)', () {
    test(
      'PersistedRuntimeStateRepository exposes the same repositories it delegates to',
      () {
        final facade = PersistedRuntimeStateRepository(db.db);
        expect(facade.workItems, isA<SessionWorkItemRepository>());
        expect(facade.notices, isA<RuntimeNoticeRepository>());
        expect(facade.legacy, isA<LegacyRuntimeStateMigrator>());
        expect(facade.cleanup, isA<RuntimeStateCleanup>());
      },
    );

    test(
      'facade clearAllForSession delegates to the same cleanup instance',
      () {
        seedSession('s-facade');
        final facade = PersistedRuntimeStateRepository(db.db);
        facade.enqueueWorkItem(
          workItemId: 'w',
          sessionId: 's-facade',
          requestId: 'req',
        );
        facade.upsertNotice(
          sessionId: 's-facade',
          status: 'blocked',
          reason: 'auth',
          title: 'T',
          message: 'M',
        );
        facade.clearAllForSession('s-facade');
        expect(facade.findWorkItem('w')!.state, SessionWorkState.cancelled);
        expect(facade.findNotice('s-facade'), isNull);
      },
    );
  });
}
