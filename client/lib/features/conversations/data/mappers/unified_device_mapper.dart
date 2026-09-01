import 'package:sanad_client/features/conversations/data/mappers/device_event_mapper.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';
import 'package:sanad_client/features/conversations/domain/models/llm_usage_snapshot.dart';
import 'package:sanad_client/features/conversations/domain/models/compaction_event_snapshot.dart';
import 'package:sanad_client/features/conversations/domain/models/session_route_snapshot.dart';

/// Maps standardized agent events (live Redis stream + persisted history rows) into
/// `CanonicalEvent`s.
///
/// The server never merges tool_use + tool_result — that happens in
/// `ConversationState` via upsert-by-id. Both events therefore map to the same
/// canonical id (`tool_<tool_call_id>`) so state can fold them together.
class UnifiedDeviceMapper implements DeviceEventMapper {
  @override
  CanonicalEvent? mapLiveEvent(Map<String, dynamic> event) {
    final payload = event['payload'];
    // Support both the raw Redis shape (`{type, ...}`) and the Socket.IO
    // envelope shape (`{event, payload: {...}}`) so clients can feed us either.
    final type = event['event'] as String?;
    final data = <String, dynamic>{
      if (payload is Map) ...payload.cast<String, dynamic>(),
      ...event.cast<String, dynamic>(),
    };
    if (type != null) data['type'] = type;
    return _toCanonical(data);
  }

  @override
  List<CanonicalEvent> mapHistory(List<dynamic> history) {
    final List<CanonicalEvent> events = [];
    for (final raw in history) {
      if (raw is! Map) continue;
      final row = raw.cast<String, dynamic>();
      final canonical = _historyRowToCanonical(row);
      if (canonical != null) events.add(canonical);
    }
    return events;
  }

