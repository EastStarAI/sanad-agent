import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/sidebar/sidebar_conversation_row.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/sidebar/sidebar_sections.dart';
import 'package:sanad_client/features/schedules/presentation/bloc/schedules_cubit.dart';
import 'package:sanad_client/features/schedules/presentation/schedules_chrome_scope.dart';

import '../../helpers/pump_app.dart';
import 'schedules_test_harness.dart';

void main() {
  late SchedulesTestEnvironment environment;
  late FakeSchedulesClient client;
  late SchedulesCubit cubit;

  setUp(() async {
    environment = SchedulesTestEnvironment();
    client = environment.client;
    await environment.install();
    cubit = SchedulesCubit(client: client, device: () => deviceFixture());
  });

  tearDown(() async {
    await cubit.close();
    await environment.dispose();
  });

  /// A subtree that carries the chrome's schedules scope for `device-1`.
  Widget withScope(Widget child) {
    return SchedulesScope(deviceId: 'device-1', cubit: cubit, child: child);
  }

  Future<void> loadOwned() async {
    client.schedules = [
      scheduleFixture(id: 'task_1', ownerSessionId: 'session-1'),
      scheduleFixture(id: 'task_2', ownerSessionId: 'session-1'),
      scheduleFixture(id: 'task_3', ownerSessionId: 'session-2'),
      // A device-owned schedule has no conversation to mark.
      scheduleFixture(id: 'task_4', ownerSessionId: null, ownerSessionTitle: null),
    ];
    await cubit.load();
  }

  group('conversation marker', () {
    testWidgets('a conversation that owns schedules is marked, and only it', (tester) async {
      await loadOwned();
      await pumpTestApp(
        tester,
        locale: const Locale('en'),
        child: withScope(
          const Column(
            children: [
              ConversationScheduleMarker(deviceId: 'device-1', sessionId: 'session-1'),
              ConversationScheduleMarker(deviceId: 'device-1', sessionId: 'session-3'),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('schedule_marker_session-1')), findsOneWidget);
      expect(find.byKey(const Key('schedule_marker_session-3')), findsNothing);
    });

    testWidgets('the marker follows the snapshot when the list re-reads', (tester) async {
      await loadOwned();
      await pumpTestApp(
        tester,
        child: withScope(
          const ConversationScheduleMarker(deviceId: 'device-1', sessionId: 'session-2'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('schedule_marker_session-2')), findsOneWidget);

      client.schedules = [];
      await cubit.load();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('schedule_marker_session-2')), findsNothing);
    });

    testWidgets('a sidebar without a schedules scope renders no marker', (tester) async {
      await loadOwned();
      await pumpTestApp(
        tester,
        child: const ConversationScheduleMarker(deviceId: 'device-1', sessionId: 'session-1'),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('schedule_marker_session-1')), findsNothing);
    });
  });

  group('conversation delete warning', () {
    testWidgets('the decision is true only for a conversation that owns a schedule', (tester) async {
      await loadOwned();
      var owning = false;
      var foreign = true;
      var scoped = false;
      await pumpTestApp(
        tester,
        child: withScope(
          Builder(
            builder: (context) {
              owning = conversationOwnsSchedules(context, 'device-1', 'session-1');
              foreign = conversationOwnsSchedules(context, 'device-1', 'session-9');
              scoped = conversationOwnsSchedules(context, 'device-2', 'session-1');
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(owning, isTrue);
      expect(foreign, isFalse);
      expect(scoped, isFalse, reason: 'another device is never answered from this snapshot');
    });

    testWidgets('the dialog warning renders only when schedules depend on the conversation', (
      tester,
    ) async {
      await pumpTestApp(
        tester,
        child: const Column(
          children: [
            ConversationDeleteWarning(hasOwnedSchedules: true),
            ConversationDeleteWarning(key: Key('no_warning'), hasOwnedSchedules: false),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('conversation_delete_schedules_warning')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('no_warning')),
          matching: find.byKey(const Key('conversation_delete_schedules_warning')),
        ),
        findsNothing,
      );
    });
  });

  group('sidebar row', () {
    testWidgets('the Schedules row navigates to the device page', (tester) async {
      var opened = 0;
      await pumpTestApp(
        tester,
        child: SidebarSchedulesRow(onOpen: () => opened++),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('schedules_sidebar_row')), findsOneWidget);
      await tester.tap(find.byKey(const Key('schedules_sidebar_row')));
      await tester.pumpAndSettle();
      expect(opened, 1);
    });
  });
}
