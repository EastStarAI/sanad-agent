import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:sanad_agent/evolution/db/agent_maintenance_state_repository.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/agent_state_maintenance_service.dart';
import 'package:sanad_agent/evolution/db/persisted_runtime_state_repository.dart';
import 'package:sanad_agent/evolution/db/runtime/session_work_item_repository.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.utc(2026, 8, 30, 12);

  group('AgentMaintenanceStateRepository.parseSuccessTimestamp', () {
    test('missing value is due immediately', () {
      final stamp = AgentMaintenanceStateRepository.parseSuccessTimestamp(
        null,
        now,
      );
      expect(stamp.status, MaintenanceTimestampStatus.missing);
      expect(stamp.value, isNull);
      expect(stamp.isDueImmediately, isTrue);
      expect(stamp.isDue(now, const Duration(hours: 24)), isTrue);
    });

    test('empty or unparseable value is malformed and due', () {
      for (final raw in ['', '   ', 'not-a-date', 'yesterday']) {
        final stamp = AgentMaintenanceStateRepository.parseSuccessTimestamp(
          raw,
          now,
        );
        expect(
          stamp.status,
          MaintenanceTimestampStatus.malformed,
          reason: 'raw=$raw',
        );
        expect(stamp.isDue(now, const Duration(hours: 24)), isTrue);
      }
    });

    test('future timestamp is due and cannot throttle maintenance', () {
      final stamp = AgentMaintenanceStateRepository.parseSuccessTimestamp(
        DateTime.utc(2026, 9, 1).toIso8601String(),
        now,
      );
      expect(stamp.status, MaintenanceTimestampStatus.future);
      expect(stamp.isDueImmediately, isTrue);
      expect(stamp.isDue(now, const Duration(days: 7)), isTrue);
    });

    test('valid past timestamp is due only after the interval elapses', () {
      final succeededAt = now.subtract(const Duration(hours: 23, minutes: 59));
      final stamp = AgentMaintenanceStateRepository.parseSuccessTimestamp(
        succeededAt.toIso8601String(),
        now,
      );
      expect(stamp.status, MaintenanceTimestampStatus.valid);
      expect(stamp.isDueImmediately, isFalse);
      expect(stamp.isDue(now, const Duration(hours: 24)), isFalse);
    });

    test('timestamp exactly one interval old is due', () {
      final succeededAt = now.subtract(const Duration(hours: 24));
      final stamp = AgentMaintenanceStateRepository.parseSuccessTimestamp(
        succeededAt.toIso8601String(),
        now,
      );
      expect(stamp.status, MaintenanceTimestampStatus.valid);
      expect(stamp.isDue(now, const Duration(hours: 24)), isTrue);
    });

    test('timestamp older than the interval is due', () {
      final succeededAt = now.subtract(const Duration(days: 8));
      final stamp = AgentMaintenanceStateRepository.parseSuccessTimestamp(
        succeededAt.toIso8601String(),
        now,
      );
      expect(stamp.isDue(now, const Duration(days: 7)), isTrue);
    });
  });

  group('AgentStateDatabase maintenance primitives', () {
    late AgentStateDatabase db;

    setUp(() => db = AgentStateDatabase.inMemory());
    tearDown(() => db.dispose());

    test('creates agent_maintenance_state idempotently', () {
      final tables = db.db.select(
        "SELECT name FROM sqlite_master WHERE type = 'table' "
        "AND name = 'agent_maintenance_state'",
      );
      expect(tables, isNotEmpty);
      AgentStateDatabase.fromConnection(db.db);
      expect(
        db.db.select(
          "SELECT name FROM sqlite_master WHERE type = 'table' "
          "AND name = 'agent_maintenance_state'",
        ),
        isNotEmpty,
      );
    });

    test('VACUUM guard rejects an open owner transaction', () {
      expect(
        () => db.transaction((_) => db.vacuum()),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('VACUUM'),
          ),
        ),
      );
      expect(db.hasOpenTransaction, isFalse);
      db.vacuum();
    });
  });

  group('SessionWorkItemRepository terminal prune', () {
    late AgentStateDatabase db;
    late SessionWorkItemRepository workItems;

    setUp(() {
      db = AgentStateDatabase.inMemory();
      workItems = SessionWorkItemRepository(db);
    });
    tearDown(() => db.dispose());

    test('deletes completed and cancelled rows older than cutoff', () {
      _seedSession(db, 's-old');
      _insertWorkItem(
        workItems,
        id: 'w-completed-old',
        sessionId: 's-old',
        requestId: 'req-completed-old',
        state: SessionWorkState.completed,
        updatedAt: now.subtract(const Duration(days: 15)),
      );
      _insertWorkItem(
        workItems,
        id: 'w-cancelled-old',
        sessionId: 's-old',
        requestId: 'req-cancelled-old',
        state: SessionWorkState.cancelled,
        updatedAt: now.subtract(const Duration(days: 14, seconds: 1)),
      );

      final deleted = workItems.deleteTerminalWorkItemsOlderThan(now);
      expect(deleted, 2);
      expect(workItems.findWorkItem('w-completed-old'), isNull);
      expect(workItems.findWorkItem('w-cancelled-old'), isNull);
    });

    test('keeps terminal rows newer than or exactly at cutoff', () {
      final cutoff = now.subtract(const Duration(days: 14));
      _seedSession(db, 's-keep');
      _insertWorkItem(
        workItems,
        id: 'w-at-cutoff',
        sessionId: 's-keep',
        requestId: 'req-at-cutoff',
        state: SessionWorkState.completed,
        updatedAt: cutoff,
      );
      _insertWorkItem(
        workItems,
        id: 'w-newer',
        sessionId: 's-keep',
        requestId: 'req-newer',
        state: SessionWorkState.cancelled,
        updatedAt: cutoff.add(const Duration(seconds: 1)),
      );

      expect(workItems.deleteTerminalWorkItemsOlderThan(cutoff), 0);
      expect(workItems.findWorkItem('w-at-cutoff'), isNotNull);
      expect(workItems.findWorkItem('w-newer'), isNotNull);
    });

    test('never deletes active work states regardless of age', () {
      const states = [
        SessionWorkState.queued,
        SessionWorkState.running,
        SessionWorkState.waiting,
        SessionWorkState.blocked,
        SessionWorkState.resuming,
      ];
      final ancient = now.subtract(const Duration(days: 400));
      for (final state in states) {
        final sessionId = 's-${state.name}';
        _seedSession(db, sessionId);
        _insertWorkItem(
          workItems,
          id: 'w-${state.name}',
          sessionId: sessionId,
          requestId: 'req-${state.name}',
          state: state,
          updatedAt: ancient,
        );
      }

      expect(workItems.deleteTerminalWorkItemsOlderThan(now), 0);
      for (final state in states) {
        expect(workItems.findWorkItem('w-${state.name}'), isNotNull);
      }
    });

    test('leaves sessions and messages untouched after prune', () {
      _seedSession(db, 's-msg');
      db.db.execute(
        "INSERT INTO messages (session_id, data) VALUES ('s-msg', ?)",
        ['{"role":"user","content":"keep me"}'],
      );
      _insertWorkItem(
        workItems,
        id: 'w-old',
        sessionId: 's-msg',
        requestId: 'req-old',
        state: SessionWorkState.completed,
        updatedAt: now.subtract(const Duration(days: 30)),
      );

      workItems.deleteTerminalWorkItemsOlderThan(now);
      expect(
        db.db.select('SELECT session_id FROM sessions WHERE session_id = ?', [
          's-msg',
        ]),
        isNotEmpty,
      );
      expect(
        db.db.select('SELECT data FROM messages WHERE session_id = ?', [
          's-msg',
        ]).first['data'],
        '{"role":"user","content":"keep me"}',
      );
    });

    test('cleans a legacy orphan after FK-off insert then re-enable', () {
      _seedSession(db, 's-live');
      _insertWorkItem(
        workItems,
        id: 'w-live',
        sessionId: 's-live',
        requestId: 'req-live',
        state: SessionWorkState.queued,
        updatedAt: now,
      );
      db.db.execute('PRAGMA foreign_keys = OFF');
      db.db.execute(
        '''
        INSERT INTO session_work_items (
          work_item_id, session_id, request_id, sequence,
          payload_json, attempt, state, continuation_metadata,
          created_at, updated_at
        ) VALUES (
          'w-orphan', 'missing-session', 'req-orphan', 0,
          '{}', 0, 'queued', '{}', ?, ?
        )
      ''',
        [now.toIso8601String(), now.toIso8601String()],
      );
      db.db.execute('PRAGMA foreign_keys = ON');

      expect(workItems.cleanupOrphanedWorkItems(), 1);
      expect(workItems.findWorkItem('w-orphan'), isNull);
      expect(workItems.findWorkItem('w-live'), isNotNull);
    });
  });

  group('AgentStateMaintenanceService policy', () {
    late AgentStateDatabase db;
    late SessionWorkItemRepository workItems;
    late AgentMaintenanceStateRepository stamps;
    late DateTime clock;

    setUp(() {
      db = AgentStateDatabase.inMemory();
      workItems = SessionWorkItemRepository(db);
      stamps = AgentMaintenanceStateRepository(db);
      clock = now;
    });
    tearDown(() => db.dispose());

    AgentStateMaintenanceService service({
      AgentStatePageStatistics Function()? stats,
      void Function()? vacuum,
      AgentMaintenanceStateRepository? maintenanceState,
      int vacuumMinReclaimableBytes = 64 * 1024 * 1024,
      double vacuumMinFreeRatio = 0.20,
    }) {
      return AgentStateMaintenanceService(
        db,
        workItems: workItems,
        maintenanceState: maintenanceState ?? stamps,
        clock: () => clock,
        vacuumMinReclaimableBytes: vacuumMinReclaimableBytes,
        vacuumMinFreeRatio: vacuumMinFreeRatio,
        readPageStatistics: stats,
        runVacuum: vacuum,
      );
    }

    test('first run prunes; a run inside 24 hours skips prune', () {
      _seedSession(db, 's-prune');
      _insertWorkItem(
        workItems,
        id: 'w-old',
        sessionId: 's-prune',
        requestId: 'req-old',
        state: SessionWorkState.completed,
        updatedAt: now.subtract(const Duration(days: 20)),
      );

      final first = service(
        stats: () => const AgentStatePageStatistics(
          pageSize: 4096,
          pageCount: 10,
          freelistCount: 0,
        ),
      ).run();
      expect(first.terminalPruneRan, isTrue);
      expect(first.terminalWorkItemsDeleted, 1);

      clock = now.add(const Duration(hours: 23, minutes: 59));
      _insertWorkItem(
        workItems,
        id: 'w-old-2',
        sessionId: 's-prune',
        requestId: 'req-old-2',
        state: SessionWorkState.completed,
        updatedAt: now.subtract(const Duration(days: 20)),
      );
      final second = service(
        stats: () => const AgentStatePageStatistics(
          pageSize: 4096,
          pageCount: 10,
          freelistCount: 0,
        ),
      ).run();
      expect(second.terminalPruneRan, isFalse);
      expect(second.terminalWorkItemsDeleted, 0);
      expect(workItems.findWorkItem('w-old-2'), isNotNull);
    });

    test('prune becomes due at exactly 24 hours', () {
      stamps.writeTerminalPruneSucceededAt(now);
      clock = now.add(const Duration(hours: 24));
      _seedSession(db, 's-due');
      _insertWorkItem(
        workItems,
        id: 'w-old',
        sessionId: 's-due',
        requestId: 'req-old',
        state: SessionWorkState.cancelled,
        updatedAt: now.subtract(const Duration(days: 20)),
      );

      final result = service(
        stats: () => const AgentStatePageStatistics(
          pageSize: 4096,
          pageCount: 10,
          freelistCount: 0,
        ),
      ).run();
      expect(result.terminalPruneRan, isTrue);
      expect(result.terminalWorkItemsDeleted, 1);
    });

    test(
      'successful prune with zero deletes still writes the success stamp',
      () {
        _seedSession(db, 's-empty');
        final result = service(
          stats: () => const AgentStatePageStatistics(
            pageSize: 4096,
            pageCount: 10,
            freelistCount: 0,
          ),
        ).run();
        expect(result.terminalPruneRan, isTrue);
        expect(result.terminalWorkItemsDeleted, 0);
        expect(
          stamps.readTerminalPruneSucceededAt(clock).status,
          MaintenanceTimestampStatus.valid,
        );
      },
    );

    test('malformed or future prune stamps do not block a run', () {
      _seedSession(db, 's-stamp');
      _insertWorkItem(
        workItems,
        id: 'w-old',
        sessionId: 's-stamp',
        requestId: 'req-old',
        state: SessionWorkState.completed,
        updatedAt: now.subtract(const Duration(days: 20)),
      );
      db.db.execute(
        'INSERT INTO agent_maintenance_state (key, value) VALUES (?, ?)',
        [
          AgentMaintenanceStateRepository.lastTerminalPruneSucceededAtKey,
          'not-a-date',
        ],
      );

      final malformed = service(
        stats: () => const AgentStatePageStatistics(
          pageSize: 4096,
          pageCount: 10,
          freelistCount: 0,
        ),
      ).run();
      expect(malformed.terminalPruneRan, isTrue);

      db.db.execute(
        'UPDATE agent_maintenance_state SET value = ? WHERE key = ?',
        [
          now.add(const Duration(days: 30)).toIso8601String(),
          AgentMaintenanceStateRepository.lastTerminalPruneSucceededAtKey,
        ],
      );
      _insertWorkItem(
        workItems,
        id: 'w-old-2',
        sessionId: 's-stamp',
        requestId: 'req-old-2',
        state: SessionWorkState.completed,
        updatedAt: now.subtract(const Duration(days: 20)),
      );
      final future = service(
        stats: () => const AgentStatePageStatistics(
          pageSize: 4096,
          pageCount: 10,
          freelistCount: 0,
        ),
      ).run();
      expect(future.terminalPruneRan, isTrue);
      expect(workItems.findWorkItem('w-old-2'), isNull);
    });

    test('failed prune rolls back deletes and the success stamp', () {
      _seedSession(db, 's-rollback');
      _insertWorkItem(
        workItems,
        id: 'w-old',
        sessionId: 's-rollback',
        requestId: 'req-old',
        state: SessionWorkState.completed,
        updatedAt: now.subtract(const Duration(days: 20)),
      );

      final result = service(
        maintenanceState: _FailingStampRepository(db),
        stats: () => const AgentStatePageStatistics(
          pageSize: 4096,
          pageCount: 10,
          freelistCount: 1,
        ),
      ).run();

      expect(result.failed, isTrue);
      expect(result.terminalPruneRan, isFalse);
      expect(result.vacuumDecision, AgentStateVacuumDecision.failed);
      expect(workItems.findWorkItem('w-old'), isNotNull);
      expect(
        db.db.select(
          'SELECT value FROM agent_maintenance_state WHERE key = ?',
          [AgentMaintenanceStateRepository.lastTerminalPruneSucceededAtKey],
        ),
        isEmpty,
      );
    });

    test(
      'vacuum stays skipped below 64MiB or below 20% even if the other holds',
      () {
        stamps.writeVacuumSucceededAt(now.subtract(const Duration(days: 8)));

        final belowBytes = service(
          stats: () => const AgentStatePageStatistics(
            pageSize: 4096,
            pageCount: 100,
            freelistCount: 30,
          ),
        ).run();
        expect(
          belowBytes.vacuumDecision,
          AgentStateVacuumDecision.belowThreshold,
        );
        expect(
          belowBytes.reclaimableBytesBeforeVacuum <
              AgentStateMaintenanceService.vacuumMinReclaimableBytes,
          isTrue,
        );
        expect(
          belowBytes.reclaimableBytesBeforeVacuum / (4096 * 100) >= 0.20,
          isTrue,
        );

        var vacuumed = false;
        final belowRatio = service(
          stats: () => const AgentStatePageStatistics(
            pageSize: 64 * 1024 * 1024,
            pageCount: 10,
            freelistCount: 1,
          ),
          vacuum: () => vacuumed = true,
        ).run();
        expect(
          belowRatio.vacuumDecision,
          AgentStateVacuumDecision.belowThreshold,
        );
        expect(
          belowRatio.reclaimableBytesBeforeVacuum >=
              AgentStateMaintenanceService.vacuumMinReclaimableBytes,
          isTrue,
        );
        expect(
          belowRatio.reclaimableBytesBeforeVacuum / (64 * 1024 * 1024 * 10) <
              0.20,
          isTrue,
        );
        expect(vacuumed, isFalse);
      },
    );

    test('vacuum executes at exact 64MiB and 20% after 7 days', () {
      stamps.writeVacuumSucceededAt(now.subtract(const Duration(days: 7)));
      var vacuumed = false;
      // 16384 * 4096 = 64MiB; 16384 / 81920 = 0.20
      final result = service(
        stats: () => const AgentStatePageStatistics(
          pageSize: 4096,
          pageCount: 81920,
          freelistCount: 16384,
        ),
        vacuum: () => vacuumed = true,
      ).run();
      expect(result.vacuumDecision, AgentStateVacuumDecision.executed);
      expect(vacuumed, isTrue);
      expect(
        result.reclaimableBytesBeforeVacuum,
        AgentStateMaintenanceService.vacuumMinReclaimableBytes,
      );
      expect(
        stamps.readVacuumSucceededAt(clock).status,
        MaintenanceTimestampStatus.valid,
      );
    });

    test('vacuum is throttled when last success is younger than 7 days', () {
      stamps.writeVacuumSucceededAt(
        now.subtract(const Duration(days: 6, hours: 23)),
      );
      var vacuumed = false;
      final result = service(
        stats: () => const AgentStatePageStatistics(
          pageSize: 4096,
          pageCount: 81920,
          freelistCount: 16384,
        ),
        vacuum: () => vacuumed = true,
      ).run();
      expect(result.vacuumDecision, AgentStateVacuumDecision.throttled);
      expect(vacuumed, isFalse);
      expect(
        stamps.readVacuumSucceededAt(clock).value,
        now.subtract(const Duration(days: 6, hours: 23)).toUtc(),
      );
    });

    test('successful VACUUM writes its stamp; failure does not', () {
      var vacuumed = false;
      service(
        stats: () => const AgentStatePageStatistics(
          pageSize: 4096,
          pageCount: 81920,
          freelistCount: 16384,
        ),
        vacuum: () => vacuumed = true,
      ).run();
      expect(vacuumed, isTrue);
      expect(
        stamps.readVacuumSucceededAt(clock).status,
        MaintenanceTimestampStatus.valid,
      );

      clock = now.add(const Duration(days: 8));
      final failed = service(
        stats: () => const AgentStatePageStatistics(
          pageSize: 4096,
          pageCount: 81920,
          freelistCount: 16384,
        ),
        vacuum: () => throw StateError('vacuum failed'),
      ).run();
      expect(failed.vacuumDecision, AgentStateVacuumDecision.failed);
      expect(failed.failed, isTrue);
      final stamp = stamps.readVacuumSucceededAt(clock);
      expect(stamp.status, MaintenanceTimestampStatus.valid);
      expect(stamp.value, now.toUtc());
    });

    test('provider_model_cache is unchanged after maintenance', () {
      _seedSession(db, 's-cache');
      _insertWorkItem(
        workItems,
        id: 'w-old',
        sessionId: 's-cache',
        requestId: 'req-old',
        state: SessionWorkState.completed,
        updatedAt: now.subtract(const Duration(days: 20)),
      );
      db.db.execute(
        '''
        INSERT INTO provider_instances (
          id, template_id, display_name, display_name_lower, protocol,
          auth_method, status, is_default, config_revision,
          credential_revision, created_at, updated_at
        ) VALUES (
          'inst-1', 'openai', 'Test', 'test', 'openai_compatible',
          'api_key', 'ready', 1, 1, 1, ?, ?
        )
      ''',
        [now.toIso8601String(), now.toIso8601String()],
      );
      db.db.execute('''
        INSERT INTO provider_model_cache (
          instance_id, cache_key, models_json, fetched_at, source,
          config_revision, credential_revision
        ) VALUES (
          'inst-1', 'default', '["kept"]', '2020-01-01T00:00:00.000Z',
          'live', 1, 1
        )
      ''');

      service(
        stats: () => const AgentStatePageStatistics(
          pageSize: 4096,
          pageCount: 10,
          freelistCount: 0,
        ),
      ).run();

      final cache = db.db.select('SELECT * FROM provider_model_cache');
      expect(cache, hasLength(1));
      expect(cache.first['models_json'], '["kept"]');
      expect(cache.first['fetched_at'], '2020-01-01T00:00:00.000Z');
    });
  });

  test(
    'startup wrapper continues restore and start when the service throws',
    () {
      final db = AgentStateDatabase.inMemory();
      addTearDown(db.dispose);
      final logs = <String>[];
      Logger.root.level = Level.WARNING;
      final sub = Logger.root.onRecord.listen((record) {
        logs.add(record.message);
      });
      addTearDown(sub.cancel);

      final steps = <String>[];
      expect(() {
        runAgentStateMaintenanceSafely(
          _ThrowingMaintenanceService(db),
          logger: Logger('DaemonStartup'),
        );
        steps.add('restore');
        steps.add('start');
      }, returnsNormally);
      expect(logs, contains(contains('Agent state maintenance failed')));
      expect(steps, ['restore', 'start']);
    },
  );

  test(
    'daemon calls maintenance once before restore and platform start',
    () async {
      final configUri = await Isolate.resolvePackageUri(
        Uri.parse('package:sanad_agent/core/config.dart'),
      );
      final packageRoot = File.fromUri(configUri!).parent.parent.parent;
      final daemon = File(
        p.join(packageRoot.path, 'bin/daemon.dart'),
      ).readAsStringSync();
      final restorer = File(
        p.join(
          packageRoot.path,
          'lib/interfaces/runtime/session_recovery_restorer.dart',
        ),
      ).readAsStringSync();

      expect('_runAgentStateMaintenanceSafely()'.allMatches(daemon).length, 2);
      expect(
        daemon.indexOf('_runAgentStateMaintenanceSafely()'),
        lessThan(daemon.indexOf('gatewayManager.attachOrchestrator()')),
      );
      expect(
        daemon.indexOf('_runAgentStateMaintenanceSafely()'),
        lessThan(daemon.indexOf('_restoreDurableStateSafely')),
      );
      expect(
        daemon.indexOf('_runAgentStateMaintenanceSafely()'),
        lessThan(daemon.indexOf('gatewayManager.start()')),
      );
      expect(restorer.contains('cleanupOrphanedWorkItems'), isFalse);
    },
  );

  group('on-disk vacuum reclaim', () {
    late Directory temp;
    late AgentStateDatabase db;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('sanad-state-maint-');
      db = AgentStateDatabase.atPath(temp.path);
    });

    tearDown(() {
      db.dispose();
      if (temp.existsSync()) {
        temp.deleteSync(recursive: true);
      }
    });

    test('prune raises freelist and qualified vacuum shrinks page_count', () {
      final workItems = SessionWorkItemRepository(db);
      _seedSession(db, 's-disk');
      final old = DateTime.utc(2026, 1, 1);
      final payload = 'x' * 8192;
      for (var i = 0; i < 40; i++) {
        _insertWorkItem(
          workItems,
          id: 'w-$i',
          sessionId: 's-disk',
          requestId: 'req-$i',
          sequence: i,
          state: SessionWorkState.completed,
          updatedAt: old,
          payload: {'blob': payload},
        );
      }

      final before = db.pageStatistics();
      final deleted = workItems.deleteTerminalWorkItemsOlderThan(
        DateTime.utc(2026, 8, 1),
      );
      expect(deleted, 40);
      final afterDelete = db.pageStatistics();
      expect(afterDelete.freelistCount, greaterThan(before.freelistCount));

      AgentStateMaintenanceService(
        db,
        workItems: workItems,
        clock: () => DateTime.utc(2026, 8, 30),
        vacuumMinReclaimableBytes: 1,
        vacuumMinFreeRatio: 0.01,
      ).run();

      final afterVacuum = db.pageStatistics();
      expect(afterVacuum.pageCount, lessThan(afterDelete.pageCount));
    });
  });

  test('daemon-backed startup prunes terminal work before restore', () async {
    final configUri = await Isolate.resolvePackageUri(
      Uri.parse('package:sanad_agent/core/config.dart'),
    );
    final packageRoot = File.fromUri(configUri!).parent.parent.parent;
    final home = Directory.systemTemp.createTempSync('sanad-maint-home-');
    final stateHome = Directory.systemTemp.createTempSync('sanad-maint-state-');
    addTearDown(() {
      if (home.existsSync()) home.deleteSync(recursive: true);
      if (stateHome.existsSync()) stateHome.deleteSync(recursive: true);
    });

    final seed = AgentStateDatabase.atPath(stateHome.path);
    final workItems = SessionWorkItemRepository(seed);
    _seedSession(seed, 's-boot');
    _insertWorkItem(
      workItems,
      id: 'w-old-terminal',
      sessionId: 's-boot',
      requestId: 'req-old',
      state: SessionWorkState.completed,
      updatedAt: DateTime.utc(2026, 1, 1),
      payload: {'message': 'drop'},
    );
    _insertWorkItem(
      workItems,
      id: 'w-active',
      sessionId: 's-boot',
      requestId: 'req-active',
      state: SessionWorkState.queued,
      updatedAt: DateTime.utc(2026, 1, 1),
      payload: {'message': 'keep'},
    );
    seed.dispose();

    final process = await Process.start(
      Platform.resolvedExecutable,
      ['bin/daemon.dart'],
      workingDirectory: packageRoot.path,
      environment: {
        ...Platform.environment,
        'SANAD_HOME': home.path,
        'SANAD_STATE_HOME': stateHome.path,
        'SANAD_E2E_TEST_MODE': 'true',
        'ENABLE_GATEWAY': 'false',
        'ENABLE_LOCAL_GATEWAY': 'false',
        'LOG_LEVEL': 'INFO',
      },
    );
    var exited = false;
    unawaited(process.exitCode.then((_) => exited = true));
    final output = StringBuffer();
    process.stdout
        .transform(utf8.decoder)
        .listen((chunk) => output.write(chunk));
    process.stderr
        .transform(utf8.decoder)
        .listen((chunk) => output.write(chunk));

    try {
      final deadline = DateTime.now().add(const Duration(seconds: 45));
      var ready = false;
      while (DateTime.now().isBefore(deadline)) {
        final text = output.toString();
        if (text.contains('Daemon is running') ||
            text.contains('Durable state restored')) {
          ready = true;
          break;
        }
        if (exited) {
          fail('daemon exited early:\n$text');
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      expect(ready, isTrue, reason: output.toString());

      final verify = AgentStateDatabase.atPath(stateHome.path);
      addTearDown(verify.dispose);
      final repo = SessionWorkItemRepository(verify);
      expect(repo.findWorkItem('w-old-terminal'), isNull);
      expect(repo.findWorkItem('w-active'), isNotNull);
    } finally {
      process.kill();
      await process.exitCode.timeout(const Duration(seconds: 10));
    }
  }, timeout: const Timeout(Duration(seconds: 60)));
}

void _seedSession(AgentStateDatabase db, String sessionId) {
  db.db.execute(
    'INSERT INTO sessions (session_id, model, created_at, updated_at) '
    'VALUES (?, ?, ?, ?)',
    [
      sessionId,
      'gpt-4o',
      DateTime.utc(2026, 7, 1).toIso8601String(),
      DateTime.utc(2026, 7, 1).toIso8601String(),
    ],
  );
}

void _insertWorkItem(
  SessionWorkItemRepository workItems, {
  required String id,
  required String sessionId,
  required String requestId,
  required SessionWorkState state,
  required DateTime updatedAt,
  int sequence = 0,
  Map<String, dynamic> payload = const {},
}) {
  workItems.insertWorkItem(
    SessionWorkItem(
      workItemId: id,
      sessionId: sessionId,
      requestId: requestId,
      sequence: sequence,
      payload: payload,
      attempt: 0,
      state: state,
      createdAt: updatedAt,
      updatedAt: updatedAt,
    ),
  );
}

class _FailingStampRepository extends AgentMaintenanceStateRepository {
  _FailingStampRepository(super.state);

  @override
  void writeTerminalPruneSucceededAt(
    DateTime succeededAt, {
    AgentStateTransaction? transaction,
  }) {
    throw StateError('forced stamp failure');
  }
}

class _ThrowingMaintenanceService extends AgentStateMaintenanceService {
  _ThrowingMaintenanceService(super.state);

  @override
  AgentStateMaintenanceResult run() {
    throw StateError('forced maintenance failure');
  }
}
