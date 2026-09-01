import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_failure_reason.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_notice.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_recovery_service.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/evolution/db/runtime/session_route_mutation_coordinator.dart';
import 'package:sanad_agent/evolution/models/session_route_transition.dart';
import 'package:sanad_agent/interfaces/models/delivery/models.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';
import 'package:sanad_agent/interfaces/runtime/session_run_orchestrator.dart';
import 'package:sanad_agent/interfaces/session_payload_builder.dart';

import '../sanad_protocol_bridge.dart';

/// Handles Plan 30 runtime recovery commands: retry, stop, and continue with
/// another provider, plus the canonical route-confirmation broadcast.
class SessionRecoveryCommandHandler {
  final RuntimeRecoveryService _recovery;
  final SessionRunOrchestrator _orchestrator;
  final SessionManager _sessionManager;
  final ProviderInstanceRepository _instanceRepository;
  final SessionRouteMutationCoordinator? _routeCoordinator;
  final SanadProtocolBridge _bridge;

  SessionRecoveryCommandHandler({
    required RuntimeRecoveryService recovery,
    required SessionRunOrchestrator orchestrator,
    required SessionManager sessionManager,
    required ProviderInstanceRepository instanceRepository,
    SessionRouteMutationCoordinator? routeCoordinator,
    required SanadProtocolBridge bridge,
  }) : _recovery = recovery,
       _orchestrator = orchestrator,
       _sessionManager = sessionManager,
       _instanceRepository = instanceRepository,
       _routeCoordinator = routeCoordinator,
       _bridge = bridge;

  Future<void> handleRuntimeStop(CanonicalEvent event) async {
    final sessionId = event.sessionId ?? '';

    if (sessionId.isEmpty) {
      return;
    }

    var forceEmitStopped = false;
    forceEmitStopped = _recovery.hasActiveNotice(sessionId);
    await _orchestrator.requestStop(
      sessionId,
      forceEmitStopped: forceEmitStopped,
    );
  }

  Future<void> handleRuntimeRetry(
    CanonicalEvent event,
    Future<void> Function(Map<String, dynamic> envelope) emitEnvelope,
  ) async {
    final sessionId = event.sessionId ?? '';
    final requestId = event.payload['request_id'] as String?;
    final providerInstanceId = event.payload['provider_instance_id'] as String?;
    final requestedModelId = event.payload['model_id'] as String?;

    if (sessionId.isEmpty) {
      return;
    }

    final resolvedModel = _resolveRouteModel(
      providerInstanceId: providerInstanceId,
      modelId: requestedModelId,
    );

    if (providerInstanceId != null &&
        providerInstanceId.isNotEmpty &&
        (resolvedModel == null || resolvedModel.isEmpty)) {
      _recovery.reportFailure(
        sessionId: sessionId,
        reason: RuntimeFailureReason.modelNotFound,
        providerInstanceId: providerInstanceId,
        requestId: requestId,
        message:
            'The selected provider has no default model. Please choose a model to continue.',
      );
      return;
    }

    final hasRoute =
        (providerInstanceId != null && providerInstanceId.isNotEmpty) ||
        (resolvedModel != null && resolvedModel.isNotEmpty);

    final resumed = await _orchestrator.resumeSuspended(
      sessionId,
      providerInstanceId: providerInstanceId,
      modelId: resolvedModel,
      recoveryReason: 'manual_retry',
      recoveryMessage: 'The agent is retrying the last request.',
      onClaimed: hasRoute
          ? () => _confirmSessionRoute(
              sessionId: sessionId,
              requestId: requestId,
              providerInstanceId: providerInstanceId,
              modelId: resolvedModel,
              reason: 'manual_retry',
              emitEnvelope: emitEnvelope,
            )
          : null,
    );

    if (resumed == ResumeSuspendedResult.unsafeCheckpoint) {
      _recovery.reportFailure(
        sessionId: sessionId,
        reason: RuntimeFailureReason.unknown,
        requestId: requestId,
        providerInstanceId: providerInstanceId,
        title: 'Saved work is not safe to retry',
        message:
            'The interrupted provider request has no recognized preceding checkpoint. '
            'The session remains blocked so you can change provider or stop.',
        forceBlocked: true,
      );
      return;
    }

    if (resumed == ResumeSuspendedResult.missing ||
        (resumed == ResumeSuspendedResult.alreadyResuming &&
            _hasActiveWaitingNotice(sessionId))) {
      if (_hasActiveWaitingNotice(sessionId)) {
        if (hasRoute) {
          _orchestrator.updateActiveRunnerRoute(
            sessionId,
            providerId: providerInstanceId,
            modelId: resolvedModel,
          );
          _orchestrator.rewriteQueuedRoute(
            sessionId,
            providerInstanceId: providerInstanceId,
            modelId: resolvedModel,
            persist: _routeCoordinator == null,
          );
          await _confirmSessionRoute(
            sessionId: sessionId,
            requestId: requestId,
            providerInstanceId: providerInstanceId,
            modelId: resolvedModel,
            reason: 'manual_retry',
            emitEnvelope: emitEnvelope,
          );
        }
        _recovery.abort(sessionId);
        _recovery.emitResuming(
          sessionId: sessionId,
          reason: 'manual_retry',
          requestId: requestId,
          providerInstanceId: providerInstanceId,
          message: 'The agent is retrying the last request.',
        );
      } else if (_orchestrator.isSessionBusy(sessionId)) {
        return;
      } else {
        if (hasRoute) {
          await _confirmSessionRoute(
            sessionId: sessionId,
            requestId: requestId,
            providerInstanceId: providerInstanceId,
            modelId: resolvedModel,
            reason: 'manual_retry',
            emitEnvelope: emitEnvelope,
          );
        }
        _recovery.reportFailure(
          sessionId: sessionId,
          reason: RuntimeFailureReason.unknown,
          requestId: requestId,
          providerInstanceId: providerInstanceId,
          title: 'Saved work could not be resumed',
          message:
              'The daemon could not find the saved work needed for retry. '
              'The session remains blocked so you can retry again, change provider, or stop.',
          forceBlocked: true,
        );
      }
    }
  }

