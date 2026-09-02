import 'dart:async';
import 'package:logging/logging.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_recovery_service.dart';
import 'package:sanad_agent/evolution/db/persisted_runtime_state_repository.dart';
import 'package:sanad_agent/evolution/db/runtime/session_route_mutation_coordinator.dart';
import 'package:sanad_agent/evolution/models/session_execution_snapshot.dart';
import 'platforms/base_platform.dart';
import 'models/delivery/models.dart';
import 'models/gateway_event.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/interfaces/runtime/compaction_lifecycle_relay.dart';
import 'package:sanad_agent/interfaces/runtime/session_run_orchestrator.dart';
import 'package:sanad_agent/interfaces/runtime/platform_runtime_bridge.dart';

class GatewayManager {
  final _logger = Logger('GatewayManager');
  final List<BasePlatform> _platforms = [];
  final Map<String, StreamSubscription> _subscriptions = {};
  StreamSubscription<GatewayResponse>? _orchestratorSubscription;
  StreamSubscription<SessionExecutionSnapshot>? _executionStateSubscription;
  StreamSubscription<SessionRouteMutationResult>? _routeStateSubscription;

  List<GatewayEvent> getQueuedEvents(String sessionId) {
    if (getIt.isRegistered<SessionRunOrchestrator>()) {
      return getIt<SessionRunOrchestrator>().getQueuedEvents(sessionId);
    }
    return const [];
  }

  void registerPlatform(BasePlatform platform) {
    _platforms.add(platform);
  }

  /// Gate F.1 — subscribes the gateway manager to the orchestrator's
  /// response and notice streams WITHOUT initializing any platform.
  ///
  /// Must be invoked from daemon startup before
  /// `SessionRunOrchestrator.restorePersistedState()` so that bootstrap
  /// responses and notices scheduled inside restore (via `Future.microtask`
  /// from queue-only sessions) reach a live subscriber and are not dropped
  /// on the broadcast stream controller. The actual platform transports
  /// are bound later by [start].
  void attachOrchestrator() {
    if (getIt.isRegistered<PlatformRuntimeBridge>()) {
      getIt<PlatformRuntimeBridge>().attachResponseSink(
        _onOrchestratorResponse,
      );
    }
    if (_orchestratorSubscription != null) {
      return;
    }
    if (getIt.isRegistered<SessionRunOrchestrator>()) {
      final orchestrator = getIt<SessionRunOrchestrator>();
      _orchestratorSubscription = orchestrator.responses.listen(
        _onOrchestratorResponse,
      );
    }
    CompactionLifecycleRelay.sink = _onOrchestratorResponse;
    if (getIt.isRegistered<RuntimeRecoveryService>()) {
      getIt<RuntimeRecoveryService>().attachNoticeSink(_onRuntimeNotice);
    }
    if (_executionStateSubscription == null &&
        getIt.isRegistered<PersistedRuntimeStateRepository>()) {
      _executionStateSubscription = getIt<PersistedRuntimeStateRepository>()
          .executionState
          .changes
          .listen(_onExecutionStateChanged);
    }
    if (_routeStateSubscription == null &&
        getIt.isRegistered<SessionRouteMutationCoordinator>()) {
      _routeStateSubscription = getIt<SessionRouteMutationCoordinator>().changes
          .listen(_onSessionRouteChanged);
    }
  }

  Future<void> start() async {
    _logger.info(
      'Starting Gateway Manager with ${_platforms.length} platforms...',
    );

    // Idempotent: allows callers to attach the orchestrator early (Gate F.1)
    // and still call start() later without double-subscribing.
    attachOrchestrator();

    for (final platform in _platforms) {
      try {
        await platform.initialize();
        _logger.info('Platform ${platform.platformId} initialized.');
        final subscription = platform.eventStream.listen((event) {
          unawaited(
            _handleEvent(platform, event).catchError((error, stack) {
              _handleEventFailure(platform, event, error, stack);
            }),
          );
        });
        _subscriptions[platform.platformId] = subscription;
      } catch (e, stack) {
        _logger.severe(
          'Platform ${platform.platformId} failed to initialize. Continuing with remaining platforms.',
          e,
          stack,
        );
      }
    }
  }

  /// Phase 27 — resolve the platform that produced the triggering request.
  BasePlatform? _resolveOriginPlatform(String? platformId) {
    if (platformId == null) return null;
    for (final platform in _platforms) {
      if (platform.platformId == platformId) return platform;
    }
    return null;
  }

