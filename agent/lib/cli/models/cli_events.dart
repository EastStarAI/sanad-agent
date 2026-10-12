import 'dart:convert';

/// Base class for all events emitted by the CLI gateway client.
sealed class CliEvent {
  final String type;
  final String? sessionId;
  final String? runId;
  final String? eventId;
  final DateTime timestamp;
  final Map<String, dynamic> raw;

  CliEvent({
    required this.type,
    this.sessionId,
    this.runId,
    this.eventId,
    DateTime? timestamp,
    this.raw = const {},
  }) : timestamp = timestamp ?? DateTime.now();

  /// Parses an incoming JSON map from the local gateway into a typed [CliEvent].
  static CliEvent fromJson(Map<String, dynamic> json) {
    // 1. Check top-level welcome / registration
    final topType = json['type'] as String?;
    if (topType == 'register_success') {
      return CliConnectionRegisteredEvent(
        platformId: json['platform_id'] as String? ?? '',
        gatewayUrl: json['url'] as String? ?? '',
        raw: json,
      );
    }

    if (topType == 'capabilities') {
      final payload = json['payload'];
      return CliCapabilitiesEvent(
        capabilities: payload is Map<String, dynamic>
            ? payload
            : payload is Map
            ? Map<String, dynamic>.from(payload)
            : const {},
        requestId: json['request_id'] as String?,
        raw: json,
      );
    }

    // 2. Resolve inner canonical event if wrapped in device_event or protocol_event
    Map<String, dynamic> canonicalMap = json;
    if (json.containsKey('event') && json['event'] is Map) {
      canonicalMap = Map<String, dynamic>.from(json['event'] as Map);
    }

    final eventType =
        (json['event'] is String && (json['event'] as String).isNotEmpty
                ? json['event']
                : (canonicalMap['type'] != null &&
                          canonicalMap['type'] != 'device_event' &&
                          canonicalMap['type'] != 'agent_event'
                      ? canonicalMap['type']
                      : (json['message_type'] != null &&
                                json['message_type'] != 'device_event' &&
                                json['message_type'] != 'agent_event'
                            ? json['message_type']
                            : canonicalMap['type'] ?? topType ?? 'unknown')))
            .toString();

    final rawPayload = canonicalMap['payload'] ?? json['payload'];
    final payload = rawPayload is Map<String, dynamic>
        ? rawPayload
        : rawPayload is Map
        ? Map<String, dynamic>.from(rawPayload)
        : <String, dynamic>{};

    final sessionId =
        (canonicalMap['session_id'] ??
                json['session_id'] ??
                payload['session_id'])
            ?.toString();

    final runId =
        (canonicalMap['run_id'] ?? json['run_id'] ?? payload['run_id'])
            ?.toString();

    final eventId =
        (canonicalMap['event_id'] ?? json['event_id'] ?? payload['event_id'])
            ?.toString();

    switch (eventType) {
      case 'thought_stream':
      case 'thought':
      case 'assistant':
        final content =
            payload['delta'] ??
            payload['text'] ??
            payload['content'] ??
            payload['chunk'] ??
            '';
        final isFirst = payload['is_first'] as bool? ?? false;
        return CliAssistantChunkEvent(
          content: content.toString(),
          isFirstChunk: isFirst,
          sessionId: sessionId,
          runId: runId,
          eventId: eventId,
          raw: json,
        );

      case 'reasoning_stream':
      case 'reasoning':
        final delta =
            payload['delta'] ??
            payload['text'] ??
            payload['content'] ??
            payload['reasoning'] ??
            '';
        final isFirst = payload['is_first'] as bool? ?? false;
        return CliReasoningDeltaEvent(
          content: delta.toString(),
          isFirstChunk: isFirst,
          sessionId: sessionId,
          runId: runId,
          eventId: eventId,
          raw: json,
        );

      case 'tool_call':
      case 'tool_use':
        final toolName =
            payload['tool_name']?.toString() ??
            payload['tool']?.toString() ??
            payload['name']?.toString() ??
            'unknown_tool';
        final callId =
            payload['tool_call_id']?.toString() ??
            payload['id']?.toString() ??
            '';
        final rawArgs = payload['arguments'] ?? payload['input'];
        final arguments = rawArgs is Map<String, dynamic>
            ? rawArgs
            : rawArgs is Map
            ? Map<String, dynamic>.from(rawArgs)
            : rawArgs is String
            ? _tryParseJson(rawArgs)
            : <String, dynamic>{};
        return CliToolCallEvent(
          toolCallId: callId,
          toolName: toolName,
          arguments: arguments,
          sessionId: sessionId,
          runId: runId,
          eventId: eventId,
          raw: json,
        );

      case 'tool_result':
        final toolName =
            payload['tool_name']?.toString() ??
            payload['tool']?.toString() ??
            payload['name']?.toString() ??
            '';
        final callId =
            payload['tool_call_id']?.toString() ??
            payload['id']?.toString() ??
            '';
        final isError =
            payload['is_error'] as bool? ??
            payload['isError'] as bool? ??
            (payload['status'] == 'error');
        final isCancelled =
            payload['is_cancelled'] as bool? ??
            payload['isCancelled'] as bool? ??
            (payload['status'] == 'cancelled');
        return CliToolResultEvent(
          toolCallId: callId,
          toolName: toolName,
          result:
              payload['result'] ??
              payload['output'] ??
              payload['content'] ??
              '',
          isError: isError,
          isCancelled: isCancelled,
          sessionId: sessionId,
          runId: runId,
          eventId: eventId,
          raw: json,
        );

      case 'tool_permission_request':
        final rawInput =
            payload['tool_input'] ?? payload['arguments'] ?? payload['input'];
        final toolInput = rawInput is Map<String, dynamic>
            ? rawInput
            : rawInput is Map
            ? Map<String, dynamic>.from(rawInput)
            : rawInput is String
            ? _tryParseJson(rawInput)
            : <String, dynamic>{};
        return CliPermissionRequestEvent(
          requestId: payload['request_id']?.toString() ?? '',
          toolName: payload['tool_name']?.toString() ?? '',
          permissionClass: payload['permission_class']?.toString() ?? 'general',
          workspaceName: payload['workspace_name']?.toString(),
          workspacePath: payload['workspace_path']?.toString(),
          questions: payload['questions'] is List
              ? (payload['questions'] as List)
                    .map(
                      (q) => q is Map
                          ? Map<String, dynamic>.from(q)
                          : <String, dynamic>{'question': q.toString()},
                    )
                    .toList()
              : const [],
          toolInput: toolInput,
          sessionId: sessionId,
          runId: runId,
          eventId: eventId,
          raw: json,
        );

      case 'final_answer':
      case 'turn_complete':
        final content =
            payload['text'] ?? payload['content'] ?? payload['message'] ?? '';
        final usage = payload['usage'] is Map
            ? Map<String, dynamic>.from(payload['usage'] as Map)
            : null;
        final contextUsage = payload['context_usage'] is Map
            ? Map<String, dynamic>.from(payload['context_usage'] as Map)
            : null;
        return CliTurnCompleteEvent(
          finalMessage: content.toString(),
          usage: usage,
          contextUsage: contextUsage,
          model: payload['model']?.toString(),
          provider: payload['provider']?.toString(),
          sessionId: sessionId,
          runId: runId,
          eventId: eventId,
          raw: json,
        );

      case 'session.runtime_notice':
        final title = payload['title']?.toString() ?? '';
        final msg = payload['message']?.toString() ?? '';
        final effMsg = title.isNotEmpty && msg.isNotEmpty
            ? '$title: $msg'
            : (title.isNotEmpty
                  ? title
                  : (msg.isNotEmpty ? msg : 'Runtime notice'));
        return CliRuntimeNoticeEvent(
          code:
              payload['reason']?.toString() ??
              payload['code']?.toString() ??
              'runtime_notice',
          message: effMsg,
          status: payload['status']?.toString(),
          sessionId: sessionId,
          runId: runId,
          eventId: eventId,
          raw: json,
        );

      case 'error':
        return CliErrorEvent(
          message:
              payload['message']?.toString() ??
              json['message']?.toString() ??
              'Unknown error',
          code:
              payload['code']?.toString() ??
              json['code']?.toString() ??
              'unknown_error',
          isFatal: payload['is_fatal'] as bool? ?? false,
          sessionId: sessionId,
          runId: runId,
          eventId: eventId,
          raw: json,
        );

      case 'stopped':
        return CliTurnCancelledEvent(
          reason:
              payload['reason']?.toString() ??
              payload['message']?.toString() ??
              'Session execution stopped',
          sessionId: sessionId,
          runId: runId,
          eventId: eventId,
          raw: json,
        );

      default:
        return CliRawEvent(
          type: eventType,
          payload: payload,
          sessionId: sessionId,
          runId: runId,
          eventId: eventId,
          raw: json,
        );
    }
  }

