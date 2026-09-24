import 'dart:async';

import 'package:sanad_client/features/devices/domain/device_client_registry.dart';
import 'package:sanad_client/features/devices/domain/device_repository.dart';
import 'package:sanad_client/core/interfaces/socket_service.dart';
import 'package:sanad_client/features/conversations/domain/conversation_client.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../domain/models/device_config.dart';
import 'device_state.dart';

class DeviceCubit extends Cubit<DeviceState> {
  final ISocketService socketService;
  final IDeviceRepository agentRepository;
  final IDeviceClientRegistry agentClientRegistry;
  final ManagedConversationClientRegistry? conversationClientRegistry;
  StreamSubscription? _agentsSubscription;
  StreamSubscription? _authSubscription;
  int _backendFetchesInFlight = 0;
  int _inventoryEpoch = 0;

  DeviceCubit({
    required this.socketService,
    required this.agentRepository,
    required this.agentClientRegistry,
    this.conversationClientRegistry,
  }) : super(AgentInitial());

  Stream<List<DeviceConfig>> get onAgentsUpdate => agentRepository.onAgentsUpdate;

  Future<void> init() async {
    // Listen to auth immediately before any awaits so we don't miss the event.
    bool wasAuthedBeforeManagerCreated = false;
    _authSubscription ??= socketService.onAuthSuccess.listen((_) {
      if (state is! AgentInitial && state is! DeviceLoading) {
        unawaited(_fetchAgentsWithLoading());
      } else {
        wasAuthedBeforeManagerCreated = true;
      }
    });

    emit(DeviceLoading());
    try {
      await agentRepository.init();

      _agentsSubscription = agentRepository.onAgentsUpdate.listen(_handleAgentsUpdated);

      // If auth happened while we were creating the manager, fetch now
      if (wasAuthedBeforeManagerCreated) {
        unawaited(_fetchAgentsWithLoading());
      } else if (socketService.isConnected) {
        unawaited(_fetchAgentsWithLoading());
      }

      final active = _resolveInitialActiveAgent(agentRepository.agents);
      if (active != null) {
        await switchAgent(active);
      } else {
        emit(
          DeviceNoActive(
            agents: agentRepository.agents,
            isLoadingFromBackend: _hasBackendFetchInFlight,
          ),
        );
      }
    } catch (e) {
      emit(AgentError('Failed to load agents: $e'));
    }
  }

  Future<List<DeviceConfig>> _fetchAgentsWithLoading() async {
    final fetchEpoch = _inventoryEpoch;
    _backendFetchesInFlight++;
    _publishBackendLoading();

    try {
      return await agentRepository.fetchAgents();
    } catch (error) {
      // A failed fetch (including a timeout) must never wipe valid cached data
      // nor trigger a logout. We surface a typed error while retaining agents.
      // A stale fetch (superseded by logout/reset, epoch changed) must not
      // surface its error on the reset surface: only the current epoch's error
      // is shown, keeping event ordering causal (Plan 97g).
      if (fetchEpoch == _inventoryEpoch) {
        _recordInventoryError(error);
      }
      return agentRepository.agents;
    } finally {
      if (fetchEpoch == _inventoryEpoch) {
        _backendFetchesInFlight--;
        _publishBackendLoading();
      }
    }
  }

  /// Surfaces an inventory fetch failure without clearing [agentRepository]
  /// data or the auth session. On the "no active device" surface the cached
  /// [DeviceNoActive.agents] are retained so the UI shows an error (or stale)
  /// state instead of a false authoritative empty.
  void _recordInventoryError(Object error) {
    if (isClosed) return;
    final current = state;
    // A live session keeps its active device: never degrade to empty on error.
    if (current is DeviceActive || current is! DeviceNoActive) return;
    emit(
      DeviceNoActive(
        agents: current.agents,
        isLoadingFromBackend: false,
        errorMessage: _friendlyErrorMessage(error),
      ),
    );
  }

  String _friendlyErrorMessage(Object error) {
    if (error is TimeoutException) {
      return 'Timed out while checking for your devices. Check your connection and try again.';
    }
    return 'Could not load your devices. Check your connection and try again.';
  }

  bool get _hasBackendFetchInFlight => _backendFetchesInFlight > 0;

  void _publishBackendLoading() {
    if (isClosed) return;
    final current = state;
    if (current is! DeviceNoActive) return;

    final isLoading = _hasBackendFetchInFlight;
    if (current.isLoadingFromBackend != isLoading || (isLoading && current.errorMessage != null)) {
      // Starting a new fetch clears the previous transient error.
      emit(
        current.copyWith(
          isLoadingFromBackend: isLoading,
          clearError: isLoading,
        ),
      );
    }
  }

