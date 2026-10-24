import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/core/navigation/app_router.dart';
import 'package:sanad_client/core/navigation/app_routes.dart';
import 'package:sanad_client/features/auth/domain/auth_repository.dart';
import 'package:sanad_client/features/auth/presentation/bloc/auth_cubit.dart';
import 'package:sanad_client/features/auth/presentation/bloc/auth_state.dart';
import 'package:sanad_client/features/home/presentation/screens/home_screen.dart';
import 'package:sanad_client/features/schedules/presentation/screens/schedules_route_surface.dart';
import 'package:sanad_client/utils/app_platform.dart';


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

    test('the default builders host both routes in the device chrome', () {
      // A Schedules route renders inside the real sidebar, which needs
      // HomeScreen's provider tree, so the route builds the chrome and hands it
      // the schedules surface instead of a standalone page (Task 139 C1).
      final list = AppRouter.buildSchedulesPage(deviceId: 'device-1');
      final detail = AppRouter.buildScheduleDetailPage(deviceId: 'device-1', scheduleId: 'task_9');

      expect(list, isA<HomeScreen>());
      final listSurface = (list as HomeScreen).deviceContent;
      expect(listSurface, isA<SchedulesRouteSurface>());
      expect((listSurface as SchedulesRouteSurface).deviceId, 'device-1');
      expect(listSurface.scheduleId, isNull);

      expect(detail, isA<HomeScreen>());
      final detailSurface = (detail as HomeScreen).deviceContent;
      expect(detailSurface, isA<SchedulesRouteSurface>());
      expect((detailSurface as SchedulesRouteSurface).deviceId, 'device-1');
      expect(detailSurface.scheduleId, 'task_9');
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

    testWidgets('the schedules path is still never read as a session id', (tester) async {
      var sessionId = '';
      final setup = AppRouter.createRouter(
        authCubit,
        initialLocation: AppRoutes.schedulesLocation('agent-123'),
        builders: AppRouterBuilders(
          homeBuilder: (context, state) {
            sessionId = state.pathParameters['sessionId'] ?? 'session-was-matched';
            return const Text('session', textDirection: TextDirection.ltr);
          },
          schedulesBuilder: (context, state) => const Text('schedules', textDirection: TextDirection.ltr),
        ),
      );

      await tester.pumpWidget(MaterialApp.router(routerConfig: setup.router));
      await tester.pumpAndSettle();

      expect(find.text('schedules'), findsOneWidget);
      expect(sessionId, isEmpty);
    });
  });
}