  static Map<String, dynamic> _tryParseJson(String raw) {
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic>
          ? decoded
          : decoded is Map
          ? Map<String, dynamic>.from(decoded)
          : <String, dynamic>{'value': decoded};
    } catch (_) {
      return {'value': raw};
    }
  }
}

/// Dispatched upon successful WebSocket registration with local gateway.
class CliConnectionRegisteredEvent extends CliEvent {
  final String platformId;
  final String gatewayUrl;

  CliConnectionRegisteredEvent({
    required this.platformId,
    required this.gatewayUrl,
    super.raw,
  }) : super(type: 'register_success');
}

/// Dispatched when gateway capabilities are returned.
class CliCapabilitiesEvent extends CliEvent {
  final Map<String, dynamic> capabilities;
  final String? requestId;

  CliCapabilitiesEvent({required this.capabilities, this.requestId, super.raw})
    : super(type: 'capabilities');
}

/// Dispatched for streaming assistant text chunks.
class CliAssistantChunkEvent extends CliEvent {
  final String content;
  final bool isFirstChunk;

  CliAssistantChunkEvent({
    required this.content,
    this.isFirstChunk = false,
    super.sessionId,
    super.runId,
    super.eventId,
    super.raw,
  }) : super(type: 'assistant_chunk');
}

