import 'dart:async';
import 'dart:io';

import 'package:get_it/get_it.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/evolution/cron_scheduler.dart';
import 'package:sanad_agent/evolution/db/scheduled_task_run_repository.dart';
import 'package:sanad_agent/evolution/models/session_execution_snapshot.dart';
import 'package:sanad_agent/evolution/models/session_state.dart';
import 'package:sanad_agent/evolution/scheduling/schedule_model.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/interfaces/models/gateway_event.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late SessionManager sessionManager;
  late CronScheduler scheduler;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('schedule_conv_runs_test_');
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

  group('Schedule Run Row Lifecycle & Ordering (A3, D9, B-D1)', () {
    test('run row starts running before dispatch event leaves scheduler on timer fire', () async {
      final session = sessionManager.createSession('test-model');
      final schedule = scheduler.createSchedule(
        task: 'Timer fire check',
        sessionId: session.sessionId,
        definition: ScheduleDefinition(
          kind: ScheduleKind.interval,
          zone: 'local',
          intervalMinutes: 1,
        ),
      );

      String? capturedRunId;
      ScheduledTaskRun? capturedRunAtEvent;
      final completer = Completer<void>();

      final sub = scheduler.eventStream.listen((event) {
        capturedRunId = event.runId;
        if (event.runId != null) {
          capturedRunAtEvent = sessionManager.db.scheduledTaskRuns.getRun(event.runId!);
        }
        completer.complete();
      });

      // Manually invoke execution to simulate timer fire
      scheduler.executeTaskForTesting(schedule);
      await completer.future.timeout(const Duration(seconds: 2));
      await sub.cancel();

      expect(capturedRunId, isNotNull);
      expect(capturedRunAtEvent, isNotNull);
      expect(capturedRunAtEvent!.status, ScheduledTaskRunStatus.running);
      expect(capturedRunAtEvent!.trigger, ScheduledTaskRunTrigger.scheduled);
      expect(capturedRunAtEvent!.scheduleId, schedule.id);
    });

    test('run row starts running before recovery dispatch event leaves scheduler on startup', () async {
      final now = DateTime.utc(2026, 10, 20, 10, 30);
      final dueInstant = DateTime.utc(2026, 10, 20, 10, 0); // 30 mins ago, in grace

      sessionManager.db.saveScheduledTask(
        'task_rec_order',
        'Recovery order check',
        dueInstant,
        'session_rec',
        kind: 'daily',
        atTime: '10:00',
        zone: 'Z',
        enabled: true,
      );

      String? capturedRunId;
      ScheduledTaskRun? capturedRunAtEvent;
      final completer = Completer<void>();

      final sub = scheduler.eventStream.listen((event) {
        capturedRunId = event.runId;
        if (event.runId != null) {
          capturedRunAtEvent = sessionManager.db.scheduledTaskRuns.getRun(event.runId!);
        }
        completer.complete();
      });

      await scheduler.initialize(now: now);
      await completer.future.timeout(const Duration(seconds: 2));
      await sub.cancel();

      expect(capturedRunId, isNotNull);
      expect(capturedRunAtEvent, isNotNull);
      expect(capturedRunAtEvent!.status, ScheduledTaskRunStatus.running);
      expect(capturedRunAtEvent!.trigger, ScheduledTaskRunTrigger.recovery);
      expect(capturedRunAtEvent!.scheduleId, 'task_rec_order');
    });

    test('manual run starts running before dispatch and records trigger=manual', () async {
      final session = sessionManager.createSession('test-model');
      final schedule = scheduler.createSchedule(
        task: 'Manual run order check',
        sessionId: session.sessionId,
        definition: ScheduleDefinition(
          kind: ScheduleKind.daily,
          zone: 'local',
          atTime: '09:00',
        ),
      );

      String? capturedRunId;
      ScheduledTaskRun? capturedRunAtEvent;
      final completer = Completer<void>();

      final sub = scheduler.eventStream.listen((event) {
        capturedRunId = event.runId;
        if (event.runId != null) {
          capturedRunAtEvent = sessionManager.db.scheduledTaskRuns.getRun(event.runId!);
        }
        completer.complete();
      });

      final result = scheduler.runNowSchedule(
        schedule.id,
        const ScheduleCaller.user(),
      );

      await completer.future.timeout(const Duration(seconds: 2));
      await sub.cancel();

      expect(result.runId, capturedRunId);
      expect(capturedRunAtEvent, isNotNull);
      expect(capturedRunAtEvent!.status, ScheduledTaskRunStatus.running);
      expect(capturedRunAtEvent!.trigger, ScheduledTaskRunTrigger.manual);
      expect(capturedRunAtEvent!.scheduleId, schedule.id);
    });

    test('missed-beyond-grace writes skipped directly and never dispatches event', () async {
      final now = DateTime.utc(2026, 10, 20, 15, 0);
      final dueInstant = DateTime.utc(2026, 10, 20, 10, 0); // 5 hours ago, beyond grace (2h)

      sessionManager.db.saveScheduledTask(
        'task_skipped_order',
        'Skipped check',
        dueInstant,
        'session_skip',
        kind: 'daily',
        atTime: '10:00',
        zone: 'Z',
        enabled: true,
      );

      final receivedEvents = <GatewayEvent>[];
      final sub = scheduler.eventStream.listen(receivedEvents.add);

      await scheduler.initialize(now: now);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await sub.cancel();

      expect(receivedEvents, isEmpty);

      final runs = sessionManager.db.scheduledTaskRuns.listRuns('task_skipped_order');
      expect(runs.runs.length, 1);
      final run = runs.runs.first;
      expect(run.status, ScheduledTaskRunStatus.skipped);
      expect(run.durationMs, 0);
      expect(run.trigger, ScheduledTaskRunTrigger.recovery);
    });
  });

  group('User Message Anchoring (S9, S20)', () {
    test('user message commit anchors message_id on the running row before terminal status', () {
      final session = sessionManager.createSession('test-model');
      final schedule = scheduler.createSchedule(
        task: 'Anchor check',
        sessionId: session.sessionId,
        definition: ScheduleDefinition(
          kind: ScheduleKind.daily,
          zone: 'local',
          atTime: '09:00',
        ),
      );

      final runId = scheduler.runRecorder.startRun(
        scheduleId: schedule.id,
        runAt: DateTime.now().toUtc(),
        trigger: ScheduledTaskRunTrigger.scheduled,
      );

      var run = sessionManager.db.scheduledTaskRuns.getRun(runId)!;
      expect(run.messageId, isNull);
      expect(run.sessionId, isNull);
      expect(run.hasPosition, isFalse);

      // Commit user message in session message repository
      final msg = Message(
        role: MessageRole.user,
        content: 'Anchor check',
        metadata: {
          'message_id': 'msg_anchor_42',
          'request_id': runId,
        },
      );
      sessionManager.db.replaceMessages(session.sessionId, [msg]);

      // Resolve and attach anchor
      final resolvedMsgId = scheduler.runRecorder.resolveUserMessageId(
        session.sessionId,
        runId,
      );
      expect(resolvedMsgId, 'msg_anchor_42');

      final attached = scheduler.runRecorder.attachUserMessage(
        runId,
        sessionId: session.sessionId,
        messageId: resolvedMsgId!,
      );
      expect(attached, isTrue);

      run = sessionManager.db.scheduledTaskRuns.getRun(runId)!;
      expect(run.messageId, 'msg_anchor_42');
      expect(run.sessionId, session.sessionId);
      expect(run.hasPosition, isTrue);
      expect(run.status, ScheduledTaskRunStatus.running);

      // Complete run after anchoring
      scheduler.runRecorder.completeRun(
        runId,
        status: ScheduledTaskRunStatus.succeeded,
      );

      run = sessionManager.db.scheduledTaskRuns.getRun(runId)!;
      expect(run.status, ScheduledTaskRunStatus.succeeded);
      expect(run.messageId, 'msg_anchor_42');
      expect(run.hasPosition, isTrue);
    });
  });

  group('Execution State Observer & Turn Completion (Q1, D9)', () {
    test('observer completes run as succeeded when conversation transitions to idle with completed outcome', () {
      final session = sessionManager.createSession('test-model');
      final schedule = scheduler.createSchedule(
        task: 'Turn success',
        sessionId: session.sessionId,
        definition: ScheduleDefinition(
          kind: ScheduleKind.daily,
          zone: 'local',
          atTime: '09:00',
        ),
      );

      final observer = ScheduleRunObserver(
        recorder: scheduler.runRecorder,
        lookupOutcome: (sid, rid) => ScheduleRunTurnOutcome.completed,
      );

      final runId = scheduler.runRecorder.startRun(
        scheduleId: schedule.id,
        runAt: DateTime.now().toUtc(),
        trigger: ScheduledTaskRunTrigger.manual,
      );

      observer.track(
        runId: runId,
        sessionId: session.sessionId,
        scheduleId: schedule.id,
      );

      // Running snapshot
      observer.observe(SessionExecutionSnapshot(
        sessionId: session.sessionId,
        state: SessionExecutionState.running,
        workItemId: 'work_1',
        requestId: runId,
        revision: 1,
        updatedAt: DateTime.now().toUtc(),
      ));

      var run = sessionManager.db.scheduledTaskRuns.getRun(runId)!;
      expect(run.status, ScheduledTaskRunStatus.running);

      // Idle snapshot (turn finished)
      observer.observe(SessionExecutionSnapshot(
        sessionId: session.sessionId,
        state: SessionExecutionState.idle,
        workItemId: null,
        requestId: null,
        revision: 2,
        updatedAt: DateTime.now().toUtc(),
      ));

      run = sessionManager.db.scheduledTaskRuns.getRun(runId)!;
      expect(run.status, ScheduledTaskRunStatus.succeeded);
      expect(run.durationMs, isNotNull);
      expect(run.durationMs!, greaterThanOrEqualTo(0));
      expect(run.error, isNull);
    });

    test('observer completes run as failed with bounded redacted error when outcome is failed', () {
      final session = sessionManager.createSession('test-model');
      final schedule = scheduler.createSchedule(
        task: 'Turn failure',
        sessionId: session.sessionId,
        definition: ScheduleDefinition(
          kind: ScheduleKind.daily,
          zone: 'local',
          atTime: '09:00',
        ),
      );

      var failedNotified = false;
      final observer = ScheduleRunObserver(
        recorder: scheduler.runRecorder,
        lookupOutcome: (sid, rid) => ScheduleRunTurnOutcome.failed,
        lookupError: (sid, rid) => 'API key sk-ant-secret123 failed: Rate limit exceeded',
        onRunFailed: ({
          required consecutiveFailures,
          String? error,
          required runId,
          required scheduleId,
          required sessionId,
          required suggestPause,
        }) {
          failedNotified = true;
          expect(error, contains('sk-***'));
          expect(error, isNot(contains('secret123')));
        },
      );

      final runId = scheduler.runRecorder.startRun(
        scheduleId: schedule.id,
        runAt: DateTime.now().toUtc(),
        trigger: ScheduledTaskRunTrigger.manual,
      );

      observer.track(
        runId: runId,
        sessionId: session.sessionId,
        scheduleId: schedule.id,
      );

      observer.observe(SessionExecutionSnapshot(
        sessionId: session.sessionId,
        state: SessionExecutionState.running,
        workItemId: 'work_fail',
        requestId: runId,
        revision: 1,
        updatedAt: DateTime.now().toUtc(),
      ));

      observer.observe(SessionExecutionSnapshot(
        sessionId: session.sessionId,
        state: SessionExecutionState.idle,
        workItemId: null,
        requestId: null,
        revision: 2,
        updatedAt: DateTime.now().toUtc(),
      ));

      final run = sessionManager.db.scheduledTaskRuns.getRun(runId)!;
      expect(run.status, ScheduledTaskRunStatus.failed);
      expect(run.error, isNotNull);
      expect(run.error, isNot(contains('sk-ant-secret123')));
      expect(run.error, contains('sk-***'));
      expect(failedNotified, isTrue);
    });

    test('startup reconcile marks stale running run as failed interrupted when not active', () {
      final session = sessionManager.createSession('test-model');
      final schedule = scheduler.createSchedule(
        task: 'Stale run reconcile',
        sessionId: session.sessionId,
        definition: ScheduleDefinition(
          kind: ScheduleKind.daily,
          zone: 'local',
          atTime: '09:00',
        ),
      );

      final staleRunId = scheduler.runRecorder.startRun(
        scheduleId: schedule.id,
        runAt: DateTime.now().toUtc().subtract(const Duration(hours: 1)),
        trigger: ScheduledTaskRunTrigger.scheduled,
      );

      var run = sessionManager.db.scheduledTaskRuns.getRun(staleRunId)!;
      expect(run.status, ScheduledTaskRunStatus.running);

      final recovered = scheduler.runRecorder.recoverInterruptedRuns(
        isRunActive: (sessionId, runId) => false, // no active work
      );

      expect(recovered, 1);
      run = sessionManager.db.scheduledTaskRuns.getRun(staleRunId)!;
      expect(run.status, ScheduledTaskRunStatus.failed);
      expect(run.error, ScheduleRunRecorder.interruptedRunError);

      // A second reconcile pass is idempotent
      final secondPass = scheduler.runRecorder.recoverInterruptedRuns(
        isRunActive: (sessionId, runId) => false,
      );
      expect(secondPass, 0);
    });

    test('startup reconcile preserves active running run', () {
      final session = sessionManager.createSession('test-model');
      final schedule = scheduler.createSchedule(
        task: 'Active run reconcile',
        sessionId: session.sessionId,
        definition: ScheduleDefinition(
          kind: ScheduleKind.daily,
          zone: 'local',
          atTime: '09:00',
        ),
      );

      final activeRunId = scheduler.runRecorder.startRun(
        scheduleId: schedule.id,
        runAt: DateTime.now().toUtc(),
        trigger: ScheduledTaskRunTrigger.scheduled,
      );

      // Attach message so sessionId is known
      scheduler.runRecorder.attachUserMessage(
        activeRunId,
        sessionId: session.sessionId,
        messageId: 'msg_active',
      );

      final recovered = scheduler.runRecorder.recoverInterruptedRuns(
        isRunActive: (sessionId, runId) => runId == activeRunId,
      );

      expect(recovered, 0);
      final run = sessionManager.db.scheduledTaskRuns.getRun(activeRunId)!;
      expect(run.status, ScheduledTaskRunStatus.running);
    });

    test('no double-completion: completeRun on terminal run returns false and changes nothing', () {
      final session = sessionManager.createSession('test-model');
      final schedule = scheduler.createSchedule(
        task: 'No double complete',
        sessionId: session.sessionId,
        definition: ScheduleDefinition(
          kind: ScheduleKind.daily,
          zone: 'local',
          atTime: '09:00',
        ),
      );

      final runId = scheduler.runRecorder.startRun(
        scheduleId: schedule.id,
        runAt: DateTime.now().toUtc(),
        trigger: ScheduledTaskRunTrigger.manual,
      );

      final firstCompleted = scheduler.runRecorder.completeRun(
        runId,
        status: ScheduledTaskRunStatus.succeeded,
      );
      expect(firstCompleted, isTrue);

      final firstRun = sessionManager.db.scheduledTaskRuns.getRun(runId)!;
      final duration = firstRun.durationMs;

      // Second attempt to complete with different status
      final secondCompleted = scheduler.runRecorder.completeRun(
        runId,
        status: ScheduledTaskRunStatus.failed,
        error: 'Should not overwrite',
      );
      expect(secondCompleted, isFalse);

      final secondRun = sessionManager.db.scheduledTaskRuns.getRun(runId)!;
      expect(secondRun.status, ScheduledTaskRunStatus.succeeded);
      expect(secondRun.durationMs, duration);
      expect(secondRun.error, isNull);
    });

    test('observer dispose cancels subscription and clears pending tracking', () async {
      final observer = ScheduleRunObserver(
        recorder: scheduler.runRecorder,
        lookupOutcome: (sid, rid) => ScheduleRunTurnOutcome.completed,
      );

      final controller = StreamController<SessionExecutionSnapshot>.broadcast();
      observer.listen(controller.stream);
      expect(observer.isListening, isTrue);

      observer.track(runId: 'r1', sessionId: 's1', scheduleId: 'sch1');
      expect(observer.pendingRunIds, contains('r1'));

      await observer.dispose();
      expect(observer.isListening, isFalse);
      expect(observer.pendingRunIds, isEmpty);

      await controller.close();
    });
  });

  group('Consecutive Failures and Pause Suggestion (S16, S22)', () {
    test('failing manual run advances consecutive_failures and triggers suggest_pause on third failure', () {
      final session = sessionManager.createSession('test-model');
      final schedule = scheduler.createSchedule(
        task: 'Streak check',
        sessionId: session.sessionId,
        definition: ScheduleDefinition(
          kind: ScheduleKind.daily,
          zone: 'local',
          atTime: '09:00',
        ),
      );

      expect(scheduler.consecutiveFailures(schedule.id), 0);
      expect(scheduler.suggestPause(schedule.id), isFalse);

      // Failure 1 (scheduled)
      final r1 = scheduler.runRecorder.startRun(
        scheduleId: schedule.id,
        runAt: DateTime.now().toUtc().subtract(const Duration(hours: 3)),
        trigger: ScheduledTaskRunTrigger.scheduled,
      );
      scheduler.runRecorder.completeRun(r1, status: ScheduledTaskRunStatus.failed, error: 'fail 1');
      expect(scheduler.consecutiveFailures(schedule.id), 1);
      expect(scheduler.suggestPause(schedule.id), isFalse);

      // Failure 2 (manual - counts the same as scheduled per S22)
      final r2 = scheduler.runRecorder.startRun(
        scheduleId: schedule.id,
        runAt: DateTime.now().toUtc().subtract(const Duration(hours: 2)),
        trigger: ScheduledTaskRunTrigger.manual,
      );
      scheduler.runRecorder.completeRun(r2, status: ScheduledTaskRunStatus.failed, error: 'fail 2');
      expect(scheduler.consecutiveFailures(schedule.id), 2);
      expect(scheduler.suggestPause(schedule.id), isFalse);

      // Failure 3 (manual)
      final r3 = scheduler.runRecorder.startRun(
        scheduleId: schedule.id,
        runAt: DateTime.now().toUtc().subtract(const Duration(hours: 1)),
        trigger: ScheduledTaskRunTrigger.manual,
      );
      scheduler.runRecorder.completeRun(r3, status: ScheduledTaskRunStatus.failed, error: 'fail 3');
      expect(scheduler.consecutiveFailures(schedule.id), 3);
      expect(scheduler.suggestPause(schedule.id), isTrue);

      // Success resets consecutive failures to 0
      final r4 = scheduler.runRecorder.startRun(
        scheduleId: schedule.id,
        runAt: DateTime.now().toUtc(),
        trigger: ScheduledTaskRunTrigger.manual,
      );
      scheduler.runRecorder.completeRun(r4, status: ScheduledTaskRunStatus.succeeded);
      expect(scheduler.consecutiveFailures(schedule.id), 0);
      expect(scheduler.suggestPause(schedule.id), isFalse);
    });
  });

  group('Schedule Conversations: Continuous vs New Each Run (A4, S3, S4, S5, S23, D8, D10)', () {
    test('continuous creates exactly one conversation and reuses it across dispatches', () {
      final schedule = scheduler.createSchedule(
        task: 'Continuous task',
        name: 'Continuous Schedule',
        ownerKind: ScheduleOwnerKind.user,
        conversationMode: ScheduleConversationMode.continuous,
        workspaceId: 'ws_alpha',
        providerInstanceId: 'prov_alpha',
        model: 'model_alpha',
        definition: ScheduleDefinition(
          kind: ScheduleKind.daily,
          zone: 'local',
          atTime: '09:00',
        ),
      );

      expect(schedule.runSessionId, isNull);

      // First run resolves and creates conversation
      final firstSessionId = scheduler.conversationFactory.resolveDispatchSession(schedule);
      expect(firstSessionId, isNotEmpty);

      // Verify conversation properties in SessionDB
      final sessionRecord = sessionManager.getSessionRecord(firstSessionId);
      expect(sessionRecord, isNotNull);
      expect(sessionRecord!.workspaceId, 'ws_alpha');
      expect(sessionRecord.providerId, 'prov_alpha');
      expect(sessionRecord.model, 'model_alpha');
      expect(sessionRecord.title, 'Continuous Schedule');
      expect(sessionRecord.titleStatus, SessionTitleStatus.finalized);

      // Schedule in DB updated with run_session_id
      final updatedRecord = scheduler.getSchedule(schedule.id)!;
      expect(updatedRecord.runSessionId, firstSessionId);

      // Second run reuses the same conversation
      final secondSessionId = scheduler.conversationFactory.resolveDispatchSession(updatedRecord);
      expect(secondSessionId, firstSessionId);
    });

    test('schedule without name derives pending title from task snippet', () {
      final schedule = scheduler.createSchedule(
        task: 'Summarise all pull requests in repository and send a brief report',
        ownerKind: ScheduleOwnerKind.user,
        conversationMode: ScheduleConversationMode.continuous,
        definition: ScheduleDefinition(
          kind: ScheduleKind.daily,
          zone: 'local',
          atTime: '09:00',
        ),
      );

      final sessionId = scheduler.conversationFactory.resolveDispatchSession(schedule);
      final sessionRecord = sessionManager.getSessionRecord(sessionId)!;
      expect(sessionRecord.title, 'Summarise all pull requests in repository and send a brie...');
      expect(sessionRecord.title!.length, 60);
      expect(sessionRecord.titleStatus, SessionTitleStatus.pending);
    });

    test('new_each_run creates fresh conversation per run', () {
      final schedule = scheduler.createSchedule(
        task: 'Per run task',
        ownerKind: ScheduleOwnerKind.user,
        conversationMode: ScheduleConversationMode.newEachRun,
        workspaceId: 'ws_beta',
        definition: ScheduleDefinition(
          kind: ScheduleKind.daily,
          zone: 'local',
          atTime: '09:00',
        ),
      );

      final session1 = scheduler.conversationFactory.resolveDispatchSession(schedule);
      final session2 = scheduler.conversationFactory.resolveDispatchSession(schedule);

      expect(session1, isNot(session2));
      expect(sessionManager.getSessionRecord(session1), isNotNull);
      expect(sessionManager.getSessionRecord(session2), isNotNull);

      // Record runSessionId remains null on schedule record
      final record = scheduler.getSchedule(schedule.id)!;
      expect(record.runSessionId, isNull);
    });

    test('user-owned continuous schedule dispatches into newly created conversation on runNowSchedule', () {
      final schedule = scheduler.createSchedule(
        task: 'Run now first dispatch',
        ownerKind: ScheduleOwnerKind.user,
        conversationMode: ScheduleConversationMode.continuous,
        definition: ScheduleDefinition(
          kind: ScheduleKind.daily,
          zone: 'local',
          atTime: '09:00',
        ),
      );

      expect(schedule.runSessionId, isNull);

      final result = scheduler.runNowSchedule(
        schedule.id,
        const ScheduleCaller.user(),
      );

      expect(result.sessionId, isNotEmpty);
      final updated = scheduler.getSchedule(schedule.id)!;
      expect(updated.runSessionId, result.sessionId);
    });

    test('model-owned schedule whose conversation was deleted throws ScheduleOrphanedException (S23, D10)', () {
      final session = sessionManager.createSession('test-model');
      final schedule = scheduler.createSchedule(
        task: 'Model orphaned check',
        sessionId: session.sessionId,
        definition: ScheduleDefinition(
          kind: ScheduleKind.daily,
          zone: 'local',
          atTime: '09:00',
        ),
      );

      // Delete the conversation
      sessionManager.deleteSession(session.sessionId);

      final paused = scheduler.getSchedule(schedule.id)!;
      expect(paused.enabled, isFalse);

      // resume throws ScheduleOrphanedException
      expect(
        () => scheduler.resumeSchedule(schedule.id, const ScheduleCaller.user()),
        throwsA(isA<ScheduleOrphanedException>()),
      );

      // runNow throws ScheduleOrphanedException
      expect(
        () => scheduler.runNowSchedule(schedule.id, const ScheduleCaller.user()),
        throwsA(isA<ScheduleOrphanedException>()),
      );
    });
  });

  group('Retention Policy (D2)', () {
    test('run recorder prunes runs beyond 200 per schedule on write', () {
      final session = sessionManager.createSession('test-model');
      final schedule = scheduler.createSchedule(
        task: 'Retention check',
        sessionId: session.sessionId,
        definition: ScheduleDefinition(
          kind: ScheduleKind.daily,
          zone: 'local',
          atTime: '09:00',
        ),
      );

      final baseTime = DateTime.utc(2026, 10, 20, 12, 0);

      // Insert 205 runs directly via recorder
      for (var i = 0; i < 205; i++) {
        scheduler.runRecorder.startRun(
          scheduleId: schedule.id,
          runAt: baseTime.add(Duration(minutes: i)),
          trigger: ScheduledTaskRunTrigger.scheduled,
        );
      }

      final page = sessionManager.db.scheduledTaskRuns.listRuns(
        schedule.id,
        limit: 300,
      );

      expect(page.runs.length, ScheduledTaskRunRetention.maxRunsPerSchedule);
    });
  });
}
