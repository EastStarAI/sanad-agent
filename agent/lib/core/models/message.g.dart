// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'message.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

Message _$MessageFromJson(Map<String, dynamic> json) => Message(
  role: $enumDecode(_$MessageRoleEnumMap, json['role']),
  content: json['content'] as String?,
  attachments:
      (json['attachments'] as List<dynamic>?)
          ?.map((e) => UserAttachment.fromJson(e as Map<String, dynamic>))
          .toList() ??
      [],
  toolCalls: (json['toolCalls'] as List<dynamic>?)
      ?.map((e) => ToolCall.fromJson(e as Map<String, dynamic>))
      .toList(),
  toolCallId: json['toolCallId'] as String?,
  toolResult: json['toolResult'] == null
      ? null
      : ToolExecutionResult.fromJson(
          json['toolResult'] as Map<String, dynamic>,
        ),
  thought: json['thought'] as String?,
  reasoning: json['reasoning'] as String?,
  providerState: json['providerState'] == null
      ? null
      : LLMProviderState.fromJson(
          json['providerState'] as Map<String, dynamic>,
        ),
  finishReason:
      $enumDecodeNullable(
        _$LLMFinishReasonEnumMap,
        json['finishReason'],
        unknownValue: LLMFinishReason.unknown,
      ) ??
      LLMFinishReason.unknown,
  metadata: json['metadata'] as Map<String, dynamic>?,
);

Map<String, dynamic> _$MessageToJson(Message instance) => <String, dynamic>{
  'role': _$MessageRoleEnumMap[instance.role]!,
  'content': instance.content,
  'attachments': instance.attachments.map((e) => e.toJson()).toList(),
  'toolCalls': instance.toolCalls?.map((e) => e.toJson()).toList(),
  'toolCallId': instance.toolCallId,
  'toolResult': instance.toolResult?.toJson(),
  'thought': instance.thought,
  'reasoning': instance.reasoning,
  'providerState': instance.providerState?.toJson(),
  'finishReason': _$LLMFinishReasonEnumMap[instance.finishReason]!,
  'metadata': instance.metadata,
};

const _$MessageRoleEnumMap = {
  MessageRole.system: 'system',
  MessageRole.user: 'user',
  MessageRole.assistant: 'assistant',
  MessageRole.tool: 'tool',
};

const _$LLMFinishReasonEnumMap = {
  LLMFinishReason.stop: 'stop',
  LLMFinishReason.toolCalls: 'toolCalls',
  LLMFinishReason.incomplete: 'incomplete',
  LLMFinishReason.length: 'length',
  LLMFinishReason.failed: 'failed',
  LLMFinishReason.cancelled: 'cancelled',
  LLMFinishReason.unknown: 'unknown',
};
