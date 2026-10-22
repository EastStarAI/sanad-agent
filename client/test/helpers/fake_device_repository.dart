import 'dart:async';

import 'package:sanad_client/infrastructure/devices/models/device_client.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/devices/domain/device_client_registry.dart';
import 'package:sanad_client/features/devices/domain/device_repository.dart';
import 'package:sanad_client/features/conversations/domain/conversation_client.dart';
import 'package:sanad_client/features/devices/presentation/bloc/device_cubit.dart';
import 'package:sanad_client/features/devices/presentation/bloc/device_state.dart';
import 'package:sanad_client/infrastructure/socket/sanad_socket_service.dart';

class FakeDeviceRepository implements IDeviceRepository {
  final _agentsController = StreamController<List<DeviceConfig>>.broadcast();
  List<DeviceConfig> _agents = [];
  String? _activeAgentId;
  final List<(DeviceConfig, String)> renameCalls = [];

  void seedAgents(List<DeviceConfig> agents, {String? activeAgentId}) {
    _agents = agents;
    _activeAgentId = activeAgentId;
  }

  void emitAgentsUpdate() {
    _agentsController.add(_agents);
  }

  @override
  List<DeviceConfig> get agents => _agents;

  @override
  Stream<List<DeviceConfig>> get onAgentsUpdate => _agentsController.stream;

  @override
  Future<void> init() async {}

  @override
  Future<List<DeviceConfig>> fetchAgents() async {
    _agentsController.add(_agents);
    return _agents;
  }

  @override
  DeviceConfig? getActiveAgent() {
    final activeAgentId = _activeAgentId;
    if (activeAgentId == null) return null;
    return _agents.where((agent) => agent.id == activeAgentId).firstOrNull;
  }

  @override
  String? getActiveAgentId() => _activeAgentId;

  /// Defaults to a cloud inventory that can still arrive, the cold-start case.
  bool cloudInventoryPending = true;

  @override
  bool get isCloudInventoryPending => cloudInventoryPending;

  @override
  Future<void> setActiveAgent(String? deviceId) async {
    _activeAgentId = deviceId;
  }

  @override
  void createAgent(String name, {String type = 'computer'}) {}

  @override
  Future<void> renameAgent(DeviceConfig device, String name) async {
    renameCalls.add((device, name));
  }

  @override
  void deleteAgent(String deviceId) {}

  @override
  Future<void> clearAgents() async {
    _agents = [];
    _activeAgentId = null;
    _agentsController.add(_agents);
  }

  @override
  void dispose() {
    unawaited(_agentsController.close());
  }
}

class FakeDeviceClientRegistry implements IDeviceClientRegistry, ConversationClientRegistry {
  final Map<String, DeviceClient> _clientsByAgentId = {};

  void registerClient(String deviceId, DeviceClient client) {
    _clientsByAgentId[deviceId] = client;
  }

  @override
  DeviceClient getOrCreateClientForAgent(DeviceConfig config) {
    final client = _clientsByAgentId[config.id];
    if (client == null) {
      throw StateError('No fake client registered for ${config.id}');
    }
    return client;
  }

  @override
  ConversationClient getOrCreateConversationClientForAgent(DeviceConfig config) {
    return getOrCreateClientForAgent(config) as ConversationClient;
  }

  @override
  void retainClientsFor(List<DeviceConfig> agents) {}

  @override
  void clear() {
    _clientsByAgentId.clear();
  }

  @override
  void dispose() {
    clear();
  }
}

class TestDeviceCubit extends DeviceCubit {
  TestDeviceCubit({
    required SanadSocketService socketService,
    required IDeviceRepository agentRepository,
    required IDeviceClientRegistry agentClientRegistry,
  }) : super(socketService: socketService, agentRepository: agentRepository, agentClientRegistry: agentClientRegistry);

  void emitState(DeviceState state) {
    emit(state);
  }
}