  /// Phase 27 — delivery-policy router. The runtime owns the semantic scope
  /// of each event; this manager selects the destination platforms by
  /// declared `delivery` and platform `descriptor.family`, without a switch
  /// over event names or platform-id strings.
  void _onOrchestratorResponse(GatewayResponse response) {
    final originPlatform = _resolveOriginPlatform(response.platformId);
    final originContext = originPlatform != null
        ? _buildOriginContext(originPlatform, response)
        : null;
    final routed = response.copyWithDelivery(origin: originContext);

    final reason = routed.delivery.validate();
    if (reason != null) {
      _logger.warning(
        'Dropping response ${_shortEventId(routed)}: invalid delivery ($reason).',
      );
      return;
    }

    switch (routed.delivery.scope) {
      case DeliveryScope.origin:
        _deliverOrigin(routed, originPlatform);
      case DeliveryScope.platformFamily:
        _deliverPlatformFamily(routed, originPlatform);
      case DeliveryScope.hardware:
        _deliverHardware(routed, originPlatform);
      case DeliveryScope.device:
        _deliverDevice(routed, originPlatform);
    }
  }

  void _onRuntimeNotice(Map<String, dynamic> payload) {
    final sessionId = payload['session_id']?.toString();
    if (sessionId == null || sessionId.isEmpty) {
      _logger.warning('Dropping runtime notice without session_id.');
      return;
    }
    _onOrchestratorResponse(
      GatewayResponse(
        sessionId: sessionId,
        message: Message(
          role: MessageRole.assistant,
          metadata: {
            'canonical_event_type': payload['status'] == 'cleared'
                ? 'session.runtime_notice_cleared'
                : 'session.runtime_notice',
            'canonical_payload': payload,
          },
        ),
      ),
    );
  }

  void _onExecutionStateChanged(SessionExecutionSnapshot snapshot) {
    _onOrchestratorResponse(
      GatewayResponse(
        sessionId: snapshot.sessionId,
        message: Message(
          role: MessageRole.assistant,
          metadata: {
            'canonical_event_type': 'session.execution_state_changed',
            'canonical_payload': snapshot.toPayload(),
          },
        ),
        delivery: DeliveryPolicy.platformFamily(PlatformFamily.sanadClient),
      ),
    );
  }

  void _onSessionRouteChanged(SessionRouteMutationResult route) {
    if (!route.changed || route.eventId == null) return;
    _onOrchestratorResponse(
      GatewayResponse(
        sessionId: route.sessionId,
        eventId: route.eventId!,
        message: Message(
          role: MessageRole.assistant,
          metadata: {
            'canonical_event_type': 'session_preferences_updated',
            'canonical_payload': route.toPayload(),
          },
        ),
        delivery: DeliveryPolicy.platformFamily(PlatformFamily.sanadClient),
      ),
    );
  }

  OriginContext _buildOriginContext(
    BasePlatform origin,
    GatewayResponse response,
  ) {
    final d = origin.descriptor;
    return OriginContext(
      platformFamily: d.platformFamily,
      transport: d.transport,
      platformInstanceId: d.platformInstanceId ?? origin.platformId,
      platformId: origin.platformId,
      requestId: response.delivery.requestId,
      sessionId: response.sessionId,
    );
  }

  /// `origin` — return to the originating platform instance and conversation
  /// only. Fail closed when the origin is unknown (no broadcast fallback).
  void _deliverOrigin(GatewayResponse response, BasePlatform? originPlatform) {
    if (originPlatform == null) {
      _logger.warning(
        'Dropping origin response ${_shortEventId(response)}: '
        'origin platform not found (fail closed).',
      );
      return;
    }
    if (_isUserEchoSuppressed(response, originPlatform)) return;
    _send(originPlatform, response);
  }

  /// `platform_family` — fan out to every platform instance of the declared
  /// family. `sanad_client` local + cloud synchronize this way. External
  /// families are isolated because they never share this family with Sanad.
  void _deliverPlatformFamily(
    GatewayResponse response,
    BasePlatform? originPlatform,
  ) {
    final family = response.delivery.platformFamily!;
    var delivered = 0;
    for (final platform in _platforms) {
      if (platform.descriptor.platformFamily != family) continue;
      if (_isUserEchoSuppressed(response, platform)) continue;
      _send(platform, response);
      delivered++;
    }
    if (delivered == 0) {
      _logger.warning(
        'platform_family delivery ${_shortEventId(response)} '
        'reached 0 platforms (family=${family.value}).',
      );
    }
  }

