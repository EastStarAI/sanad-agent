import 'dart:async';

import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/evolution/db/message_history_identity.dart';
import 'package:sanad_agent/evolution/db/persisted_runtime_state_repository.dart';
import 'package:sanad_agent/evolution/models/session_execution_snapshot.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/interfaces/models/agent_turn_request.dart';
import 'package:sanad_agent/interfaces/models/gateway_event.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';
import 'package:sanad_agent/interfaces/runtime/session_run_orchestrator.dart';
import 'package:sanad_agent/interfaces/runtime/turn_replay_service.dart';

import '../sanad_protocol_bridge.dart';

class SessionTurnReplayCommandHandler {
  static const Duration defaultIdleWaitTimeout = Duration(seconds: 15);
  static const Duration defaultIdlePollInterval = Duration(milliseconds: 25);

  final SessionRunOrchestrator _orchestrator;
  final SessionManager _sessionManager;
  final PersistedRuntimeStateRepository? _persistedState;
  final SanadProtocolBridge _bridge;
  final Duration _idleWaitTimeout;
  final Duration _idlePollInterval;
  final Set<String> _sessionsInFlight = <String>{};

  SessionTurnReplayCommandHandler({
    required SessionRunOrchestrator orchestrator,
    required SessionManager sessionManager,
    PersistedRuntimeStateRepository? persistedState,
    required SanadProtocolBridge bridge,
    Duration idleWaitTimeout = defaultIdleWaitTimeout,
    Duration idlePollInterval = defaultIdlePollInterval,
  }) : _orchestrator = orchestrator,
       _sessionManager = sessionManager,
       _persistedState = persistedState,
       _bridge = bridge,
       _idleWaitTimeout = idleWaitTimeout,
       _idlePollInterval = idlePollInterval;

