import 'dart:async';

import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/devices/domain/stores/device_capabilities_store.dart';
import 'package:sanad_client/features/devices/presentation/bloc/device_cubit.dart';
import 'package:sanad_client/features/devices/presentation/bloc/device_state.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'device_capabilities_state.dart';

class DeviceCapabilitiesCubit extends Cubit<DeviceCapabilitiesState> {
  final DeviceCapabilitiesStore capabilities;
  final DeviceCubit agentCubit;
  StreamSubscription? _capabilitiesSubscription;
  StreamSubscription? _agentSubscription;
  final Map<String, bool> _onlineByAgentId = {};

  DeviceCapabilitiesCubit({
    required this.capabilities,
    required this.agentCubit,
  }) : super(DeviceCapabilitiesState(capabilitiesByAgentId: capabilities.capabilitiesByAgentId)) {
    _capabilitiesSubscription = capabilities.onUpdate.listen((capabilitiesByAgentId) {
      emit(DeviceCapabilitiesState(capabilitiesByAgentId: capabilitiesByAgentId));
    });
    _agentSubscription = agentCubit.stream.listen(_ensureCapabilitiesForDeviceState);
    _ensureCapabilitiesForDeviceState(agentCubit.state);
  }

  Future<void> ensureFreshForAgent(DeviceConfig agent, {bool force = false}) async {
    await capabilities.ensureFreshForAgent(agent, force: force);
    emit(DeviceCapabilitiesState(capabilitiesByAgentId: capabilities.capabilitiesByAgentId));
  }

  void _ensureCapabilitiesForDeviceState(DeviceState agentState) {
    final agents = _agentsFrom(agentState);
    final currentIds = agents.map((agent) => agent.id).toSet();
    _onlineByAgentId.removeWhere((deviceId, _) => !currentIds.contains(deviceId));

    for (final agent in agents) {
      final becameOnline = agent.isOnline && !(_onlineByAgentId[agent.id] ?? false);
      _onlineByAgentId[agent.id] = agent.isOnline;
      unawaited(
        ensureFreshForAgent(
          agent,
          force: agent.isLocalReachable || becameOnline,
        ),
      );
    }
  }

  List<DeviceConfig> _agentsFrom(DeviceState agentState) {
    return switch (agentState) {
      DeviceActive(agents: final agents) => agents,
      DeviceNoActive(agents: final agents) => agents,
      _ => const <DeviceConfig>[],
    };
  }

  @override
  Future<void> close() async {
    await _capabilitiesSubscription?.cancel();
    await _agentSubscription?.cancel();
    return super.close();
  }
}
