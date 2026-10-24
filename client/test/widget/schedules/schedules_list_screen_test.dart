import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/schedules/domain/models/schedule.dart';
import 'package:sanad_client/features/schedules/domain/models/schedule_error.dart';
import 'package:sanad_client/features/schedules/domain/models/schedule_run_failure_notice.dart';
import 'package:sanad_client/features/schedules/presentation/screens/schedules_screen.dart';

import '../../helpers/pump_app.dart';
import 'schedules_test_harness.dart';

void main() {
  late SchedulesTestEnvironment environment;
  late FakeSchedulesClient client;

  setUp(() async {
    environment = SchedulesTestEnvironment();
    client = environment.client;
    await environment.install();
  });

  tearDown(() async {
    await environment.dispose();
  });

  Future<void> pumpList(WidgetTester tester, {Locale locale = const Locale('en')}) async {
    await pumpSchedulesSurface(
      tester,
      const SchedulesScreen(deviceId: 'device-1'),
      locale: locale,
      cacheRepository: environment.cacheRepository,
      conversationRepository: environment.conversationRepository,
    );
  }

  group('states', () {
    testWidgets('a skeleton shows while the first read is in flight', (tester) async {
      client.schedules = [scheduleFixture()];
      client.listGate = Completer<void>();

      await pumpTestApp(tester, child: const SchedulesScreen(deviceId: 'device-1'));
      await tester.pump();

      expect(find.byKey(const Key('schedules_loading')), findsOneWidget);
      expect(find.byKey(const Key('schedules_list')), findsNothing);

      client.listGate!.complete();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('schedules_list')), findsOneWidget);
    });

    testWidgets('an empty device offers the create action', (tester) async {
      await pumpList(tester);
      final l10n = await l10nFor('en');

      expect(find.byKey(const Key('schedules_empty')), findsOneWidget);
      expect(find.text(l10n.scheduleEmpty), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byKey(const Key('schedules_empty_create_btn'))).onPressed,
        isNotNull,
      );
      // The create action opens the editor form for a new schedule.
      await tester.tap(find.byKey(const Key('schedules_create_btn')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('schedule_editor_sheet')), findsOneWidget);
    });

    testWidgets('a typed failure shows localized copy and Retry re-reads', (tester) async {
      client.listError = const ScheduleException(ScheduleErrorCode.internalError);
      await pumpList(tester);
      final l10n = await l10nFor('en');

      expect(find.byKey(const Key('schedules_error')), findsOneWidget);
      expect(find.text(l10n.scheduleLoadFailed), findsOneWidget);
      expect(find.text(l10n.scheduleErrorInternal), findsOneWidget);
      expect(client.listCalls, hasLength(1));

      client.listError = null;
      client.schedules = [scheduleFixture()];
      await tester.tap(find.byKey(const Key('schedules_retry_btn')));
      await tester.pumpAndSettle();

      expect(client.listCalls, hasLength(2));
      expect(find.byKey(const Key('schedules_list')), findsOneWidget);
    });

    testWidgets('an offline device shows the banner, no list, and no enabled action', (tester) async {
      environment.reseed([deviceFixture(isOnline: false)]);
      client.schedules = [scheduleFixture()];

      await pumpSchedulesSurface(
        tester,
        const SchedulesScreen(deviceId: 'device-1'),
        cacheRepository: environment.cacheRepository,
        conversationRepository: environment.conversationRepository,
      );
      final l10n = await l10nFor('en');

      expect(find.byKey(const Key('schedules_unavailable_banner')), findsOneWidget);
      expect(find.text(l10n.scheduleUnavailable), findsOneWidget);
      expect(find.byKey(const Key('schedules_list')), findsNothing);
      expect(
        tester.widget<FilledButton>(find.byKey(const Key('schedules_create_btn'))).onPressed,
        isNull,
      );
      expect(client.listCalls, isEmpty, reason: 'an offline device is never asked');
    });
  });

  group('availability (F3)', () {
    testWidgets('a deviceUnavailable state disables create while the device is online', (tester) async {
      // The inventory still reports the device online; the schedules transport has
      // already said it cannot answer. Both facts must close every action (S18).
      environment.reseed([deviceFixture()]);
      client.listError = const ScheduleException(ScheduleErrorCode.deviceUnavailable);

      await pumpList(tester);
      final l10n = await l10nFor('en');

      expect(find.byKey(const Key('schedules_unavailable_banner')), findsOneWidget);
      expect(find.text(l10n.scheduleUnavailable), findsOneWidget);
      expect(find.byKey(const Key('schedules_list')), findsNothing);
      expect(
        tester.widget<FilledButton>(find.byKey(const Key('schedules_create_btn'))).onPressed,
        isNull,
        reason: 'a device that cannot answer never offers the create action',
      );
      expect(find.byKey(const Key('schedules_empty_create_btn')), findsNothing);

      // Tapping it opens nothing.
      await tester.tap(find.byKey(const Key('schedules_create_btn')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('schedule_editor_sheet')), findsNothing);
    });
  });

  group('rows', () {
    testWidgets('a row shows its label, summary, next run, outcome and paused state', (tester) async {
      client.schedules = [
        scheduleFixture(
          enabled: false,
          lastOutcome: ScheduleLastOutcome.fired,
          lastRunAt: DateTime.utc(2026, 10, 24, 6),
        ),
      ];
      await pumpList(tester);
      final l10n = await l10nFor('en');

      expect(find.byKey(const Key('schedule_row_task_1')), findsOneWidget);
      expect(find.text('Morning brief'), findsOneWidget);
      expect(find.text('Daily at 9:00 AM'), findsOneWidget);
      expect(find.byKey(const Key('schedule_paused_pill_task_1')), findsOneWidget);
      expect(find.textContaining(l10n.scheduleLastOutcomeFired), findsOneWidget);
    });

    testWidgets('run now stays enabled on a paused row and never resumes it', (tester) async {
      client.schedules = [scheduleFixture(enabled: false)];
      await pumpList(tester);

      final runNow = find.byKey(const Key('schedule_run_now_btn_task_1'));
      expect(tester.widget<TextButton>(runNow).onPressed, isNotNull);
      expect(find.byKey(const Key('schedule_resume_btn_task_1')), findsOneWidget);

      await tester.tap(runNow);
      await tester.pumpAndSettle();

      expect(client.runNowCalls, ['task_1']);
      expect(client.resumeCalls, isEmpty, reason: 'a manual run never resumes the schedule');
      expect(client.pauseCalls, isEmpty);
    });

    testWidgets('an orphaned model-owned row offers edit and delete only', (tester) async {
      client.schedules = [
        scheduleFixture(
          ownerKind: ScheduleOwnerKind.model,
          ownerSessionId: null,
          ownerSessionTitle: null,
        ),
      ];
      await pumpList(tester);
      final l10n = await l10nFor('en');

      expect(find.byKey(const Key('schedule_edit_btn_task_1')), findsOneWidget);
      expect(find.byKey(const Key('schedule_delete_btn_task_1')), findsOneWidget);
      expect(find.byKey(const Key('schedule_run_now_btn_task_1')), findsNothing);
      expect(find.byKey(const Key('schedule_pause_btn_task_1')), findsNothing);
      expect(find.byKey(const Key('schedule_resume_btn_task_1')), findsNothing);
      expect(find.text(l10n.scheduleEdit), findsOneWidget);
    });

    testWidgets('pause and resume call the client once each', (tester) async {
      client.schedules = [scheduleFixture()];
      await pumpList(tester);

      // The Agent is authoritative: the mutation answer is not patched in, the
      // list is re-read, and that read reports the paused row.
      client.schedules = [scheduleFixture(enabled: false)];
      await tester.tap(find.byKey(const Key('schedule_pause_btn_task_1')));
      await tester.pumpAndSettle();
      expect(client.pauseCalls, ['task_1']);
      expect(client.listCalls, hasLength(2), reason: 'a mutation re-reads the list');

      await tester.tap(find.byKey(const Key('schedule_resume_btn_task_1')));
      await tester.pumpAndSettle();
      expect(client.resumeCalls, ['task_1']);
    });

    testWidgets('delete asks for confirmation and only then calls the device', (tester) async {
      client.schedules = [scheduleFixture()];
      await pumpList(tester);

      await tester.tap(find.byKey(const Key('schedule_delete_btn_task_1')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('schedule_delete_dialog')), findsOneWidget);
      expect(client.deleteCalls, isEmpty);

      await tester.tap(find.byKey(const Key('schedule_delete_cancel_btn')));
      await tester.pumpAndSettle();
      expect(client.deleteCalls, isEmpty);

      await tester.tap(find.byKey(const Key('schedule_delete_btn_task_1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('schedule_delete_confirm_btn')));
      await tester.pumpAndSettle();

      expect(client.deleteCalls, ['task_1']);
    });

    testWidgets('a refusal is shown as typed localized copy, never as Agent text', (tester) async {
      client.schedules = [scheduleFixture()];
      client.actionError = const ScheduleException(
        ScheduleErrorCode.scheduleOrphaned,
        scheduleId: 'task_1',
      );
      await pumpList(tester);
      final l10n = await l10nFor('en');

      await tester.tap(find.byKey(const Key('schedule_run_now_btn_task_1')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('schedule_action_failure_notice')), findsOneWidget);
      expect(find.text(l10n.scheduleErrorOrphaned), findsOneWidget);
    });
  });

  group('freshness (F5)', () {
    testWidgets('a run-failed notice re-reads the list once and the badge appears', (tester) async {
      client.schedules = [scheduleFixture(consecutiveFailures: 2)];
      await pumpList(tester);
      expect(client.listCalls, hasLength(1));
      expect(
        find.byKey(const Key('schedule_failure_badge_task_1')),
        findsNothing,
        reason: 'two failures are below the pause suggestion',
      );

      // The Agent has just recorded the third failure; the notice carries the
      // streak but the Client must ask for the authoritative row.
      client.schedules = [scheduleFixture(consecutiveFailures: 3)];
      client.failuresController.add(
        const ScheduleRunFailureNotice(
          scheduleId: 'task_1',
          runId: 'run_3',
          scheduleName: 'Morning brief',
          consecutiveFailures: 3,
        ),
      );
      await tester.pumpAndSettle();

      expect(client.listCalls, hasLength(2), reason: 'exactly one refresh per notice');
      final badge = find.byKey(const Key('schedule_failure_badge_task_1'));
      expect(badge, findsOneWidget);
      expect(find.descendant(of: badge, matching: find.text('3')), findsOneWidget);
    });
  });

  group('localization', () {
    testWidgets('the list renders right-to-left in Arabic', (tester) async {
      client.schedules = [scheduleFixture()];
      await pumpList(tester, locale: const Locale('ar'));
      final ar = await l10nFor('ar');

      expect(
        Directionality.of(tester.element(find.byKey(const Key('schedules_screen')))),
        TextDirection.rtl,
      );
      expect(find.text(ar.schedules), findsOneWidget);
      expect(find.text(ar.newSchedule), findsOneWidget);
      expect(find.text(ar.schedulePaused), findsNothing);
    });
  });
}