  /// History rows come from the agent-owned conversation store via the gateway as
  /// `{id, sender, type, content, metadata, created_at}`.
  CanonicalEvent? _historyRowToCanonical(Map<String, dynamic> row) {
    final type = row['type'] as String?;
    final metadata = (row['metadata'] as Map?)?.cast<String, dynamic>() ?? {};
    final timestamp = _extractTimestamp(row['created_at']) ?? DateTime.now();
    final toolMetadata = (metadata['tool'] is Map) ? (metadata['tool'] as Map).cast<String, dynamic>() : null;
    final canonicalFields = <String, dynamic>{
      'request_id': row['request_id'] ?? metadata['request_id'],
      'session_id': row['session_id'] ?? metadata['session_id'],
      'run_id': row['run_id'] ?? metadata['run_id'],
      'model_step_id': row['model_step_id'] ?? metadata['model_step_id'],
      'tool_call_id': row['tool_call_id'] ?? metadata['tool_call_id'],
      'model': row['model'] ?? metadata['model'],
      'model_display': row['model_display'] ?? metadata['model_display'],
      'provider': row['provider'] ?? metadata['provider'],
      'usage': row['usage'] ?? metadata['usage'],
      'context_usage': row['context_usage'] ?? metadata['context_usage'],
      'runtime_ms': row['runtime_ms'] ?? metadata['runtime_ms'],
      'context_tokens': row['context_tokens'] ?? metadata['context_tokens'],
      'thinking_mode': row['thinking_mode'] ?? metadata['thinking_mode'],
      'reasoning_level': row['reasoning_level'] ?? metadata['reasoning_level'],
      'event_id': row['event_id'] ?? metadata['event_id'] ?? row['id'],
      'source': row['source'] ?? metadata['source'],
      'previous_provider_instance_id':
          row['previous_provider_instance_id'] ?? metadata['previous_provider_instance_id'],
      'provider_instance_id': row['provider_instance_id'] ?? metadata['provider_instance_id'],
      'model_id': row['model_id'] ?? metadata['model_id'],
      'route_revision': row['route_revision'] ?? metadata['route_revision'],
      'reason': row['reason'] ?? metadata['reason'],
      'generation': row['generation'] ?? metadata['generation'],
      'revision': row['revision'] ?? metadata['revision'],
      'started_at': row['started_at'] ?? metadata['started_at'],
      'terminal_at': row['terminal_at'] ?? metadata['terminal_at'],
      'cleanup_outcome': row['cleanup_outcome'] ?? metadata['cleanup_outcome'],
      'previous_provider_display_name':
          row['previous_provider_display_name'] ?? metadata['previous_provider_display_name'],
      'provider_display_name': row['provider_display_name'] ?? metadata['provider_display_name'],
    };
    final historyStructuredFields = switch (type) {
      'tool_use' => <String, dynamic>{
        'tool': row['tool'] ?? _historyToolName(metadata['tool']) ?? toolMetadata,
        'input': row['input'] ?? metadata['input'] ?? toolMetadata?['input'],
      },
      'tool_result' => <String, dynamic>{
        'tool': row['tool'] ?? _historyToolName(metadata['tool']) ?? toolMetadata,
        'output': row['output'] ?? metadata['output'] ?? toolMetadata?['output'],
        'isError': row['isError'] ?? metadata['isError'],
        'status': row['status'] ?? metadata['status'],
        'provider_instance_id': row['provider_instance_id'] ?? metadata['provider_instance_id'],
        'model_id': row['model_id'] ?? metadata['model_id'],
      },
      'tool_call' => <String, dynamic>{
        'tool': row['tool'] ?? toolMetadata ?? _historyToolName(metadata['tool']),
        'input': row['input'] ?? metadata['input'] ?? toolMetadata?['input'],
        'output': row['output'] ?? metadata['output'] ?? toolMetadata?['output'],
        'status': row['status'] ?? metadata['status'],
      },
      'plan' => <String, dynamic>{'plan': row['plan'] ?? metadata['plan']},
      'context_compaction.started' ||
      'context_compaction.completed' ||
      'context_compaction.failed' => <String, dynamic>{
        'compaction_id': row['compaction_id'] ?? metadata['compaction_id'],
        'trigger': row['trigger'] ?? metadata['trigger'],
        'status': row['status'] ?? metadata['status'],
        'started_at': row['started_at'] ?? metadata['started_at'],
        'completed_at': row['completed_at'] ?? metadata['completed_at'],
        'failure_reason': row['failure_reason'] ?? metadata['failure_reason'],
        'context_window_tokens': row['context_window_tokens'] ?? metadata['context_window_tokens'],
        'estimated_request_tokens_before':
            row['estimated_request_tokens_before'] ?? metadata['estimated_request_tokens_before'],
        'estimated_request_tokens_after':
            row['estimated_request_tokens_after'] ?? metadata['estimated_request_tokens_after'],
        'before_measurement_kind': row['before_measurement_kind'] ?? metadata['before_measurement_kind'],
        'provider_confirmed_request_tokens_after':
            row['provider_confirmed_request_tokens_after'] ?? metadata['provider_confirmed_request_tokens_after'],
        'retained_tail_tokens': row['retained_tail_tokens'] ?? metadata['retained_tail_tokens'],
        'duration_ms': row['duration_ms'] ?? metadata['duration_ms'],
      },
      _ => const <String, dynamic>{},
    };

    final flattened = <String, dynamic>{
      'type': type,
      'content': row['content'],
      'timestamp': timestamp.toIso8601String(),
      ...canonicalFields,
      ...historyStructuredFields,
      'metadata': metadata,
    };
    return _toCanonical(flattened);
  }

