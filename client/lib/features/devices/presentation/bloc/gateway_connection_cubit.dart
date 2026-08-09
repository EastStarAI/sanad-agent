import 'package:logging/logging.dart';
import 'dart:async';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:sanad_client/core/navigation/app_routes.dart';
import 'package:sanad_client/core/config/app_config.dart';
import 'package:sanad_client/features/auth/presentation/bloc/auth_cubit.dart';
import 'package:sanad_client/features/auth/presentation/bloc/auth_state.dart';
import 'package:sanad_client/features/devices/data/device_connection_coordinator.dart';
import 'package:sanad_client/features/devices/data/device_inventory_source.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/devices/domain/models/gateway_connection_status.dart';
import 'package:sanad_client/features/devices/presentation/bloc/device_cubit.dart';
import 'package:sanad_client/features/devices/presentation/bloc/device_state.dart';
import 'package:sanad_client/infrastructure/socket/sanad_socket_service.dart';
import 'package:sanad_client/utils/app_platform.dart';

class GatewayConnectionCubit extends Cubit<GatewayConnectionStatus> {
  static final _logger = Logger('GatewayConnectionCubit');

  final AuthCubit _authCubit;
  final DeviceCubit _deviceCubit;
  final DeviceConnectionCoordinator _connectionCoordinator;

  StreamSubscription? _authSubscription;
  StreamSubscription? _deviceSubscription;
  StreamSubscription? _connectionSubscription;
  bool? _isLocalServiceInstalled;

  GatewayConnectionCubit({
    required AuthCubit authCubit,
    required DeviceCubit deviceCubit,
    required DeviceConnectionCoordinator connectionCoordinator,
  }) : _authCubit = authCubit,
       _deviceCubit = deviceCubit,
       _connectionCoordinator = connectionCoordinator,
       super(const GatewayConnectionStatus.initial()) {
    _authSubscription = _authCubit.stream.listen((_) => refresh());
    _deviceSubscription = _deviceCubit.stream.listen((_) => refresh());
    _connectionSubscription = _connectionCoordinator.changes.listen(
      (_) => refresh(),
    );
    unawaited(refresh(probeLocalService: true));
  }

  Future<void> refresh({bool probeLocalService = false}) async {
    if (probeLocalService && AppPlatform.isDesktop) {
      _isLocalServiceInstalled = _connectionCoordinator.serviceManager.isServiceInstalled();
    }

    emit(
      GatewayConnectionStatus(
        localGateway: _localGatewayStatus(),
        sanadGateway: _sanadGatewayStatus(),
        actions: _actions(),
        recommendedRoute: _recommendedRoute(),
        isDesktop: AppPlatform.isDesktop,
      ),
    );
  }

  Future<void> startLocalGateway() async {
    if (!AppPlatform.isDesktop) return;
    await _connectionCoordinator.checkAndStartLocalDaemon(force: true);
    await _connectionCoordinator.ensureLocalConnection();
    await refresh(probeLocalService: true);
  }

  Future<void> restartLocalGateway() async {
    if (!AppPlatform.isDesktop) return;
    await _connectionCoordinator.serviceManager.restartDaemon();
    await _connectionCoordinator.ensureLocalConnection();
    await refresh(probeLocalService: true);
  }

  Future<void> stopLocalGateway() async {
    if (!AppPlatform.isDesktop) return;
    await _connectionCoordinator.serviceManager.stopDaemon();
    await refresh(probeLocalService: true);
  }

  Future<void> retryCloudGateway() async {
    if (!AppConfig.enableCloudGateway) return;
    if (_authCubit.state is! AuthAuthenticated) return;
    final socket = _connectionCoordinator.cloudSocketService;
    try {
      await socket.connect();
      unawaited(_deviceCubit.fetchAgents());
    } catch (_) {
      await refresh();
    }
  }

  Future<String> resolveInitialRoute({String? requestedLocation}) async {
    await _waitForAuthBootstrap();
    final localGatewayReady = await _waitForLocalGatewayForBootstrap();

    final authState = _authCubit.state;
    if (authState is! AuthAuthenticated) {
      if (!AppPlatform.isDesktop) return AppRoutes.login;

      if (localGatewayReady) {
        return _safeRequestedLocation(requestedLocation);
      }

      await refresh(probeLocalService: true);
      return AppRoutes.onboarding;
    }

    await _waitForDeviceBootstrap();
    final cloudSnapshot = await _waitForCloudDeviceSnapshot();
    await refresh(probeLocalService: AppPlatform.isDesktop);

    final devices = cloudSnapshot ?? _devicesFromState(_deviceCubit.state);
    final hasRegisteredDevices = _hasRegisteredDevices(devices);
    if (!AppPlatform.isDesktop) {
      final route = hasRegisteredDevices ? _safeRequestedLocation(requestedLocation) : AppRoutes.onboarding;
      _logBootstrapDecision(
        route,
        devices: devices,
        hasRegisteredDevices: hasRegisteredDevices,
      );
      return route;
    }

    final hasLocalGateway = localGatewayReady;
    if (hasLocalGateway || hasRegisteredDevices) {
      final route = _safeRequestedLocation(requestedLocation);
      _logBootstrapDecision(
        route,
        devices: devices,
        hasRegisteredDevices: hasRegisteredDevices,
        hasLocalGateway: hasLocalGateway,
      );
      return route;
    }

    _logBootstrapDecision(
      AppRoutes.onboarding,
      devices: devices,
      hasRegisteredDevices: hasRegisteredDevices,
      hasLocalGateway: hasLocalGateway,
    );
    return AppRoutes.onboarding;
  }