  Future<void> handle(
    CanonicalEvent event,
    Future<void> Function(Map<String, dynamic> envelope) emitEnvelope,
  ) async {
    final sessionId =
        event.sessionId ?? event.payload['session_id']?.toString() ?? '';
    final targetRequestId =
        event.payload['target_request_id']?.toString().trim() ?? '';
    final targetMessageId =
        event.payload['target_message_id']?.toString().trim() ?? '';
    final targetTurnId =
        event.payload['target_turn_id']?.toString().trim() ?? '';
    final commandRequestId =
        event.payload['request_id']?.toString().trim() ?? '';
    final action = event.payload['action']?.toString() ?? 'retry';
    final confirmed = event.payload['confirmed_replay_unsafe'] == true;
    final confirmedDropSteers =
        event.payload['confirmed_drop_steers'] == true;
    final expectedHistoryRevision = _parseRevision(
      event.payload['expected_history_revision'],
    );

    if (sessionId.isEmpty ||
        targetRequestId.isEmpty ||
        targetMessageId.isEmpty ||
        targetTurnId.isEmpty ||
        commandRequestId.isEmpty ||
        expectedHistoryRevision == null) {
      await _emitResult(
        emitEnvelope,
        sessionId: sessionId,
        requestId: commandRequestId,
        targetRequestId: targetRequestId,
        targetMessageId: targetMessageId,
        targetTurnId: targetTurnId,
        action: action,
        outcome: 'invalid_request',
        safety: TurnReplaySafety.unknown,
      );
      return;
    }
    if (action != 'retry' && action != 'edit') {
      await _emitResult(
        emitEnvelope,
        sessionId: sessionId,
        requestId: commandRequestId,
        targetRequestId: targetRequestId,
        targetMessageId: targetMessageId,
        targetTurnId: targetTurnId,
        action: action,
        outcome: 'invalid_request',
        safety: TurnReplaySafety.unknown,
      );
      return;
    }
    if (!_sessionsInFlight.add(sessionId)) {
      await _emitResult(
        emitEnvelope,
        sessionId: sessionId,
        requestId: commandRequestId,
        targetRequestId: targetRequestId,
        targetMessageId: targetMessageId,
        targetTurnId: targetTurnId,
        action: action,
        outcome: 'already_in_progress',
        safety: TurnReplaySafety.unknown,
      );
      return;
    }

    try {
      final replay = TurnReplayService(
        sessionManager: _sessionManager,
        persistedState: _persistedState,
      );
      final inspection = replay.inspect(
        sessionId: sessionId,
        targetRequestId: targetRequestId,
        targetMessageId: targetMessageId,
        targetTurnId: targetTurnId,
        expectedHistoryRevision: expectedHistoryRevision,
      );
      if (!inspection.canReplay) {
        await _emitResult(
          emitEnvelope,
          sessionId: sessionId,
          requestId: commandRequestId,
          targetRequestId: targetRequestId,
          targetMessageId: targetMessageId,
          targetTurnId: targetTurnId,
          action: action,
          outcome: _failureName(inspection.failure!),
          safety: inspection.safety,
          containsSteers: inspection.containsSteers,
          historyRevision: inspection.historyRevision,
        );
        return;
      }
      if (inspection.requiresConfirmation && !confirmed) {
        await _emitResult(
          emitEnvelope,
          sessionId: sessionId,
          requestId: commandRequestId,
          targetRequestId: targetRequestId,
          targetMessageId: targetMessageId,
          targetTurnId: targetTurnId,
          action: action,
          outcome: 'confirmation_required',
          safety: inspection.safety,
          requiresConfirmation: true,
          containsSteers: inspection.containsSteers,
          historyRevision: inspection.historyRevision,
        );
        return;
      }
      if (inspection.containsSteers && !confirmedDropSteers) {
        await _emitResult(
          emitEnvelope,
          sessionId: sessionId,
          requestId: commandRequestId,
          targetRequestId: targetRequestId,
          targetMessageId: targetMessageId,
          targetTurnId: targetTurnId,
          action: action,
          outcome: 'steer_reinjection_confirmation_required',
          safety: inspection.safety,
          containsSteers: true,
          requiresSteerDropConfirmation: true,
          historyRevision: inspection.historyRevision,
        );
        return;
      }

      final editedMessage = event.payload['message']?.toString().trim();
      final replayMessage = action == 'edit'
          ? (editedMessage ?? '')
          : inspection.originalMessage;
      if (replayMessage.isEmpty) {
        await _emitResult(
          emitEnvelope,
          sessionId: sessionId,
          requestId: commandRequestId,
          targetRequestId: targetRequestId,
          targetMessageId: targetMessageId,
          targetTurnId: targetTurnId,
          action: action,
          outcome: 'empty_message',
          safety: inspection.safety,
        );
        return;
      }

      await _orchestrator.requestStop(sessionId);
      final reachedIdle = await _waitForAuthoritativeIdle(sessionId);
      if (!reachedIdle) {
        await _emitResult(
          emitEnvelope,
          sessionId: sessionId,
          requestId: commandRequestId,
          targetRequestId: targetRequestId,
          targetMessageId: targetMessageId,
          targetTurnId: targetTurnId,
          action: action,
          outcome: 'session_not_idle',
          safety: inspection.safety,
          containsSteers: inspection.containsSteers,
          historyRevision: inspection.historyRevision,
        );
        return;
      }
      final postIdle = replay.inspect(
        sessionId: sessionId,
        targetRequestId: targetRequestId,
        targetMessageId: targetMessageId,
        targetTurnId: targetTurnId,
        expectedHistoryRevision: expectedHistoryRevision,
      );
      if (!postIdle.canReplay) {
        await _emitResult(
          emitEnvelope,
          sessionId: sessionId,
          requestId: commandRequestId,
          targetRequestId: targetRequestId,
          targetMessageId: targetMessageId,
          targetTurnId: targetTurnId,
          action: action,
          outcome: _postIdleFailureName(postIdle.failure!),
          safety: postIdle.safety,
          containsSteers: postIdle.containsSteers,
          historyRevision: postIdle.historyRevision,
        );
        return;
      }
      final admission = replay.admitReplacement(
        inspection: postIdle,
        replacementRequestId: commandRequestId,
        replacementText: replayMessage,
        action: action,
      );
      if (admission == null) {
        final current = replay.inspect(
          sessionId: sessionId,
          targetRequestId: targetRequestId,
          targetMessageId: targetMessageId,
          targetTurnId: targetTurnId,
          expectedHistoryRevision: expectedHistoryRevision,
        );
        await _emitResult(
          emitEnvelope,
          sessionId: sessionId,
          requestId: commandRequestId,
          targetRequestId: targetRequestId,
          targetMessageId: targetMessageId,
          targetTurnId: targetTurnId,
          action: action,
          outcome:
              current.failure ==
                  TurnReplayInspectionFailure.historyRevisionMismatch
              ? 'history_revision_mismatch'
              : 'stale_turn_boundary',
          safety: inspection.safety,
          containsSteers: inspection.containsSteers,
          historyRevision: current.historyRevision,
        );
        return;
      }

      final session = _sessionManager.getSession(sessionId);
      final providerInstanceId = event.payload['provider_instance_id']
          ?.toString()
          .trim();
      final modelId = (event.payload['model_id'] ?? event.payload['model'])
          ?.toString()
          .trim();
      final thinkingMode = event.payload['thinking_mode']?.toString().trim();
      final request = AgentTurnRequest(
        sessionId: sessionId,
        message: replayMessage,
        workspaceId: session?.workspaceId,
        providerInstanceId:
            providerInstanceId == null || providerInstanceId.isEmpty
            ? null
            : providerInstanceId,
        model: modelId == null || modelId.isEmpty ? null : modelId,
        thinkingMode: thinkingMode == null || thinkingMode.isEmpty
            ? null
            : thinkingMode,
        requestId: commandRequestId,
        metadata: {
          'turn_replay_action': action,
          'replayed_request_id': targetRequestId,
        },
      );
      final gatewayEvent = GatewayEvent(
        sessionId: sessionId,
        platformId: 'sanad_client',
        message: Message(
          role: MessageRole.user,
          content: replayMessage,
          metadata: {
            'request_id': commandRequestId,
            'message_id': admission.replacementMessageId,
            'turn_id': admission.replacementTurnId,
            'input_kind': MessageHistoryIdentity.rootTurn,
            'history_status': MessageHistoryIdentity.active,
          },
        ),
        metadata: {'command': 'think', 'payload': request.toMetadata()},
        turnRequest: request,
      );

      await _emitResult(
        emitEnvelope,
        sessionId: sessionId,
        requestId: commandRequestId,
        targetRequestId: targetRequestId,
        targetMessageId: targetMessageId,
        targetTurnId: targetTurnId,
        action: action,
        outcome: 'accepted',
        safety: postIdle.safety,
        containsSteers: postIdle.containsSteers,
        historyRevision: admission.historyRevision,
      );
      unawaited(_orchestrator.handleEvent(gatewayEvent));
    } catch (_) {
      await _emitResult(
        emitEnvelope,
        sessionId: sessionId,
        requestId: commandRequestId,
        targetRequestId: targetRequestId,
        targetMessageId: targetMessageId,
        targetTurnId: targetTurnId,
        action: action,
        outcome: 'failed',
        safety: TurnReplaySafety.unknown,
      );
    } finally {
      _sessionsInFlight.remove(sessionId);
    }
  }

