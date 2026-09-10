import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/devices/presentation/bloc/device_cubit.dart';
import 'package:sanad_client/features/devices/presentation/bloc/device_state.dart';
import 'package:sanad_client/features/devices/domain/device_client_registry.dart';
import 'package:sanad_client/features/conversations/domain/conversation_client.dart';
import 'package:sanad_client/infrastructure/devices/models/device_client.dart';

import '../../helpers/fake_device_repository.dart';
import '../../mocks/mock_socket_service.dart';

/// Lenient registry that returns a no-op client instead of throwing, so tests
/// can drive [DeviceCubit] device-selection logic without a full client.
class _LenientClientRegistry implements IDeviceClientRegistry, ConversationClientRegistry {
  @override
  DeviceClient getOrCreateClientForAgent(DeviceConfig config) => _NoopDeviceClient();

  @override
  ConversationClient getOrCreateConversationClientForAgent(DeviceConfig config) => _NoopDeviceClient();

  @override
  void retainClientsFor(List<DeviceConfig> agents) {}

  @override
  void clear() {}

  @override
  void dispose() {}
}

class _NoopDeviceClient extends Fake implements DeviceClient, ConversationClient {}

class _ControlledFetchDeviceRepository extends FakeDeviceRepository {
  final Completer<List<DeviceConfig>> fetchCompleter = Completer<List<DeviceConfig>>();

  @override
  Future<List<DeviceConfig>> fetchAgents() => fetchCompleter.future;

  void completeFetch() {
    fetchCompleter.complete(agents);
  }

  void failFetch() {
    fetchCompleter.completeError(StateError('inventory unavailable'));
  }
}

