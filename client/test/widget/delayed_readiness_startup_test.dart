import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/core/presentation/widgets/app_progress_indicator.dart';
import 'package:sanad_client/core/di/injection.dart';
import 'package:sanad_client/features/auth/presentation/bloc/auth_cubit.dart';
import 'package:sanad_client/features/auth/presentation/bloc/auth_state.dart';
import 'package:sanad_client/features/devices/data/device_connection_coordinator.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/devices/domain/models/gateway_connection_status.dart';
import 'package:sanad_client/features/devices/presentation/bloc/device_cubit.dart';
import 'package:sanad_client/features/devices/presentation/bloc/device_state.dart';
import 'package:sanad_client/features/devices/presentation/bloc/gateway_connection_cubit.dart';
import 'package:sanad_client/features/devices/presentation/screens/onboarding_setup_screen.dart';
import 'package:sanad_client/features/provider_setup/data/models/provider_readiness_dto.dart';
import 'package:sanad_client/features/provider_setup/data/provider_setup_client.dart';

class _FakeProviderSetupClient extends Fake implements ProviderSetupClient {
  Completer<ProviderReadinessDto>? runtimeCheckCompleter;
  int runtimeCheckCount = 0;

  @override
  Future<ProviderReadinessDto> runtimeCheck({DeviceConfig? agent}) {
    runtimeCheckCount++;
    if (runtimeCheckCompleter != null) {
      return runtimeCheckCompleter!.future;
    }
    return Future.value(
      const ProviderReadinessDto(
        hasProvider: true,
        runtimeReady: true,
      ),
    );
  }
}

class _FakeDeviceConnectionCoordinator extends Fake implements DeviceConnectionCoordinator {
  @override
  String get expectedVersion => '1.0.10';
}

class _MockAuthCubit extends Fake implements AuthCubit {
  final _controller = StreamController<AuthState>.broadcast();
  AuthState _state = AuthUnauthenticated();

  @override
  AuthState get state => _state;

  @override
  Stream<AuthState> get stream => _controller.stream;

  void emitState(AuthState state) {
    _state = state;
    _controller.add(state);
  }
}

class _MockGatewayConnectionCubit extends Fake implements GatewayConnectionCubit {
  final _controller = StreamController<GatewayConnectionStatus>.broadcast();
  GatewayConnectionStatus _state = const GatewayConnectionStatus.initial();

  @override
  GatewayConnectionStatus get state => _state;

  @override
  Stream<GatewayConnectionStatus> get stream => _controller.stream;

  void emitState(GatewayConnectionStatus state) {
    _state = state;
    _controller.add(state);
  }
}

class _MockDeviceCubit extends Fake implements DeviceCubit {
  final _controller = StreamController<DeviceState>.broadcast();
  DeviceState _state = const DeviceNoActive();

  @override
  DeviceState get state => _state;

  @override
  Stream<DeviceState> get stream => _controller.stream;

  void emitState(DeviceState state) {
    _state = state;
    _controller.add(state);
  }

  @override
  Future<List<DeviceConfig>> fetchAgents() async => const [];
}

void main() {
  late _FakeProviderSetupClient fakeSetupClient;
  late _MockAuthCubit mockAuthCubit;
  late _MockGatewayConnectionCubit mockGatewayCubit;
  late _MockDeviceCubit mockDeviceCubit;

  setUp(() async {
    await getIt.reset();
    fakeSetupClient = _FakeProviderSetupClient();
    mockAuthCubit = _MockAuthCubit();
    mockGatewayCubit = _MockGatewayConnectionCubit();
    mockDeviceCubit = _MockDeviceCubit();

    getIt.registerSingleton<ProviderSetupClient>(fakeSetupClient);
    getIt.registerSingleton<DeviceConnectionCoordinator>(
      _FakeDeviceConnectionCoordinator(),
    );
  });

  tearDown(() async {
    await getIt.reset();
  });

  Widget createSubject() {
    return MultiBlocProvider(
      providers: [
        BlocProvider<AuthCubit>.value(value: mockAuthCubit),
        BlocProvider<GatewayConnectionCubit>.value(value: mockGatewayCubit),
        BlocProvider<DeviceCubit>.value(value: mockDeviceCubit),
      ],
      child: const MaterialApp(
        home: OnboardingSetupScreen(),
      ),
    );
  }

  testWidgets(
    'onboarding screen with delayed readiness check renders neutral checking UI without flashing setup choices',
    (tester) async {
      final completer = Completer<ProviderReadinessDto>();
      fakeSetupClient.runtimeCheckCompleter = completer;

      // Local gateway is connected
      mockGatewayCubit.emitState(
        const GatewayConnectionStatus(
          localGateway: LocalGatewayStatus.connected,
          sanadGateway: SanadGatewayStatus.disconnected,
          isDesktop: true,
          actions: [],
          recommendedRoute: '/onboarding',
        ),
      );

      await tester.pumpWidget(createSubject());
      await tester.pump();

      // Proves: neutral checking UI is rendered, not the setup choices or "No provider" flash
      expect(find.text('Checking provider readiness...'), findsOneWidget);
      expect(find.byType(AppProgressIndicator), findsOneWidget);
      expect(find.text('Run Sanad Locally'), findsNothing);

      // Now complete the readiness check with ready=true
      completer.complete(
        const ProviderReadinessDto(
          hasProvider: true,
          runtimeReady: true,
        ),
      );
      await tester.pumpAndSettle();

      // Check finished without flash
      expect(fakeSetupClient.runtimeCheckCount, 1);
    },
  );

  testWidgets(
    'onboarding screen on check error does not trap into setup flow',
    (tester) async {
      final completer = Completer<ProviderReadinessDto>();
      fakeSetupClient.runtimeCheckCompleter = completer;

      mockGatewayCubit.emitState(
        const GatewayConnectionStatus(
          localGateway: LocalGatewayStatus.connected,
          sanadGateway: SanadGatewayStatus.disconnected,
          isDesktop: true,
          actions: [],
          recommendedRoute: '/onboarding',
        ),
      );

      await tester.pumpWidget(createSubject());
      await tester.pump();

      expect(find.text('Checking provider readiness...'), findsOneWidget);

      // Fail the check (simulating socket error/timeout)
      completer.completeError(TimeoutException('Agent socket timeout'));
      await tester.pumpAndSettle();

      // Proves: Does NOT trap into ProviderSetupFlow (which assumes no providers)
      expect(find.text('Checking provider readiness...'), findsNothing);
      expect(find.text('Choose your AI provider'), findsNothing);
      expect(find.text('Configured Providers'), findsNothing);
    },
  );
}
