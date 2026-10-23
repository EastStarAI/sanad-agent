import 'package:sanad_agent/evolution/cron_scheduler.dart';
import 'package:sanad_agent/evolution/db/scheduled_task_run_repository.dart';
import 'package:sanad_agent/evolution/models/session_execution_snapshot.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/schedule_run_failure_notice.dart';
import 'package:test/test.dart';

import 'handlers/support/schedule_protocol_harness.dart';

void main() {
  late ScheduleProtocolHarness harness;
  late List<CanonicalEvent> published;

  setUp(() async {
    harness = await ScheduleProtocolHarness.start();
    published = [];
  });

  tearDown(() async {
    await harness.dispose();
  });

  ScheduleRunFailureNotice noticeFor({String? name = 'Morning brief'}) =>
      ScheduleRunFailureNotice(
        publishFamilyEvent: published.add,
        scheduleName: (scheduleId) => name,
      );

  Map<String, dynamic> publishFailure(
    ScheduleRunFailureNotice notice, {
    String scheduleId = 'task_1',
    String runId = 'run_1',
    String sessionId = 'session_1',
    int consecutiveFailures = 1,
    bool suggestPause = false,
    String? error,
  }) {
    notice.publish(
      scheduleId: scheduleId,
      runId: runId,
      sessionId: sessionId,
      consecutiveFailures: consecutiveFailures,
      suggestPause: suggestPause,
      error: error,
    );
    return Map<String, dynamic>.from(published.last.payload);
  }

  group('ScheduleRunFailureNotice', () {
    test('carries exactly the documented fields on the run conversation',
        () async {
      final payload = publishFailure(
        noticeFor(),
        consecutiveFailures: 3,
        suggestPause: true,
        error: 'Rate limit exceeded',
      );

      expect(published.single.type, CanonicalEventTypes.scheduleRunFailed);
      expect(published.single.sessionId, 'session_1');
      expect(payload.keys.toSet(), {
        'schedule_id',
        'schedule_name',
        'run_id',
        'session_id',
        'consecutive_failures',
        'suggest_pause',
      });
      expect(payload, {
        'schedule_id': 'task_1',
        'schedule_name': 'Morning brief',
        'run_id': 'run_1',
        'session_id': 'session_1',
        'consecutive_failures': 3,
        'suggest_pause': true,
      });
      // The bounded failure text stays in the run row (coordinator decision).
      expect(payload.containsKey('error'), isFalse);
      expect(payload.toString(), isNot(contains('Rate limit')));
    });

    test('schedule_name is the stored name only, never a derived label',
        () async {
      final payload = publishFailure(noticeFor(name: null));

      expect(payload['schedule_name'], isNull);
    });

    test('does not publish without a conversation', () async {
      final notice = noticeFor();
      notice.publish(
        scheduleId: 'task_1',
        runId: 'run_1',
        sessionId: '',
        consecutiveFailures: 1,
        suggestPause: false,
      );

      expect(published, isEmpty);
    });

    test('passes the accumulated streak through unchanged', () async {
      publishFailure(noticeFor(), consecutiveFailures: 1);
      publishFailure(noticeFor(), consecutiveFailures: 2);
      publishFailure(noticeFor(), consecutiveFailures: 3, suggestPause: true);

      expect(
        [for (final event in published) event.payload['consecutive_failures']],
        [1, 2, 3],
      );
      expect(
        [for (final event in published) event.payload['suggest_pause']],
        [false, false, true],
      );
    });
  });

  group('Failure Surfacing Through the Observer', () {
    test('publishes once per failed run and suggests pausing on the third',
        () async {
      final created = await harness.send(
        harness.event(CanonicalEventTypes.scheduleCreate, {
          'task': 'Failing task',
          'kind': 'daily',
          'time': '09:00',
          'zone': 'Z',
        }),
      );
      final scheduleId =
          (harness.payloadOf(created)['schedule'] as Map)['id'] as String;
      final session = harness.sessionManager.createSession('test-model');
      final notice = ScheduleRunFailureNotice(
        publishFamilyEvent: published.add,
        scheduleName: (id) => harness.scheduler.getSchedule(id)?.name,
      );
      final observer = ScheduleRunObserver(
        recorder: harness.scheduler.runRecorder,
        lookupOutcome: (sid, rid) => ScheduleRunTurnOutcome.failed,
        lookupError: (sid, rid) => 'Provider refused the request',
        onRunFailed: notice.publish,
      );

      for (var attempt = 1; attempt <= 3; attempt++) {
        final runId = harness.scheduler.runRecorder.startRun(
          scheduleId: scheduleId,
          runAt: DateTime.now().toUtc(),
          trigger: ScheduledTaskRunTrigger.manual,
        );
        observer.track(
          runId: runId,
          sessionId: session.sessionId,
          scheduleId: scheduleId,
        );
        observer.observe(
          SessionExecutionSnapshot(
            sessionId: session.sessionId,
            state: SessionExecutionState.running,
            workItemId: 'work_$attempt',
            requestId: runId,
            revision: attempt * 2,
            updatedAt: DateTime.now().toUtc(),
          ),
        );
        observer.observe(
          SessionExecutionSnapshot(
            sessionId: session.sessionId,
            state: SessionExecutionState.idle,
            workItemId: null,
            requestId: null,
            revision: attempt * 2 + 1,
            updatedAt: DateTime.now().toUtc(),
          ),
        );
      }

      expect(published, hasLength(3));
      expect(
        [for (final event in published) event.payload['consecutive_failures']],
        [1, 2, 3],
      );
      expect(
        [for (final event in published) event.payload['suggest_pause']],
        [false, false, true],
      );
      for (final event in published) {
        expect(event.type, CanonicalEventTypes.scheduleRunFailed);
        expect(event.sessionId, session.sessionId);
        expect(event.payload['schedule_id'], scheduleId);
        expect(event.payload['session_id'], session.sessionId);
        expect(event.payload['schedule_name'], isNull);
        expect(event.payload.containsKey('error'), isFalse);
      }
      // Nothing disabled the schedule (S16).
      expect(harness.scheduler.getSchedule(scheduleId)!.enabled, isTrue);

      await observer.dispose();
    });

    test('a successful run publishes nothing and resets the streak', () async {
      final created = await harness.send(
        harness.event(CanonicalEventTypes.scheduleCreate, {
          'task': 'Recovering task',
          'kind': 'daily',
          'time': '09:00',
          'zone': 'Z',
        }),
      );
      final scheduleId =
          (harness.payloadOf(created)['schedule'] as Map)['id'] as String;
      final session = harness.sessionManager.createSession('test-model');
      final notice = noticeFor();
      harness.seedRun(
        scheduleId: scheduleId,
        status: ScheduledTaskRunStatus.failed,
      );

      final observer = ScheduleRunObserver(
        recorder: harness.scheduler.runRecorder,
        lookupOutcome: (sid, rid) => ScheduleRunTurnOutcome.completed,
        onRunFailed: notice.publish,
      );
      final runId = harness.scheduler.runRecorder.startRun(
        scheduleId: scheduleId,
        runAt: DateTime.now().toUtc(),
        trigger: ScheduledTaskRunTrigger.scheduled,
      );
      observer.track(
        runId: runId,
        sessionId: session.sessionId,
        scheduleId: scheduleId,
      );
      observer.observe(
        SessionExecutionSnapshot(
          sessionId: session.sessionId,
          state: SessionExecutionState.running,
          workItemId: 'work_ok',
          requestId: runId,
          revision: 1,
          updatedAt: DateTime.now().toUtc(),
        ),
      );
      observer.observe(
        SessionExecutionSnapshot(
          sessionId: session.sessionId,
          state: SessionExecutionState.idle,
          workItemId: null,
          requestId: null,
          revision: 2,
          updatedAt: DateTime.now().toUtc(),
        ),
      );

      expect(published, isEmpty);
      expect(harness.scheduler.consecutiveFailures(scheduleId), 0);
      expect(
        harness.sessionManager.db.scheduledTaskRuns.getRun(runId)!.status,
        ScheduledTaskRunStatus.succeeded,
      );

      await observer.dispose();
    });
  });
}
