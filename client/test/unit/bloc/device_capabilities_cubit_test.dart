import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/devices/domain/models/capability.dart';
import 'package:sanad_client/features/devices/domain/stores/device_capabilities_store.dart';
import 'package:sanad_client/features/devices/presentation/bloc/device_capabilities_cubit.dart';
import 'package:sanad_client/features/devices/presentation/bloc/device_state.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fake_device_repository.dart';
import '../../helpers/fake_socket.dart';

void main() {
  late FakeSanadSocketService socket;
  late FakeDeviceRepository agentRepository;
  late FakeDeviceClientRegistry agentClientRegistry;
  late TestDeviceCubit agentCubit;
  late DeviceCapabilitiesStore capabilities;

  setUp(() {
    socket = FakeSanadSocketService();
    agentRepository = FakeDeviceRepository();
    agentClientRegistry = FakeDeviceClientRegistry();
    agentCubit = TestDeviceCubit(
      socketService: socket,
      agentRepository: agentRepository,
      agentClientRegistry: agentClientRegistry,
    );
    capabilities = DeviceCapabilitiesStore(createTestResolver(cloudSocket: socket, localSocket: socket));
  });

  tearDown(() async {
    await agentCubit.close();
    capabilities.dispose();
    socket.dispose();
  });

  test('forces a capability refresh when a remote device becomes online', () async {
    socket.setConnected(true);
    final offlineAgent = DeviceConfig(
      id: 'newly-paired-device',
      name: 'Remote',
      isOnline: false,
    );
    final cubit = DeviceCapabilitiesCubit(
      capabilities: capabilities,
      agentCubit: agentCubit,
    );

    agentCubit.emitState(
      DeviceActive(activeAgent: offlineAgent, agents: [offlineAgent]),
    );
    await Future<void>.delayed(Duration.zero);
    socket.clearCaptured();
    socket.autoCapabilitiesPayload = const {
      'supports_model_change': true,
      'supports_thinking_mode_change': true,
    };

    final onlineAgent = offlineAgent.copyWith(isOnline: true);
    agentCubit.emitState(
      DeviceActive(activeAgent: onlineAgent, agents: [onlineAgent]),
    );
    await Future<void>.delayed(Duration.zero);

    expect(
      socket.capturedCommands.where((command) => command['event'] == 'get_capabilities'),
      hasLength(1),
    );
    expect(
      cubit.state.getForAgent(onlineAgent.id).supportsModelChange,
      isTrue,
    );
    expect(
      cubit.state.getForAgent(onlineAgent.id).supportsThinkingModeChange,
      isTrue,
    );

    await cubit.close();
  });

  test('tracks agent state without relying on DeviceCubit ownership', () async {
    final computerAgent = DeviceConfig(id: 'agent-computer', name: 'Computer', isOnline: true);
    final cubit = DeviceCapabilitiesCubit(capabilities: capabilities, agentCubit: agentCubit);

    agentCubit.emitState(DeviceActive(activeAgent: computerAgent, agents: [computerAgent]));
    await Future<void>.delayed(Duration.zero);

    expect(cubit.state.getForAgent('agent-computer').supportsDeleteSession, isFalse);
    expect(cubit.state.getForAgent('missing-agent'), const Capability());

    await cubit.close();
  });
}
