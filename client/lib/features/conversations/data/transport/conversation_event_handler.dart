import 'dart:async';

import 'package:sanad_client/features/conversations/data/mappers/device_event_mapper.dart';
import 'package:sanad_client/features/conversations/data/transport/conversation_command_gateway.dart';
import 'package:sanad_client/features/conversations/domain/models/device_suspended_request.dart';
import 'package:sanad_client/features/conversations/domain/models/runtime_notice.dart';
import 'package:sanad_client/features/conversations/domain/models/session_route_snapshot.dart';
import 'package:sanad_client/features/conversations/domain/models/pending_steer_record.dart';
import 'package:sanad_client/features/conversations/domain/models/stop_draft_recovery.dart';
import 'package:sanad_client/features/conversations/domain/stores/device_conversation_store.dart';

class ConversationEventHandler {
  static const Set<String> _streamingEvents = {
    'thought_stream',
    'thought',
    'reasoning_stream',
    'reasoning',
    'tool_use',
    'tool_result',
    'user_message',
    'step_start',
    'final_answer',
    'stopped',
    'error',
    'thinking',
    'tool_call',
  };

  final String _deviceId;
  final ConversationCommandGateway _gateway;
  final DeviceConversationStore _conversationStore;
  final DeviceEventMapper _mapper;
  late final StreamSubscription<Map<String, dynamic>> _eventSubscription;

  ConversationEventHandler({
    required String deviceId,
    required ConversationCommandGateway gateway,
    required DeviceConversationStore conversationStore,
    required DeviceEventMapper mapper,
  }) : _deviceId = deviceId,
       _gateway = gateway,
       _conversationStore = conversationStore,
       _mapper = mapper {
    _eventSubscription = _gateway.events.listen(handleIncomingEvent);
  }