  /// Stop acknowledgement and terminal work items are not dispatch authority.
  /// Replay waits until the persisted snapshot is exactly [idle], including
  /// queued, running, waiting, blocked, and resuming work after scoped stop.
  Future<bool> _waitForAuthoritativeIdle(String sessionId) async {
    if (_persistedState == null) return false;
    final deadline = DateTime.now().add(_idleWaitTimeout);
    while (true) {
      final snapshot = _persistedState.executionSnapshots.getSnapshot(
        sessionId,
      );
      if (snapshot.state == SessionExecutionState.idle) return true;
      if (!DateTime.now().isBefore(deadline)) return false;
      await Future<void>.delayed(_idlePollInterval);
    }
  }

  Future<void> _emitResult(
    Future<void> Function(Map<String, dynamic> envelope) emitEnvelope, {
    required String sessionId,
    required String requestId,
    required String targetRequestId,
    String targetMessageId = '',
    String targetTurnId = '',
    required String action,
    required String outcome,
    required TurnReplaySafety safety,
    bool requiresConfirmation = false,
    bool requiresSteerDropConfirmation = false,
    bool containsSteers = false,
    int? historyRevision,
  }) {
    return emitEnvelope(
      _bridge.buildAgentEventEnvelope(
        CanonicalEvent(
          type: CanonicalEventTypes.sessionTurnReplayResult,
          sessionId: sessionId,
          payload: {
            'session_id': sessionId,
            'request_id': requestId,
            'target_request_id': targetRequestId,
            'target_message_id': targetMessageId,
            'target_turn_id': targetTurnId,
            'action': action,
            'outcome': outcome,
            'replay_safety': safety.name,
            'requires_confirmation': requiresConfirmation,
            'requires_steer_drop_confirmation': requiresSteerDropConfirmation,
            'contains_steers': containsSteers,
            'history_revision': ?historyRevision,
          },
        ),
      ),
    );
  }

  static int? _parseRevision(Object? value) {
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString().trim() ?? '');
  }

  static String _failureName(TurnReplayInspectionFailure failure) =>
      switch (failure) {
        TurnReplayInspectionFailure.sessionNotFound => 'session_not_found',
        TurnReplayInspectionFailure.targetNotFound => 'turn_boundary_not_found',
        TurnReplayInspectionFailure.targetIsNotLatestTurn => 'not_latest_turn',
        TurnReplayInspectionFailure.emptyMessage => 'empty_message',
        TurnReplayInspectionFailure.targetNotReplayableInput =>
          'target_not_replayable_input',
        TurnReplayInspectionFailure.identityIncomplete => 'identity_incomplete',
        TurnReplayInspectionFailure.historyRevisionMismatch =>
          'history_revision_mismatch',
      };

  static String _postIdleFailureName(TurnReplayInspectionFailure failure) =>
      switch (failure) {
        TurnReplayInspectionFailure.targetNotFound ||
        TurnReplayInspectionFailure.targetIsNotLatestTurn ||
        TurnReplayInspectionFailure.identityIncomplete => 'stale_turn_boundary',
        TurnReplayInspectionFailure.historyRevisionMismatch =>
          'history_revision_mismatch',
        _ => _failureName(failure),
      };
}
