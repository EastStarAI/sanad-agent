import 'llm_usage_snapshot.dart';

/// Kinds of events that can occur in a conversation
enum EventKind {
  userMessage,
  thinking,
  reasoning,
  toolCall,
  finalAnswer,
  plan,
  error,
  informational,
}

/// Status of an event
enum EventStatus {
  running,
  done,
  error,
  cancelled,
}

/// Canonical representation of a conversation event
/// Device-scoped conversation event used as the source of truth for UI.
class CanonicalEvent {
  final String id;
  final EventKind kind;
  final EventStatus status;
  final String text;
  final Map<String, dynamic>? tool;
  final Map<String, dynamic>? plan;
  final DateTime timestamp;
  final String? sessionId;
  final String? runId;
  final String? modelStepId;
  final String? toolCallId;
  final String? eventId;
  final String? model;
  final String? modelDisplay;
  final String? provider;
  final dynamic usage;
  final LlmUsageSnapshot? contextUsage;
  final int? runtimeMs;
  final int? contextTokens;
  final String? thinkingMode;
  final String? reasoningLevel;
  final Map<String, dynamic>? metadata;

  String? get requestId {
    final value = metadata?['request_id']?.toString().trim();
    return value == null || value.isEmpty ? null : value;
  }

  int? get generation => _metadataInt(metadata?['generation']);

  int? get revision => _metadataInt(metadata?['revision']);

  CanonicalEvent({
    required this.id,
    required this.kind,
    this.status = EventStatus.done,
    this.text = '',
    this.tool,
    this.plan,
    required this.timestamp,
    this.sessionId,
    this.runId,
    this.modelStepId,
    this.toolCallId,
    this.eventId,
    this.model,
    this.modelDisplay,
    this.provider,
    this.usage,
    this.contextUsage,
    this.runtimeMs,
    this.contextTokens,
    this.thinkingMode,
    this.reasoningLevel,
    this.metadata,
  });

  /// The name of the tool if this is a tool_call event
  String? get toolName => tool?['name'] as String?;

  /// The input parameters of the tool
  dynamic get toolInput => tool?['input'];

  /// The output/result of the tool
  dynamic get toolOutput => tool?['output'];

  /// Create a copy of this event with some fields updated
  CanonicalEvent copyWith({
    String? id,
    EventKind? kind,
    EventStatus? status,
    String? text,
    Map<String, dynamic>? tool,
    Map<String, dynamic>? plan,
    DateTime? timestamp,
    String? sessionId,
    String? runId,
    String? modelStepId,
    String? toolCallId,
    String? eventId,
    String? model,
    String? modelDisplay,
    String? provider,
    dynamic usage,
    LlmUsageSnapshot? contextUsage,
    int? runtimeMs,
    int? contextTokens,
    String? thinkingMode,
    String? reasoningLevel,
    Map<String, dynamic>? metadata,
  }) {
    return CanonicalEvent(
      id: id ?? this.id,
      kind: kind ?? this.kind,
      status: status ?? this.status,
      text: text ?? this.text,
      tool: tool ?? this.tool,
      plan: plan ?? this.plan,
      timestamp: timestamp ?? this.timestamp,
      sessionId: sessionId ?? this.sessionId,
      runId: runId ?? this.runId,
      modelStepId: modelStepId ?? this.modelStepId,
      toolCallId: toolCallId ?? this.toolCallId,
      eventId: eventId ?? this.eventId,
      model: model ?? this.model,
      modelDisplay: modelDisplay ?? this.modelDisplay,
      provider: provider ?? this.provider,
      usage: usage ?? this.usage,
      contextUsage: contextUsage ?? this.contextUsage,
      runtimeMs: runtimeMs ?? this.runtimeMs,
      contextTokens: contextTokens ?? this.contextTokens,
      thinkingMode: thinkingMode ?? this.thinkingMode,
      reasoningLevel: reasoningLevel ?? this.reasoningLevel,
      metadata: metadata ?? this.metadata,
    );
  }

  /// Merges another event into this one (e.g. tool_result into tool_use)
  CanonicalEvent merge(CanonicalEvent other) {
    return copyWith(
      text: other.text.isNotEmpty ? other.text : text,
      status: _terminalStatusPrecedence(status, other.status),
      tool: other.tool != null ? {...?tool, ...other.tool!} : tool,
      plan: other.plan != null ? {...?plan, ...other.plan!} : plan,
      model: other.model ?? model,
      modelDisplay: other.modelDisplay ?? modelDisplay,
      provider: other.provider ?? provider,
      usage: other.usage ?? usage,
      contextUsage: other.contextUsage ?? contextUsage,
      runtimeMs: other.runtimeMs ?? runtimeMs,
      contextTokens: other.contextTokens ?? contextTokens,
      thinkingMode: other.thinkingMode ?? thinkingMode,
      reasoningLevel: other.reasoningLevel ?? reasoningLevel,
      modelStepId: other.modelStepId ?? modelStepId,
      toolCallId: other.toolCallId ?? toolCallId,
      eventId: other.eventId ?? eventId,
      metadata: other.metadata != null ? {...?metadata, ...other.metadata!} : metadata,
    );
  }

