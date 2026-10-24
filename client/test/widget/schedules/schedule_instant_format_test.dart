import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/schedules/domain/models/schedule.dart';
import 'package:sanad_client/features/schedules/domain/models/schedule_instant.dart';
import 'package:sanad_client/features/schedules/presentation/screens/schedules_screen.dart';
import 'package:sanad_client/features/schedules/presentation/widgets/schedule_format.dart';

import '../../helpers/pump_app.dart';
import 'schedules_test_harness.dart';

/// `local` means the **Agent's** local zone (Task 139 F4).
///
/// The Agent writes `next_run_at` with the offset it computed in
/// (`2026-10-24T09:00:00+03:00`), so a remote device's 09:00 must render as 09:00
/// on a Client in another timezone. `last_run_at` and `run_at` travel as UTC, so
/// the schedule row's own designator is the offset those render in.
void main() {
  group('wire instants', () {
    test('the offset token survives parsing and the value stays UTC', () {
      final parsed = ScheduleInstant.tryParse('2026-10-24T09:00:00+03:00');

      expect(parsed, isNotNull);
      expect(parsed!.instant, DateTime.utc(2026, 10, 24, 6));
      expect(parsed.offset, '+03:00');
    });

    test('a UTC designator is kept as the zero offset', () {
      expect(ScheduleInstant.tryParse('2026-10-24T06:00:00Z')!.offset, 'Z');
    });

    test('a value without an offset keeps a null offset instead of guessing', () {
      expect(ScheduleInstant.tryParse('2026-10-24T06:00:00')!.offset, isNull);
      expect(ScheduleInstant.tryParse(null), isNull);
      expect(ScheduleInstant.tryParse(''), isNull);
    });

    test('the row model round-trips the wire offset', () {
      final schedule = Schedule.fromJson({
        'id': 'task_1',
        'task': 'Do it',
        'kind': 'daily',
        'at_time': '09:00',
        'zone': 'local',
        'enabled': true,
        'owner_kind': 'user',
        'conversation_mode': 'continuous',
        'next_run_at': '2026-10-24T09:00:00+03:00',
        'last_run_at': '2026-10-23T09:00:04Z',
      });

      expect(schedule.nextRunAt, DateTime.utc(2026, 10, 24, 6));
      expect(schedule.nextRunAtOffset, '+03:00');
      // `last_run_at` arrives as UTC by protocol, so only the value is kept.
      expect(schedule.lastRunAt, DateTime.utc(2026, 10, 23, 9, 0, 4));
    });
  });

  group('wall clock', () {
    final instant = DateTime.utc(2026, 10, 24, 6);

    test('a local zone renders in the offset the Agent wrote', () {
      final wallClock = scheduleWallClock(instant, zone: 'local', wireOffset: '+03:00');

      expect(wallClock.hour, 9);
      expect(wallClock.minute, 0);
    });

    test('an explicit zone keeps its own offset', () {
      final wallClock = scheduleWallClock(instant, zone: '+03:00', wireOffset: '+05:00');

      expect(wallClock.hour, 9, reason: 'the stored zone wins over the wire designator');
    });

    test('a negative offset and a UTC designator both resolve', () {
      expect(scheduleWallClock(instant, zone: 'local', wireOffset: '-05:00').hour, 1);
      expect(scheduleWallClock(instant, zone: 'local', wireOffset: 'Z').hour, 6);
    });

    test('the zone token is parsed with or without a colon', () {
      expect(parseScheduleWireOffset('+0330'), const Duration(hours: 3, minutes: 30));
      expect(parseScheduleWireOffset('+03:30'), const Duration(hours: 3, minutes: 30));
      expect(parseScheduleWireOffset('local'), isNull);
    });
  });

  group('rendered surfaces', () {
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

    Future<void> pumpList(WidgetTester tester) async {
      await pumpTestApp(
        tester,
        child: const SchedulesScreen(deviceId: 'device-1'),
        conversationCacheRepository: environment.cacheRepository,
        conversationRepository: environment.conversationRepository,
      );
      await tester.pumpAndSettle();
    }

    testWidgets('a local-zone row renders 09:00, not the UTC 06:00', (tester) async {
      client.schedules = [
        scheduleFixture(
          zone: 'local',
          nextRunAt: DateTime.utc(2026, 10, 25, 6),
          nextRunAtOffset: '+03:00',
        ),
      ];
      await pumpList(tester);
      final l10n = await l10nFor('en');

      expect(
        find.text(l10n.scheduleInstantWithZone('Sun, Oct 25 9:00 AM', 'local')),
        findsOneWidget,
      );
      expect(find.textContaining('6:00 AM'), findsNothing);
    });

    testWidgets('an explicit-zone row still renders its own wall clock', (tester) async {
      client.schedules = [
        scheduleFixture(
          zone: '+03:00',
          nextRunAt: DateTime.utc(2026, 10, 25, 6),
          nextRunAtOffset: '+03:00',
        ),
      ];
      await pumpList(tester);
      final l10n = await l10nFor('en');

      expect(
        find.text(l10n.scheduleInstantWithZone('Sun, Oct 25 9:00 AM', '+03:00')),
        findsOneWidget,
      );
    });

    testWidgets('a local-zone last run uses the row designator for its UTC instant', (tester) async {
      client.schedules = [
        scheduleFixture(
          zone: 'local',
          nextRunAtOffset: '+03:00',
          lastRunAt: DateTime.utc(2026, 10, 24, 6),
          lastOutcome: ScheduleLastOutcome.fired,
        ),
      ];
      await pumpList(tester);
      final l10n = await l10nFor('en');

      expect(
        find.textContaining('${l10n.scheduleLastOutcomeFired} · Sat, Oct 24 9:00 AM'),
        findsOneWidget,
      );
    });
  });
}