  /// `hardware` — target the platform instance(s) owning `target_hardware_id`
  /// within the declared family. No fallback to family broadcast.
  /// Phase C routes to the owning family; Phase D refines per-socket hardware
  /// filtering inside the local connection registry.
  void _deliverHardware(
    GatewayResponse response,
    BasePlatform? originPlatform,
  ) {
    final family = response.delivery.platformFamily!;
    final target = response.delivery.targetHardwareId!;
    var delivered = 0;
    for (final platform in _platforms) {
      if (platform.descriptor.platformFamily != family) continue;
      // The platform's sendResponse is responsible for filtering by hardware
      // identity in Phase D; for now we deliver to family platforms and let
      // the local registry filter by `_sessionHardwareIds`.
      if (_isUserEchoSuppressed(response, platform)) continue;
      _send(platform, response);
      delivered++;
    }
    if (delivered == 0) {
      _logger.warning(
        'hardware delivery ${_shortEventId(response)} '
        'target=$target reached 0 platforms (fail closed).',
      );
    }
  }

  /// `device` — app → daemon direction. Routes to the local daemon transport
  /// of the declared family (sanad_client local in this phase).
  void _deliverDevice(GatewayResponse response, BasePlatform? originPlatform) {
    for (final platform in _platforms) {
      if (platform.descriptor.platformFamily != PlatformFamily.sanadClient) {
        continue;
      }
      if (platform.descriptor.transport != PlatformTransport.local) continue;
      _send(platform, response);
    }
  }

  /// User-message echoes are delivered only to platforms that opted in via
  /// `shouldReceiveUserEcho`. Non-echo events are always eligible.
  bool _isUserEchoSuppressed(GatewayResponse response, BasePlatform platform) {
    return response.message.role == MessageRole.user &&
        !platform.shouldReceiveUserEcho;
  }

  void _send(BasePlatform platform, GatewayResponse response) {
    try {
      unawaited(
        platform.sendResponse(response).catchError((error, stack) {
          _logger.warning(
            'Failed to deliver ${_shortEventId(response)} '
            'to ${platform.platformId}: $error',
            error,
            stack,
          );
        }),
      );
    } catch (e, stack) {
      _logger.warning(
        'Failed to deliver ${_shortEventId(response)} '
        'to ${platform.platformId}: $e',
        e,
        stack,
      );
    }
  }

  String _shortEventId(GatewayResponse response) => response.eventId.length > 12
      ? response.eventId.substring(0, 12)
      : response.eventId;

  Future<void> _handleEvent(BasePlatform platform, GatewayEvent event) async {
    _logger.info(
      '[${platform.platformId}] Incoming event for session: ${event.sessionId}',
    );

    final payload = event.metadata['payload'];
    final commandPayload = payload is Map
        ? Map<String, dynamic>.from(payload)
        : const <String, dynamic>{};
    final origin = OriginContext(
      platformFamily: platform.descriptor.platformFamily,
      transport: platform.descriptor.transport,
      platformInstanceId:
          platform.descriptor.platformInstanceId ?? platform.platformId,
      platformId: platform.platformId,
      requestId: commandPayload['request_id']?.toString(),
      sessionId: event.sessionId,
      deviceId:
          event.metadata['device_id']?.toString() ??
          commandPayload['device_id']?.toString(),
      hardwareId:
          event.metadata['hardware_id']?.toString() ??
          commandPayload['hardware_id']?.toString(),
    );
    final originatedEvent = event.copyWithOrigin(origin);
    if (getIt.isRegistered<PlatformRuntimeBridge>()) {
      getIt<PlatformRuntimeBridge>().registerSessionOrigin(
        event.sessionId,
        origin,
      );
    }

    if (getIt.isRegistered<SessionRunOrchestrator>()) {
      await getIt<SessionRunOrchestrator>().handleEvent(originatedEvent);
    } else {
      _logger.severe(
        'SessionRunOrchestrator not registered. Cannot handle event.',
      );
    }
  }

  void _handleEventFailure(
    BasePlatform platform,
    GatewayEvent event,
    Object error,
    StackTrace stack,
  ) {
    _logger.severe(
      '[${platform.platformId}] Command failed for session '
      '${event.sessionId}; daemon remains available.',
      error,
      stack,
    );
    _onOrchestratorResponse(
      GatewayResponse(
        sessionId: event.sessionId,
        platformId: platform.platformId,
        message: Message(
          role: MessageRole.assistant,
          content: 'Error: The command could not be processed.',
        ),
        isComplete: true,
        runId: event.runId,
      ),
    );
  }

  Future<void> stop() async {
    await _orchestratorSubscription?.cancel();
    _orchestratorSubscription = null;
    await _executionStateSubscription?.cancel();
    _executionStateSubscription = null;
    await _routeStateSubscription?.cancel();
    _routeStateSubscription = null;
    for (final subscription in _subscriptions.values) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    for (final platform in _platforms) {
      await platform.dispose();
    }
  }
}