  CanonicalEvent? _toCanonical(Map<String, dynamic> event) {
    final type = event['type'] as String?;
    final timestamp = _extractTimestamp(event['timestamp']) ?? DateTime.now();
    final runId = event['run_id'] as String?;
    final modelStepId = _stringId(event['model_step_id']);
    final toolCallId = _stringId(event['tool_call_id']);
    final eventId = _stringId(event['event_id']);
    final requestId = event['request_id']?.toString();
    final sessionId = event['session_id'] as String?;
    final status = _extractStatus(event['status']);
    final text = _extractText(event);
    final metadata = _extractMetadata(event);
    final model = event['model']?.toString();
    final modelDisplay = event['model_display']?.toString();
    final provider = event['provider']?.toString();
    final usage = event['usage'];
    final rawContextUsage = event['context_usage'];
    final contextUsage = rawContextUsage is Map
        ? LlmUsageSnapshot.fromJson(Map<String, dynamic>.from(rawContextUsage))
        : null;
    final runtimeMs = event['runtime_ms'] is num ? (event['runtime_ms'] as num).toInt() : null;
    final contextTokens = event['context_tokens'] is num ? (event['context_tokens'] as num).toInt() : null;
    final thinkingMode = event['thinking_mode']?.toString();
    final reasoningLevel = event['reasoning_level']?.toString();

    switch (type) {
      case 'user_message':
      // Legacy rows persisted as 'text' before the refactor.
      case 'text':
        return CanonicalEvent(
          id:
              eventId ??
              (requestId != null && requestId.isNotEmpty
                  ? 'user_$requestId'
                  : 'user_${timestamp.millisecondsSinceEpoch}_${text.hashCode}'),
          kind: EventKind.userMessage,
          status: EventStatus.done,
          text: text,
          timestamp: timestamp,
          sessionId: sessionId,
          runId: runId,
          eventId: eventId,
          model: model,
          modelDisplay: modelDisplay,
          provider: provider,
          usage: usage,
          contextUsage: contextUsage,
          runtimeMs: runtimeMs,
          contextTokens: contextTokens,
          thinkingMode: thinkingMode,
          reasoningLevel: reasoningLevel,
          metadata: metadata,
        );

      case 'thinking':
      case 'thought_stream':
        if (text.trim().isEmpty) return null;
        return CanonicalEvent(
          id: _thinkingId(modelStepId, runId, eventId, timestamp),
          kind: EventKind.thinking,
          status: status ?? EventStatus.running,
          text: text,
          timestamp: timestamp,
          sessionId: sessionId,
          runId: runId,
          modelStepId: modelStepId,
          eventId: eventId,
          model: model,
          modelDisplay: modelDisplay,
          provider: provider,
          usage: usage,
          contextUsage: contextUsage,
          runtimeMs: runtimeMs,
          contextTokens: contextTokens,
          thinkingMode: thinkingMode,
          reasoningLevel: reasoningLevel,
          metadata: metadata,
        );

      case 'reasoning_stream':
        if (text.trim().isEmpty) return null;
        return CanonicalEvent(
          id: _reasoningId(modelStepId, runId, eventId, timestamp),
          kind: EventKind.reasoning,
          status: status ?? EventStatus.running,
          text: text,
          timestamp: timestamp,
          sessionId: sessionId,
          runId: runId,
          modelStepId: modelStepId,
          eventId: eventId,
          model: model,
          modelDisplay: modelDisplay,
          provider: provider,
          usage: usage,
          contextUsage: contextUsage,
          runtimeMs: runtimeMs,
          contextTokens: contextTokens,
          thinkingMode: thinkingMode,
          reasoningLevel: reasoningLevel,
          metadata: metadata,
        );

      case 'thought':
        return CanonicalEvent(
          id: _thinkingId(modelStepId, runId, eventId, timestamp),
          kind: EventKind.thinking,
          status: EventStatus.done,
          text: text,
          timestamp: timestamp,
          sessionId: sessionId,
          runId: runId,
          modelStepId: modelStepId,
          eventId: eventId,
          model: model,
          modelDisplay: modelDisplay,
          provider: provider,
          usage: usage,
          contextUsage: contextUsage,
          runtimeMs: runtimeMs,
          contextTokens: contextTokens,
          thinkingMode: thinkingMode,
          reasoningLevel: reasoningLevel,
          metadata: metadata,
        );

      case 'reasoning':
        if (text.trim().isEmpty) return null;
        return CanonicalEvent(
          id: _reasoningId(modelStepId, runId, eventId, timestamp),
          kind: EventKind.reasoning,
          status: EventStatus.done,
          text: text,
          timestamp: timestamp,
          sessionId: sessionId,
          runId: runId,
          modelStepId: modelStepId,
          eventId: eventId,
          model: model,
          modelDisplay: modelDisplay,
          provider: provider,
          usage: usage,
          contextUsage: contextUsage,
          runtimeMs: runtimeMs,
          contextTokens: contextTokens,
          thinkingMode: thinkingMode,
          reasoningLevel: reasoningLevel,
          metadata: metadata,
        );

      case 'stopped':
        return null;

      case 'step_start':
        // Purely a "Thinking..." placeholder — ignored so it never creates a
        // separate bubble; the first thought_stream chunk will create one.
        return null;

      case 'tool_use':
        return CanonicalEvent(
          id: _toolId(toolCallId, eventId, timestamp),
          kind: EventKind.toolCall,
          status: status ?? EventStatus.running,
          tool: {
            'name': event['tool'] ?? 'Unknown Tool',
            'input': event['input'],
          },
          timestamp: timestamp,
          sessionId: sessionId,
          runId: runId,
          modelStepId: modelStepId,
          toolCallId: toolCallId,
          eventId: eventId,
          model: model,
          modelDisplay: modelDisplay,
          provider: provider,
          usage: usage,
          contextUsage: contextUsage,
          runtimeMs: runtimeMs,
          contextTokens: contextTokens,
          thinkingMode: thinkingMode,
          reasoningLevel: reasoningLevel,
          metadata: metadata,
        );

      case 'tool_result':
        final output = event['output']?.toString() ?? '';
        final explicitStatus = _extractStatus(event['status']);
        final isCancelled = explicitStatus == EventStatus.cancelled || event['status']?.toString() == 'cancelled';
        final isError = !isCancelled && (event['isError'] == true || explicitStatus == EventStatus.error);

        return CanonicalEvent(
          id: _toolId(toolCallId, eventId, timestamp),
          kind: EventKind.toolCall,
          status: isCancelled ? EventStatus.cancelled : (isError ? EventStatus.error : EventStatus.done),
          tool: {'name': event['tool'] ?? '', 'output': output},
          timestamp: timestamp,
          sessionId: sessionId,
          runId: runId,
          modelStepId: modelStepId,
          toolCallId: toolCallId,
          eventId: eventId,
          model: model,
          modelDisplay: modelDisplay,
          provider: provider,
          usage: usage,
          contextUsage: contextUsage,
          runtimeMs: runtimeMs,
          contextTokens: contextTokens,
          thinkingMode: thinkingMode,
          reasoningLevel: reasoningLevel,
          metadata: metadata,
        );

      case 'tool_call':
        final tool = (event['tool'] as Map?)?.cast<String, dynamic>();
        return CanonicalEvent(
          id: _toolId(toolCallId, eventId, timestamp),
          kind: EventKind.toolCall,
          status: status ?? EventStatus.running,
          tool: {
            'name': tool?['name'] ?? event['tool'] ?? 'Unknown Tool',
            'input': tool?['input'] ?? event['input'],
            'output': tool?['output'] ?? event['output'],
          },
          timestamp: timestamp,
          sessionId: sessionId,
          runId: runId,
          toolCallId: toolCallId,
          eventId: eventId,
          model: model,
          modelDisplay: modelDisplay,
          provider: provider,
          usage: usage,
          contextUsage: contextUsage,
          runtimeMs: runtimeMs,
          contextTokens: contextTokens,
          thinkingMode: thinkingMode,
          reasoningLevel: reasoningLevel,
          metadata: metadata,
        );

      case 'final_answer':
        return CanonicalEvent(
          id: 'answer_${modelStepId ?? runId ?? eventId ?? timestamp.millisecondsSinceEpoch}',
          kind: EventKind.finalAnswer,
          status: EventStatus.done,
          text: text,
          timestamp: timestamp,
          sessionId: sessionId,
          runId: runId,
          modelStepId: modelStepId,
          eventId: eventId,
          model: model,
          modelDisplay: modelDisplay,
          provider: provider,
          usage: usage,
          contextUsage: contextUsage,
          runtimeMs: runtimeMs,
          contextTokens: contextTokens,
          thinkingMode: thinkingMode,
          reasoningLevel: reasoningLevel,
          metadata: metadata,
        );

      case 'plan':
        final planData = event['plan'];
        return CanonicalEvent(
          id: 'plan_${runId ?? timestamp.millisecondsSinceEpoch}',
          kind: EventKind.plan,
          status: EventStatus.done,
          text: text,
          plan: planData is Map ? planData.cast<String, dynamic>() : null,
          timestamp: timestamp,
          sessionId: sessionId,
          runId: runId,
          model: model,
          modelDisplay: modelDisplay,
          provider: provider,
          usage: usage,
          contextUsage: contextUsage,
          runtimeMs: runtimeMs,
          contextTokens: contextTokens,
          thinkingMode: thinkingMode,
          reasoningLevel: reasoningLevel,
          metadata: metadata,
        );

      case 'error':
        return CanonicalEvent(
          id: 'error_${runId ?? timestamp.millisecondsSinceEpoch}',
          kind: EventKind.error,
          status: EventStatus.error,
          text: text,
          timestamp: timestamp,
          sessionId: sessionId,
          runId: runId,
          model: model,
          modelDisplay: modelDisplay,
          provider: provider,
          usage: usage,
          contextUsage: contextUsage,
          runtimeMs: runtimeMs,
          contextTokens: contextTokens,
          thinkingMode: thinkingMode,
          reasoningLevel: reasoningLevel,
          metadata: metadata,
        );

      case 'context_compaction.started':
      case 'context_compaction.completed':
      case 'context_compaction.failed':
        return _mapCompactionEvent(event, timestamp);

      case 'session_route_transition':
        final snapshot = SessionRouteSnapshot.fromJson(event);
        return CanonicalEvent(
          id: snapshot.logicalEventId,
          kind: EventKind.informational,
          status: EventStatus.done,
          text: text.isNotEmpty ? text : snapshot.informationalText,
          timestamp: snapshot.updatedAt ?? timestamp,
          sessionId: snapshot.sessionId,
          model: snapshot.model,
          provider: snapshot.providerInstanceId,
          metadata: {
            ...?metadata,
            'informational': true,
            'event_id': snapshot.eventId,
            'route_revision': snapshot.routeRevision,
            'source': 'auto_failover',
          },
        );

      default:
        return null;
    }
  }

