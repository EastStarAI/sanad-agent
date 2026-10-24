import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:sanad_client/core/navigation/app_routes.dart';
import 'package:sanad_client/features/schedules/domain/models/schedule_error.dart';
import 'package:sanad_client/features/schedules/domain/models/schedule_run.dart';
import 'package:sanad_client/features/schedules/domain/models/schedule_run_failure_notice.dart';
import 'package:sanad_client/features/schedules/presentation/screens/schedule_detail_screen.dart';

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

  Future<GoRouter> pumpDetail(
    WidgetTester tester, {
    Locale locale = const Locale('en'),
    String scheduleId = 'task_1',
  }) async {
    final router = GoRouter(
      initialLocation: '/conversations/device-1/schedules/$scheduleId',
      routes: [
        GoRoute(
          path: AppRoutes.scheduleDetail,
          builder: (context, state) => ScheduleDetailScreen(
            deviceId: state.pathParameters['deviceId'] ?? '',
            scheduleId: state.pathParameters['scheduleId'] ?? '',
          ),
        ),
        GoRoute(
          path: AppRoutes.session,
          builder: (context, state) => Text(
            'session:${state.pathParameters['sessionId']}',
            textDirection: TextDirection.ltr,
          ),
        ),
      ],
    );
    await pumpTestApp(
      tester,
      child: const SizedBox.shrink(),
      router: router,
      locale: locale,
      conversationCacheRepository: environment.cacheRepository,
      conversationRepository: environment.conversationRepository,
    );
    await tester.pumpAndSettle();
    return router;
  }

  group('tabs', () {
    testWidgets('the details tab presents the owner, recurrence and stored route', (tester) async {
      client.schedules = [scheduleFixture(workspaceId: 'ws-1')];
      await pumpDetail(tester);
      final l10n = await l10nFor('en');

      expect(find.byKey(const Key('schedule_detail_screen')), findsOneWidget);
      expect(find.byKey(const Key('schedule_detail_details_tab')), findsOneWidget);
      expect(find.text(l10n.scheduleOwner), findsOneWidget);
      expect(find.text(l10n.scheduleOwnedByConversation('Morning brief runs')), findsOneWidget);
      expect(find.text(l10n.scheduleConversationMode), findsOneWidget);
      expect(find.text(l10n.scheduleModeContinuous), findsOneWidget);
      expect(find.text('ws-1'), findsOneWidget);
      expect(find.text('provider-1 / gpt-4o'), findsOneWidget);
      // Every action of the row is offered here too.
      expect(find.byKey(const Key('schedule_run_now_btn_task_1')), findsOneWidget);
      expect(find.byKey(const Key('schedule_delete_btn_task_1')), findsOneWidget);
    });

    testWidgets('the run history tab lists each run with its status and duration', (tester) async {
      client.schedules = [scheduleFixture()];
      client.runsBySchedule = {
        'task_1': [
          runFixture(id: 'run_1', status: ScheduleRunStatus.succeeded, durationMs: 8400),
          runFixture(
            id: 'run_2',
            status: ScheduleRunStatus.failed,
            durationMs: 1500,
            error: 'provider refused the request',
            hasPosition: false,
          ),
          runFixture(id: 'run_3', status: ScheduleRunStatus.running, durationMs: null),
        ],
      };
      await pumpDetail(tester);
      final l10n = await l10nFor('en');

      await tester.tap(find.byKey(const Key('schedule_run_history_tab_btn')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('schedule_detail_runs_tab')), findsOneWidget);
      expect(find.text(l10n.scheduleRunStatusSucceeded), findsOneWidget);
      expect(find.text(l10n.scheduleRunStatusFailed), findsOneWidget);
      expect(find.text(l10n.scheduleRunStatusRunning), findsOneWidget);
      expect(find.textContaining('${l10n.scheduleDuration}: 8s'), findsOneWidget);
      expect(find.text('provider refused the request'), findsOneWidget);
      expect(find.text(l10n.scheduleRunTriggerManual), findsNothing);
    });

    testWidgets('load more uses the cursor the Agent minted', (tester) async {
      client.schedules = [scheduleFixture()];
      client.runsBySchedule = {
        'task_1': [runFixture()],
      };
      client
        ..hasMoreRuns = true
        ..nextRunCursor = 'cursor-2'
        ..nextPageRuns = [runFixture(id: 'run_2', hasPosition: false)];
      await pumpDetail(tester);

      await tester.tap(find.byKey(const Key('schedule_run_history_tab_btn')));
      await tester.pumpAndSettle();
      expect(client.runsCursors, [null]);

      await tester.tap(find.byKey(const Key('schedule_runs_load_more_btn')));
      await tester.pumpAndSettle();
      expect(client.runsCursors, [null, 'cursor-2']);
    });
  });

  group('availability and freshness', () {
    testWidgets('the same unavailable state closes the detail actions', (tester) async {
      // The device reports online while the schedules transport reports it cannot
      // answer: the detail must show the banner and offer nothing (S18).
      environment.reseed([deviceFixture()]);
      client.listError = const ScheduleException(ScheduleErrorCode.deviceUnavailable);

      await pumpDetail(tester);
      final l10n = await l10nFor('en');

      expect(find.byKey(const Key('schedules_unavailable_banner')), findsOneWidget);
      expect(find.text(l10n.scheduleUnavailable), findsOneWidget);
      expect(find.byKey(const Key('schedule_run_now_btn_task_1')), findsNothing);
      expect(find.byKey(const Key('schedule_delete_btn_task_1')), findsNothing);
      expect(find.byKey(const Key('schedule_detail_runs_tab')), findsNothing);
    });

    testWidgets('a notice for the open schedule re-reads its run page', (tester) async {
      client.schedules = [scheduleFixture()];
      client.runsBySchedule = {
        'task_1': [runFixture(id: 'run_1')],
      };
      await pumpDetail(tester);
      expect(client.listCalls, hasLength(1));
      expect(client.runsCalls, ['task_1']);

      client.failuresController.add(
        const ScheduleRunFailureNotice(
          scheduleId: 'task_1',
          runId: 'run_2',
          consecutiveFailures: 3,
          suggestPause: true,
        ),
      );
      await tester.pumpAndSettle();

      expect(client.listCalls, hasLength(2), reason: 'the streak lives in the list');
      expect(client.runsCalls, ['task_1', 'task_1'], reason: 'the terminal run row is on this page');

      // Another schedule's failure refreshes the list but must not re-page a
      // history this page is not showing.
      client.failuresController.add(
        const ScheduleRunFailureNotice(scheduleId: 'task_9', runId: 'run_9'),
      );
      await tester.pumpAndSettle();

      expect(client.listCalls, hasLength(3));
      expect(client.runsCalls, ['task_1', 'task_1']);
    });
  });

  group('open conversation', () {
    testWidgets('a run position lands on its own user message', (tester) async {
      client.schedules = [scheduleFixture()];
      client.runsBySchedule = {
        'task_1': [
          runFixture(id: 'run_1', sessionId: 'session-1', messageId: 'msg_42', hasPosition: true),
        ],
      };
      final router = await pumpDetail(tester);

      await tester.tap(find.byKey(const Key('schedule_run_history_tab_btn')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('schedule_open_conversation_btn_run_1')));
      await tester.pumpAndSettle();

      expect(
        environment.cacheRepository.sessionViewportAnchor('device-1', 'session-1'),
        'msg_42',
        reason: "has_position means the run's user message is the anchor",
      );
      expect(router.state.matchedLocation, '/conversations/device-1/session-1');
      expect(find.text('session:session-1'), findsOneWidget);
    });

    testWidgets('a run without a position opens the conversation itself', (tester) async {
      client.schedules = [scheduleFixture()];
      client.runsBySchedule = {
        'task_1': [
          runFixture(id: 'run_1', sessionId: 'session-1', messageId: null, hasPosition: false),
        ],
      };
      final router = await pumpDetail(tester);

      await tester.tap(find.byKey(const Key('schedule_run_history_tab_btn')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('schedule_open_conversation_btn_run_1')));
      await tester.pumpAndSettle();

      expect(environment.cacheRepository.sessionViewportAnchor('device-1', 'session-1'), isNull);
      expect(router.state.matchedLocation, '/conversations/device-1/session-1');
    });
  });

  group('localization', () {
    testWidgets('the detail and its run history render right-to-left in Arabic', (tester) async {
      client.schedules = [scheduleFixture()];
      client.runsBySchedule = {
        'task_1': [runFixture(status: ScheduleRunStatus.failed, error: 'refused')],
      };
      await pumpDetail(tester, locale: const Locale('ar'));
      final ar = await l10nFor('ar');

      expect(
        Directionality.of(tester.element(find.byKey(const Key('schedule_detail_screen')))),
        TextDirection.rtl,
      );
      expect(find.text(ar.scheduleDetails), findsOneWidget);

      await tester.tap(find.byKey(const Key('schedule_run_history_tab_btn')));
      await tester.pumpAndSettle();

      expect(find.text(ar.scheduleRunStatusFailed), findsOneWidget);
      expect(
        Directionality.of(tester.element(find.byKey(const Key('schedule_detail_runs_tab')))),
        TextDirection.rtl,
      );
    });
  });
}
