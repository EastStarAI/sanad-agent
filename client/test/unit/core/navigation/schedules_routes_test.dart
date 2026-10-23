import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/core/di/injection.dart';
import 'package:sanad_client/core/navigation/app_router.dart';
import 'package:sanad_client/core/navigation/app_routes.dart';
import 'package:sanad_client/features/auth/domain/auth_repository.dart';
import 'package:sanad_client/features/auth/presentation/bloc/auth_cubit.dart';
import 'package:sanad_client/features/auth/presentation/bloc/auth_state.dart';
import 'package:sanad_client/features/devices/domain/device_repository.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/schedules/data/schedules_client.dart';
import 'package:sanad_client/features/schedules/domain/models/schedule.dart';
import 'package:sanad_client/features/schedules/domain/models/schedule_run.dart';
import 'package:sanad_client/features/schedules/domain/models/schedule_run_failure_notice.dart';
import 'package:sanad_client/features/schedules/presentation/screens/schedule_detail_screen.dart';
import 'package:sanad_client/features/schedules/presentation/screens/schedules_screen.dart';
import 'package:sanad_client/utils/app_platform.dart';

import '../../../helpers/fake_device_repository.dart';

class _FakeAuthCubit extends AuthCubit {
  _FakeAuthCubit() : super(authRepository: _FakeAuthRepository());

  final StreamController<AuthState> _stateController = StreamController<AuthState>.broadcast();
  AuthState _state = AuthInitial();

  @override
  AuthState get state => _state;

  @override
  Stream<AuthState> get stream => _stateController.stream;

  void emitState(AuthState newState) {
    _state = newState;
    _stateController.add(newState);
  }

  @override
  Future<void> close() async {
    await _stateController.close();
    return super.close();
  }
}

class _FakeAuthRepository implements IAuthRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Records the device it was asked about and answers with one schedule.
class _RecordingSchedulesClient implements SchedulesClient {
  final listCalls = <String>[];
  final runsCalls = <String>[];

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
  Stream<void> changes(DeviceConfig device) => const Stream<void>.empty();

  @override
  Stream<ScheduleRunFailureNotice> runFailures(DeviceConfig device) =>
      const Stream<ScheduleRunFailureNotice>.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

AuthState _authenticatedState() => const AuthAuthenticated(
  username: 'test',
  email: 'test@example.com',
  userId: 'user1',
  accessToken: 'token',
  userCredits: 100.0,
  totalCredits: 100.0,
);

void main() {
  late _FakeAuthCubit authCubit;

  setUp(() {
    authCubit = _FakeAuthCubit();
    authCubit.emitState(_authenticatedState());
    AppPlatform.overrideIsDesktop = false;
  });

  tearDown(() async {
    await authCubit.close();
    AppPlatform.overrideIsDesktop = null;
  });

  group('route constants and builders', () {
    test('the schedule routes live under the device conversation scope', () {
      expect(AppRoutes.schedules, '/conversations/:deviceId/schedules');
      expect(AppRoutes.scheduleDetail, '/conversations/:deviceId/schedules/:scheduleId');
    });

    test('path builders produce the canonical locations', () {
      expect(AppRoutes.schedulesLocation('device-1'), '/conversations/device-1/schedules');
      expect(
        AppRoutes.scheduleDetailLocation('device-1', 'task_9'),
        '/conversations/device-1/schedules/task_9',
      );
    });

    test('the default builders point at the two thin shells', () {
      final list = AppRouter.buildSchedulesPage(deviceId: 'device-1');
      final detail = AppRouter.buildScheduleDetailPage(deviceId: 'device-1', scheduleId: 'task_9');

      expect(list, isA<SchedulesScreen>());
      expect((list as SchedulesScreen).deviceId, 'device-1');
      expect(detail, isA<ScheduleDetailScreen>());
      expect((detail as ScheduleDetailScreen).deviceId, 'device-1');
      expect(detail.scheduleId, 'task_9');
    });
  });

  group('route resolution', () {
    testWidgets('the list path resolves with its deviceId and is not read as a session id', (tester) async {
      var sessionsListed = false;
      final built = <String>[];
      final setup = AppRouter.createRouter(
        authCubit,
        initialLocation: AppRoutes.schedulesLocation('agent-123'),
        builders: AppRouterBuilders(
          homeBuilder: (context, state) {
            sessionsListed = true;
            return const Text('session', textDirection: TextDirection.ltr);
          },
          schedulesBuilder: (context, state) {
            built.add('schedules:${state.pathParameters['deviceId']}');
            return const SizedBox.shrink();
          },
        ),
      );

      await tester.pumpWidget(MaterialApp.router(routerConfig: setup.router));
      await tester.pumpAndSettle();

      expect(built, ['schedules:agent-123']);
      expect(sessionsListed, isFalse);
    });

    testWidgets('the detail path resolves with its deviceId and scheduleId', (tester) async {
      final built = <String>[];
      final setup = AppRouter.createRouter(
        authCubit,
        initialLocation: AppRoutes.scheduleDetailLocation('agent-123', 'task_9'),
        builders: AppRouterBuilders(
          scheduleDetailBuilder: (context, state) {
            built.add('detail:${state.pathParameters['deviceId']}:${state.pathParameters['scheduleId']}');
            return const SizedBox.shrink();
          },
        ),
      );

      await tester.pumpWidget(MaterialApp.router(routerConfig: setup.router));
      await tester.pumpAndSettle();

      expect(built, ['detail:agent-123:task_9']);
    });

    testWidgets('a session path still resolves to the conversation surface', (tester) async {
      var sessionId = '';
      final setup = AppRouter.createRouter(
        authCubit,
        initialLocation: AppRoutes.sessionLocation('agent-123', 'session-456'),
        builders: AppRouterBuilders(
          homeBuilder: (context, state) {
            sessionId = state.pathParameters['sessionId'] ?? '';
            return const Text('session', textDirection: TextDirection.ltr);
          },
          schedulesBuilder: (context, state) => const Text('schedules', textDirection: TextDirection.ltr),
        ),
      );

      await tester.pumpWidget(MaterialApp.router(routerConfig: setup.router));
      await tester.pumpAndSettle();

      expect(sessionId, 'session-456');
    });

    testWidgets('the default schedule paths render the shells with the route device', (tester) async {
      final client = _RecordingSchedulesClient();
      final repository = FakeDeviceRepository()
        ..seedAgents(
          [DeviceConfig(id: 'device-1', name: 'Laptop', hardwareId: 'hw-1', isOnline: true)],
          activeAgentId: 'device-1',
        );
      getIt.registerSingleton<IDeviceRepository>(repository);
      getIt.registerSingleton<SchedulesClient>(client);
      addTearDown(() async {
        await getIt.unregister<IDeviceRepository>();
        await getIt.unregister<SchedulesClient>();
      });

      final detailSetup = AppRouter.createRouter(
        authCubit,
        initialLocation: AppRoutes.scheduleDetailLocation('device-1', 'task_9'),
      );
      await tester.pumpWidget(MaterialApp.router(routerConfig: detailSetup.router));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('schedule_detail_screen')), findsOneWidget);
      expect(client.listCalls, ['device-1']);
      expect(client.runsCalls, ['task_9']);
    });
  });
}