  CanonicalEvent? _mapCompactionEvent(
    Map<String, dynamic> event,
    DateTime timestamp,
  ) {
    final snapshot = CompactionEventSnapshot.fromJson(event);
    final status = switch (snapshot.status) {
      CompactionLifecycleStatus.started => EventStatus.running,
      CompactionLifecycleStatus.completed => EventStatus.done,
      CompactionLifecycleStatus.failed => EventStatus.error,
    };
    final tokensAfterCompaction = snapshot.providerConfirmedRequestTokensAfter ?? snapshot.estimatedRequestTokensAfter;
    final contextUsage =
        snapshot.status == CompactionLifecycleStatus.completed &&
            tokensAfterCompaction != null &&
            snapshot.contextWindowTokens != null
        ? LlmUsageSnapshot(
            inputTokens: tokensAfterCompaction,
            contextWindowTokens: snapshot.contextWindowTokens,
            modelId: event['model_id']?.toString(),
            providerInstanceId: event['provider_instance_id']?.toString(),
            observedAt: snapshot.completedAt ?? timestamp,
          )
        : null;
    return CanonicalEvent(
      id: snapshot.logicalEventId,
      kind: EventKind.informational,
      status: status,
      text: snapshot.timelineLabel,
      timestamp: snapshot.completedAt ?? snapshot.startedAt ?? timestamp,
      sessionId: snapshot.sessionId,
      eventId: event['event_id']?.toString() ?? 'context_compaction:${snapshot.compactionId}:${snapshot.status.name}',
      contextUsage: contextUsage,
      metadata: {
        'informational': true,
        'compaction_event': true,
        'compaction_id': snapshot.compactionId,
        'compaction_status': snapshot.status.name,
        'compaction_trigger': snapshot.trigger.name,
        if (event['provider_instance_id'] != null) 'provider_instance_id': event['provider_instance_id'],
        if (event['model_id'] != null) 'model_id': event['model_id'],
        if (snapshot.failureReason != null) 'failure_reason': snapshot.failureReason,
        if (snapshot.contextWindowTokens != null) 'context_window_tokens': snapshot.contextWindowTokens,
        if (snapshot.effectiveInputBudgetTokens != null)
          'effective_input_budget_tokens': snapshot.effectiveInputBudgetTokens,
        if (snapshot.autoThresholdTokens != null) 'auto_threshold_tokens': snapshot.autoThresholdTokens,
        if (snapshot.estimatedRequestTokensBefore != null)
          'estimated_request_tokens_before': snapshot.estimatedRequestTokensBefore,
        if (snapshot.estimatedRequestTokensAfter != null)
          'estimated_request_tokens_after': snapshot.estimatedRequestTokensAfter,
        if (snapshot.beforeMeasurementKind != null) 'before_measurement_kind': snapshot.beforeMeasurementKind,
        if (snapshot.providerConfirmedRequestTokensAfter != null)
          'provider_confirmed_request_tokens_after': snapshot.providerConfirmedRequestTokensAfter,
        if (snapshot.retainedTailTokens != null) 'retained_tail_tokens': snapshot.retainedTailTokens,
        if (snapshot.durationMs != null) 'duration_ms': snapshot.durationMs,
      },
    );
  }