  Future<void> handleRuntimeContinueWithProvider(
    CanonicalEvent event,
    Future<void> Function(Map<String, dynamic> envelope) emitEnvelope,
  ) async {
    final sessionId = event.sessionId ?? '';
    final requestId = event.payload['request_id'] as String?;
    final newProviderInstanceId =
        event.payload['provider_instance_id'] as String? ?? '';
    final modelId = event.payload['model_id'] as String?;

    if (sessionId.isEmpty || newProviderInstanceId.isEmpty) {
      return;
    }

    final resolvedModel = _resolveRouteModel(
      providerInstanceId: newProviderInstanceId,
      modelId: modelId,
    );
    if (resolvedModel == null || resolvedModel.isEmpty) {
      _recovery.reportFailure(
        sessionId: sessionId,
        reason: RuntimeFailureReason.modelNotFound,
        providerInstanceId: newProviderInstanceId,
        requestId: requestId,
        message:
            'The selected provider has no default model. Please choose a model to continue.',
      );
      return;
    }

    final resumed = await _orchestrator.resumeSuspended(
      sessionId,
      providerInstanceId: newProviderInstanceId,
      modelId: resolvedModel,
      recoveryReason: 'provider_changed',
      recoveryMessage: 'Resuming execution with the selected provider.',
      onClaimed: () => _confirmSessionRoute(
        sessionId: sessionId,
        requestId: requestId,
        providerInstanceId: newProviderInstanceId,
        modelId: resolvedModel,
        reason: 'provider_changed',
        emitEnvelope: emitEnvelope,
      ),
    );

    if (resumed == ResumeSuspendedResult.unsafeCheckpoint) {
      _recovery.reportFailure(
        sessionId: sessionId,
        reason: RuntimeFailureReason.unknown,
        requestId: requestId,
        providerInstanceId: newProviderInstanceId,
        title: 'Saved work is not safe to retry',
        message:
            'The interrupted provider request has no recognized preceding checkpoint. '
            'The session remains blocked so you can choose another action or stop.',
        forceBlocked: true,
      );
      return;
    }

    if (resumed == ResumeSuspendedResult.missing ||
        (resumed == ResumeSuspendedResult.alreadyResuming &&
            _hasActiveWaitingNotice(sessionId))) {
      if (_hasActiveWaitingNotice(sessionId)) {
        _orchestrator.updateActiveRunnerRoute(
          sessionId,
          providerId: newProviderInstanceId,
          modelId: resolvedModel,
        );
        _orchestrator.rewriteQueuedRoute(
          sessionId,
          providerInstanceId: newProviderInstanceId,
          modelId: resolvedModel,
          persist: _routeCoordinator == null,
        );
        await _confirmSessionRoute(
          sessionId: sessionId,
          requestId: requestId,
          providerInstanceId: newProviderInstanceId,
          modelId: resolvedModel,
          reason: 'provider_changed',
          emitEnvelope: emitEnvelope,
        );
        _recovery.abort(sessionId);
        _recovery.emitResuming(
          sessionId: sessionId,
          reason: 'provider_changed',
          requestId: requestId,
          providerInstanceId: newProviderInstanceId,
          message: 'Resuming execution with the selected provider.',
        );
      } else if (_orchestrator.isSessionBusy(sessionId)) {
        return;
      } else {
        await _confirmSessionRoute(
          sessionId: sessionId,
          requestId: requestId,
          providerInstanceId: newProviderInstanceId,
          modelId: resolvedModel,
          reason: 'provider_changed',
          emitEnvelope: emitEnvelope,
        );
        _recovery.reportFailure(
          sessionId: sessionId,
          reason: RuntimeFailureReason.unknown,
          requestId: requestId,
          providerInstanceId: newProviderInstanceId,
          title: 'Saved work could not be resumed',
          message:
              'The daemon could not find the saved work needed for the provider change. '
              'The session remains blocked so you can retry, choose another provider, or stop.',
          forceBlocked: true,
        );
      }
    }
  }