  Future<void> _waitForAuthBootstrap() async {
    if (_authCubit.state is! AuthInitial && _authCubit.state is! AuthLoading) {
      return;
    }
    try {
      await _authCubit.stream
          .firstWhere((state) => state is! AuthInitial && state is! AuthLoading)
          .timeout(const Duration(seconds: 5));
    } catch (_) {}
  }

  Future<void> _waitForDeviceBootstrap() async {
    if (_deviceCubit.state is! DeviceLoading) return;
    try {
      await _deviceCubit.stream.firstWhere((state) => state is! DeviceLoading).timeout(const Duration(seconds: 2));
    } catch (_) {}
  }

  Future<bool> _isLocalDaemonRunningWithTimeout() async {
    if (!AppPlatform.isDesktop) return false;
    try {
      return await _connectionCoordinator.serviceManager.isDaemonRunning().timeout(const Duration(milliseconds: 1200));
    } catch (_) {
      return false;
    }
  }

  Future<bool> _waitForLocalGatewayForBootstrap() async {
    if (!AppPlatform.isDesktop) return false;
    if (_localGatewayStatus() == LocalGatewayStatus.connected) return true;

    final canUseLocalGateway =
        await _isLocalDaemonRunningWithTimeout() || await _connectionCoordinator.checkAndStartLocalDaemon();
    if (!canUseLocalGateway) {
      await refresh(probeLocalService: true);
      return false;
    }

    while (_localGatewayStatus() != LocalGatewayStatus.connected) {
      try {
        await _connectionCoordinator.localSocketService.connect();
      } catch (_) {}
      await refresh(probeLocalService: true);
      if (_localGatewayStatus() == LocalGatewayStatus.connected) return true;
      try {
        await _connectionCoordinator.localSocketService.lifecycleStateStream
            .firstWhere((state) => state == SocketLifecycleState.ready)
            .timeout(const Duration(seconds: 1));
      } catch (_) {}
    }
    return true;
  }

  Future<List<DeviceConfig>?> _waitForCloudDeviceSnapshot() async {
    if (!AppConfig.enableCloudGateway) return const <DeviceConfig>[];
    final socket = _connectionCoordinator.cloudSocketService;

    if (socket.lifecycleState != SocketLifecycleState.ready) {
      try {
        await socket.connect();
      } catch (_) {
        return null;
      }
    }

    if (socket.lifecycleState != SocketLifecycleState.ready) {
      try {
        await socket.lifecycleStateStream
            .firstWhere((state) => state == SocketLifecycleState.ready)
            .timeout(const Duration(seconds: 3));
      } catch (_) {
        return null;
      }
    }

    try {
      final devices = await _deviceCubit.fetchAgents();
      await _waitForDeviceStateToInclude(devices);
      return devices;
    } catch (_) {}
    return null;
  }

  Future<void> _waitForDeviceStateToInclude(List<DeviceConfig> devices) async {
    if (devices.isEmpty) return;
    final expectedIds = devices.map((device) => device.id).toSet();
    if (expectedIds
        .difference(
          _devicesFromState(
            _deviceCubit.state,
          ).map((device) => device.id).toSet(),
        )
        .isEmpty) {
      return;
    }

    try {
      await _deviceCubit.stream
          .firstWhere((state) {
            final stateIds = _devicesFromState(
              state,
            ).map((device) => device.id).toSet();
            return expectedIds.difference(stateIds).isEmpty;
          })
          .timeout(const Duration(seconds: 1));
    } catch (_) {}
  }

  String _safeRequestedLocation(String? requestedLocation) {
    if (requestedLocation == null || requestedLocation.isEmpty) {
      return AppRoutes.home;
    }

    final uri = Uri.tryParse(requestedLocation);
    final path = uri?.path;
    if (path == null || path.isEmpty || path == AppRoutes.splash || path == AppRoutes.login) {
      return AppRoutes.home;
    }

    return requestedLocation;
  }

  LocalGatewayStatus _localGatewayStatus() {
    if (!AppPlatform.isDesktop) return LocalGatewayStatus.notFound;

    final lifecycle = _connectionCoordinator.localSocketService.lifecycleState;
    return switch (lifecycle) {
      SocketLifecycleState.ready => LocalGatewayStatus.connected,
      SocketLifecycleState.connecting || SocketLifecycleState.authenticating => LocalGatewayStatus.connecting,
      SocketLifecycleState.error || SocketLifecycleState.authFailed => LocalGatewayStatus.needsRepair,
      SocketLifecycleState.disconnected =>
        (_isLocalServiceInstalled ?? false) ? LocalGatewayStatus.installedButStopped : LocalGatewayStatus.notFound,
    };
  }

