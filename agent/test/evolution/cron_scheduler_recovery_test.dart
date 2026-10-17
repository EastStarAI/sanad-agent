import 'dart:async';
import 'dart:io';
import 'package:get_it/get_it.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/evolution/cron_scheduler.dart';
import 'package:sanad_agent/evolution/scheduling/schedule_model.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/interfaces/models/gateway_event.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late SessionManager sessionManager;
  late CronScheduler scheduler;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('cron_recovery_test_');
    setSanadHomeOverride(tempDir.path);
    setSanadStateHomeOverride(tempDir.path);

    if (GetIt.I.isRegistered<SessionManager>()) {
      await GetIt.I.reset();
    }
    setupDI();

    sessionManager = SessionManager();
    scheduler = CronScheduler();
  });

  tearDown(() async {
    await scheduler.dispose();
    SessionManager.resetForTesting();
    setSanadHomeOverride(null);
    setSanadStateHomeOverride(null);
    try {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    } catch (_) {}
    await GetIt.I.reset();
  });

  group('CronScheduler Recovery and Missed-Occurrence Policy (Gate B1, B-D1..B-D4, B-D6)', () {
    test('due-inside-grace fires once on startup and advances with last_status=fired', () async {
      final now = DateTime.utc(2026, 10, 20, 10, 30);
      final dueInstant = DateTime.utc(2026, 10, 20, 10, 0); // 30 mins ago
      // Daily schedule at 10:00. Grace is 2 hours (half of 24h clamped to 2h).
      // 30 mins is within grace!

      sessionManager.db.saveScheduledTask(
        'task_daily_grace',
        'Daily Report',
        dueInstant,
        'session_alpha',
        kind: 'daily',
        atTime: '10:00',
        zone: 'Z',
        enabled: true,
      );

      final receivedEvents = <GatewayEvent>[];
      final completer = Completer<void>();
      final subscription = scheduler.eventStream.listen((event) {
        receivedEvents.add(event);
        completer.complete();
      });

      // Initialize scheduler simulating startup at `now`
      await scheduler.initialize(now: now);
      await completer.future.timeout(const Duration(seconds: 2));
      await subscription.cancel();

      // Exactly one fire
      expect(receivedEvents.length, 1);
      expect(receivedEvents.first.sessionId, 'session_alpha');
      expect(receivedEvents.first.message.content, 'Daily Report');

      // Row updated in DB: last_status = 'fired', next_run_at advanced to tomorrow 10:00
      final updatedRow = sessionManager.db.getScheduledTask('task_daily_grace');
      expect(updatedRow, isNotNull);
      expect(updatedRow!['last_status'], 'fired');
      expect(updatedRow['last_run_at'], now.toIso8601String());
      expect(
        updatedRow['next_run_at'],
        DateTime.utc(2026, 10, 21, 10, 0).toIso8601String(),
      );

      // Active in-memory timer scheduled for tomorrow 10:00
      final active = scheduler.activeTasks.where((t) => t.id == 'task_daily_grace');
      expect(active.length, 1);
      expect(active.first.time, DateTime.utc(2026, 10, 21, 10, 0));
    });

    test('due-beyond-grace fires zero times, advances, and records last_status=skipped_missed', () async {
      final now = DateTime.utc(2026, 10, 20, 15, 0);
      final dueInstant = DateTime.utc(2026, 10, 20, 10, 0); // 5 hours ago
      // Daily schedule at 10:00. Grace is 2 hours.
      // 5 hours > 2 hours -> beyond grace!

      sessionManager.db.saveScheduledTask(
        'task_daily_stale',
        'Daily Sync',
        dueInstant,
        'session_beta',
        kind: 'daily',
        atTime: '10:00',
        zone: 'Z',
        enabled: true,
      );

      final receivedEvents = <GatewayEvent>[];
      final subscription = scheduler.eventStream.listen(receivedEvents.add);

      // Initialize simulating startup at `now`
      await scheduler.initialize(now: now);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await subscription.cancel();

      // Fires ZERO times (no event emitted)
      expect(receivedEvents, isEmpty);

      // Row updated in DB: last_status = 'skipped_missed', advanced to tomorrow 10:00
      final updatedRow = sessionManager.db.getScheduledTask('task_daily_stale');
      expect(updatedRow, isNotNull);
      expect(updatedRow!['last_status'], 'skipped_missed');
      // S2: last_run_at is preserved without change (remains null)
      expect(updatedRow['last_run_at'], isNull);
      expect(
        updatedRow['next_run_at'],
        DateTime.utc(2026, 10, 21, 10, 0).toIso8601String(),
      );

      // Active in-memory timer scheduled for tomorrow 10:00
      final active = scheduler.activeTasks.where((t) => t.id == 'task_daily_stale');
      expect(active.length, 1);
      expect(active.first.time, DateTime.utc(2026, 10, 21, 10, 0));
    });

    test('interval schedule missed beyond grace window preserves last_run_at and cadence (S2)', () async {
      // Interval: 10 minutes. Grace is 5 minutes (half period).
      // Last ran at 10:00. Next was 10:10.
      // Restart happens at 10:59 (downtime of 59m).
      // Occurrences: 10:10, 10:20, 10:30, 10:40, 10:50.
      // Most recent missed is 10:50.
      // Missed by 9 minutes > 5 minutes grace -> beyond grace!
      final now = DateTime.utc(2026, 10, 20, 10, 59);
      final lastRun = DateTime.utc(2026, 10, 20, 10, 0);
      final initialNextRun = DateTime.utc(2026, 10, 20, 10, 10);

      sessionManager.db.saveScheduledTask(
        'task_intv_stale',
        'Interval Stale',
        initialNextRun,
        'session_stale',
        kind: 'interval',
        intervalMinutes: 10,
        zone: 'Z',
        lastRunAt: lastRun,
        enabled: true,
      );

      final receivedEvents = <GatewayEvent>[];
      final subscription = scheduler.eventStream.listen(receivedEvents.add);

      await scheduler.initialize(now: now);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await subscription.cancel();

      // Zero fires (skipped beyond grace)
      expect(receivedEvents, isEmpty);

      final row = sessionManager.db.getScheduledTask('task_intv_stale');
      expect(row, isNotNull);
      expect(row!['last_status'], 'skipped_missed');
      // S2: Stored last_run_at is preserved unchanged (10:00), not re-stamped to now
      expect(row['last_run_at'], lastRun.toIso8601String());
      // Cadence is preserved: next is 11:00 (on cadence from 10:00), NOT re-anchored on restart (10:59 + 10 = 11:09)
      expect(row['next_run_at'], DateTime.utc(2026, 10, 20, 11, 0).toIso8601String());

      final active = scheduler.activeTasks.where((t) => t.id == 'task_intv_stale');
      expect(active.length, 1);
      expect(active.first.time, DateTime.utc(2026, 10, 20, 11, 0));
    });

    test('schedule recovery provably terminates with at most one fire when last run is far in the past (S3)', () async {
      // Cadence: every 15 minutes.
      // Last run was 6 months ago (2026-04-20 10:00).
      // Startup at 2026-10-20 10:40 (40m past the hour; slots at :00, :15, :30, :45).
      // Most recent missed is 10:30.
      // Missed by 10 minutes > 7.5m grace -> skipped beyond grace!
      final now = DateTime.utc(2026, 10, 20, 10, 40);
      final farPastRun = DateTime.utc(2026, 4, 20, 10, 0);
      final initialNextRun = DateTime.utc(2026, 4, 20, 10, 15);

      sessionManager.db.saveScheduledTask(
        'task_far_past',
        'Far Past Interval',
        initialNextRun,
        'session_past',
        kind: 'interval',
        intervalMinutes: 15,
        zone: 'Z',
        lastRunAt: farPastRun,
        enabled: true,
      );

      final receivedEvents = <GatewayEvent>[];
      final subscription = scheduler.eventStream.listen(receivedEvents.add);

      // Must initialize and terminate immediately without looping millions of times
      final stopwatch = Stopwatch()..start();
      await scheduler.initialize(now: now);
      stopwatch.stop();

      await Future<void>.delayed(const Duration(milliseconds: 50));
      await subscription.cancel();

      // Took milliseconds, not seconds
      expect(stopwatch.elapsedMilliseconds, lessThan(1000));

      // At most one fire: exactly zero fires (missed > grace)
      expect(receivedEvents, isEmpty);

      final row = sessionManager.db.getScheduledTask('task_far_past');
      expect(row!['last_status'], 'skipped_missed');
      // Preserves original last_run_at from 6 months ago
      expect(row['last_run_at'], farPastRun.toIso8601String());
      // Advances to next future slot on cadence (10:45)
      expect(row['next_run_at'], DateTime.utc(2026, 10, 20, 10, 45).toIso8601String());
    });

    test('downtime spanning several occurrences produces one fire at most, never a burst', () async {
      // Interval: every 15 minutes. Grace = 7.5m (450s).
      // Last run was at 10:00. Next was 10:15.
      // Downtime was 2 hours. Startup at 12:03.
      // Occurrences: 10:15, 10:30, 10:45, 11:00, 11:15, 11:30, 11:45, 12:00.
      // Most recent missed occurrence was 12:00.
      // Missed by 3 minutes <= 7.5m grace -> inside grace!
      final now = DateTime.utc(2026, 10, 20, 12, 3);
      final lastRun = DateTime.utc(2026, 10, 20, 10, 0);
      final initialNextRun = DateTime.utc(2026, 10, 20, 10, 15);

      sessionManager.db.saveScheduledTask(
        'task_intv_multi',
        'Interval Ping',
        initialNextRun,
        'session_gamma',
        kind: 'interval',
        intervalMinutes: 15,
        zone: 'Z',
        lastRunAt: lastRun,
        enabled: true,
      );

      final receivedEvents = <GatewayEvent>[];
      final completer = Completer<void>();
      final subscription = scheduler.eventStream.listen((event) {
        receivedEvents.add(event);
        if (!completer.isCompleted) completer.complete();
      });

      await scheduler.initialize(now: now);
      await completer.future.timeout(const Duration(seconds: 2));
      // Settle briefly to prove NO burst of events follows
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await subscription.cancel();

      // Exactly ONE event emitted, never a burst of 8 events
      expect(receivedEvents.length, 1);

      // Advances to the next future occurrence on the cadence (12:15)
      final row = sessionManager.db.getScheduledTask('task_intv_multi');
      expect(row!['last_status'], 'fired');
      expect(row['next_run_at'], DateTime.utc(2026, 10, 20, 12, 15).toIso8601String());
    });

    test('interval cadence is unchanged across a simulated restart (no re-anchoring on restart instant)', () async {
      // Cadence: :00, :15, :30, :45.
      // Task last ran at 10:00. Next run is 10:15.
      // Restart happens at 10:07 (restart instant).
      // If it re-anchored on restart instant, next would become 10:07 + 15m = 10:22.
      // But B-D3 anchors on the cadence / stored last run -> remains 10:15!
      final restartTime = DateTime.utc(2026, 10, 20, 10, 7);
      final lastRun = DateTime.utc(2026, 10, 20, 10, 0);
      final nextRun = DateTime.utc(2026, 10, 20, 10, 15);

      sessionManager.db.saveScheduledTask(
        'task_intv_cadence',
        'Cadence Test',
        nextRun,
        'session_cadence',
        kind: 'interval',
        intervalMinutes: 15,
        zone: 'Z',
        lastRunAt: lastRun,
        enabled: true,
      );

      await scheduler.initialize(now: restartTime);

      final active = scheduler.activeTasks.firstWhere((t) => t.id == 'task_intv_cadence');
      expect(active.time, DateTime.utc(2026, 10, 20, 10, 15));

      final row = sessionManager.db.getScheduledTask('task_intv_cadence');
      expect(row!['next_run_at'], DateTime.utc(2026, 10, 20, 10, 15).toIso8601String());
    });

    test('durable-ordering proves no double fire when process stops between persisting and emitting', () async {
      // Simulate crash between persisting next instant and emitting run event (Decision B-D1)
      final t0 = DateTime.utc(2026, 10, 20, 10, 0);
      final t1 = DateTime.utc(2026, 10, 20, 10, 15);

      // Persist as if _executeTask already saved the nextRecord before crash
      sessionManager.db.saveScheduledTask(
        'task_crash_recovery',
        'Crash Test',
        t1,
        'session_crash',
        kind: 'interval',
        intervalMinutes: 15,
        zone: 'Z',
        lastRunAt: t0,
        lastStatus: 'fired',
        enabled: true,
      );

      // Now process restarts at 10:02 (after crash)
      final restartTime = DateTime.utc(2026, 10, 20, 10, 2);
      final events = <GatewayEvent>[];
      final subscription = scheduler.eventStream.listen(events.add);

      await scheduler.initialize(now: restartTime);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await subscription.cancel();

      // Zero fires: the slot t0 does NOT fire again because t1 is in the future
      expect(events, isEmpty);

      // Timer armed for t1
      final active = scheduler.activeTasks.firstWhere((t) => t.id == 'task_crash_recovery');
      expect(active.time, t1);
    });

    test('preserves one-shot behavior unchanged (B-D4)', () async {
      final now = DateTime.utc(2026, 10, 20, 10, 4);

      // 1. One-shot within 5-min grace (scheduled at 10:01, now is 10:04 -> 3 mins ago)
      sessionManager.db.saveScheduledTask(
        'once_within_grace',
        'Once Grace',
        DateTime.utc(2026, 10, 20, 10, 1),
        'session_once',
        kind: 'once',
        zone: 'local',
        enabled: true,
      );

      // 2. One-shot beyond 5-min grace (scheduled at 09:50 -> 14 mins ago)
      sessionManager.db.saveScheduledTask(
        'once_beyond_grace',
        'Once Stale',
        DateTime.utc(2026, 10, 20, 9, 50),
        'session_once',
        kind: 'once',
        zone: 'local',
        enabled: true,
      );

      final receivedEvents = <GatewayEvent>[];
      final completer = Completer<void>();
      final subscription = scheduler.eventStream.listen((e) {
        receivedEvents.add(e);
        completer.complete();
      });

      await scheduler.initialize(now: now);
      await completer.future.timeout(const Duration(seconds: 2));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await subscription.cancel();

      // Only the within-grace task fired
      expect(receivedEvents.length, 1);
      expect(receivedEvents.first.message.content, 'Once Grace');

      // Both one-shot tasks were deleted from DB
      expect(sessionManager.db.getScheduledTask('once_within_grace'), isNull);
      expect(sessionManager.db.getScheduledTask('once_beyond_grace'), isNull);
    });
  });

  group('CronScheduler Mutation Liveness (Gate B2, Decision B-D5)', () {
    test('cancel removes in-memory timer and row; no event emitted', () async {
      final record = scheduler.createSchedule(
        task: 'Cancel Target',
        sessionId: 'session_cancel',
        definition: ScheduleDefinition(
          kind: ScheduleKind.interval,
          intervalMinutes: 10,
          zone: 'local',
        ),
      );

      expect(scheduler.activeTasks.any((t) => t.id == record.id), isTrue);
      expect(sessionManager.db.getScheduledTask(record.id), isNotNull);

      final events = <GatewayEvent>[];
      final subscription = scheduler.eventStream.listen(events.add);

      // Cancel schedule
      final cancelled = scheduler.cancelSchedule(
        record.id,
        callerSessionId: 'session_cancel',
      );
      expect(cancelled.id, record.id);

      // Row removed from DB
      expect(sessionManager.db.getScheduledTask(record.id), isNull);

      // Timer removed from in-memory active tasks
      expect(scheduler.activeTasks.any((t) => t.id == record.id), isFalse);

      await Future<void>.delayed(const Duration(milliseconds: 50));
      await subscription.cancel();
      expect(events, isEmpty);
    });

    test('update replaces the timer with the recomputed instant (no orphan timer)', () async {
      final record = scheduler.createSchedule(
        task: 'Initial Task',
        sessionId: 'session_update',
        definition: ScheduleDefinition(
          kind: ScheduleKind.interval,
          intervalMinutes: 10,
          zone: 'local',
        ),
      );

      final initialMeta = scheduler.activeTasks.firstWhere((t) => t.id == record.id);
      expect(initialMeta.time, record.nextRunAt);

      // Update interval to 45 minutes
      final updated = scheduler.updateSchedule(
        id: record.id,
        callerSessionId: 'session_update',
        definition: ScheduleDefinition(
          kind: ScheduleKind.interval,
          intervalMinutes: 45,
          zone: 'local',
        ),
      );

      // Active tasks contains exactly one timer for this id, matching updated nextRunAt
      final matches = scheduler.activeTasks.where((t) => t.id == record.id).toList();
      expect(matches.length, 1);
      expect(matches.first.time, updated.nextRunAt);
      expect(matches.first.time.isAfter(record.nextRunAt), isTrue);
    });

    test('disposal cancels every active timer', () async {
      scheduler.createSchedule(
        id: 'task_disp_1',
        task: 'Task 1',
        sessionId: 'session_disp',
        definition: ScheduleDefinition(kind: ScheduleKind.interval, intervalMinutes: 10, zone: 'local'),
      );
      scheduler.createSchedule(
        id: 'task_disp_2',
        task: 'Task 2',
        sessionId: 'session_disp',
        definition: ScheduleDefinition(kind: ScheduleKind.daily, atTime: '12:00', zone: 'local'),
      );

      expect(scheduler.activeTasks.length, 2);

      await scheduler.dispose();

      expect(scheduler.activeTasks, isEmpty);
    });
  });
}