  bool _hasActiveWaitingNotice(String sessionId) =>
      _recovery.activeNotice(sessionId)?.status == RuntimeNoticeStatus.waiting;

  Future<void> _confirmSessionRoute({
    required String sessionId,
    required String? requestId,
    required String? providerInstanceId,
    required String? modelId,
    required String reason,
    required Future<void> Function(Map<String, dynamic> envelope) emitEnvelope,
  }) async {
    final session = _sessionManager.getSession(sessionId);
    final resolvedProvider = providerInstanceId ?? session?.providerId;
    final resolvedModel = modelId ?? session?.model;
    if (resolvedProvider == null || resolvedModel == null) return;
    final coordinator = _routeCoordinator;
    if (coordinator == null) {
      // Isolated legacy tests may construct the protocol bridge without the
      // production AgentStateDatabase graph. Production DI always supplies
      // the authoritative coordinator.
      _sessionManager.updateSessionModeling(
        sessionId,
        providerId: resolvedProvider,
        model: resolvedModel,
      );
      final confirmed = _sessionManager.getSession(sessionId)!;
      await emitEnvelope(
        _bridge.buildAgentEventEnvelope(
          CanonicalEvent(
            type: CanonicalEventTypes.sessionPreferencesUpdated,
            sessionId: sessionId,
            payload: {
              'request_id': requestId,
              ...buildSessionPayload(session: confirmed),
            },
            delivery: const DeliveryPolicy.platformFamily(
              PlatformFamily.sanadClient,
            ),
          ),
        ),
      );
      return;
    }
    final route = coordinator.mutate(
      sessionId: sessionId,
      providerInstanceId: resolvedProvider,
      model: resolvedModel,
      source: SessionRouteSource.recovery,
      reason: reason,
      requestId: requestId,
    );
    if (!route.changed || route.eventId == null) return;
    await emitEnvelope(
      _bridge.buildAgentEventEnvelope(
        CanonicalEvent(
          type: CanonicalEventTypes.sessionPreferencesUpdated,
          sessionId: sessionId,
          payload: route.toPayload(),
          eventId: route.eventId!,
          delivery: const DeliveryPolicy.platformFamily(
            PlatformFamily.sanadClient,
          ),
        ),
      ),
    );
  }

  String? _resolveRouteModel({
    required String? providerInstanceId,
    required String? modelId,
  }) {
    if (modelId != null && modelId.isNotEmpty) {
      return modelId;
    }
    if (providerInstanceId == null || providerInstanceId.isEmpty) {
      return null;
    }
    final instance = _instanceRepository.findById(providerInstanceId);
    final defaultModel = instance?.defaultModel?.trim();
    if (defaultModel == null || defaultModel.isEmpty) {
      return null;
    }
    return defaultModel;
  }
}
