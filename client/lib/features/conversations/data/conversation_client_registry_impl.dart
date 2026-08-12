import 'dart:async';

import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/devices/domain/stores/device_capabilities_store.dart';
import 'package:sanad_client/features/conversations/data/clients/socket_conversation_client.dart';
import 'package:sanad_client/features/conversations/domain/conversation_client.dart';

import '../../devices/data/device_connection_coordinator.dart';

class ConversationClientRegistryImpl implements ManagedConversationClientRegistry {
  final DeviceConnectionCoordinator _connectionCoordinator;
  final DeviceCapabilitiesStore _capabilitiesStore;
  final Map<String, SocketConversationClient> _clientsByAgentId = {};
  final Map<String, ConnectionScope> _scopeByAgentId = {};
  final Map<String, bool> _lastConnectedState = {};
  final Map<String, DateTime> _localFallbackDeadlines = {};
  final Map<String, Timer> _localFallbackTimers = {};
  final Duration localReconnectGracePeriod;
  StreamSubscription? _connectionSubscription;

  ConversationClientRegistryImpl(
    this._connectionCoordinator,
    this._capabilitiesStore, {
    this.localReconnectGracePeriod = const Duration(seconds: 10),
  }) {
    _connectionSubscription = _connectionCoordinator.changes.listen(_onConnectionChanged);
  }

  void _onConnectionChanged(void _) {
    for (final client in _clientsByAgentId.values) {
      final config = client.config;
      final endpoint = _resolveEndpointForExistingClient(config);

      if (!_connectionCoordinator.isTransportReadyForAgent(config)) {
        _lastConnectedState[config.id] = false;
        continue;
      }

      final currentScope = _scopeByAgentId[config.id];
      final wasConnected = _lastConnectedState[config.id] ?? false;
      final isNowConnected = endpoint.socketService.isConnected;

      final scopeChanged = currentScope != null && currentScope != endpoint.scope;
      final becameConnected = !wasConnected && isNowConnected;

      if (scopeChanged || becameConnected) {
        client.updateSocketService(endpoint.socketService);
        _scopeByAgentId[config.id] = endpoint.scope;
        _lastConnectedState[config.id] = isNowConnected;

        if (isNowConnected) {
          unawaited(
            client.synchronizeAfterReconnect().catchError((Object error) {
              // Reconnect reconciliation is best-effort; retained snapshots
              // remain visible until the next successful synchronization.
            }),
          );
        }
      } else {
        _lastConnectedState[config.id] = isNowConnected;
      }
    }
  }

  @override
  ConversationClient getOrCreateConversationClientForAgent(DeviceConfig config) {
    final existing = _clientsByAgentId[config.id];
    final existingScope = _scopeByAgentId[config.id];

    final endpoint = _resolveEndpointForExistingClient(config);
    final configScope = endpoint.scope;

    if (existing != null && existingScope == configScope) {
      return existing;
    }

    if (existing != null) {
      existing.updateSocketService(endpoint.socketService);
      _scopeByAgentId[config.id] = configScope;
      return existing;
    }

    final client = SocketConversationClient(
      config: config,
      socketService: endpoint.socketService,
      capabilitiesStore: _capabilitiesStore,
    );
    _clientsByAgentId[config.id] = client;
    _scopeByAgentId[config.id] = configScope;
    _lastConnectedState[config.id] = endpoint.socketService.isConnected;
    return client;
  }

  @override
  void retainClientsFor(List<DeviceConfig> agents) {
    final liveAgentIds = agents.map((agent) => agent.id).toSet();
    final staleAgentIds = _clientsByAgentId.keys.where((id) => !liveAgentIds.contains(id)).toList();
    for (final id in staleAgentIds) {
      _clientsByAgentId.remove(id)?.dispose();
      _scopeByAgentId.remove(id);
      _lastConnectedState.remove(id);
      _localFallbackDeadlines.remove(id);
      _localFallbackTimers.remove(id)?.cancel();
    }
  }

  @override
  void clear() {
    for (final client in _clientsByAgentId.values) {
      client.dispose();
    }
    _clientsByAgentId.clear();
    _scopeByAgentId.clear();
    _lastConnectedState.clear();
    _localFallbackDeadlines.clear();
    for (final timer in _localFallbackTimers.values) {
      timer.cancel();
    }
    _localFallbackTimers.clear();
  }

  ResolvedAgentEndpoint _resolveEndpointForExistingClient(DeviceConfig config) {
    final resolved = _connectionCoordinator.resolve(config);
    final currentScope = _scopeByAgentId[config.id];
    final localReady = _connectionCoordinator.localSocketService.isConnected;
    if (currentScope != ConnectionScope.local || !_connectionCoordinator.isLocalCandidate(config) || localReady) {
      _clearLocalFallbackGrace(config.id);
      return resolved;
    }

    final now = DateTime.now();
    final deadline = _localFallbackDeadlines.putIfAbsent(
      config.id,
      () => now.add(localReconnectGracePeriod),
    );
    if (now.isBefore(deadline)) {
      _localFallbackTimers.putIfAbsent(
        config.id,
        () => Timer(deadline.difference(now), () => _onConnectionChanged(null)),
      );
      return ResolvedAgentEndpoint(
        agent: config,
        scope: ConnectionScope.local,
        socketService: _connectionCoordinator.localSocketService,
        isLocalReachable: false,
      );
    }

    _clearLocalFallbackGrace(config.id);
    return resolved;
  }

  void _clearLocalFallbackGrace(String agentId) {
    _localFallbackDeadlines.remove(agentId);
    _localFallbackTimers.remove(agentId)?.cancel();
  }

  @override
  void dispose() {
    final subscription = _connectionSubscription;
    if (subscription != null) {
      unawaited(subscription.cancel());
    }
    clear();
  }
}
