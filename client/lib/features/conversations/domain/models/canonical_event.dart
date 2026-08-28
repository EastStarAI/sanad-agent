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

EventStatus _terminalStatusPrecedence(EventStatus current, EventStatus incoming) {
  return terminalStatusRank(incoming) >= terminalStatusRank(current)
      ? incoming
      : current;
}

LlmUsageSnapshot? latestContextUsage(List<CanonicalEvent> events) {
  for (final event in events.reversed) {
    if (event.contextUsage != null) return event.contextUsage;
  }
  return null;
}
