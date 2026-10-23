import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/core/di/injection.dart';
import 'package:sanad_client/features/devices/domain/device_repository.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/schedules/data/schedules_client.dart';
import 'package:sanad_client/features/schedules/domain/models/schedule.dart';
import 'package:sanad_client/features/schedules/domain/models/schedule_preview.dart';
import 'package:sanad_client/features/schedules/domain/models/schedule_request.dart';
import 'package:sanad_client/features/schedules/domain/models/schedule_run.dart';
import 'package:sanad_client/features/schedules/domain/models/schedule_run_failure_notice.dart';
import 'package:sanad_client/features/schedules/presentation/screens/schedule_detail_screen.dart';
import 'package:sanad_client/features/schedules/presentation/screens/schedules_screen.dart';

import '../../helpers/fake_device_repository.dart';

class _ScriptedClient implements SchedulesClient {
  final listCalls = <String>[];
  final runsCalls = <String>[];
  final changesController = StreamController<void>.broadcast();
  final failuresController = StreamController<ScheduleRunFailureNotice>.broadcast();

  @override
  Future<SchedulesSnapshot> list(DeviceConfig device) async {
    listCalls.add(device.id);
    return const SchedulesSnapshot(schedules: []);
  }

  @override
  Future<ScheduleRunsPage> runs(
    DeviceConfig device, {
    required String scheduleId,
    int? limit,
    String? cursor,
  }) async {
    runsCalls.add(scheduleId);
    return ScheduleRunsPage(scheduleId: scheduleId, runs: const []);
  }

  @override
  Future<SchedulePreview> preview(DeviceConfig device, ScheduleDefinitionInput definition) =>
      throw UnimplementedError();

  @override
  Stream<void> changes(DeviceConfig device) => changesController.stream;

  @override
  Stream<ScheduleRunFailureNotice> runFailures(DeviceConfig device) => failuresController.stream;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _ScriptedClient client;
  late FakeDeviceRepository repository;

  setUp(() {
    client = _ScriptedClient();
    repository = FakeDeviceRepository()
      ..seedAgents(
        [DeviceConfig(id: 'device-1', name: 'Laptop', hardwareId: 'hw-1', isOnline: true)],
        activeAgentId: 'device-1',
      );
    getIt.registerSingleton<IDeviceRepository>(repository);
    getIt.registerSingleton<SchedulesClient>(client);
  });

  tearDown(() async {
    await getIt.unregister<IDeviceRepository>();
    await getIt.unregister<SchedulesClient>();
    await client.changesController.close();
    await client.failuresController.close();
  });

  Future<void> pumpScreen(WidgetTester tester, Widget screen) async {
    await tester.pumpWidget(MaterialApp(home: screen));
    await tester.pumpAndSettle();
  }

  testWidgets('the list shell reads once and a rebuild issues no second request', (tester) async {
    await pumpScreen(tester, const SchedulesScreen(deviceId: 'device-1'));

    expect(find.byKey(const Key('schedules_screen')), findsOneWidget);
    expect(client.listCalls, ['device-1']);

    tester.widget(find.byKey(const Key('schedules_screen')));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(client.listCalls, ['device-1'], reason: 'a rebuild is not a fetch intent');
  });

  testWidgets('a schedule.changed broadcast refreshes through the page cubit', (tester) async {
    await pumpScreen(tester, const SchedulesScreen(deviceId: 'device-1'));
    expect(client.listCalls, hasLength(1));

    client.changesController.add(null);
    await tester.pumpAndSettle();

    expect(client.listCalls, hasLength(2));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(client.changesController.hasListener, isFalse);
  });

  testWidgets('a route device outside the inventory issues no request', (tester) async {
    await pumpScreen(tester, const SchedulesScreen(deviceId: 'device-unknown'));

    expect(find.byKey(const Key('schedules_screen')), findsOneWidget);
    expect(client.listCalls, isEmpty);
  });

  testWidgets('the detail shell reads the list and the run history once', (tester) async {
    await pumpScreen(
      tester,
      const ScheduleDetailScreen(deviceId: 'device-1', scheduleId: 'task_9'),
    );

    expect(find.byKey(const Key('schedule_detail_screen')), findsOneWidget);
    expect(client.listCalls, ['device-1']);
    expect(client.runsCalls, ['task_9']);
  });
}