  @override
  String toString() {
    return 'CanonicalEvent(id: $id, kind: $kind, status: $status, text: ${text.length > 20 ? text.substring(0, 20) : text})';
  }
}

int terminalStatusRank(EventStatus status) => switch (status) {
  EventStatus.running => 0,
  EventStatus.done => 1,
  EventStatus.error => 2,
  EventStatus.cancelled => 3,
};

int? _metadataInt(dynamic value) {
  if (value is int) return value;
  if (value is num && value.toInt() == value) return value.toInt();
  return int.tryParse(value?.toString() ?? '');
}

/// Whether [incoming] is a strictly newer terminal observation of [current].
///
/// Tool generation/revision is authoritative when present. Legacy events
/// without version metadata retain cancellation precedence so a late timeout
/// or completion cannot revive a row closed by Stop.
bool isNewerToolTerminalEvent(
  CanonicalEvent current,
  CanonicalEvent incoming,
) {
  if (current.kind != EventKind.toolCall ||
      incoming.kind != EventKind.toolCall ||
      incoming.status == EventStatus.running) {
    return false;
  }
  if (current.status == EventStatus.running) return true;
  if (current.status == EventStatus.cancelled && incoming.status != EventStatus.cancelled) {
    return false;
  }

  final currentGeneration = current.generation;
  final incomingGeneration = incoming.generation;
  if (currentGeneration != null && incomingGeneration != null) {
    if (incomingGeneration != currentGeneration) {
      return incomingGeneration > currentGeneration;
    }
  } else if (incomingGeneration != null) {
    return true;
  } else if (currentGeneration != null) {
    return false;
  }

  final currentRevision = current.revision;
  final incomingRevision = incoming.revision;
  if (currentRevision != null && incomingRevision != null) {
    if (incomingRevision != currentRevision) {
      return incomingRevision > currentRevision;
    }
    return false;
  }
  if (incomingRevision != null) return true;
  if (currentRevision != null) return false;

  return terminalStatusRank(incoming.status) > terminalStatusRank(current.status);
}

EventStatus _terminalStatusPrecedence(EventStatus current, EventStatus incoming) {
  return terminalStatusRank(incoming) >= terminalStatusRank(current) ? incoming : current;
}

LlmUsageSnapshot? latestContextUsage(List<CanonicalEvent> events) {
  for (var index = events.length - 1; index >= 0; index--) {
    final event = events[index];
    final compactionUsage = _completedCompactionContextUsage(event);
    if (compactionUsage != null) {
      LlmUsageSnapshot? priorUsage;
      for (var priorIndex = index - 1; priorIndex >= 0; priorIndex--) {
        if (events[priorIndex].metadata?['compaction_event'] == true) continue;
        priorUsage = events[priorIndex].contextUsage;
        if (priorUsage != null) break;
      }
      final sameModel =
          priorUsage == null ||
          compactionUsage.modelId == null ||
          priorUsage.modelId == null ||
          compactionUsage.modelId == priorUsage.modelId;
      return LlmUsageSnapshot(
        inputTokens: compactionUsage.inputTokens,
        contextWindowTokens: sameModel
            ? priorUsage?.contextWindowTokens ?? compactionUsage.contextWindowTokens
            : compactionUsage.contextWindowTokens,
        modelId: compactionUsage.modelId ?? priorUsage?.modelId,
        providerInstanceId: compactionUsage.providerInstanceId ?? priorUsage?.providerInstanceId,
        observedAt: compactionUsage.observedAt,
      );
    }
    if (event.contextUsage != null) return event.contextUsage;
  }
  return null;
}

LlmUsageSnapshot? _completedCompactionContextUsage(CanonicalEvent event) {
  final metadata = event.metadata;
  if (metadata?['compaction_event'] != true || metadata?['compaction_status'] != 'completed') {
    return null;
  }
  final inputTokens =
      _metadataInt(metadata?['provider_confirmed_request_tokens_after']) ??
      _metadataInt(metadata?['estimated_request_tokens_after']);
  final contextWindowTokens = _metadataInt(metadata?['context_window_tokens']);
  if (inputTokens == null || contextWindowTokens == null) return null;
  return LlmUsageSnapshot(
    inputTokens: inputTokens,
    contextWindowTokens: contextWindowTokens,
    modelId: metadata?['model_id']?.toString(),
    providerInstanceId: metadata?['provider_instance_id']?.toString(),
    observedAt: event.timestamp,
  );
}
