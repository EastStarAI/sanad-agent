import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/devices/presentation/bloc/device_state.dart';
import 'package:sanad_client/features/schedules/domain/models/schedule_run_failure_notice.dart';
import 'package:sanad_client/features/schedules/presentation/schedules_chrome_scope.dart';

import '../../helpers/fake_device_repository.dart';
import '../../helpers/fake_socket.dart';
import '../../helpers/pump_app.dart';
import 'schedules_test_harness.dart';

/// The chrome's run-failure surface (Task 139 §Protocol → Failure surfacing,
/// S16, S22): a localized, non-modal notice for the affected schedule, carrying
/// the pause suggestion only when the Agent said the streak reached it, and no
/// error text at all.
void main() {
  late SchedulesTestEnvironment environment;
  late FakeSchedulesClient client;
  late FakeDeviceRepository deviceRepository;
  late TestDeviceCubit deviceCubit;

  setUp(() async {
    environment = SchedulesTestEnvironment();
    client = environment.client;
    await environment.install();
    deviceRepository = FakeDeviceRepository()
      ..seedAgents([deviceFixture()], activeAgentId: 'device-1');
    deviceCubit = TestDeviceCubit(
      socketService: FakeSanadSocketService(),
      agentRepository: deviceRepository,
      agentClientRegistry: FakeDeviceClientRegistry(),
    );
    deviceCubit.emitState(DeviceActive(activeAgent: deviceFixture(), agents: [deviceFixture()]));
  });

  tearDown(() async {
    await deviceCubit.close();
    await environment.dispose();
  });

  Future<void> pumpChrome(WidgetTester tester) async {
    await pumpTestApp(
      tester,
      agentCubit: deviceCubit,
      child: const SchedulesChromeScope(
        child: Scaffold(body: SizedBox.expand(key: Key('chrome_body'))),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a failed run shows a localized notice naming the schedule', (tester) async {
    await pumpChrome(tester);
    final l10n = await l10nFor('en');

    client.failuresController.add(
      const ScheduleRunFailureNotice(
        scheduleId: 'task_1',
        runId: 'run_1',
        scheduleName: 'Morning brief',
        sessionId: 'session-1',
        consecutiveFailures: 1,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('schedule_failure_notice')), findsOneWidget);
    expect(find.text(l10n.scheduleFailureNotice('Morning brief')), findsOneWidget);
    expect(find.byKey(const Key('schedule_failure_notice_suggestion')), findsNothing);
  });

  testWidgets('the pause suggestion appears only when the Agent suggests pausing', (tester) async {
    await pumpChrome(tester);
    final l10n = await l10nFor('en');

    client.failuresController.add(
      const ScheduleRunFailureNotice(
        scheduleId: 'task_1',
        runId: 'run_1',
        scheduleName: 'Morning brief',
        consecutiveFailures: 3,
        suggestPause: true,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('schedule_failure_notice_suggestion')), findsOneWidget);
    expect(find.text(l10n.scheduleFailureSuggestion), findsOneWidget);
  });

  testWidgets('a notice without a stored name falls back to the schedule identity', (tester) async {
    await pumpChrome(tester);
    final l10n = await l10nFor('en');

    client.failuresController.add(
      const ScheduleRunFailureNotice(scheduleId: 'task_9', runId: 'run_1'),
    );
    await tester.pumpAndSettle();

    expect(find.text(l10n.scheduleFailureNotice(l10n.scheduleDerivedLabel('task_9'))), findsOneWidget);
  });

  testWidgets('the chrome reads the list once for the active device', (tester) async {
    await pumpChrome(tester);

    expect(client.listCalls, ['device-1']);
    // The scope is what the sidebar marker and the delete warning read.
    expect(SchedulesScope.deviceIdOf(tester.element(find.byKey(const Key('chrome_body')))), 'device-1');
  });
}
