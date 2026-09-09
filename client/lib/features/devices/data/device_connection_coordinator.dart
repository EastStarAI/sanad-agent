import 'dart:async';

import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/devices/data/daemon/local_daemon_controller.dart';
import 'package:sanad_client/features/devices/data/daemon/standalone_daemon_controller.dart';
import 'package:sanad_client/infrastructure/socket/event_deduplicator.dart';
import 'package:sanad_client/infrastructure/socket/sanad_socket_service.dart';
import 'package:sanad_client/utils/app_platform.dart';

enum ConnectionScope { cloud, local }

class ResolvedAgentEndpoint {
  final DeviceConfig agent;
  final ConnectionScope scope;
  final SanadSocketService socketService;
  final bool isLocalReachable;

  const ResolvedAgentEndpoint({
    required this.agent,
    required this.scope,
    required this.socketService,
    required this.isLocalReachable,
  });

  String get protocolDeviceId => switch (scope) {
    ConnectionScope.local => agent.hardwareId ?? agent.id,
    ConnectionScope.cloud => agent.accountDeviceId ?? agent.id,
  };
}

class DeviceConnectionCoordinator {
  final SanadSocketService _cloudSocketService;
  final SanadSocketService _localSocketService;
  final String _currentDeviceId;
  final LocalDaemonController _serviceManager;
  final String expectedVersion;

  /// Phase 27 — shared cross-transport event deduplicator. Both socket
  /// services consult this instance so a same-device client never applies
  /// the same canonical event twice when local and cloud deliver it.
  final EventDeduplicator _eventDeduplicator = EventDeduplicator();

  final _changesController = StreamController<void>.broadcast();
  Stream<void> get changes => _changesController.stream;

  StreamSubscription? _cloudLifecycleSubscription;
  StreamSubscription? _localLifecycleSubscription;
  bool _isDisposed = false;
  Future<void>? _localConnectionFuture;

  DeviceConnectionCoordinator({
    required SanadSocketService cloudSocketService,
    required SanadSocketService localSocketService,
    required String currentDeviceId,
    LocalDaemonController? daemonController,
    this.expectedVersion = '1.0.0',
  }) : _cloudSocketService = cloudSocketService,
       _localSocketService = localSocketService,
       _currentDeviceId = currentDeviceId,
       _serviceManager = daemonController ?? const StandaloneDaemonController() {
    _cloudLifecycleSubscription = _cloudSocketService.lifecycleStateStream.listen((_) => _emitChange());
    _localLifecycleSubscription = _localSocketService.lifecycleStateStream.listen((_) => _emitChange());
    // Phase 27 — share one deduplicator across both transports.
    _cloudSocketService.eventDeduplicator = _eventDeduplicator;
    _localSocketService.eventDeduplicator = _eventDeduplicator;
  }

  SanadSocketService get cloudSocketService => _cloudSocketService;
  SanadSocketService get localSocketService => _localSocketService;
  LocalDaemonController get serviceManager => _serviceManager;
  String get currentDeviceId => _currentDeviceId;
  List<Stream<Map<String, dynamic>>> get eventStreams => [
    _cloudSocketService.events,
    _localSocketService.events,
  ];

  /// Phase 27 — clears the cross-transport dedupe state. Call on full logout
  /// only, NOT on a transport switch for the same device.
  void clearEventDeduplicationState() => _eventDeduplicator.clear();

  void _emitChange() {
    if (!_isDisposed && !_changesController.isClosed) {
      _changesController.add(null);
    }
  }

  Future<bool> checkAndStartLocalDaemon({bool force = false}) async {
    if (!AppPlatform.isDesktop) return false;

    final isRunning = await _serviceManager.isDaemonRunning();
    if (isRunning) {
      final result = await _serviceManager.updateDaemon(
        targetVersion: expectedVersion,
      );
      return result.isSuccess;
    }

    if ((_serviceManager.shouldAutoStart || force) && _serviceManager.isServiceInstalled()) {
      final started = await _serviceManager.startDaemon();
      if (!started) return false;
      for (var attempt = 0; attempt < 8; attempt++) {
        if (await _serviceManager.isDaemonRunning()) {
          final result = await _serviceManager.updateDaemon(
            targetVersion: expectedVersion,
          );
          return result.isSuccess;
        }
        await Future<void>.delayed(Duration(milliseconds: 300 + attempt * 250));
      }
    }
    return false;
  }

