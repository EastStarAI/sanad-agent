import 'dart:async';

import 'package:sanad_client/features/devices/data/device_connection_coordinator.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/devices/domain/models/capability.dart';
import 'package:uuid/uuid.dart';

class DeviceCapabilitiesStore {
  static const Duration cacheTtl = Duration(minutes: 10);

  final DeviceConnectionCoordinator _connectionCoordinator;
  final Map<String, Capability> _cache = {};
  final Map<String, DateTime> _lastFetchedAt = {};
  final Map<String, Future<Capability>> _inFlightFetches = {};
  final _controller = StreamController<Map<String, Capability>>.broadcast();

  Stream<Map<String, Capability>> get onUpdate => _controller.stream;
  Map<String, Capability> get capabilitiesByAgentId => Map.unmodifiable(_cache);

  DeviceCapabilitiesStore(this._connectionCoordinator);

  Capability getForAgent(String deviceId) {
    return _cache[deviceId] ?? const Capability();
  }

  Future<Capability> ensureFreshForAgent(DeviceConfig agent, {bool force = false}) async {
    final deviceId = agent.id;
    if (!force && _isFresh(deviceId)) {
      return getForAgent(deviceId);
    }

    final inFlight = _inFlightFetches[deviceId];
    if (inFlight != null) {
      return inFlight;
    }

    final request = _fetchForAgent(agent);
    _inFlightFetches[deviceId] = request;
    try {
      return await request;
    } finally {
      unawaited(_inFlightFetches.remove(deviceId));
    }
  }

  Future<Capability> fetchForAgent(DeviceConfig agent) {
    return ensureFreshForAgent(agent, force: true);
  }

  Future<Capability> _fetchForAgent(DeviceConfig agent) async {
    final endpoint = await _connectionCoordinator.ensureConnectedEndpointForAgent(agent);

    if (!endpoint.socketService.isConnected) {
      return getForAgent(agent.id);
    }

    final requestId = const Uuid().v4();
    final completer = Completer<Capability>();

    late final StreamSubscription<Map<String, dynamic>> subscription;
    subscription = endpoint.socketService.events.listen((event) {
      final eventType = event['type'] as String?;
      if (eventType != 'capabilities') {
        return;
      }

      final responseRequestId = event['request_id'] as String?;
      final responseAgentId = event['device_id'] as String?;
      final matchesRequest = responseRequestId != null && responseRequestId == requestId;
      final matchesAgent = responseAgentId != null && responseAgentId == agent.id;
      final matchesLocalUnscoped =
          endpoint.scope == ConnectionScope.local && responseRequestId == null && responseAgentId == null;

      if (!matchesRequest && !matchesAgent && !matchesLocalUnscoped) {
        return;
      }

      final rawCaps = event['capabilities'] ?? event['payload'];
      if (rawCaps is! Map) {
        // Cloud routing can answer a pre-online request with a correlated null
        // payload. Return the current projection without making that absence a
        // fresh cache entry, so the Online inventory update retries normally.
        if (!completer.isCompleted) {
          completer.complete(getForAgent(agent.id));
        }
        return;
      }
      final capability = Capability.fromJson(
        Map<String, dynamic>.from(rawCaps),
      );
      _storeCapabilities(agent.id, capability);
      if (!completer.isCompleted) {
        completer.complete(capability);
      }
    });

    endpoint.socketService.emit('get_capabilities', {
      'device_id': agent.id,
      'request_id': requestId,
    });

    try {
      return await completer.future.timeout(const Duration(seconds: 3));
    } catch (_) {
      return getForAgent(agent.id);
    } finally {
      await subscription.cancel();
    }
  }

  bool _isFresh(String deviceId) {
    if (!_cache.containsKey(deviceId)) return false;
    final lastFetchedAt = _lastFetchedAt[deviceId];
    if (lastFetchedAt == null) return false;
    return DateTime.now().difference(lastFetchedAt) < cacheTtl;
  }

  void _storeCapabilities(String deviceId, Capability caps) {
    final previous = _cache[deviceId];
    _cache[deviceId] = caps;
    _lastFetchedAt[deviceId] = DateTime.now();
    if (previous != caps) {
      _controller.add(Map.unmodifiable(_cache));
    }
  }

  void dispose() {
    _inFlightFetches.clear();
    unawaited(_controller.close());
  }
}
