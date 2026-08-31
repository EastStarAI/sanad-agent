import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/engine/compaction/compaction.dart';
import 'package:sanad_agent/engine/runtime/compaction_coordinator.dart';
import 'package:sanad_agent/interfaces/models/gateway_event.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';

typedef CompactionLifecycleSink = void Function(GatewayResponse response);

/// Maps engine lifecycle events to canonical gateway responses (Plan 53d D6).
class CompactionLifecycleBroadcaster {
  final CompactionLifecycleSink _sink;

  CompactionLifecycleBroadcaster(this._sink);

  void handle(CompactionLifecycleEvent event) {
    final wireType = switch (event.status) {
      CompactionStatus.started => CanonicalEventTypes.contextCompactionStarted,
      CompactionStatus.completed =>
        CanonicalEventTypes.contextCompactionCompleted,
      CompactionStatus.failed => CanonicalEventTypes.contextCompactionFailed,
    };

    final metrics = event.metrics;
    _sink(
      GatewayResponse(
        sessionId: event.sessionId,
        eventId: event.eventId,
        message: Message(
          role: MessageRole.system,
          metadata: {
            'canonical_event_type': wireType,
            'canonical_payload': {
              'session_id': event.sessionId,
              'compaction_id': event.compactionId,
              'trigger': event.trigger.wireValue,
              'status': event.status.wireValue,
              if (event.providerInstanceId != null)
                'provider_instance_id': event.providerInstanceId,
              if (event.modelId != null) 'model_id': event.modelId,
              if (event.failureReason != null)
                'failure_reason': event.failureReason!.wireValue,
              if (metrics != null) ...{
                'context_window_tokens': metrics.contextWindowTokens,
                if (metrics.effectiveInputBudgetTokens != null)
                  'effective_input_budget_tokens':
                      metrics.effectiveInputBudgetTokens,
                if (metrics.autoThresholdTokens != null)
                  'auto_threshold_tokens': metrics.autoThresholdTokens,
                'estimated_request_tokens_before':
                    metrics.estimatedRequestTokensBefore,
                'estimated_request_tokens_after':
                    metrics.estimatedRequestTokensAfter,
                'before_measurement_kind':
                    metrics.beforeMeasurementKind.wireValue,
                if (metrics.providerConfirmedRequestTokensAfter != null)
                  'provider_confirmed_request_tokens_after':
                      metrics.providerConfirmedRequestTokensAfter,
                'retained_tail_tokens': metrics.retainedTailTokens,
                if (metrics.duration != null)
                  'duration_ms': metrics.duration!.inMilliseconds,
              },
              'started_at': event.startedAt.toUtc().toIso8601String(),
              if (event.completedAt != null)
                'completed_at': event.completedAt!.toUtc().toIso8601String(),
            },
          },
        ),
        isComplete: event.status.isTerminal,
      ),
    );
  }
}
