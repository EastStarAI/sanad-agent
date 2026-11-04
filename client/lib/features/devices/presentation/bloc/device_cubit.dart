import 'dart:async';

import 'package:sanad_client/features/devices/domain/device_client_registry.dart';
import 'package:sanad_client/features/devices/domain/device_repository.dart';
import 'package:sanad_client/core/interfaces/socket_service.dart';
import 'package:sanad_client/features/conversations/domain/conversation_client.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:logging/logging.dart';
import 'package:sanad_client/core/navigation/nav_trace.dart' show shortId;

import '../../domain/models/device_config.dart';
import 'device_state.dart';

class DeviceCubit extends Cubit<DeviceState> {
  static final _logger = Logger('DeviceCubit');

  final ISocketService socketService;
  final IDeviceRepository agentRepository;
  final IDeviceClientRegistry agentClientRegistry;
  final ManagedConversationClientRegistry? conversationClientRegistry;
  StreamSubscription? _agentsSubscription;
  StreamSubscription? _authSubscription;
  int _backendFetchesInFlight = 0;
  int _inventoryEpoch = 0;
  int _inventoryFetchRetries = 0;

  /// True while the active device is a fallback for a remembered device that
  /// cannot appear. The remembered preference is kept, so it is restored when
  /// it becomes available again unless the user picks a device first.
  bool _isFallbackSelection = false;

  DeviceCubit({
    required this.socketService,
    required this.agentRepository,
    required this.agentClientRegistry,
    this.conversationClientRegistry,
  }) : super(AgentInitial());