  // Same id for every chunk + finalized thought within one cycle so
  // ConversationState folds them into one bubble.
  String _thinkingId(
    String? modelStepId,
    String? runId,
    String? eventId,
    DateTime timestamp,
  ) => 'thinking_${modelStepId ?? runId ?? eventId ?? timestamp.millisecondsSinceEpoch}';

  // Reasoning and ordinary assistant text may share one model step, so they
  // need distinct identities while each stream still folds its own chunks.
  String _reasoningId(
    String? modelStepId,
    String? runId,
    String? eventId,
    DateTime timestamp,
  ) => 'reasoning_${modelStepId ?? runId ?? eventId ?? timestamp.millisecondsSinceEpoch}';

  // Same id for tool_use + matching tool_result so they fold together.
  String _toolId(String? toolCallId, String? eventId, DateTime timestamp) =>
      'tool_${toolCallId ?? eventId ?? timestamp.microsecondsSinceEpoch}';

  String? _stringId(dynamic value) {
    final normalized = value?.toString().trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }

  DateTime? _extractTimestamp(dynamic value) {
    if (value == null) return null;
    if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
    if (value is String) return DateTime.tryParse(value);
    return null;
  }

  String _extractText(Map<String, dynamic> event) {
    final value = event['content'] ?? event['text'] ?? event['message'];
    return (value ?? '').toString();
  }

