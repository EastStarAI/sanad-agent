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

  void failFetchWith(Object error) {
    fetchCompleter.completeError(error);
  }
}

/// Loses the first inventory request (the post-sign-in socket flap) and answers
/// the retry, which is what the live device showed when Retry was pressed.
class _FailOnceDeviceRepository extends FakeDeviceRepository {
  int calls = 0;

  @override
  Future<List<DeviceConfig>> fetchAgents() async {
    calls += 1;
    if (calls == 1) {
      throw TimeoutException('Timed out waiting for the device inventory');
    }
    authoritativeInventory = true;
    emitAgentsUpdate();
    return agents;
  }
}

class _FailingRefreshRepository extends FakeDeviceRepository {
  Object? errorToThrow;

  @override
  Future<List<DeviceConfig>> fetchAgents() {
    final error = errorToThrow;
    if (error != null) return Future.error(error);
    emitAgentsUpdate();
    return Future.value(agents);
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

  test('a lost first inventory request retries once instead of asking the user to retry', () async {
    // Live reproduction: the post-sign-in request was emitted onto a connection
    // that dropped 3ms later, so the 5s fetch timed out and the user saw an error
    // surface; pressing Retry then loaded devices in ~120ms.
    final flakyRepository = _FailOnceDeviceRepository();
    flakyRepository.cloudInventoryPending = true;
    flakyRepository.authoritativeInventory = false;
    flakyRepository.seedAgents([cloudDevice]);
    repository = flakyRepository;
    socket.setConnected(true);

    final cubit = buildCubit();
    await cubit.init();
    await Future<void>.delayed(const Duration(milliseconds: 1200));

    expect(flakyRepository.calls, 2);
    expect(cubit.state, isA<DeviceActive>());
    await cubit.close();
  });

  test('an empty update after a transport error still waits, it does not claim empty', () async {
    // A dropped socket makes the gateway report "not pending" while no
    // authoritative inventory exists yet; that is still not an empty account.
    repository.cloudInventoryPending = false;
    repository.authoritativeInventory = false;
    final cubit = buildCubit();
    await cubit.init();
    await Future<void>.delayed(Duration.zero);
    cubit.markInventoryPending();

    repository.emitAgentsUpdate();
    await Future<void>.delayed(Duration.zero);

    expect((cubit.state as DeviceNoActive).phase, DevicesPhase.loading);

    // Only an applied inventory response may publish an authoritative empty.
    repository.authoritativeInventory = true;
    repository.emitAgentsUpdate();
    await Future<void>.delayed(Duration.zero);

    expect((cubit.state as DeviceNoActive).phase, DevicesPhase.readyEmpty);
  });

  test('an empty inventory update while the gateway is pending keeps loading', () async {
    // The repository pushes an empty inventory on connection changes; that push
    // is not an authoritative answer before a successful response lands, and it
    // must not replace the loading phase with a "no devices" claim.
    repository.cloudInventoryPending = true;
    repository.authoritativeInventory = false;
    final cubit = buildCubit();
    await cubit.init();
    await Future<void>.delayed(Duration.zero);
    cubit.markInventoryPending();

    repository.emitAgentsUpdate();
    await Future<void>.delayed(Duration.zero);

    expect((cubit.state as DeviceNoActive).phase, DevicesPhase.loading);
  });

  test('a gateway that cannot answer keeps the inventory pending, never empty', () async {
    repository.inventoryReady = false;
    final cubit = buildCubit();
    await cubit.init();
    await Future<void>.delayed(Duration.zero);

    await cubit.fetchAgents();

    final pending = cubit.state as DeviceNoActive;
    expect(pending.agents, isEmpty);
    expect(pending.phase, DevicesPhase.loading);

    // Once the gateway answers, the same fetch resolves the real inventory.
    repository.inventoryReady = true;
    repository.seedAgents([cloudDevice]);
    await cubit.fetchAgents();
    await Future<void>.delayed(Duration.zero);

    expect(cubit.state, isA<DeviceActive>());
  });

  test('a pending inventory after sign-in is never an authoritative empty', () async {
    final cubit = buildCubit();
    await cubit.init();
    await Future<void>.delayed(Duration.zero);
    expect(cubit.state, isA<DeviceNoActive>());

    // Sign-in completes before the cloud gateway is ready: publishing that
    // window as an empty result is what looked like lost devices on the phone.
    repository.cloudInventoryPending = false;
    cubit.markInventoryPending();

    final pending = cubit.state as DeviceNoActive;
    expect(pending.agents, isEmpty);
    expect(pending.isLoadingFromBackend, isTrue);
    expect(pending.phase, DevicesPhase.loading);
    expect(cubit.state, isNot(predicate<DeviceState>((state) => state is DeviceNoActive && state.phase == DevicesPhase.readyEmpty)));

    // The fetch that follows publishes the real inventory.
    repository.seedAgents([cloudDevice]);
    await cubit.fetchAgents();
    await Future<void>.delayed(Duration.zero);

    expect(cubit.state, isA<DeviceActive>());
  });

  test('a known active device is not degraded to a pending inventory', () async {
    repository.cloudInventoryPending = false;
    repository.seedAgents([cloudDevice]);
    final cubit = buildCubit();
    await cubit.init();
    await Future<void>.delayed(Duration.zero);
    expect(cubit.state, isA<DeviceActive>());

    cubit.markInventoryPending();

    expect(cubit.state, isA<DeviceActive>());
  });

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

  group('remembered device that cannot appear', () {
    test('falls back to the local device without forgetting the remembered cloud device', () async {
      repository.seedAgents([localDevice], activeAgentId: cloudDevice.id);
      repository.cloudInventoryPending = false;

      final cubit = buildCubit();
      await cubit.init();
      await Future<void>.delayed(Duration.zero);

      final state = cubit.state;
      expect(state, isA<DeviceActive>());
      expect((state as DeviceActive).activeAgent.id, localDevice.id);
      expect(repository.getActiveAgentId(), cloudDevice.id);
      await cubit.close();
    });

    test('falls back when a pending cloud inventory stops being pending', () async {
      repository.seedAgents([localDevice], activeAgentId: cloudDevice.id);

      final cubit = buildCubit();
      await cubit.init();
      expect(cubit.state, isA<DeviceNoActive>());

      // The cloud socket failed or the account signed out: the inventory
      // publishes again and the remembered device can no longer arrive.
      repository.cloudInventoryPending = false;
      repository.emitAgentsUpdate();
      await Future<void>.delayed(Duration.zero);

      final state = cubit.state;
      expect(state, isA<DeviceActive>());
      expect((state as DeviceActive).activeAgent.id, localDevice.id);
      expect(repository.getActiveAgentId(), cloudDevice.id);
      await cubit.close();
    });

    test('an active cloud device that leaves the inventory falls back to the local device', () async {
      repository.seedAgents([localDevice, cloudDevice], activeAgentId: cloudDevice.id);
      final cubit = buildCubit();
      await cubit.init();
      expect((cubit.state as DeviceActive).activeAgent.id, cloudDevice.id);

      repository.cloudInventoryPending = false;
      repository.seedAgents([localDevice], activeAgentId: cloudDevice.id);
      repository.emitAgentsUpdate();
      await Future<void>.delayed(Duration.zero);

      final state = cubit.state;
      expect(state, isA<DeviceActive>());
      expect((state as DeviceActive).activeAgent.id, localDevice.id);
      expect(repository.getActiveAgentId(), cloudDevice.id);
      await cubit.close();
    });

    test('restores the remembered device when it becomes available again', () async {
      repository.seedAgents([localDevice], activeAgentId: cloudDevice.id);
      repository.cloudInventoryPending = false;
      final cubit = buildCubit();
      await cubit.init();
      expect((cubit.state as DeviceActive).activeAgent.id, localDevice.id);

      repository.cloudInventoryPending = true;
      repository.seedAgents([localDevice, cloudDevice], activeAgentId: cloudDevice.id);
      repository.emitAgentsUpdate();
      await Future<void>.delayed(Duration.zero);

      expect((cubit.state as DeviceActive).activeAgent.id, cloudDevice.id);
      await cubit.close();
    });

    test('a user pick during the fallback replaces the remembered device', () async {
      repository.seedAgents([localDevice], activeAgentId: cloudDevice.id);
      repository.cloudInventoryPending = false;
      final cubit = buildCubit();
      await cubit.init();

      await cubit.setActiveAgent(localDevice.id);
      expect(repository.getActiveAgentId(), localDevice.id);

      repository.seedAgents([localDevice, cloudDevice], activeAgentId: localDevice.id);
      repository.emitAgentsUpdate();
      await Future<void>.delayed(Duration.zero);

      expect((cubit.state as DeviceActive).activeAgent.id, localDevice.id);
      await cubit.close();
    });

    test('never invents a selection when no device is available', () async {
      repository.seedAgents([localDevice.copyWith(isOnline: false)], activeAgentId: cloudDevice.id);
      repository.cloudInventoryPending = false;

      final cubit = buildCubit();
      await cubit.init();
      await Future<void>.delayed(Duration.zero);

      expect(cubit.state, isA<DeviceNoActive>());
      expect(repository.getActiveAgentId(), cloudDevice.id);
      await cubit.close();
    });
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
    controlledRepository.cloudInventoryPending = false;
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
    controlledRepository.cloudInventoryPending = false;
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

  test('failed initial inventory fetch surfaces a typed error, not an authoritative empty', () async {
    final controlledRepository = _ControlledFetchDeviceRepository();
    controlledRepository.cloudInventoryPending = false;
    repository = controlledRepository;
    socket.setConnected(true);

    final cubit = buildCubit();
    await cubit.init();
    expect((cubit.state as DeviceNoActive).isLoadingFromBackend, isTrue);

    controlledRepository.failFetch();
    await Future<void>.delayed(Duration.zero);

    final state = cubit.state as DeviceNoActive;
    expect(state.isLoadingFromBackend, isFalse);
    expect(state.phase, DevicesPhase.error);
    expect(state.errorMessage, isNotNull);
    // A failure never clears the auth/session or repository identity.
    expect(repository.getActiveAgentId(), isNull);
    await cubit.close();
  });

  test('timeout is a typed error, never an authoritative empty', () async {
    final controlledRepository = _ControlledFetchDeviceRepository();
    controlledRepository.cloudInventoryPending = false;
    repository = controlledRepository;
    socket.setConnected(true);

    final cubit = buildCubit();
    await cubit.init();

    controlledRepository.failFetchWith(TimeoutException('Device inventory timed out'));
    await Future<void>.delayed(Duration.zero);

    final state = cubit.state as DeviceNoActive;
    expect(state.phase, DevicesPhase.error);
    expect(state.isLoadingFromBackend, isFalse);
    expect(state.errorMessage, contains('Timed out'));
    await cubit.close();
  });

  test('failed refresh during a live session keeps the active device and never logs out', () async {
    final failingRepository = _FailingRefreshRepository();
    failingRepository.seedAgents([localDevice, cloudDevice], activeAgentId: cloudDevice.id);
    repository = failingRepository;
    socket.setConnected(true);

    final cubit = buildCubit();
    await cubit.init();
    expect(cubit.state, isA<DeviceActive>());

    failingRepository.errorToThrow = StateError('cloud unreachable');
    await cubit.fetchAgents();
    await Future<void>.delayed(Duration.zero);

    final state = cubit.state;
    expect(state, isA<DeviceActive>());
    expect((state as DeviceActive).activeAgent.id, cloudDevice.id);
    // Cached/active data retained and auth session intact.
    expect(repository.getActiveAgentId(), cloudDevice.id);
    await cubit.close();
  });

  test('DeviceNoActive exposes typed loading/ready-empty/error/stale phases', () async {
    const emptyLoading = DeviceNoActive(isLoadingFromBackend: true);
    expect(emptyLoading.phase, DevicesPhase.loading);

    const authoritativeEmpty = DeviceNoActive();
    expect(authoritativeEmpty.phase, DevicesPhase.readyEmpty);

    final stale = DeviceNoActive(agents: [cloudDevice], isLoadingFromBackend: true);
    expect(stale.phase, DevicesPhase.stale);

    final failed = DeviceNoActive(errorMessage: 'failed');
    expect(failed.phase, DevicesPhase.error);
    expect(failed.agents, isEmpty);
    await Future<void>.delayed(Duration.zero);
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
