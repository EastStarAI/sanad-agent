import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/auth/presentation/bloc/auth_cubit.dart';
import 'package:sanad_client/features/auth/presentation/bloc/auth_state.dart';
import 'package:sanad_client/features/devices/data/daemon/local_daemon_controller.dart';
import 'package:sanad_client/features/devices/data/device_connection_coordinator.dart';
import 'package:sanad_client/features/devices/presentation/bloc/device_cubit.dart';
import 'package:sanad_client/features/devices/presentation/bloc/device_state.dart';
import 'package:sanad_client/features/devices/presentation/bloc/gateway_connection_cubit.dart';
import 'package:sanad_client/utils/app_platform.dart';

import '../../mocks/mock_socket_service.dart';

class _ConnectingSocket extends FakeSanadSocketService {
  _ConnectingSocket() : super(hardwareId: 'device-1', isLocalTransport: true);

  @override
  Future<void> connect() async => setConnected(true);
}

class _SignedOutAuth extends Fake implements AuthCubit {
  @override
  AuthState get state => AuthUnauthenticated();
  @override
  Stream<AuthState> get stream => const Stream.empty();
}

class _IdleDevices extends Fake implements DeviceCubit {
  @override
  DeviceState get state => const DeviceNoActive();
  @override
  Stream<DeviceState> get stream => const Stream.empty();
}

/// A running agent whose version is older than the client.
class _OlderRunningAgent implements LocalDaemonController {
  _OlderRunningAgent({this.updateStatus = AgentLifecycleStatus.ready});

  final AgentLifecycleStatus updateStatus;
  final updateTargets = <String>[];

  @override
  bool get ownsStoppedAgentLifecycle => true;
  @override
  bool get shouldAutoStart => true;
  @override
  bool isServiceInstalled() => true;
  @override
  Future<bool> isDaemonRunning() async => true;
  @override
  Future<Map<String, dynamic>?> getDaemonHealth() async => {'version': '1.0.15'};
  @override
  Future<String?> getDaemonVersion() async => '1.0.15';
  @override
  Future<bool> install() async => true;
  @override
  Future<bool> restartDaemon() async => true;
  @override
  Future<bool> startDaemon() async => true;
  @override
  Future<bool> stopDaemon() async => true;
  @override
  Future<AgentLifecycleResult> updateDaemon({
    required String targetVersion,
    void Function(double progress)? onProgress,
  }) async {
    updateTargets.add(targetVersion);
    return AgentLifecycleResult(updateStatus);
  }
}

void main() {
  Future<(GatewayConnectionCubit, DeviceConnectionCoordinator)> build(LocalDaemonController daemon) async {
    final coordinator = DeviceConnectionCoordinator(
      cloudSocketService: FakeSanadSocketService(hardwareId: 'device-1'),
      localSocketService: _ConnectingSocket(),
      currentDeviceId: 'device-1',
      daemonController: daemon,
      expectedVersion: '1.0.17',
    );
    final cubit = GatewayConnectionCubit(
      authCubit: _SignedOutAuth(),
      deviceCubit: _IdleDevices(),
      connectionCoordinator: coordinator,
    );
    addTearDown(() async {
      await cubit.close();
      coordinator.dispose();
    });
    return (cubit, coordinator);
  }

  test('bootstrap pairs an older running local agent to the exact client version', () async {
    final daemon = _OlderRunningAgent();
    final (cubit, _) = await build(daemon);

    await cubit.resolveInitialRoute();

    expect(daemon.updateTargets, ['1.0.17'], reason: 'a running agent must not short-circuit version pairing');
  }, skip: !AppPlatform.isDesktop);

  test('a failed pairing still uses the running agent', () async {
    final daemon = _OlderRunningAgent(updateStatus: AgentLifecycleStatus.networkFailed);
    final (cubit, coordinator) = await build(daemon);

    await cubit.resolveInitialRoute();

    expect(daemon.updateTargets, ['1.0.17']);
    expect(coordinator.localSocketService.isConnected, isTrue);
  }, skip: !AppPlatform.isDesktop);
}
