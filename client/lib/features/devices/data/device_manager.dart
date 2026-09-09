import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/devices/domain/device_repository.dart';
import 'package:sanad_client/infrastructure/socket/sanad_socket_service.dart';
import 'package:uuid/uuid.dart';

import 'device_connection_coordinator.dart';
import 'device_inventory_source.dart';

/// Service for managing agent configurations via Socket.IO
class DeviceManager {
  static const String _activeAgentKey = 'active_device_id';

  final SanadSocketService _socket;
  final DeviceConnectionCoordinator _connectionCoordinator;
  final DeviceInventoryMerger _inventoryMerger;
  final SharedPreferences _prefs;

  List<DeviceConfig> _cloudAgents = [];
  List<DeviceConfig> _agents = [];
  List<DeviceConfig> get agents => _agents;

  // Stream controllers for agent events
  final _agentsUpdateController = StreamController<List<DeviceConfig>>.broadcast();
  Stream<List<DeviceConfig>> get onAgentsUpdate => _agentsUpdateController.stream;

  final _agentStatusController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get onAgentStatusChange => _agentStatusController.stream;

  StreamSubscription? _authSuccessSubscription;
  StreamSubscription? _connectionChangesSubscription;
  final List<Completer<List<DeviceConfig>>> _pendingFetches = [];
  final Map<String, Completer<void>> _pendingUpdates = {};

  DeviceManager._(
    this._socket,
    this._connectionCoordinator,
    this._prefs, {
    DeviceInventoryMerger? inventoryMerger,
  }) : _inventoryMerger =
           inventoryMerger ??
           DeviceInventoryMerger(
             connectionCoordinator: _connectionCoordinator,
             localSource: LocalDeviceInventorySource(_connectionCoordinator),
           ) {
    _setupSocketListeners();
    _rebuildInventory();
    _emitAgentsUpdate();
    _authSuccessSubscription = _socket.onAuthSuccess.listen((_) async {
      _setupSocketListeners();
      unawaited(fetchAgents());
    });
    _connectionChangesSubscription = _connectionCoordinator.changes.listen((_) {
      _rebuildInventory();
      _emitAgentsUpdate();
    });
  }

  /// Create an instance of DeviceManager
  static Future<DeviceManager> create(
    SanadSocketService socket,
    DeviceConnectionCoordinator connectionCoordinator,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final manager = DeviceManager._(socket, connectionCoordinator, prefs);
    return manager;
  }

  /// Setup Socket.IO listeners for device events
  void _setupSocketListeners() {
    final socket = _socket.socket;
    if (socket == null) return;

    socket.off('devices_response');
    socket.off('device_created');
    socket.off('device_updated');
    socket.off('device_deleted');
    socket.off('device_status_changed');

    socket.on('devices_response', (data) {
      unawaited(_handleDevicesResponse(data));
    });

    // Listen for device creation
    socket.on('device_created', _handleDeviceCreated);

    // Listen for device updates
    socket.on('device_updated', (data) {
      _handleDeviceUpdated(data);
    });

    // Listen for device deletions
    socket.on('device_deleted', (data) {
      if (data is Map<String, dynamic> && data['status'] == 'ok') {
        final deviceId = data['device_id'] as String;
        _cloudAgents = _cloudAgents.where((a) => a.id != deviceId).toList();
        _rebuildInventory();
        _emitAgentsUpdate();

        // If deleted device was active, switch to null
        final activeId = getActiveAgentId();
        if (activeId == deviceId) {
          unawaited(setActiveAgent(null));
        }
      }
    });

    socket.on('device_status_changed', (data) {
      _handleStatusChange(data);
    });
  }