  void _handleAgentsUpdated(List<DeviceConfig> agents) {
    final current = state;
    final stableAgents =
        current is DeviceActive &&
            current.activeAgent.isLocalInventoryDevice &&
            !agents.any(
              (agent) => agent.representsDeviceId(current.activeAgent.id),
            )
        ? <DeviceConfig>[
            current.activeAgent.copyWith(isOnline: false),
            ...agents,
          ]
        : agents;

    agentClientRegistry.retainClientsFor(stableAgents);
    conversationClientRegistry?.retainClientsFor(stableAgents);

    if (state is DeviceActive) {
      final s = state as DeviceActive;
      final activeMatches = stableAgents.where(
        (agent) => agent.representsDeviceId(s.activeAgent.id) || s.activeAgent.representsDeviceId(agent.id),
      );
      if (activeMatches.isEmpty) {
        final replacement = _resolveInitialActiveAgent(stableAgents);
        if (replacement != null) {
          unawaited(switchAgent(replacement));
        } else {
          emit(
            DeviceNoActive(
              agents: agents,
              isLoadingFromBackend: _hasBackendFetchInFlight,
            ),
          );
        }
        return;
      }
      final refreshedActive = activeMatches.first;
      agentClientRegistry.getOrCreateClientForAgent(refreshedActive);
      conversationClientRegistry?.getOrCreateConversationClientForAgent(refreshedActive);
      emit(s.copyWith(activeAgent: activeMatches.first, agents: stableAgents));
    } else {
      final active = _resolveInitialActiveAgent(agents);
      if (active != null) {
        unawaited(switchAgent(active));
      } else {
        emit(
          DeviceNoActive(
            agents: agents,
            isLoadingFromBackend: _hasBackendFetchInFlight,
          ),
        );
      }
    }
  }

  /// Resolve which device should become active when there is no active device
  /// yet (cold start or after logout).
  ///
  /// Returns the persisted active device when it is already present in
  /// [agents]. When a device id IS persisted but its config has not loaded
  /// yet (cold start, before the cloud device list arrives), this returns
  /// `null` so we do NOT fall back to a default device (e.g. the local
  /// device) and then clobber the persisted selection / fetch history from
  /// the wrong device. The subsequent `_handleAgentsUpdated` once the list
  /// arrives will then resolve the persisted device correctly.
  ///
  /// Only when NO device id is persisted at all do we fall back to a
  /// sensible default (online registered device, else the local device).
  DeviceConfig? _resolveInitialActiveAgent(List<DeviceConfig> agents) {
    final persisted = agentRepository.getActiveAgent();
    if (persisted != null) return persisted;
    // A device id is saved but its config is not loaded yet -> wait for the
    // device list instead of switching to an arbitrary default.
    if (agentRepository.getActiveAgentId() != null) return null;
    return _defaultActiveAgent(agents);
  }

  Future<void> switchAgent(DeviceConfig config) async {
    agentClientRegistry.getOrCreateClientForAgent(config);
    conversationClientRegistry?.getOrCreateConversationClientForAgent(config);

    final currentAgents = agentRepository.agents;
    emit(
      DeviceActive(
        activeAgent: config,
        agents: currentAgents,
      ),
    );
  }

  DeviceConfig? _defaultActiveAgent(List<DeviceConfig> agents) {
    final registeredAgents = agents.where((agent) => agent.accountDeviceId != null).toList();
    if (registeredAgents.isEmpty) {
      final localAgents = agents.where(
        (agent) => agent.isLocalInventoryDevice && agent.isOnline,
      );
      return localAgents.firstOrNull;
    }
    final onlineAgents = registeredAgents.where((agent) => agent.isOnline);
    return onlineAgents.firstOrNull ?? registeredAgents.first;
  }

  Future<List<DeviceConfig>> fetchAgents() {
    return _fetchAgentsWithLoading();
  }

  Future<void> setActiveAgent(String deviceId) async {
    await agentRepository.setActiveAgent(deviceId);
    final selected = agentRepository.agents.where((a) => a.representsDeviceId(deviceId)).firstOrNull;
    if (selected != null) {
      await switchAgent(selected);
    }
  }

  void createAgent(String name, {String type = 'computer'}) {
    agentRepository.createAgent(name, type: type);
  }

  Future<void> renameAgent(DeviceConfig device, String name) {
    return agentRepository.renameAgent(device, name);
  }

  void deleteAgent(String deviceId) {
    agentRepository.deleteAgent(deviceId);
  }

  Future<void> resetForLogout() async {
    _inventoryEpoch++;
    _backendFetchesInFlight = 0;
    await agentRepository.clearAgents();
    agentClientRegistry.retainClientsFor(agentRepository.agents);
    conversationClientRegistry?.retainClientsFor(agentRepository.agents);
    final active = _defaultActiveAgent(agentRepository.agents);
    if (active != null) {
      await switchAgent(active);
    } else {
      emit(DeviceNoActive(agents: agentRepository.agents));
    }
  }

  @override
  Future<void> close() async {
    await _authSubscription?.cancel();
    await _agentsSubscription?.cancel();
    agentClientRegistry.dispose();
    conversationClientRegistry?.dispose();
    agentRepository.dispose();
    return super.close();
  }
}