void main() {
  late FakeSanadSocketService socket;
  late FakeDeviceRepository repository;
  late _LenientClientRegistry clientRegistry;

  final localDevice = DeviceConfig(
    id: 'hardware-1',
    name: 'This Mac',
    hardwareId: 'hardware-1',
    isOnline: true,
  );
  final cloudDevice = DeviceConfig(
    id: 'cloud-device',
    name: 'Cloud Machine',
    isOnline: true,
  );

  setUp(() {
    socket = FakeSanadSocketService();
    repository = FakeDeviceRepository();
    clientRegistry = _LenientClientRegistry();
  });

  DeviceCubit buildCubit() => DeviceCubit(
    socketService: socket,
    agentRepository: repository,
    agentClientRegistry: clientRegistry,
  );

  test('cold start with a persisted device that is not loaded yet does not fall back to the local device', () async {
    // Persisted active device id points at the cloud device, but the initial
    // inventory only contains the local device (cloud list not yet arrived).
    repository.seedAgents([localDevice], activeAgentId: cloudDevice.id);

    final cubit = buildCubit();
    await cubit.init();
    await Future<void>.delayed(Duration.zero);

    // It must NOT switch to the local device; it waits with no active device.
    expect(cubit.state, isA<DeviceNoActive>());
    expect(repository.getActiveAgentId(), cloudDevice.id);

    // When the cloud device list finally arrives, the persisted device wins.
    repository.seedAgents([localDevice, cloudDevice], activeAgentId: cloudDevice.id);
    await repository.fetchAgents();
    await Future<void>.delayed(Duration.zero);

    final state = cubit.state;
    expect(state, isA<DeviceActive>());
    expect((state as DeviceActive).activeAgent.id, cloudDevice.id);
    await cubit.close();
  });

  test('authoritative inventory without the persisted device falls back after the stale id is cleared', () async {
    repository.seedAgents([localDevice], activeAgentId: cloudDevice.id);

    final cubit = buildCubit();
    await cubit.init();
    expect(cubit.state, isA<DeviceNoActive>());

    // DeviceManager clears a missing cloud id before publishing a successful,
    // authoritative devices_response.
    repository.seedAgents([localDevice], activeAgentId: null);
    await repository.fetchAgents();
    await Future<void>.delayed(Duration.zero);

    final state = cubit.state;
    expect(state, isA<DeviceActive>());
    expect((state as DeviceActive).activeAgent.id, localDevice.id);
    await cubit.close();
  });

  test('temporary local inventory gap keeps the active local device offline', () async {
    repository.seedAgents([localDevice], activeAgentId: localDevice.id);
    final cubit = buildCubit();
    await cubit.init();
    expect((cubit.state as DeviceActive).activeAgent.id, localDevice.id);

    repository.seedAgents(const [], activeAgentId: localDevice.id);
    await repository.fetchAgents();
    await Future<void>.delayed(Duration.zero);

    final state = cubit.state;
    expect(state, isA<DeviceActive>());
    final active = (state as DeviceActive).activeAgent;
    expect(active.id, localDevice.id);
    expect(active.isOnline, isFalse);
    expect(state.agents.map((agent) => agent.id), contains(localDevice.id));
    await cubit.close();
  });

  test('merged local alias keeps the active device through an inventory identity change', () async {
    repository.seedAgents([cloudDevice], activeAgentId: cloudDevice.id);
    final cubit = buildCubit();
    await cubit.init();
    expect((cubit.state as DeviceActive).activeAgent.id, cloudDevice.id);

    final mergedLocal = localDevice.copyWith(
      metadata: {'cloud_device_id': cloudDevice.id},
      isOnline: false,
    );
    repository.seedAgents([mergedLocal], activeAgentId: localDevice.id);
    await repository.fetchAgents();
    await Future<void>.delayed(Duration.zero);

    final state = cubit.state;
    expect(state, isA<DeviceActive>());
    expect((state as DeviceActive).activeAgent.id, localDevice.id);
    await cubit.close();
  });

  test('cold start with NO persisted device falls back to the default device', () async {
    repository.seedAgents([localDevice], activeAgentId: null);

    final cubit = buildCubit();
    await cubit.init();
    await Future<void>.delayed(Duration.zero);

    final state = cubit.state;
    expect(state, isA<DeviceActive>());
    expect((state as DeviceActive).activeAgent.id, localDevice.id);
    await cubit.close();
  });

  test('empty inventory remains loading until its fetch settles without a stream event', () async {
    final controlledRepository = _ControlledFetchDeviceRepository();
    repository = controlledRepository;
    socket.setConnected(true);

    final cubit = buildCubit();
    await cubit.init();

    expect(
      cubit.state,
      isA<DeviceNoActive>().having(
        (state) => state.isLoadingFromBackend,
        'isLoadingFromBackend',
        isTrue,
      ),
    );

    controlledRepository.emitAgentsUpdate();
    await Future<void>.delayed(Duration.zero);
    expect((cubit.state as DeviceNoActive).isLoadingFromBackend, isTrue);

    controlledRepository.completeFetch();
    await Future<void>.delayed(Duration.zero);
    expect((cubit.state as DeviceNoActive).isLoadingFromBackend, isFalse);
    await cubit.close();
  });

  test('failed initial inventory fetch clears loading without an unhandled error', () async {
    final controlledRepository = _ControlledFetchDeviceRepository();
    repository = controlledRepository;
    socket.setConnected(true);

    final cubit = buildCubit();
    await cubit.init();
    expect((cubit.state as DeviceNoActive).isLoadingFromBackend, isTrue);

    controlledRepository.failFetch();
    await Future<void>.delayed(Duration.zero);

    expect((cubit.state as DeviceNoActive).isLoadingFromBackend, isFalse);
    await cubit.close();
  });

  test('logout invalidates a pending inventory fetch without claiming a new fetch', () async {
    final controlledRepository = _ControlledFetchDeviceRepository();
    repository = controlledRepository;
    socket.setConnected(true);

    final cubit = buildCubit();
    await cubit.init();
    expect((cubit.state as DeviceNoActive).isLoadingFromBackend, isTrue);

    await cubit.resetForLogout();
    expect((cubit.state as DeviceNoActive).isLoadingFromBackend, isFalse);

    controlledRepository.completeFetch();
    await Future<void>.delayed(Duration.zero);
    expect((cubit.state as DeviceNoActive).isLoadingFromBackend, isFalse);
    await cubit.close();
  });

  test('rename delegates the selected device and name to the repository', () async {
    final cubit = buildCubit();

    await cubit.renameAgent(cloudDevice, 'Renamed machine');

    expect(repository.renameCalls, [(cloudDevice, 'Renamed machine')]);
    await cubit.close();
  });
}