  SanadGatewayStatus _sanadGatewayStatus() {
    if (!AppConfig.enableCloudGateway) {
      return SanadGatewayStatus.disconnected;
    }
    final authState = _authCubit.state;
    if (authState is AuthInitial || authState is AuthLoading) {
      return SanadGatewayStatus.connecting;
    }
    if (authState is! AuthAuthenticated) {
      return SanadGatewayStatus.loginRequired;
    }

    final lifecycle = _connectionCoordinator.cloudSocketService.lifecycleState;
    if (lifecycle == SocketLifecycleState.connecting || lifecycle == SocketLifecycleState.authenticating) {
      return SanadGatewayStatus.connecting;
    }
    if (lifecycle == SocketLifecycleState.ready) {
      return _hasCloudDevices ? SanadGatewayStatus.authenticatedWithDevices : SanadGatewayStatus.authenticatedNoDevices;
    }
    return SanadGatewayStatus.disconnected;
  }

  List<GatewayConnectionAction> _actions() {
    final actions = <GatewayConnectionAction>[];
    final authState = _authCubit.state;
    final local = _localGatewayStatus();
    final cloud = _sanadGatewayStatus();

    if (AppPlatform.isDesktop) {
      if (local == LocalGatewayStatus.connected) {
        actions.add(GatewayConnectionAction.restartLocalAgent);
        actions.add(GatewayConnectionAction.stopLocalAgent);
      } else if (local != LocalGatewayStatus.connecting) {
        actions.add(GatewayConnectionAction.startLocalAgent);
        if (local == LocalGatewayStatus.needsRepair || local == LocalGatewayStatus.installedButStopped) {
          actions.add(GatewayConnectionAction.repairLocalAgent);
        }
      }
    }

    if (authState is AuthAuthenticated) {
      if (cloud == SanadGatewayStatus.disconnected) {
        actions.add(GatewayConnectionAction.retryCloud);
      }
      if (cloud == SanadGatewayStatus.authenticatedNoDevices) {
        actions.add(GatewayConnectionAction.addDevice);
      }
    } else if (authState is! AuthInitial && authState is! AuthLoading) {
      actions.add(GatewayConnectionAction.signIn);
    }

    return List.unmodifiable(actions);
  }

  String _recommendedRoute() {
    if (AppPlatform.isDesktop && _localGatewayStatus() == LocalGatewayStatus.connected) {
      return AppRoutes.home;
    }

    final cloud = _sanadGatewayStatus();
    final authState = _authCubit.state;
    if (!AppPlatform.isDesktop && cloud == SanadGatewayStatus.loginRequired) {
      return AppRoutes.login;
    }
    if (cloud == SanadGatewayStatus.authenticatedNoDevices) {
      return AppRoutes.onboarding;
    }
    if (cloud == SanadGatewayStatus.authenticatedWithDevices ||
        cloud == SanadGatewayStatus.connected ||
        (authState is AuthAuthenticated && cloud == SanadGatewayStatus.disconnected)) {
      return AppRoutes.home;
    }
    return AppPlatform.isDesktop ? AppRoutes.onboarding : AppRoutes.login;
  }

  bool get _hasCloudDevices {
    return _hasRegisteredDevices(_devicesFromState(_deviceCubit.state));
  }

  bool _hasRegisteredDevices(List<DeviceConfig> devices) {
    return devices.any((device) => device.id != DeviceInventoryIds.localDevice);
  }

  List<DeviceConfig> _devicesFromState(DeviceState state) {
    return switch (state) {
      DeviceActive(:final agents) => agents,
      DeviceNoActive(:final agents) => agents,
      _ => const <DeviceConfig>[],
    };
  }

  void _logBootstrapDecision(
    String route, {
    required List<DeviceConfig> devices,
    required bool hasRegisteredDevices,
    bool? hasLocalGateway,
  }) {
    _logger.info(
      'GatewayBootstrap: route=$route auth=${_authCubit.state.runtimeType} '
      'platform=${AppPlatform.isDesktop ? 'desktop' : 'non_desktop'} '
      'cloud=${_sanadGatewayStatus().name} local=${_localGatewayStatus().name} '
      'hasRegisteredDevices=$hasRegisteredDevices hasLocalGateway=$hasLocalGateway '
      'deviceCount=${devices.length} devices=${devices.map((device) => "${device.id}:${device.name}:online=${device.isOnline}:local=${device.isLocalCandidate}").join(",")}',
    );
  }

  @override
  Future<void> close() async {
    await _authSubscription?.cancel();
    await _deviceSubscription?.cancel();
    await _connectionSubscription?.cancel();
    return super.close();
  }
}