  /// Maximum automatic re-attempts after a failed inventory fetch.
  ///
  /// The first request after sign-in can be lost while the gateway connection
  /// settles (the socket accepts it and drops immediately), and the server then
  /// answers the next request in well under a second. One automatic retry hides
  /// Up to [_maxInventoryFetchRetries] automatic re-attempts hide that
  /// transport flap; the next failure stays a typed error with Retry.
  static const int _maxInventoryFetchRetries = 2;

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
        await _activate(active);
      } else {
        emit(
          DeviceNoActive(
            agents: agentRepository.agents,
            isLoadingFromBackend: _isInventoryPending,
          ),
        );
      }
    } catch (e) {
      emit(AgentError('Failed to load agents: $e'));
    }
  }

  /// Marks the inventory as awaiting a fresh result.
  ///
  /// Signing in completes authentication before the cloud gateway is ready, so
  /// between the two the inventory holds no data. Publishing that window as an
  /// authoritative empty surface is what made a successful sign-in look like
  /// lost devices, so the surface keeps a loading phase until the fetch lands.
  void markInventoryPending() {
    if (isClosed) return;
    final current = state;
    if (current is DeviceActive) return;
    final cached = current is DeviceNoActive ? current.agents : agentRepository.agents;
    if (current is DeviceNoActive && current.isLoadingFromBackend && current.agents.length == cached.length) {
      return;
    }
    _logger.info(
      'device.inventory.pending reason=sign-in cached=${cached.length} '
      'authoritative=${agentRepository.hasAuthoritativeInventory} '
      'gatewayPending=${agentRepository.isCloudInventoryPending}',
    );
    emit(DeviceNoActive(agents: cached, isLoadingFromBackend: true));
  }

  Future<List<DeviceConfig>> _fetchAgentsWithLoading() async {
    final fetchEpoch = _inventoryEpoch;
    _logger.info(
      'device.inventory.fetch.start ready=${agentRepository.isInventoryReady} '
      'authoritative=${agentRepository.hasAuthoritativeInventory} '
      'gatewayPending=${agentRepository.isCloudInventoryPending} inflight=$_backendFetchesInFlight',
    );
    if (!agentRepository.isInventoryReady) {
      // The gateway cannot answer yet, so a fetch would only echo the cached
      // snapshot (usually empty). Keep the pending phase: the socket's auth
      // event and the resume reconnect re-enter this fetch once it is ready.
      _logger.info('device.inventory.fetch.skipped reason=gateway-not-ready');
      markInventoryPending();
      return agentRepository.agents;
    }
    _backendFetchesInFlight++;
    _publishBackendLoading();

    try {
      final agents = await agentRepository.fetchAgents();
      _inventoryFetchRetries = 0;
      return agents;
    } catch (error) {
      // A failed fetch (including a timeout) must never wipe valid cached data
      // nor trigger a logout. We surface a typed error while retaining agents.
      // A stale fetch (superseded by logout/reset, epoch changed) must not
      // surface its error on the reset surface: only the current epoch's error
      // is shown, keeping event ordering causal (Plan 97g).
      if (fetchEpoch != _inventoryEpoch) return agentRepository.agents;
      if (_shouldRetryInventoryFetch(error)) {
        _inventoryFetchRetries++;
        _logger.info(
          'device.inventory.fetch.retry reason=${error.runtimeType} '
          'attempt=$_inventoryFetchRetries',
        );
        unawaited(
          Future<void>.delayed(const Duration(milliseconds: 800), () {
            if (!isClosed && fetchEpoch == _inventoryEpoch) {
              unawaited(_fetchAgentsWithLoading());
            }
          }),
        );
      } else {
        _logger.info('device.inventory.fetch.failed reason=${error.runtimeType}');
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

  /// Retry a failed inventory fetch while no authoritative answer exists.
  ///
  /// The first request after sign-in can be emitted onto a connection that drops
  /// immediately; the same request then answers in about 100ms. By the time the
  /// 5s timeout fires the socket can already report `error`, so "is the gateway
  /// still pending" is the wrong test: what matters is that no inventory answer
  /// has landed for this session yet.
  bool _shouldRetryInventoryFetch(Object error) {
    if (_inventoryFetchRetries >= _maxInventoryFetchRetries) return false;
    return !agentRepository.hasAuthoritativeInventory;
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

  /// True while the inventory still has no authoritative answer for the account.
  ///
  /// An empty list is only a real answer once a `get_devices` response has
  /// landed for this session. Every other empty moment (connecting, a reconnect,
  /// a transport error, or a fetch in flight) is pending data, so the surfaces
  /// keep their loading phase instead of claiming the account has no devices.
  bool get _isInventoryPending =>
      _hasBackendFetchInFlight || !agentRepository.hasAuthoritativeInventory;

  void _publishBackendLoading() {
    if (isClosed) return;
    final current = state;
    if (current is! DeviceNoActive) return;

    // A failed fetch owns the surface until the next attempt: a retry-able
    // error must not be hidden behind an endless loading phase.
    final isLoading = current.errorMessage == null && _isInventoryPending;
    if (current.isLoadingFromBackend != isLoading || (isLoading && current.errorMessage != null)) {
      // Starting a new fetch clears the previous transient error.
      _logger.info(
        'device.inventory.phase phase=${isLoading ? 'loading' : current.phase.name} '
        'count=${current.agents.length} gatewayPending=${agentRepository.isCloudInventoryPending}',
      );
      emit(
        current.copyWith(
          isLoadingFromBackend: isLoading,
          clearError: isLoading,
        ),
      );
    }
  }

  void _handleAgentsUpdated(List<DeviceConfig> agents) {
    _logger.info(
      'device.inventory.update count=${agents.length} state=${state.runtimeType} '
      'authoritative=${agentRepository.hasAuthoritativeInventory} '
      'gatewayPending=${agentRepository.isCloudInventoryPending} inflight=$_backendFetchesInFlight',
    );
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
      final remembered = _isFallbackSelection ? agentRepository.getActiveAgent() : null;
      if (remembered != null && !remembered.representsDeviceId(s.activeAgent.id)) {
        _isFallbackSelection = false;
        _logger.info('device.fallback restored remembered=${shortId(remembered.id)}');
        unawaited(_activate(remembered));
        return;
      }
      final activeMatches = stableAgents.where(
        (agent) => agent.representsDeviceId(s.activeAgent.id) || s.activeAgent.representsDeviceId(agent.id),
      );
      if (activeMatches.isEmpty) {
        final replacement = _resolveInitialActiveAgent(stableAgents);
        if (replacement != null) {
          unawaited(_activate(replacement));
        } else {
          emit(
            DeviceNoActive(
              agents: agents,
              isLoadingFromBackend: _isInventoryPending,
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
      _logger.info(
        'device.inventory.resolve active=${active == null ? 'none' : shortId(active.id)} '
        'persistedId=${shortId(agentRepository.getActiveAgentId())} count=${agents.length}',
      );
      if (active != null) {
        unawaited(_activate(active));
      } else {
        emit(
          DeviceNoActive(
            agents: agents,
            isLoadingFromBackend: _isInventoryPending,
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
  /// When NO device id is persisted we fall back to a sensible default
  /// (online registered device, else the local device). When a persisted
  /// device can no longer appear because no cloud inventory is pending (cloud
  /// disabled, signed out, or the cloud socket failed), we fall back the same
  /// way but keep the persisted id, so the remembered device is restored if it
  /// returns before the user picks another one.
  DeviceConfig? _resolveInitialActiveAgent(List<DeviceConfig> agents) {
    final persisted = agentRepository.getActiveAgent();
    if (persisted != null) {
      _isFallbackSelection = false;
      return persisted;
    }
    final hasPersistedId = agentRepository.getActiveAgentId() != null;
    // A device id is saved but its config is not loaded yet -> wait for the
    // device list instead of switching to an arbitrary default.
    if (hasPersistedId && agentRepository.isCloudInventoryPending) return null;
    final fallback = _defaultActiveAgent(agents);
    final enteringFallback = hasPersistedId && fallback != null;
    if (enteringFallback && !_isFallbackSelection) {
      _logger.info(
        'device.fallback entered remembered=${shortId(agentRepository.getActiveAgentId())} '
        'active=${shortId(fallback.id)}',
      );
    }
    _isFallbackSelection = enteringFallback;
    return fallback;
  }

  /// Explicit device selection (user or navigation). It ends any fallback,
  /// so a remembered device is no longer restored over the user's choice.
  Future<void> switchAgent(DeviceConfig config) async {
    if (_isFallbackSelection) {
      _logger.info('device.fallback ended by explicit selection active=${shortId(config.id)}');
    }
    _isFallbackSelection = false;
    await _activate(config);
  }

  Future<void> _activate(DeviceConfig config) async {
    _logger.info('device.activate.start id=${shortId(config.id)} name="${config.name}"');
    agentClientRegistry.getOrCreateClientForAgent(config);
    conversationClientRegistry?.getOrCreateConversationClientForAgent(config);

    final currentAgents = agentRepository.agents;
    emit(
      DeviceActive(
        activeAgent: config,
        agents: currentAgents,
      ),
    );
    _logger.info('device.activate.done id=${shortId(config.id)} agents=${currentAgents.length}');
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
    _inventoryFetchRetries = 0;
    _isFallbackSelection = false;
    await agentRepository.clearAgents();
    agentClientRegistry.retainClientsFor(agentRepository.agents);
    conversationClientRegistry?.retainClientsFor(agentRepository.agents);
    final active = _defaultActiveAgent(agentRepository.agents);
    if (active != null) {
      await _activate(active);
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