  Future<void> ensureLocalConnection() async {
    if (!AppPlatform.isDesktop || _localSocketService.isConnected) return;
    final inFlight = _localConnectionFuture;
    if (inFlight != null) return inFlight;

    final attempt = _connectLocal();
    _localConnectionFuture = attempt;
    try {
      await attempt;
    } finally {
      _localConnectionFuture = null;
      _emitChange();
    }
  }

  Future<void> _connectLocal() async {
    await checkAndStartLocalDaemon();
    try {
      await _localSocketService.connect();
    } catch (_) {
      // A later call starts a fresh attempt; failed futures are never retained.
    }
  }

  ResolvedAgentEndpoint resolve(DeviceConfig agent) {
    final localReachable = isLocalReachable(agent);
    final scope = localReachable ? ConnectionScope.local : ConnectionScope.cloud;
    return ResolvedAgentEndpoint(
      agent: agent,
      scope: scope,
      socketService: localReachable ? _localSocketService : _cloudSocketService,
      isLocalReachable: localReachable,
    );
  }

  Future<ResolvedAgentEndpoint> ensureConnectedEndpointForAgent(
    DeviceConfig agent,
  ) async {
    await ensureLocalConnection();
    var endpoint = resolve(agent);
    if (!endpoint.socketService.isConnected) {
      try {
        await endpoint.socketService.connect();
      } catch (_) {}
      endpoint = resolve(agent);
    }
    return endpoint;
  }

  Future<SanadSocketService?> ensureConnectedLocalRuntimeSocket() async {
    if (_localSocketService.isConnected) {
      return _localSocketService;
    }
    await ensureLocalConnection();
    if (!_localSocketService.isConnected) {
      try {
        await _localSocketService.connect();
      } catch (_) {}
    }
    if (!_localSocketService.isConnected) {
      return null;
    }
    return _localSocketService;
  }

  bool isLocalReachable(DeviceConfig agent) {
    if (!AppPlatform.isDesktop) {
      return false;
    }

    final sameDevice = agent.hardwareId != null && agent.hardwareId == _currentDeviceId;
    return sameDevice && _localSocketService.isConnected;
  }

  bool isLocalCandidate(DeviceConfig agent) {
    final sameDevice = agent.hardwareId != null && agent.hardwareId == _currentDeviceId;
    return AppPlatform.isDesktop && sameDevice;
  }

  bool isTransitioningToLocal(DeviceConfig agent) {
    if (!isLocalCandidate(agent)) return false;
    final state = _localSocketService.lifecycleState;
    return state == SocketLifecycleState.connecting || state == SocketLifecycleState.authenticating;
  }

  bool isTransportReadyForAgent(DeviceConfig agent) {
    final endpoint = resolve(agent);
    if (endpoint.scope == ConnectionScope.cloud && isTransitioningToLocal(agent)) {
      return false;
    }
    return endpoint.socketService.isConnected;
  }

  DeviceConfig decorateAgent(DeviceConfig agent) {
    final endpoint = resolve(agent);
    final metadata = <String, dynamic>{
      ...?agent.metadata,
      'is_local_reachable': endpoint.isLocalReachable,
      'preferred_connection_scope': endpoint.scope.name,
      'is_local_candidate': isLocalCandidate(agent),
    };
    return agent.copyWith(
      metadata: metadata,
      isOnline: agent.isOnline || endpoint.isLocalReachable,
    );
  }

  void dispose() {
    _isDisposed = true;
    final cloudSubscription = _cloudLifecycleSubscription;
    if (cloudSubscription != null) {
      unawaited(cloudSubscription.cancel());
    }
    final subscription = _localLifecycleSubscription;
    if (subscription != null) {
      unawaited(subscription.cancel());
    }
    unawaited(_changesController.close());
  }
}
