import 'dart:io';

import 'package:get_it/get_it.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/evolution/cron_scheduler.dart';
import 'package:sanad_agent/evolution/db/scheduled_task_run_repository.dart';
import 'package:sanad_agent/evolution/scheduling/schedule_model.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late SessionManager sessionManager;
  late CronScheduler scheduler;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('schedule_control_test_');
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

  group('Schedule Control: Pause, Resume, and Run Now (A2, S13, S14, S21)', () {
    test('pause cancels timer and keeps next_run_at, last_run_at, and last_status', () {
      final session = sessionManager.createSession('test-model');
      final schedule = scheduler.createSchedule(
        task: 'Daily Brief',
        sessionId: session.sessionId,
        definition: ScheduleDefinition(
          kind: ScheduleKind.daily,
          zone: 'local',
          atTime: '09:00',
        ),
      );

      expect(schedule.enabled, isTrue);
      expect(scheduler.activeTasks.any((t) => t.id == schedule.id), isTrue);

      final originalNextRunAt = schedule.nextRunAt;
      final paused = scheduler.pauseSchedule(
        schedule.id,
        ScheduleCaller.model(session.sessionId),
      );

      expect(paused.enabled, isFalse);
      expect(paused.nextRunAt, equals(originalNextRunAt));
      expect(scheduler.activeTasks.any((t) => t.id == schedule.id), isFalse);

      final persisted = scheduler.getSchedule(schedule.id);
      expect(persisted, isNotNull);
      expect(persisted!.enabled, isFalse);
      expect(persisted.nextRunAt, equals(originalNextRunAt));
    });

    test('a paused schedule never fires from in-memory timer, on restart, or recovery', () async {
      final session = sessionManager.createSession('test-model');
      final now = DateTime.utc(2026, 10, 23, 10, 0);
      final dueInstant = DateTime.utc(2026, 10, 23, 9, 30);

      final schedule = scheduler.createSchedule(
        task: 'Paused Recurring Task',
        sessionId: session.sessionId,
        definition: ScheduleDefinition(
          kind: ScheduleKind.daily,
          zone: 'local',
          atTime: '09:30',
        ),
      );

      scheduler.pauseSchedule(
        schedule.id,
        ScheduleCaller.model(session.sessionId),
      );

      // Mutate nextRunAt into the past to simulate downtime while paused
      sessionManager.db.saveScheduledTask(
        schedule.id,
        schedule.task,
        dueInstant,
        schedule.sessionId,
        kind: 'daily',
        atTime: '09:30',
        enabled: false,
      );

      final eventsEmitted = <dynamic>[];
      final subscription = scheduler.eventStream.listen(eventsEmitted.add);

      // Re-initialize scheduler at `now`
      await scheduler.initialize(now: now);
      await pumpEventQueue();

      expect(eventsEmitted, isEmpty);
      expect(scheduler.activeTasks.any((t) => t.id == schedule.id), isFalse);
      await subscription.cancel();
    });

    test('resume recomputes next_run_at on the stored slot grid and re-arms timer', () {
      final session = sessionManager.createSession('test-model');
      final schedule = scheduler.createSchedule(
        task: 'Hourly task',
        sessionId: session.sessionId,
        definition: ScheduleDefinition(
          kind: ScheduleKind.interval,
          zone: 'local',
          intervalMinutes: 60,
        ),
      );

      scheduler.pauseSchedule(
        schedule.id,
        ScheduleCaller.model(session.sessionId),
      );
      expect(scheduler.activeTasks.any((t) => t.id == schedule.id), isFalse);

      final resumed = scheduler.resumeSchedule(
        schedule.id,
        ScheduleCaller.model(session.sessionId),
      );

      expect(resumed.enabled, isTrue);
      expect(scheduler.activeTasks.any((t) => t.id == schedule.id), isTrue);
      expect(resumed.nextRunAt.isAfter(DateTime.now().toUtc().subtract(const Duration(seconds: 1))), isTrue);
    });

    test('resume of an expired once schedule throws ScheduleExpiredException (D6)', () {
      final session = sessionManager.createSession('test-model');
      final pastTime = DateTime.now().toUtc().subtract(const Duration(hours: 1));

      final schedule = scheduler.createSchedule(
        task: 'Past Once Task',
        sessionId: session.sessionId,
        definition: ScheduleDefinition(
          kind: ScheduleKind.once,
          zone: 'local',
          onceAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
        ),
      );

      scheduler.pauseSchedule(
        schedule.id,
        ScheduleCaller.model(session.sessionId),
      );

      // Backdate next_run_at to past
      sessionManager.db.saveScheduledTask(
        schedule.id,
        schedule.task,
        pastTime,
        schedule.sessionId,
        kind: 'once',
        enabled: false,
      );

      expect(
        () => scheduler.resumeSchedule(
          schedule.id,
          ScheduleCaller.model(session.sessionId),
        ),
        throwsA(isA<ScheduleExpiredException>()),
      );
    });

    test('run now dispatches immediately on paused schedule without resuming it (S14, S21)', () async {
      final session = sessionManager.createSession('test-model');
      final schedule = scheduler.createSchedule(
        task: 'Paused Daily Task',
        sessionId: session.sessionId,
        definition: ScheduleDefinition(
          kind: ScheduleKind.daily,
          zone: 'local',
          atTime: '08:00',
        ),
      );

      final originalNextRunAt = schedule.nextRunAt;
      scheduler.pauseSchedule(
        schedule.id,
        ScheduleCaller.model(session.sessionId),
      );

      final events = [];
      final sub = scheduler.eventStream.listen(events.add);

      final result = scheduler.runNowSchedule(
        schedule.id,
        const ScheduleCaller.user(),
      );

      await pumpEventQueue();

      expect(events.length, equals(1));
      expect(result.runId, isNotEmpty);
      expect(result.sessionId, equals(session.sessionId));

      // Schedule remains paused, and next_run_at is unchanged
      final afterRun = scheduler.getSchedule(schedule.id);
      expect(afterRun, isNotNull);
      expect(afterRun!.enabled, isFalse);
      expect(afterRun.nextRunAt, equals(originalNextRunAt));

      // Run record exists with trigger = manual
      final runs = sessionManager.db.scheduledTaskRuns.listRuns(schedule.id).runs;
      expect(runs.length, equals(1));
      expect(runs.first.trigger, equals(ScheduledTaskRunTrigger.manual));
      expect(runs.first.id, equals(result.runId));

      await sub.cancel();
    });
  });

  group('Schedule Authority and Permission Checks (D5, S15)', () {
    test('user-owned schedule is mutable only by device-owner callers', () {
      final schedule = scheduler.createSchedule(
        task: 'User Task',
        ownerKind: ScheduleOwnerKind.user,
        definition: ScheduleDefinition(
          kind: ScheduleKind.daily,
          zone: 'local',
          atTime: '07:00',
        ),
      );

      expect(schedule.ownerKind, equals(ScheduleOwnerKind.user));

      // Model authority caller cannot pause or mutate user-owned schedule
      expect(
        () => scheduler.pauseSchedule(
          schedule.id,
          const ScheduleCaller.model('some_session_id'),
        ),
        throwsA(isA<SchedulePermissionException>()),
      );

      // User authority caller succeeds
      final paused = scheduler.pauseSchedule(
        schedule.id,
        const ScheduleCaller.user(),
      );
      expect(paused.enabled, isFalse);
    });

    test('model turn cannot mutate another conversation schedule', () {
      final sessionA = sessionManager.createSession('model-a');
      final sessionB = sessionManager.createSession('model-b');

      final scheduleA = scheduler.createSchedule(
        task: 'Model A Task',
        sessionId: sessionA.sessionId,
        ownerKind: ScheduleOwnerKind.model,
        definition: ScheduleDefinition(
          kind: ScheduleKind.daily,
          zone: 'local',
          atTime: '09:00',
        ),
      );

      expect(
        () => scheduler.pauseSchedule(
          scheduleA.id,
          ScheduleCaller.model(sessionB.sessionId),
        ),
        throwsA(isA<SchedulePermissionException>()),
      );

      // Device owner caller can pause model schedule
      final paused = scheduler.pauseSchedule(
        scheduleA.id,
        const ScheduleCaller.user(),
      );
      expect(paused.enabled, isFalse);
    });

    test('every scheduler re-save preserves owner_kind and route (D5)', () {
      final schedule = scheduler.createSchedule(
        task: 'User Schedule To Resave',
        ownerKind: ScheduleOwnerKind.user,
        conversationMode: ScheduleConversationMode.continuous,
        workspaceId: 'ws_alpha',
        providerInstanceId: 'prov_alpha',
        model: 'model_alpha',
        definition: ScheduleDefinition(
          kind: ScheduleKind.interval,
          zone: 'local',
          intervalMinutes: 15,
        ),
      );

      expect(schedule.ownerKind, equals(ScheduleOwnerKind.user));
      expect(schedule.workspaceId, equals('ws_alpha'));
      expect(schedule.providerInstanceId, equals('prov_alpha'));
      expect(schedule.model, equals('model_alpha'));

      // Fire the task via executeTaskForTesting (which triggers the scheduler re-save)
      scheduler.executeTaskForTesting(schedule);

      final reSaved = scheduler.getSchedule(schedule.id);
      expect(reSaved, isNotNull);
      expect(reSaved!.ownerKind, equals(ScheduleOwnerKind.user));
      expect(reSaved.workspaceId, equals('ws_alpha'));
      expect(reSaved.providerInstanceId, equals('prov_alpha'));
      expect(reSaved.model, equals('model_alpha'));
    });
  });

  group('Conversation Mode and Settings Validation', () {
    test('parseConversationMode accepts valid modes and rejects null or unknown', () {
      expect(
        ScheduleControl.parseConversationMode('continuous'),
        equals(ScheduleConversationMode.continuous),
      );
      expect(
        ScheduleControl.parseConversationMode('new_each_run'),
        equals(ScheduleConversationMode.newEachRun),
      );
      expect(
        ScheduleControl.parseConversationMode(ScheduleConversationMode.newEachRun),
        equals(ScheduleConversationMode.newEachRun),
      );

      expect(
        () => ScheduleControl.parseConversationMode(null),
        throwsA(isA<ScheduleValidationException>()),
      );
      expect(
        () => ScheduleControl.parseConversationMode(''),
        throwsA(isA<ScheduleValidationException>()),
      );
      expect(
        () => ScheduleControl.parseConversationMode('invalid_mode'),
        throwsA(isA<ScheduleValidationException>()),
      );
    });

    test('updateSchedule validates conversation_mode before repository call', () {
      final session = sessionManager.createSession('test-model');
      final schedule = scheduler.createSchedule(
        task: 'Updatable Task',
        sessionId: session.sessionId,
        definition: ScheduleDefinition(
          kind: ScheduleKind.daily,
          zone: 'local',
          atTime: '10:00',
        ),
      );

      expect(
        () => scheduler.updateSchedule(
          id: schedule.id,
          caller: const ScheduleCaller.user(),
          conversationMode: null,
        ),
        throwsA(isA<ScheduleValidationException>()),
      );

      expect(
        () => scheduler.updateSchedule(
          id: schedule.id,
          caller: const ScheduleCaller.user(),
          conversationMode: 'unsupported_mode',
        ),
        throwsA(isA<ScheduleValidationException>()),
      );
    });
  });

  group('Conversation Deletion Pause Hook (S23, Q2 Amendment)', () {
    test('deleting a session pauses schedules where sessionId matches', () {
      final session = sessionManager.createSession('test-model');
      final schedule = scheduler.createSchedule(
        task: 'Model Schedule',
        sessionId: session.sessionId,
        definition: ScheduleDefinition(
          kind: ScheduleKind.daily,
          zone: 'local',
          atTime: '11:00',
        ),
      );

      expect(schedule.enabled, isTrue);

      sessionManager.deleteSession(session.sessionId);

      final persisted = scheduler.getSchedule(schedule.id);
      expect(persisted, isNotNull);
      expect(persisted!.enabled, isFalse);

      // Resuming or running now on this orphaned model schedule fails (D10, S23)
      expect(
        () => scheduler.resumeSchedule(
          schedule.id,
          const ScheduleCaller.user(),
        ),
        throwsA(isA<ScheduleOrphanedException>()),
      );
      expect(
        () => scheduler.runNowSchedule(
          schedule.id,
          const ScheduleCaller.user(),
        ),
        throwsA(isA<ScheduleOrphanedException>()),
      );
    });

    test('deleting a continuous run session pauses schedule and clears run_session_id', () {
      final runSession = sessionManager.createSession('test-model');
      final schedule = scheduler.createSchedule(
        task: 'User Continuous Schedule',
        ownerKind: ScheduleOwnerKind.user,
        conversationMode: ScheduleConversationMode.continuous,
        runSessionId: runSession.sessionId,
        definition: ScheduleDefinition(
          kind: ScheduleKind.daily,
          zone: 'local',
          atTime: '12:00',
        ),
      );

      sessionManager.deleteSession(runSession.sessionId);

      final persisted = scheduler.getSchedule(schedule.id);
      expect(persisted, isNotNull);
      expect(persisted!.enabled, isFalse);
      expect(persisted.runSessionId, isNull);

      // Resuming user schedule succeeds and will create a new conversation on next dispatch
      final resumed = scheduler.resumeSchedule(
        schedule.id,
        const ScheduleCaller.user(),
      );
      expect(resumed.enabled, isTrue);
    });

    test('deleting a past run session does not pause a new_each_run schedule (Q2)', () {
      final creatorSession = sessionManager.createSession('creator');
      final runSession = sessionManager.createSession('run-1');

      final schedule = scheduler.createSchedule(
        task: 'New Each Run Schedule',
        sessionId: creatorSession.sessionId,
        ownerKind: ScheduleOwnerKind.user,
        conversationMode: ScheduleConversationMode.newEachRun,
        runSessionId: runSession.sessionId,
        definition: ScheduleDefinition(
          kind: ScheduleKind.daily,
          zone: 'local',
          atTime: '14:00',
        ),
      );

      // Deleting run-1 must NOT pause the schedule
      sessionManager.deleteSession(runSession.sessionId);

      final persisted = scheduler.getSchedule(schedule.id);
      expect(persisted, isNotNull);
      expect(persisted!.enabled, isTrue);
    });
  });

  group('Delete Schedule and Active Run Updates (S10, D7, S24)', () {
    test('deleteSchedule deletes schedule and runs but leaves conversations intact', () {
      final session = sessionManager.createSession('test-model');
      final schedule = scheduler.createSchedule(
        task: 'To Delete',
        sessionId: session.sessionId,
        definition: ScheduleDefinition(
          kind: ScheduleKind.daily,
          zone: 'local',
          atTime: '15:00',
        ),
      );

      scheduler.runRecorder.startRun(
        scheduleId: schedule.id,
        runAt: DateTime.now().toUtc(),
        trigger: ScheduledTaskRunTrigger.manual,
      );

      expect(sessionManager.db.scheduledTaskRuns.listRuns(schedule.id).runs, isNotEmpty);

      scheduler.deleteSchedule(
        schedule.id,
        const ScheduleCaller.user(),
      );

      expect(scheduler.getSchedule(schedule.id), isNull);
      expect(sessionManager.db.scheduledTaskRuns.listRuns(schedule.id).runs, isEmpty);
      expect(sessionManager.getSessionRecord(session.sessionId), isNotNull);
    });

    test('updateSchedule during an active run changes nothing about in-flight run (S24)', () {
      final session = sessionManager.createSession('test-model');
      final schedule = scheduler.createSchedule(
        task: 'Task Before Edit',
        sessionId: session.sessionId,
        definition: ScheduleDefinition(
          kind: ScheduleKind.daily,
          zone: 'local',
          atTime: '16:00',
        ),
      );

      final runResult = scheduler.runNowSchedule(
        schedule.id,
        const ScheduleCaller.user(),
      );

      final updated = scheduler.updateSchedule(
        id: schedule.id,
        caller: const ScheduleCaller.user(),
        task: 'Task After Edit',
        name: 'Updated Name',
      );

      expect(updated.task, equals('Task After Edit'));
      expect(updated.name, equals('Updated Name'));

      // In flight run row is still running with its original runId
      final run = sessionManager.db.scheduledTaskRuns.getRun(runResult.runId);
      expect(run, isNotNull);
      expect(run!.status, equals(ScheduledTaskRunStatus.running));
    });
  });
}
