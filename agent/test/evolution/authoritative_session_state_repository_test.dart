import 'package:sanad_agent/core/provider_runtime/provider_instance.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/core/provider_runtime/provider_protocol_constants.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/session_db.dart';
import 'package:sanad_agent/evolution/db/runtime/session_execution_snapshot_repository.dart';
import 'package:sanad_agent/evolution/db/runtime/session_execution_state_coordinator.dart';
import 'package:sanad_agent/evolution/db/runtime/session_route_transition_repository.dart';
import 'package:sanad_agent/evolution/db/runtime/session_route_mutation_coordinator.dart';
import 'package:sanad_agent/evolution/db/runtime/runtime_notice_repository.dart';
import 'package:sanad_agent/evolution/db/runtime/session_work_item_repository.dart';
import 'package:sanad_agent/evolution/db/persisted_runtime_state_repository.dart';
import 'package:sanad_agent/evolution/models/session_execution_snapshot.dart';
import 'package:sanad_agent/evolution/models/session_route_transition.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late AgentStateDatabase state;
  late SessionExecutionSnapshotRepository snapshots;
  late SessionRouteTransitionRepository transitions;
  late ProviderInstanceRepository providerInstances;
  late SessionWorkItemRepository workItems;
  late SessionExecutionStateCoordinator executionState;
  late SessionRouteMutationCoordinator routeMutations;

  setUp(() {
    state = AgentStateDatabase.inMemory();
    snapshots = SessionExecutionSnapshotRepository(state);
    transitions = SessionRouteTransitionRepository(state);
    providerInstances = ProviderInstanceRepository(state);
    workItems = SessionWorkItemRepository(state);
    executionState = SessionExecutionStateCoordinator(
      state: state,
      workItems: workItems,
      snapshots: snapshots,
    );
    routeMutations = SessionRouteMutationCoordinator(
      state: state,
      workItems: workItems,
      transitions: transitions,
      providerInstances: providerInstances,
      snapshots: snapshots,
      executionState: executionState,
    );
  });

  tearDown(() => state.dispose());

  void seedSession(
    String sessionId, {
    String providerId = 'provider-a',
    String model = 'model-a',
  }) {
    state.db.execute(
      '''
      INSERT INTO sessions (
        session_id, model, provider_id, created_at, updated_at
      ) VALUES (?, ?, ?, ?, ?)
      ''',
      [sessionId, model, providerId, '2026-07-15', '2026-07-15'],
    );
  }

  SessionRouteTransition routeTransition({
    required String sessionId,
    required int revision,
    required String eventId,
  }) {
    return SessionRouteTransition(
      sessionId: sessionId,
      routeRevision: revision,
      eventId: eventId,
      source: SessionRouteSource.autoFailover,
      previousProviderInstanceId: 'provider-a',
      providerInstanceId: 'provider-b',
      model: 'model-a',
      reason: 'rate_limit',
      requestId: 'request-1',
      createdAt: DateTime.utc(2026, 7, 15, 12),
    );
  }

  group('AgentStateDatabase transaction owner', () {
    test('commits composed writes and rolls all of them back on failure', () {
      seedSession('session-transaction');

      state.transaction((tx) {
        snapshots.updateSnapshot(
          sessionId: 'session-transaction',
          state: SessionExecutionState.running,
          workItemId: 'work-1',
          requestId: 'request-1',
          transaction: tx,
        );
        transitions.insert(
          routeTransition(
            sessionId: 'session-transaction',
            revision: 2,
            eventId: 'event-commit',
          ),
          transaction: tx,
        );
      });

      expect(
        snapshots.getSnapshot('session-transaction').state,
        SessionExecutionState.running,
      );
      expect(transitions.findByEventId('event-commit'), isNotNull);

      expect(
        () => state.transaction<void>((tx) {
          snapshots.updateSnapshot(
            sessionId: 'session-transaction',
            state: SessionExecutionState.blocked,
            workItemId: 'work-1',
            requestId: 'request-1',
            transaction: tx,
          );
          transitions.insert(
            routeTransition(
              sessionId: 'session-transaction',
              revision: 3,
              eventId: 'event-rollback',
            ),
            transaction: tx,
          );
          throw StateError('rollback');
        }),
        throwsStateError,
      );

      expect(
        snapshots.getSnapshot('session-transaction').state,
        SessionExecutionState.running,
      );
      expect(transitions.findByEventId('event-rollback'), isNull);
    });

    test(
      'nested transactions use savepoints without breaking the outer owner',
      () {
        seedSession('session-nested');

        state.transaction((outer) {
          snapshots.updateSnapshot(
            sessionId: 'session-nested',
            state: SessionExecutionState.queued,
            workItemId: 'work-1',
            requestId: 'request-1',
            transaction: outer,
          );
          expect(
            () => state.transaction<void>((inner) {
              transitions.insert(
                routeTransition(
                  sessionId: 'session-nested',
                  revision: 2,
                  eventId: 'nested-rollback',
                ),
                transaction: inner,
              );
              throw StateError('inner rollback');
            }),
            throwsStateError,
          );
          transitions.insert(
            routeTransition(
              sessionId: 'session-nested',
              revision: 2,
              eventId: 'outer-commit',
            ),
            transaction: outer,
          );
        });

        expect(
          snapshots.getSnapshot('session-nested').state,
          SessionExecutionState.queued,
        );
        expect(transitions.findByEventId('nested-rollback'), isNull);
        expect(transitions.findByEventId('outer-commit'), isNotNull);
      },
    );

    test('rejects asynchronous callbacks before committing', () {
      expect(() => state.transaction((_) async => 1), throwsStateError);
    });
  });

  group('SessionExecutionSnapshotRepository', () {
    test('canonical payload roundtrips and rejects malformed revisions', () {
      final snapshot = SessionExecutionSnapshot(
        sessionId: 'session-contract',
        state: SessionExecutionState.resuming,
        workItemId: 'work-contract',
        requestId: 'request-contract',
        revision: 7,
        updatedAt: DateTime.utc(2026, 7, 15, 12),
        turnStartedAt: DateTime.utc(2026, 7, 15, 11, 30),
      );

      final parsed = SessionExecutionSnapshot.fromPayload(
        snapshot.toPayload(observedAt: DateTime.utc(2026, 7, 15, 12)),
      );

      expect(parsed.sessionId, snapshot.sessionId);
      expect(parsed.state, snapshot.state);
      expect(parsed.workItemId, snapshot.workItemId);
      expect(parsed.requestId, snapshot.requestId);
      expect(parsed.revision, snapshot.revision);
      expect(parsed.updatedAt, snapshot.updatedAt);
      expect(parsed.turnStartedAt, snapshot.turnStartedAt);
      expect(
        snapshot.toPayload(
          observedAt: DateTime.utc(2026, 7, 15, 12),
        )['elapsed_ms'],
        const Duration(minutes: 30).inMilliseconds,
      );
      expect(
        () => SessionExecutionSnapshot.fromPayload({
          ...snapshot.toPayload(),
          'revision': -1,
        }),
        throwsFormatException,
      );
    });

    test(
      'legacy sessions without a row read as virtual idle revision zero',
      () {
        seedSession('session-legacy');

        final snapshot = snapshots.getSnapshot('session-legacy');

        expect(snapshot.state, SessionExecutionState.idle);
        expect(snapshot.revision, 0);
        expect(snapshot.workItemId, isNull);
        expect(snapshot.requestId, isNull);
        expect(snapshots.findPersistedSnapshot('session-legacy'), isNull);
      },
    );

    test(
      'increments once per tuple change and is idempotent for equal state',
      () {
        seedSession('session-revision');
        final timestamp = DateTime.utc(2026, 7, 15, 10);

        final first = snapshots.updateSnapshot(
          sessionId: 'session-revision',
          state: SessionExecutionState.running,
          workItemId: 'work-1',
          requestId: 'request-1',
          updatedAt: timestamp,
        );
        final duplicate = snapshots.updateSnapshot(
          sessionId: 'session-revision',
          state: SessionExecutionState.running,
          workItemId: 'work-1',
          requestId: 'request-1',
          updatedAt: timestamp.add(const Duration(hours: 1)),
        );
        final second = snapshots.updateSnapshot(
          sessionId: 'session-revision',
          state: SessionExecutionState.waiting,
          workItemId: 'work-1',
          requestId: 'request-1',
        );

        expect(first.changed, isTrue);
        expect(first.snapshot.revision, 1);
        expect(duplicate.changed, isFalse);
        expect(duplicate.snapshot.revision, 1);
        expect(duplicate.snapshot.updatedAt, timestamp);
        expect(second.changed, isTrue);
        expect(second.snapshot.revision, 2);
      },
    );

    test(
      'idle without a prior row stays virtual and does not consume revision',
      () {
        seedSession('session-idle');

        final idle = snapshots.updateSnapshot(
          sessionId: 'session-idle',
          state: SessionExecutionState.idle,
        );
        final running = snapshots.updateSnapshot(
          sessionId: 'session-idle',
          state: SessionExecutionState.running,
          workItemId: 'work-1',
        );

        expect(idle.changed, isFalse);
        expect(idle.snapshot.revision, 0);
        expect(running.snapshot.revision, 1);
      },
    );

    test('batch lookup fills missing sessions with virtual idle snapshots', () {
      seedSession('session-a');
      seedSession('session-b');
      snapshots.updateSnapshot(
        sessionId: 'session-a',
        state: SessionExecutionState.blocked,
        workItemId: 'work-a',
      );

      final result = snapshots.findSnapshots(['session-a', 'session-b']);

      expect(result['session-a']!.state, SessionExecutionState.blocked);
      expect(result['session-b']!.state, SessionExecutionState.idle);
      expect(result['session-b']!.revision, 0);
    });

    test('session deletion cascades to its persisted snapshot', () {
      seedSession('session-delete');
      snapshots.updateSnapshot(
        sessionId: 'session-delete',
        state: SessionExecutionState.stopping,
        workItemId: 'work-1',
      );

      state.db.execute('DELETE FROM sessions WHERE session_id = ?', [
        'session-delete',
      ]);

      expect(snapshots.findPersistedSnapshot('session-delete'), isNull);
    });
  });

  group('SessionExecutionStateCoordinator', () {
    test(
      'publishes once after commit and skips idempotent aggregate writes',
      () {
        seedSession('session-events');
        final emitted = <SessionExecutionSnapshot>[];
        executionState.changes.listen(emitted.add);

        executionState.enqueueWorkItem(
          workItemId: 'work-head',
          sessionId: 'session-events',
          requestId: 'request-head',
        );
        executionState.enqueueWorkItem(
          workItemId: 'work-tail',
          sessionId: 'session-events',
          requestId: 'request-tail',
        );

        expect(emitted, hasLength(1));
        expect(emitted.single.state, SessionExecutionState.queued);
        expect(emitted.single.workItemId, 'work-head');
        expect(emitted.single.revision, 1);
        expect(
          emitted.single.turnStartedAt,
          workItems.findWorkItem('work-head')!.createdAt.toUtc(),
        );
      },
    );

    test('restart normalization derives stale stopping from durable work', () {
      seedSession('session-restart-stopping');
      executionState.enqueueWorkItem(
        workItemId: 'work-restart',
        sessionId: 'session-restart-stopping',
        state: SessionWorkState.running,
      );
      executionState.markStopping('session-restart-stopping');

      final normalized = executionState.normalizeAfterRestart(
        'session-restart-stopping',
      );

      expect(normalized.changed, isTrue);
      expect(normalized.snapshot.state, SessionExecutionState.running);
      expect(normalized.snapshot.workItemId, 'work-restart');
    });

    test('restart recompute never projects durable active work as idle', () {
      final cases = {
        SessionWorkState.running: SessionExecutionState.running,
        SessionWorkState.waiting: SessionExecutionState.waiting,
        SessionWorkState.blocked: SessionExecutionState.blocked,
        SessionWorkState.resuming: SessionExecutionState.resuming,
      };

      for (final entry in cases.entries) {
        final sessionId = 'session-restart-${entry.key.name}';
        seedSession(sessionId);
        executionState.enqueueWorkItem(
          workItemId: 'work-${entry.key.name}',
          sessionId: sessionId,
          state: entry.key,
        );
        snapshots.updateSnapshot(
          sessionId: sessionId,
          state: SessionExecutionState.idle,
        );

        final normalized = executionState.normalizeAfterRestart(sessionId);

        expect(normalized.snapshot.state, entry.value);
        expect(normalized.snapshot.state, isNot(SessionExecutionState.idle));
      }
    });

    test('FIFO head owns queued snapshot and tail enqueue is idempotent', () {
      seedSession('session-fifo');
      final first = executionState.enqueueWorkItem(
        workItemId: 'work-1',
        sessionId: 'session-fifo',
        requestId: 'request-1',
      );
      final second = executionState.enqueueWorkItem(
        workItemId: 'work-2',
        sessionId: 'session-fifo',
        requestId: 'request-2',
      );

      expect(first.execution.snapshot.state, SessionExecutionState.queued);
      expect(first.execution.snapshot.workItemId, 'work-1');
      expect(second.execution.changed, isFalse);
      expect(second.execution.snapshot.revision, 1);
      expect(second.execution.snapshot.workItemId, 'work-1');
    });

    test(
      'active state outranks queued tail and terminal reveals FIFO head',
      () {
        seedSession('session-priority');
        executionState.enqueueWorkItem(
          workItemId: 'work-active',
          sessionId: 'session-priority',
          requestId: 'request-active',
          state: SessionWorkState.running,
        );
        executionState.enqueueWorkItem(
          workItemId: 'work-queued',
          sessionId: 'session-priority',
          requestId: 'request-queued',
        );

        expect(
          snapshots.getSnapshot('session-priority').state,
          SessionExecutionState.running,
        );
        expect(
          snapshots.getSnapshot('session-priority').workItemId,
          'work-active',
        );

        final terminal = executionState.transitionOwnedWorkItem(
          sessionId: 'session-priority',
          workItemId: 'work-active',
          toState: SessionWorkState.completed,
        );
        expect(terminal.applied, isTrue);
        expect(terminal.execution.snapshot.state, SessionExecutionState.queued);
        expect(terminal.execution.snapshot.workItemId, 'work-queued');
      },
    );

    test('waiting blocked and resuming remain authoritative active states', () {
      seedSession('session-recovery');
      executionState.enqueueWorkItem(
        workItemId: 'work-recovery',
        sessionId: 'session-recovery',
        requestId: 'request-recovery',
        state: SessionWorkState.running,
      );

      executionState.transitionWorkItem(
        workItemId: 'work-recovery',
        fromState: SessionWorkState.running,
        toState: SessionWorkState.waiting,
      );
      expect(
        snapshots.getSnapshot('session-recovery').state,
        SessionExecutionState.waiting,
      );
      executionState.transitionWorkItem(
        workItemId: 'work-recovery',
        fromState: SessionWorkState.waiting,
        toState: SessionWorkState.blocked,
      );
      expect(
        snapshots.getSnapshot('session-recovery').state,
        SessionExecutionState.blocked,
      );
      executionState.transitionWorkItem(
        workItemId: 'work-recovery',
        fromState: SessionWorkState.blocked,
        toState: SessionWorkState.resuming,
      );
      expect(
        snapshots.getSnapshot('session-recovery').state,
        SessionExecutionState.resuming,
      );
    });

    for (final recoveryState in [
      SessionWorkState.waiting,
      SessionWorkState.blocked,
    ]) {
      test(
        'owned automatic retry claims ${recoveryState.name}, commits final, and becomes idle',
        () {
          final sessionId = 'session-auto-retry-${recoveryState.name}';
          final workItemId = 'work-auto-retry-${recoveryState.name}';
          seedSession(sessionId);
          executionState.enqueueWorkItem(
            workItemId: workItemId,
            sessionId: sessionId,
            requestId: 'request-auto-retry',
            state: SessionWorkState.running,
          );
          expect(
            executionState.bindRunOwnership(
              sessionId: sessionId,
              workItemId: workItemId,
              runId: 'run-auto-retry',
              generation: 4,
            ),
            isTrue,
          );
          executionState.transitionWorkItem(
            workItemId: workItemId,
            fromState: SessionWorkState.running,
            toState: recoveryState,
          );

          final claimed = executionState.claimOwnedAutomaticRetry(
            sessionId: sessionId,
            workItemId: workItemId,
            runId: 'run-auto-retry',
            generation: 4,
            requestId: 'request-auto-retry',
          );

          expect(claimed.applied, isTrue);
          expect(claimed.value?.state, SessionWorkState.resuming);
          expect(
            claimed.execution.snapshot.state,
            SessionExecutionState.resuming,
          );

          final terminal = executionState.commitTerminal(
            sessionId: sessionId,
            workItemId: workItemId,
            runId: 'run-auto-retry',
            generation: 4,
            assistantResult: Message(
              role: MessageRole.assistant,
              content: 'Recovered answer',
            ),
          );

          expect(terminal, TerminalCommitOutcome.committed);
          expect(
            workItems.findWorkItem(workItemId)?.state,
            SessionWorkState.completed,
          );
          expect(
            snapshots.getSnapshot(sessionId).state,
            SessionExecutionState.idle,
          );
        },
      );
    }

    test(
      'automatic retry rejects a stale run without changing blocked state',
      () {
        seedSession('session-stale-auto-retry');
        executionState.enqueueWorkItem(
          workItemId: 'work-stale-auto-retry',
          sessionId: 'session-stale-auto-retry',
          requestId: 'request-stale-auto-retry',
          state: SessionWorkState.running,
        );
        executionState.bindRunOwnership(
          sessionId: 'session-stale-auto-retry',
          workItemId: 'work-stale-auto-retry',
          runId: 'run-current',
          generation: 8,
        );
        executionState.transitionWorkItem(
          workItemId: 'work-stale-auto-retry',
          fromState: SessionWorkState.running,
          toState: SessionWorkState.blocked,
        );

        final stale = executionState.claimOwnedAutomaticRetry(
          sessionId: 'session-stale-auto-retry',
          workItemId: 'work-stale-auto-retry',
          runId: 'run-old',
          generation: 7,
          requestId: 'request-stale-auto-retry',
        );

        expect(stale.applied, isFalse);
        expect(
          snapshots.getSnapshot('session-stale-auto-retry').state,
          SessionExecutionState.blocked,
        );
      },
    );

    test('normal and resume FIFO claims produce distinct execution states', () {
      seedSession('session-normal-claim');
      executionState.enqueueWorkItem(
        workItemId: 'work-normal',
        sessionId: 'session-normal-claim',
      );
      final normal = executionState.claimNext('session-normal-claim');
      expect(normal.value!.state, SessionWorkState.running);
      expect(normal.execution.snapshot.state, SessionExecutionState.running);

      seedSession('session-resume-claim');
      executionState.enqueueWorkItem(
        workItemId: 'work-resume',
        sessionId: 'session-resume-claim',
      );
      final resume = executionState.claimNext(
        'session-resume-claim',
        isResume: true,
      );
      expect(resume.value!.state, SessionWorkState.resuming);
      expect(resume.execution.snapshot.state, SessionExecutionState.resuming);
    });

    test(
      'stopping outranks newly queued work until captured work is cancelled',
      () {
        seedSession('session-stopping');
        executionState.enqueueWorkItem(
          workItemId: 'work-old',
          sessionId: 'session-stopping',
          requestId: 'request-old',
          state: SessionWorkState.running,
        );
        final stopping = executionState.markStopping(
          'session-stopping',
          expectedWorkItemId: 'work-old',
        );
        expect(stopping.snapshot.state, SessionExecutionState.stopping);

        executionState.enqueueWorkItem(
          workItemId: 'work-new',
          sessionId: 'session-stopping',
          requestId: 'request-new',
        );
        expect(
          snapshots.getSnapshot('session-stopping').state,
          SessionExecutionState.stopping,
        );

        final released = executionState.cancelWorkItems('session-stopping', [
          'work-old',
        ]);
        expect(released.snapshot.state, SessionExecutionState.queued);
        expect(released.snapshot.workItemId, 'work-new');
      },
    );

    test('last terminal transition becomes idle', () {
      seedSession('session-terminal');
      executionState.enqueueWorkItem(
        workItemId: 'work-terminal',
        sessionId: 'session-terminal',
        state: SessionWorkState.running,
      );

      final terminal = executionState.transitionOwnedWorkItem(
        sessionId: 'session-terminal',
        workItemId: 'work-terminal',
        toState: SessionWorkState.completed,
      );

      expect(terminal.execution.snapshot.state, SessionExecutionState.idle);
      expect(terminal.execution.snapshot.workItemId, isNull);
    });

    test(
      'stale work owner cannot mutate a newer active run or its revision',
      () {
        seedSession('session-stale');
        executionState.enqueueWorkItem(
          workItemId: 'work-old',
          sessionId: 'session-stale',
          state: SessionWorkState.running,
        );
        executionState.transitionOwnedWorkItem(
          sessionId: 'session-stale',
          workItemId: 'work-old',
          toState: SessionWorkState.completed,
        );
        executionState.enqueueWorkItem(
          workItemId: 'work-new',
          sessionId: 'session-stale',
          state: SessionWorkState.running,
        );
        final before = snapshots.getSnapshot('session-stale');

        final stale = executionState.transitionOwnedWorkItem(
          sessionId: 'session-stale',
          workItemId: 'work-old',
          toState: SessionWorkState.blocked,
        );
        final after = snapshots.getSnapshot('session-stale');

        expect(stale.applied, isFalse);
        expect(after.state, SessionExecutionState.running);
        expect(after.workItemId, 'work-new');
        expect(after.revision, before.revision);
      },
    );
  });

  group('SessionRouteTransitionRepository', () {
    test('roundtrips transitions in route revision order', () {
      seedSession('session-route');
      transitions.insert(
        routeTransition(
          sessionId: 'session-route',
          revision: 3,
          eventId: 'event-3',
        ),
      );
      transitions.insert(
        routeTransition(
          sessionId: 'session-route',
          revision: 2,
          eventId: 'event-2',
        ),
      );

      final rows = transitions.findForSession('session-route');

      expect(rows.map((row) => row.routeRevision), [2, 3]);
      expect(rows.first.source, SessionRouteSource.autoFailover);
      expect(rows.first.providerInstanceId, 'provider-b');
      expect(
        transitions.findByRevision('session-route', 3)!.eventId,
        'event-3',
      );
    });

    test('enforces logical revision and event identity uniqueness', () {
      seedSession('session-unique');
      transitions.insert(
        routeTransition(
          sessionId: 'session-unique',
          revision: 2,
          eventId: 'event-unique',
        ),
      );

      expect(
        () => transitions.insert(
          routeTransition(
            sessionId: 'session-unique',
            revision: 2,
            eventId: 'event-another',
          ),
        ),
        throwsA(isA<SqliteException>()),
      );
      seedSession('session-other');
      expect(
        () => transitions.insert(
          routeTransition(
            sessionId: 'session-other',
            revision: 2,
            eventId: 'event-unique',
          ),
        ),
        throwsA(isA<SqliteException>()),
      );
    });

    test(
      'schema rejects unknown route sources and cascades session deletion',
      () {
        seedSession('session-source');
        expect(
          () => state.db.execute(
            '''
          INSERT INTO session_route_transitions (
            session_id, route_revision, event_id, source,
            provider_instance_id, model, created_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?)
          ''',
            [
              'session-source',
              2,
              'event-invalid',
              'automatic',
              'provider-b',
              'model-a',
              '2026-07-15',
            ],
          ),
          throwsA(isA<SqliteException>()),
        );

        transitions.insert(
          routeTransition(
            sessionId: 'session-source',
            revision: 2,
            eventId: 'event-cascade',
          ),
        );
        state.db.execute('DELETE FROM sessions WHERE session_id = ?', [
          'session-source',
        ]);
        expect(transitions.findByEventId('event-cascade'), isNull);
      },
    );
  });

  group('SessionRouteMutationCoordinator', () {
    test(
      'atomically rewrites every non-terminal item and increments route revision once',
      () {
        seedSession('route-owner');
        workItems.enqueueWorkItem(
          workItemId: 'active',
          sessionId: 'route-owner',
          requestId: 'request-active',
          providerInstanceId: 'provider-a',
          modelId: 'model-a',
          state: SessionWorkState.running,
        );
        workItems.enqueueWorkItem(
          workItemId: 'queued',
          sessionId: 'route-owner',
          requestId: 'request-queued',
          providerInstanceId: 'provider-a',
          modelId: 'model-a',
        );
        workItems.enqueueWorkItem(
          workItemId: 'completed',
          sessionId: 'route-owner',
          providerInstanceId: 'provider-a',
          modelId: 'model-a',
          state: SessionWorkState.completed,
        );

        final result = routeMutations.mutate(
          sessionId: 'route-owner',
          providerInstanceId: 'provider-b',
          model: 'model-exact',
          source: SessionRouteSource.autoFailover,
          reason: 'rate_limit',
          requestId: 'request-active',
        );

        expect(result.changed, isTrue);
        expect(result.routeRevision, 2);
        expect(result.previousProviderInstanceId, 'provider-a');
        expect(result.model, 'model-exact');
        expect(result.eventId, startsWith('evt_'));
        expect(
          workItems.findWorkItem('active')?.providerInstanceId,
          'provider-b',
        );
        expect(workItems.findWorkItem('active')?.modelId, 'model-exact');
        expect(
          workItems.findWorkItem('queued')?.providerInstanceId,
          'provider-b',
        );
        expect(workItems.findWorkItem('queued')?.modelId, 'model-exact');
        expect(
          workItems.findWorkItem('completed')?.providerInstanceId,
          'provider-a',
        );
        final transition = transitions.findByRevision('route-owner', 2);
        expect(transition?.eventId, result.eventId);
        expect(transition?.model, 'model-exact');
      },
    );

    test('snapshots display names across provider rename and deletion', () {
      final createdAt = DateTime.utc(2026, 7, 15);
      final previous = ProviderInstance(
        id: 'provider-a',
        templateId: 'openai',
        displayName: 'Provider Alpha',
        protocol: ProviderProtocol.openaiCompatible,
        authMethod: ProviderAuthMethod.apiKey,
        createdAt: createdAt,
        updatedAt: createdAt,
      );
      final next = ProviderInstance(
        id: 'provider-b',
        templateId: 'openai',
        displayName: 'Provider Beta',
        protocol: ProviderProtocol.openaiCompatible,
        authMethod: ProviderAuthMethod.apiKey,
        createdAt: createdAt,
        updatedAt: createdAt,
      );
      providerInstances.createInstance(previous);
      providerInstances.createInstance(next);
      seedSession('route-display-names');

      final result = routeMutations.mutate(
        sessionId: 'route-display-names',
        providerInstanceId: next.id,
        model: 'model-exact',
        source: SessionRouteSource.autoFailover,
        reason: 'rate_limit',
        requestId: 'request-display-names',
      );

      providerInstances.update(
        previous.copyWith(
          displayName: 'Provider Alpha Renamed',
          updatedAt: createdAt.add(const Duration(minutes: 1)),
        ),
      );
      providerInstances.delete(next.id);

      final transition = transitions.findByRevision('route-display-names', 2);
      expect(result.previousProviderDisplayName, 'Provider Alpha');
      expect(result.providerDisplayName, 'Provider Beta');
      expect(transition?.previousProviderDisplayName, 'Provider Alpha');
      expect(transition?.providerDisplayName, 'Provider Beta');
      expect(
        transition?.toPayload(),
        containsPair('provider_display_name', 'Provider Beta'),
      );
    });

    test(
      'same provider/model is idempotent and does not publish or revise',
      () {
        seedSession('route-idempotent');
        final emitted = <SessionRouteMutationResult>[];
        final subscription = routeMutations.changes.listen(emitted.add);
        addTearDown(subscription.cancel);

        final unchanged = routeMutations.mutate(
          sessionId: 'route-idempotent',
          providerInstanceId: 'provider-a',
          model: 'model-a',
          source: SessionRouteSource.recovery,
          requestId: 'duplicate-request',
          publish: true,
        );

        expect(unchanged.changed, isFalse);
        expect(unchanged.routeRevision, 1);
        expect(unchanged.eventId, isNull);
        expect(emitted, isEmpty);
        expect(transitions.findForSession('route-idempotent'), isEmpty);
      },
    );

    test('auto failover claims exact waiting owner and route atomically', () {
      seedSession('route-claim');
      executionState.enqueueWorkItem(
        workItemId: 'work-claim',
        sessionId: 'route-claim',
        requestId: 'request-claim',
        providerInstanceId: 'provider-a',
        modelId: 'model-a',
        state: SessionWorkState.running,
      );
      expect(
        executionState.bindRunOwnership(
          sessionId: 'route-claim',
          workItemId: 'work-claim',
          runId: 'run-claim',
          generation: 7,
        ),
        isTrue,
      );
      executionState.transitionWorkItem(
        workItemId: 'work-claim',
        fromState: SessionWorkState.running,
        toState: SessionWorkState.waiting,
      );
      RuntimeNoticeRepository(state.db).upsertNotice(
        sessionId: 'route-claim',
        requestId: 'request-claim',
        runId: 'run-claim',
        status: 'waiting',
        reason: 'rateLimit',
        title: 'Waiting',
        message: 'Waiting',
      );
      final executionChanges = <SessionExecutionSnapshot>[];
      final executionSubscription = executionState.changes.listen(
        executionChanges.add,
      );
      addTearDown(executionSubscription.cancel);

      final claimed = routeMutations.claimAutoFailover(
        sessionId: 'route-claim',
        workItemId: 'work-claim',
        runId: 'run-claim',
        generation: 7,
        expectedProviderInstanceId: 'provider-a',
        providerInstanceId: 'provider-b',
        model: 'model-a',
        reason: 'rate_limit',
        requestId: 'request-claim',
      );

      expect(claimed, isNotNull);
      expect(
        workItems.findWorkItem('work-claim')?.state,
        SessionWorkState.resuming,
      );
      expect(
        workItems.findWorkItem('work-claim')?.providerInstanceId,
        'provider-b',
      );
      expect(
        snapshots.getSnapshot('route-claim').state,
        SessionExecutionState.resuming,
      );
      expect(executionChanges, hasLength(1));
      expect(executionChanges.single.state, SessionExecutionState.resuming);
      expect(transitions.findForSession('route-claim'), hasLength(1));

      final stale = routeMutations.claimAutoFailover(
        sessionId: 'route-claim',
        workItemId: 'work-claim',
        runId: 'stale-run',
        generation: 7,
        expectedProviderInstanceId: 'provider-b',
        providerInstanceId: 'provider-c',
        model: 'model-a',
        reason: 'rate_limit',
        requestId: 'request-claim',
      );
      expect(stale, isNull);
      expect(
        workItems.findWorkItem('work-claim')?.providerInstanceId,
        'provider-b',
      );
    });

    test('a transition insert failure rolls back session and work routes', () {
      seedSession('route-rollback');
      workItems.enqueueWorkItem(
        workItemId: 'queued-rollback',
        sessionId: 'route-rollback',
        providerInstanceId: 'provider-a',
        modelId: 'model-a',
      );
      state.db.execute('''
        CREATE TRIGGER reject_route_transition
        BEFORE INSERT ON session_route_transitions
        BEGIN
          SELECT RAISE(ABORT, 'reject route transition');
        END;
      ''');

      expect(
        () => routeMutations.mutate(
          sessionId: 'route-rollback',
          providerInstanceId: 'provider-b',
          model: 'model-b',
          source: SessionRouteSource.autoFailover,
        ),
        throwsA(anything),
      );

      final sessionRow = state.db.select(
        'SELECT provider_id, model, route_revision FROM sessions WHERE session_id = ?',
        ['route-rollback'],
      ).first;
      expect(sessionRow['provider_id'], 'provider-a');
      expect(sessionRow['model'], 'model-a');
      expect(sessionRow['route_revision'], 1);
      expect(
        workItems.findWorkItem('queued-rollback')?.providerInstanceId,
        'provider-a',
      );
      expect(workItems.findWorkItem('queued-rollback')?.modelId, 'model-a');
    });
  });

  test(
    'legacy session migration backfills route revision without rerouting',
    () {
      final legacyDb = sqlite3.openInMemory();
      legacyDb.execute('''
      CREATE TABLE sessions (
        session_id TEXT PRIMARY KEY,
        model TEXT NOT NULL,
        provider_id TEXT,
        thinking_mode TEXT,
        title TEXT,
        workspace_id TEXT,
        metadata TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        last_user_message_at TEXT
      )
    ''');
      legacyDb.execute('''
      INSERT INTO sessions (
        session_id, model, provider_id, created_at, updated_at,
        last_user_message_at
      ) VALUES (
        'legacy-route', 'exact-model', 'provider-original',
        '2026-07-14T10:00:00Z', '2026-07-14T11:00:00Z',
        '2026-07-14T10:30:00Z'
      )
    ''');

      final migrated = AgentStateDatabase.fromConnection(legacyDb);
      final row = legacyDb.select(
        'SELECT provider_id, model, route_revision, route_updated_at '
        'FROM sessions WHERE session_id = ?',
        ['legacy-route'],
      ).single;

      expect(row['provider_id'], 'provider-original');
      expect(row['model'], 'exact-model');
      expect(row['route_revision'], 1);
      expect(row['route_updated_at'], '2026-07-14T11:00:00Z');
      final restored = SessionDB.fromState(migrated).getSession('legacy-route');
      expect(restored?.routeRevision, 1);
      expect(restored?.routeUpdatedAt, DateTime.parse('2026-07-14T11:00:00Z'));
      expect(
        legacyDb.select('SELECT * FROM session_route_transitions'),
        isEmpty,
        reason: 'migration must not synthesize a route switch',
      );
      final transitionColumns = legacyDb
          .select('PRAGMA table_info(session_route_transitions)')
          .map((row) => row['name'])
          .toSet();
      expect(transitionColumns, contains('previous_provider_display_name'));
      expect(transitionColumns, contains('provider_display_name'));

      migrated.dispose();
      legacyDb.dispose();
    },
  );
}
