import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/devices/domain/device_repository.dart';
import 'package:sanad_client/features/devices/data/device_manager.dart';
import 'package:sanad_client/infrastructure/socket/sanad_socket_service.dart';

import 'device_connection_coordinator.dart';

class DeviceRepositoryImpl implements IDeviceRepository {
  final SanadSocketService _socketService;
  final DeviceConnectionCoordinator _connectionCoordinator;
  DeviceManager? _manager;

  DeviceRepositoryImpl(this._socketService, this._connectionCoordinator);

  @override
  Future<void> init() async {
    _manager ??= await DeviceManager.create(_socketService, _connectionCoordinator);
  }

  DeviceManager get _readyManager {
    final manager = _manager;
    if (manager == null) {
      throw StateError('DeviceRepository used before init().');
    }
    return manager;
  }

  @override
  List<DeviceConfig> get agents => _manager?.agents ?? const [];

  @override
  Stream<List<DeviceConfig>> get onAgentsUpdate => _manager?.onAgentsUpdate ?? const Stream.empty();

  @override
  Future<List<DeviceConfig>> fetchAgents() {
    return _manager?.fetchAgents() ?? Future.value(const <DeviceConfig>[]);
  }

  @override
  DeviceConfig? getActiveAgent() {
    return _manager?.getActiveAgent();
  }

  @override
  String? getActiveAgentId() {
    return _manager?.getActiveAgentId();
  }

  @override
  bool get isCloudInventoryPending => _manager?.isCloudInventoryPending ?? false;

  @override
  Future<void> setActiveAgent(String? deviceId) {
    return _readyManager.setActiveAgent(deviceId);
  }

  @override
  void createAgent(String name, {String type = 'computer'}) {
    _manager?.createAgent(name, type: type);
  }

  @override
  Future<void> renameAgent(DeviceConfig device, String name) {
    return _readyManager.renameAgent(device, name);
  }

  @override
  void deleteAgent(String deviceId) {
    _manager?.deleteAgent(deviceId);
  }

  @override
  Future<void> clearAgents() async {
    await _manager?.clearAgents();
  }

  @override
  void dispose() {
    _manager?.dispose();
  }
}