/// Dispatched for reasoning / thinking stream chunks.
class CliReasoningDeltaEvent extends CliEvent {
  final String content;
  final bool isFirstChunk;

  CliReasoningDeltaEvent({
    required this.content,
    this.isFirstChunk = false,
    super.sessionId,
    super.runId,
    super.eventId,
    super.raw,
  }) : super(type: 'reasoning_delta');
}

/// Dispatched when agent invokes a tool.
class CliToolCallEvent extends CliEvent {
  final String toolCallId;
  final String toolName;
  final Map<String, dynamic> arguments;

  CliToolCallEvent({
    required this.toolCallId,
    required this.toolName,
    required this.arguments,
    super.sessionId,
    super.runId,
    super.eventId,
    super.raw,
  }) : super(type: 'tool_call');
}

/// Dispatched when a tool completes execution.
class CliToolResultEvent extends CliEvent {
  final String toolCallId;
  final String toolName;
  final dynamic result;
  final bool isError;
  final bool isCancelled;

  CliToolResultEvent({
    required this.toolCallId,
    required this.toolName,
    required this.result,
    this.isError = false,
    this.isCancelled = false,
    super.sessionId,
    super.runId,
    super.eventId,
    super.raw,
  }) : super(type: 'tool_result');
}

/// Dispatched when an approval or clarification is required from the user.
class CliPermissionRequestEvent extends CliEvent {
  final String requestId;
  final String toolName;
  final String permissionClass;
  final String? workspaceName;
  final String? workspacePath;
  final List<Map<String, dynamic>> questions;
  final Map<String, dynamic> toolInput;

  CliPermissionRequestEvent({
    required this.requestId,
    required this.toolName,
    required this.permissionClass,
    this.workspaceName,
    this.workspacePath,
    this.questions = const [],
    this.toolInput = const {},
    super.sessionId,
    super.runId,
    super.eventId,
    super.raw,
  }) : super(type: 'tool_permission_request');

  bool get isUserQuestion =>
      toolName == 'system_ask_user' || questions.isNotEmpty;
}

/// Dispatched when an execution turn completes.
class CliTurnCompleteEvent extends CliEvent {
  final String finalMessage;
  final Map<String, dynamic>? usage;
  final Map<String, dynamic>? contextUsage;
  final String? model;
  final String? provider;

  CliTurnCompleteEvent({
    required this.finalMessage,
    this.usage,
    this.contextUsage,
    this.model,
    this.provider,
    super.sessionId,
    super.runId,
    super.eventId,
    super.raw,
  }) : super(type: 'turn_complete');
}

/// Runtime notice or advisory message from orchestrator.
class CliRuntimeNoticeEvent extends CliEvent {
  final String code;
  final String message;
  final String? status;

  CliRuntimeNoticeEvent({
    required this.code,
    required this.message,
    this.status,
    super.sessionId,
    super.runId,
    super.eventId,
    super.raw,
  }) : super(type: 'runtime_notice');

  /// Runtime states that can still continue under daemon ownership are
  /// advisory for an attached CLI, not terminal failures. `blocked` may await
  /// an explicit retry/route intervention before later emitting `resuming`.
  bool get isRecovering =>
      status == 'waiting' ||
      status == 'blocked' ||
      status == 'resuming' ||
      status == 'cleared';
}

/// Error received from gateway.
class CliErrorEvent extends CliEvent {
  final String message;
  final String code;
  final bool isFatal;

  CliErrorEvent({
    required this.message,
    required this.code,
    this.isFatal = false,
    super.sessionId,
    super.runId,
    super.eventId,
    super.raw,
  }) : super(type: 'error');
}

/// Dispatched when an execution turn or session is cancelled or stopped externally.
class CliTurnCancelledEvent extends CliEvent {
  final String reason;

  CliTurnCancelledEvent({
    this.reason = 'Session execution stopped',
    super.sessionId,
    super.runId,
    super.eventId,
    super.raw,
  }) : super(type: 'turn_cancelled');
}

/// Fallback event for unrecognized or domain query events.
class CliRawEvent extends CliEvent {
  final Map<String, dynamic> payload;

  CliRawEvent({
    required super.type,
    required this.payload,
    super.sessionId,
    super.runId,
    super.eventId,
    super.raw,
  });
}