  /// Fetch all devices from server.
  Future<List<DeviceConfig>> fetchAgents() {
    if (!_isCloudGatewayReady) return Future.value(List.unmodifiable(_agents));

    final completer = Completer<List<DeviceConfig>>();
    final isFirstFetch = _pendingFetches.isEmpty;
    _pendingFetches.add(completer);

    if (isFirstFetch) {
      _socket.emit('get_devices', null);
    }

    return completer.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        _pendingFetches.remove(completer);
        return List.unmodifiable(_agents);
      },
    );
  }

  /// Create a new device
  void createAgent(String name, {String type = 'computer'}) {
    if (!_isCloudGatewayReady) return;
    _socket.emit('create_device', {
      'name': name,
    });
  }

  /// Rename an account-owned device and wait for the authoritative response.
  Future<void> renameAgent(DeviceConfig device, String name) async {
    final deviceId = device.accountDeviceId;
    if (deviceId == null) {
      throw const DeviceMutationException('Connect this device to your Sanad account before renaming it.');
    }
    if (!_isCloudGatewayReady) {
      throw const DeviceMutationException('Sanad Gateway is not connected. Try again when the connection is restored.');
    }

    final requestId = 'req_${const Uuid().v4()}';
    final completer = Completer<void>();
    _pendingUpdates[requestId] = completer;
    _socket.emit('update_device', {
      'device_id': deviceId,
      'name': name.trim(),
      'request_id': requestId,
    });

    return completer.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        _pendingUpdates.remove(requestId);
        throw const DeviceMutationException('Timed out while renaming the device. Please try again.');
      },
    );
  }

  /// Delete a device
  void deleteAgent(String deviceId) {
    if (!_isCloudGatewayReady) return;
    _socket.emit('delete_device', {
      'device_id': deviceId,
    });
  }

  /// Get active agent ID (stored locally)
  String? getActiveAgentId() {
    return _prefs.getString(_activeAgentKey);
  }

  /// Set active agent ID (stored locally)
  Future<void> setActiveAgent(String? deviceId) async {
    if (deviceId == null) {
      await _prefs.remove(_activeAgentKey);
    } else {
      await _prefs.setString(_activeAgentKey, deviceId);
    }
  }

  /// Get active agent configuration
  DeviceConfig? getActiveAgent() {
    final activeId = getActiveAgentId();
    if (activeId == null) return null;

    try {
      return _agents.firstWhere((agent) => agent.representsDeviceId(activeId));
    } catch (e) {
      return null;
    }
  }

  /// Get agent by ID
  DeviceConfig? getAgent(String deviceId) {
    try {
      return _agents.firstWhere((agent) => agent.representsDeviceId(deviceId));
    } catch (e) {
      return null;
    }
  }

  /// Update agent status locally (called from external status updates)
  void updateAgentStatus(String deviceId, bool isOnline) {
    final index = _agents.indexWhere((a) => a.id == deviceId);
    if (index >= 0) {
      final cloudIndex = _cloudAgents.indexWhere((a) => a.id == deviceId);
      if (cloudIndex >= 0) {
        _cloudAgents = [
          ..._cloudAgents.take(cloudIndex),
          _cloudAgents[cloudIndex].copyWith(isOnline: isOnline),
          ..._cloudAgents.skip(cloudIndex + 1),
        ];
      }
      _rebuildInventory();
      _emitAgentsUpdate();
    }
  }

  /// Clear local agents list
  Future<void> clearAgents() async {
    await setActiveAgent(null);
    _cloudAgents = [];
    _rebuildInventory();
    _emitAgentsUpdate();
  }

  void _emitAgentsUpdate() {
    _agentsUpdateController.add(List.unmodifiable(_agents));
  }

  void _completePendingFetches(List<DeviceConfig> agents) {
    final pending = List<Completer<List<DeviceConfig>>>.from(_pendingFetches);
    _pendingFetches.clear();
    for (final completer in pending) {
      if (!completer.isCompleted) {
        completer.complete(List.unmodifiable(agents));
      }
    }
  }

  /// Dispose resources
  void dispose() {
    _completePendingFetches(_agents);
    for (final completer in _pendingUpdates.values) {
      if (!completer.isCompleted) {
        completer.completeError(
          const DeviceMutationException('Device manager was closed before the update completed.'),
        );
      }
    }
    _pendingUpdates.clear();
    unawaited(_authSuccessSubscription?.cancel());
    unawaited(_connectionChangesSubscription?.cancel());
    unawaited(_agentsUpdateController.close());
    unawaited(_agentStatusController.close());
  }

  void _rebuildInventory() {
    _agents = _inventoryMerger.merge(_cloudAgents);
  }

  bool get _isCloudGatewayReady => !_socket.isLocalTransport && _socket.lifecycleState == SocketLifecycleState.ready;

  Future<void> _handleDevicesResponse(dynamic data) async {
    if (data is Map<String, dynamic> && data['status'] == 'ok') {
      final rawDevices = data['devices'];
      _cloudAgents =
          (rawDevices as List?)?.map((json) => DeviceConfig.fromApiResponse(json as Map<String, dynamic>)).toList() ??
          [];
      _rebuildInventory();

      // A successful devices_response is authoritative. If another client
      // deleted the persisted active device, stop waiting for an id that can
      // never appear and let DeviceCubit choose a valid fallback. Clear the
      // preference before publishing the inventory so consumers never observe
      // an authoritative list paired with a stale active id.
      final activeId = getActiveAgentId();
      if (activeId != null) {
        final represented = _agents.where((agent) => agent.representsDeviceId(activeId)).firstOrNull;
        if (represented != null) {
          // Normalize a legacy cloud id for this hardware to the stable merged
          // local identity so subsequent disconnect updates keep the same key.
          if (represented.id != activeId) {
            await setActiveAgent(represented.id);
          }
        } else if (activeId != DeviceInventoryIds.localDevice) {
          await setActiveAgent(null);
        }
      }

      _emitAgentsUpdate();
      _completePendingFetches(_agents);
    }
  }

  @visibleForTesting
  Future<void> handleDevicesResponseForTesting(dynamic data) => _handleDevicesResponse(data);

  @visibleForTesting
  void handleDeviceCreatedForTesting(dynamic data) => _handleDeviceCreated(data);

  @visibleForTesting
  void handleDeviceUpdatedForTesting(dynamic data) => _handleDeviceUpdated(data);

  @visibleForTesting
  void handleStatusChangeForTesting(dynamic data) => _handleStatusChange(data);

  void _handleDeviceCreated(dynamic data) {
    if (data is! Map<String, dynamic> || data['status'] != 'ok') return;
    final rawDevice = data['device'];
    if (rawDevice is! Map<String, dynamic>) return;

    final agent = DeviceConfig.fromApiResponse(rawDevice);
    final existingIndex = _cloudAgents.indexWhere((candidate) => candidate.id == agent.id);
    _cloudAgents = existingIndex < 0
        ? [..._cloudAgents, agent]
        : [
            ..._cloudAgents.take(existingIndex),
            agent,
            ..._cloudAgents.skip(existingIndex + 1),
          ];
    _rebuildInventory();
    _emitAgentsUpdate();
  }

  void _handleDeviceUpdated(dynamic data) {
    if (data is! Map<String, dynamic>) return;

    final requestId = data['request_id']?.toString();
    final completer = requestId == null ? null : _pendingUpdates.remove(requestId);
    if (data['status'] != 'ok') {
      if (completer != null && !completer.isCompleted) {
        completer.completeError(
          DeviceMutationException(data['message']?.toString() ?? 'Unable to update the device.'),
        );
      }
      return;
    }

    final rawDevice = data['device'];
    if (rawDevice is! Map<String, dynamic>) {
      if (completer != null && !completer.isCompleted) {
        completer.completeError(const DeviceMutationException('The device update response was invalid.'));
      }
      return;
    }

    final agent = DeviceConfig.fromApiResponse(rawDevice);
    final index = _cloudAgents.indexWhere((candidate) => candidate.id == agent.id);
    if (index >= 0) {
      _cloudAgents = [
        ..._cloudAgents.take(index),
        agent,
        ..._cloudAgents.skip(index + 1),
      ];
      _rebuildInventory();
      _emitAgentsUpdate();
    }
    if (completer != null && !completer.isCompleted) completer.complete();
  }

  void _handleStatusChange(dynamic data) {
    if (data is Map<String, dynamic>) {
      final deviceId = data['device_id'] as String?;
      final isOnline = data['is_online'] as bool? ?? false;

      final cloudIndex = _cloudAgents.indexWhere((a) => a.id == deviceId);
      if (cloudIndex >= 0) {
        _cloudAgents = [
          ..._cloudAgents.take(cloudIndex),
          _cloudAgents[cloudIndex].copyWith(isOnline: isOnline),
          ..._cloudAgents.skip(cloudIndex + 1),
        ];
        _rebuildInventory();
        _emitAgentsUpdate();
      } else if (_isCloudGatewayReady) {
        // A newly paired Agent can publish online status before this Client
        // receives an inventory row for it. Reconcile authoritatively so the
        // capabilities owner observes the new DeviceConfig and fetches model /
        // thinking controls without requiring an Agent restart.
        unawaited(fetchAgents());
      }

      _agentStatusController.add(data);
    }
  }
}