  void handleIncomingEvent(Map<String, dynamic> event) {
    final payload = event['payload'] as Map<String, dynamic>? ?? {};
    final requestId = event['request_id'] as String? ?? payload['request_id'] as String? ?? payload['id'] as String?;
    final runId = payload['run_id'] as String?;

    final deviceId = event['device_id'];
    if (deviceId != null && deviceId != _deviceId) {
      return;
    }

    final eventType = event['event'] as String? ?? payload['type'] as String?;
    final eventSessionId = event['session_id'] as String? ?? payload['session_id'] as String?;
    final runtimeStatus = payload['status'] as String?;

    if (eventType == 'session.execution_state_changed') {
      _conversationStore.applyExecutionPayload(
        payload,
        expectedSessionId: eventSessionId,
      );
      return;
    }

    if (eventType == 'session.pending_steer_changed') {
      try {
        _conversationStore.applyPendingSteer(
          PendingSteerRecord.fromJson({
            ...payload,
            if (eventSessionId != null) 'session_id': eventSessionId,
          }),
        );
      } on FormatException {
        // A malformed lifecycle event must not corrupt the current projection.
      }
      return;
    }

    if (eventType == 'session.stop_draft_recovery') {
      try {
        _conversationStore.applyStopRecovery(
          StopDraftRecovery.fromJson({
            ...payload,
            if (eventSessionId != null) 'session_id': eventSessionId,
          }),
        );
      } on FormatException {
        // Recovery remains durable on the daemon and can be requested again.
      }
      return;
    }

    if (eventType == 'session.pending_steer_cancel_result') {
      final targetRequestId = payload['target_request_id']?.toString();
      final outcome = payload['outcome']?.toString() ?? '';
      if (targetRequestId != null) {
        _conversationStore.applyPendingSteerCancelOutcome(targetRequestId, outcome);
      }
      return;
    }

    if (eventType == 'session.queued_message_changed' || eventType == 'session.queued_message_delete_result') {
      final targetRequestId = payload['target_request_id']?.toString();
      final outcome = payload['state']?.toString();
      if (targetRequestId != null &&
          {'deleted', 'cancelled', 'already_removed', 'already_processed', 'promoted'}.contains(outcome)) {
        _conversationStore.removeQueuedMessage(targetRequestId);
      } else if (targetRequestId != null) {
        _conversationStore.applyQueueMutationOutcome(targetRequestId, outcome ?? 'unknown');
      }
      return;
    }

    if (eventType == 'session.turn_replay_result') {
      final targetRequestId = payload['target_request_id']?.toString();
      if (payload['outcome'] == 'accepted' &&
          eventSessionId != null &&
          targetRequestId != null &&
          targetRequestId.isNotEmpty) {
        _conversationStore.applyTurnReplayAccepted(
          sessionId: eventSessionId,
          targetRequestId: targetRequestId,
          targetTurnId: payload['target_turn_id']?.toString(),
          targetMessageId: payload['target_message_id']?.toString(),
        );
      }
      return;
    }

    if (eventType == 'session.compact_result') {
      // Command acknowledgement only; lifecycle tiles come from
      // context_compaction.started/completed/failed events.
      return;
    }

    if (eventType == 'session_preferences_updated') {
      final routePayload = <String, dynamic>{
        ...payload,
        if (eventSessionId != null) 'session_id': eventSessionId,
      };
      final result = _conversationStore.applyRoutePayload(
        routePayload,
        expectedSessionId: eventSessionId,
      );
      if (result.changed &&
          result.current.source == SessionRouteSource.autoFailover &&
          _conversationStore.shouldAcceptStreamingEvent(eventSessionId)) {
        final canonical = _mapper.mapLiveEvent({
          'event': 'session_route_transition',
          'payload': routePayload,
        });
        if (canonical != null) _conversationStore.apply(canonical);
      }
      return;
    }

    if (eventType == 'session_route_transition') {
      final routePayload = <String, dynamic>{
        ...payload,
        if (eventSessionId != null) 'session_id': eventSessionId,
      };
      final result = _conversationStore.applyRoutePayload(
        routePayload,
        expectedSessionId: eventSessionId,
      );
      if (result.accepted && _conversationStore.shouldAcceptStreamingEvent(eventSessionId)) {
        final canonical = _mapper.mapLiveEvent({
          'event': 'session_route_transition',
          'payload': routePayload,
        });
        if (canonical != null) _conversationStore.apply(canonical);
      }
      return;
    }

    if (eventType == 'tool_permission_request') {
      if (eventSessionId != null) {
        _conversationStore.setPendingSuspendedRequest(
          DeviceSuspendedRequest.fromJson({
            ...payload,
            'session_id': eventSessionId,
          }),
        );
      }
      return;
    }

    if (eventType == 'tool_permission_resolved') {
      if (eventSessionId != null) {
        _conversationStore.clearPendingSuspendedRequestForSession(
          eventSessionId,
          requestId: requestId,
        );
      }
      return;
    }

    final createdSessionId = payload['session_id'] as String? ?? payload['id'] as String?;
    if (eventType == 'session_created' && createdSessionId != null) {
      if (!_conversationStore.adoptCreatedSession(createdSessionId: createdSessionId, requestId: requestId)) {
        return;
      }
    }

    if (_streamingEvents.contains(eventType)) {
      if (!_conversationStore.shouldAcceptStreamingEvent(eventSessionId)) {
        return;
      }
    }

    if (eventType == 'error') {
      _conversationStore.removeThinkingByRunId(runId);
      _conversationStore.removeQueuedMessagesForSession(eventSessionId);
    }

    if (eventType == 'stopped') {
      _conversationStore.removeRunningThinkingStep(
        modelStepId: payload['model_step_id']?.toString(),
        runId: runId,
        sessionId: eventSessionId,
      );
      if (runId != null && runId.isNotEmpty) {
        _conversationStore.cancelRunningToolsForRun(
          runId: runId,
          sessionId: eventSessionId,
        );
      }
      if (eventSessionId != null) {
        _conversationStore.clearPendingSuspendedRequestForSession(
          eventSessionId,
          requestId: requestId,
        );
      }
      _conversationStore.clearRuntimeNotice(
        sessionId: eventSessionId,
        requestId: requestId,
      );
      return;
    }

    if (eventType == 'session.runtime_notice') {
      _conversationStore.removeRunningThinkingForSession(eventSessionId);
      if (eventSessionId != null && runtimeStatus != 'cleared') {
        _conversationStore.setRuntimeNotice(
          RuntimeNotice.fromJson({
            ...payload,
            if (!payload.containsKey('session_id')) 'session_id': eventSessionId,
          }),
        );
      } else if (eventSessionId != null) {
        _conversationStore.clearRuntimeNotice(
          sessionId: eventSessionId,
          requestId: requestId,
        );
      }
      return;
    }

    if (eventType == 'session.runtime_notice_cleared') {
      _conversationStore.removeRunningThinkingForSession(eventSessionId);
      _conversationStore.clearRuntimeNotice(
        sessionId: eventSessionId,
        requestId: requestId,
      );
      return;
    }

    final canonical = _mapper.mapLiveEvent(event);
    if (canonical != null) {
      _conversationStore.apply(canonical);
      if (eventType == 'tool_result' || eventType == 'final_answer' || eventType == 'error') {
        if (eventSessionId != null) {
          _conversationStore.clearPendingSuspendedRequestForSession(
            eventSessionId,
            requestId: requestId,
          );
        }
      }
    } else if (eventType == 'stopped' || eventType == 'error') {
      if (runId != null && runId.isNotEmpty) {
        _conversationStore.removeThinkingByRunId(runId);
      } else if (eventType == 'stopped') {
        _conversationStore.removeRunningThinkingForSession(eventSessionId);
      }
      if (eventType == 'error') {
        if (eventSessionId != null) {
          _conversationStore.clearPendingSuspendedRequestForSession(
            eventSessionId,
            requestId: requestId,
          );
        }
      }
    }
  }

  void dispose() {
    unawaited(_eventSubscription.cancel());
  }
}