  EventStatus? _extractStatus(dynamic value) {
    switch (value) {
      case 'running':
        return EventStatus.running;
      case 'done':
      case 'completed':
      case 'complete':
        return EventStatus.done;
      case 'error':
      case 'failed':
        return EventStatus.error;
      case 'cancelled':
        return EventStatus.cancelled;
      default:
        return null;
    }
  }

  Map<String, dynamic>? _extractMetadata(Map<String, dynamic> event) {
    final metadata = event['metadata'];
    final normalized = <String, dynamic>{
      if (metadata is Map) ...metadata.cast<String, dynamic>(),
      if (event['request_id'] != null) 'request_id': event['request_id'],
      if (event['queued'] != null) 'queued': event['queued'],
      if (event['classification'] != null) 'classification': event['classification'],
      if (event['generation'] != null) 'generation': event['generation'],
      if (event['revision'] != null) 'revision': event['revision'],
      if (event['reason'] != null) 'reason': event['reason'],
      if (event['started_at'] != null) 'started_at': event['started_at'],
      if (event['terminal_at'] != null) 'terminal_at': event['terminal_at'],
      if (event['cleanup_outcome'] != null) 'cleanup_outcome': event['cleanup_outcome'],
    };
    return normalized.isEmpty ? null : normalized;
  }

  String? _historyToolName(dynamic toolValue) {
    if (toolValue is String) {
      final trimmed = toolValue.trim();
      return trimmed.isEmpty ? null : trimmed;
    }
    if (toolValue is Map) {
      final name = toolValue['name'];
      if (name is String) {
        final trimmed = name.trim();
        return trimmed.isEmpty ? null : trimmed;
      }
    }
    return null;
  }
}
