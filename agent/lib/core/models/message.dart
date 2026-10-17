import 'package:json_annotation/json_annotation.dart';
import 'tool_call.dart';
import 'tool_execution_result.dart';
import 'llm_provider_state.dart';
import 'llm_finish_reason.dart';
import 'user_attachment.dart';

part 'message.g.dart';

enum MessageRole { system, user, assistant, tool }

@JsonSerializable(explicitToJson: true)
class Message {
  final MessageRole role;
  final String? content;

  /// Ordered canonical attachments for a user-role message.
  @JsonKey(defaultValue: <UserAttachment>[])
  final List<UserAttachment> attachments;

  final List<ToolCall>? toolCalls;
  final String? toolCallId;

  /// Authoritative rich result for a tool-role message.
  ///
  /// [content] remains the compatibility projection and must equal
  /// [ToolExecutionResult.displayText] when this field is present.
  final ToolExecutionResult? toolResult;

  final String? thought;
  final String? reasoning;

  /// Opaque, adapter-owned state required for provider protocol continuity.
  ///
  /// This is deliberately separate from user-visible [reasoning]. Keys must be
  /// namespaced by the owning adapter and are persisted with message history.
  final LLMProviderState? providerState;

  /// Provider-neutral terminal classification persisted with conversation
  /// history so continuation decisions survive process restarts.
  @JsonKey(
    defaultValue: LLMFinishReason.unknown,
    unknownEnumValue: LLMFinishReason.unknown,
  )
  final LLMFinishReason finishReason;

  /// Per-turn metrics persisted alongside this message (usage, model, provider, context_tokens, runtime_ms).
  final Map<String, dynamic>? metadata;

  Message({
    required this.role,
    String? content,
    List<UserAttachment> attachments = const [],
    this.toolCalls,
    this.toolCallId,
    this.toolResult,
    this.thought,
    this.reasoning,
    this.providerState,
    this.finishReason = LLMFinishReason.unknown,
    this.metadata,
  }) : content = content ?? toolResult?.displayText,
       attachments = List<UserAttachment>.unmodifiable(attachments) {
    if (attachments.isNotEmpty && role != MessageRole.user) {
      throw ArgumentError.value(
        role,
        'role',
        'attachments are valid only for user messages',
      );
    }
    if (toolResult != null && role != MessageRole.tool) {
      throw ArgumentError.value(
        role,
        'role',
        'toolResult is valid only for tool messages',
      );
    }
    if (toolResult != null && this.content != toolResult!.displayText) {
      throw ArgumentError.value(
        content,
        'content',
        'must equal toolResult.displayText',
      );
    }
  }

  factory Message.fromJson(Map<String, dynamic> json) =>
      _$MessageFromJson(json);
  Map<String, dynamic> toJson() => _$MessageToJson(this);

  Message copyWith({
    MessageRole? role,
    String? content,
    List<UserAttachment>? attachments,
    List<ToolCall>? toolCalls,
    String? toolCallId,
    ToolExecutionResult? toolResult,
    bool clearToolResult = false,
    String? thought,
    String? reasoning,
    LLMProviderState? providerState,
    bool clearProviderState = false,
    LLMFinishReason? finishReason,
    Map<String, dynamic>? metadata,
  }) {
    final nextToolResult = clearToolResult
        ? null
        : toolResult ?? this.toolResult;
    final nextContent = toolResult != null && content == null
        ? toolResult.displayText
        : content ?? this.content;
    return Message(
      role: role ?? this.role,
      content: nextContent,
      attachments: attachments ?? this.attachments,
      toolCalls: toolCalls ?? this.toolCalls,
      toolCallId: toolCallId ?? this.toolCallId,
      toolResult: nextToolResult,
      thought: thought ?? this.thought,
      reasoning: reasoning ?? this.reasoning,
      providerState: clearProviderState
          ? null
          : providerState ?? this.providerState,
      finishReason: finishReason ?? this.finishReason,
      metadata: metadata ?? this.metadata,
    );
  }
}
