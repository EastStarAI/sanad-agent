import 'package:uuid/uuid.dart';

import '../../core/models/llm_finish_reason.dart';
import '../../core/models/message.dart';
import '../../core/models/tool_call.dart';
import 'message_history_identity.dart';

/// Rewrites a copied active prefix so the child session owns new identities
/// while preserving content, pairing, and `origin_message_id`.
class SessionForkCopy {
  static const _uuid = Uuid();

  static String forkTitle(int sequence, String baseTitle) {
    return '($sequence) $baseTitle';
  }

  static String baseTitleOf(String? lineageBaseTitle, String? sessionTitle) {
    final stored = lineageBaseTitle?.trim();
    if (stored != null && stored.isNotEmpty) return stored;
    final title = sessionTitle?.trim();
    if (title != null && title.isNotEmpty) return title;
    return 'Untitled Session';
  }

  static bool isForkableFinalAnswer(Message message) {
    if (message.role != MessageRole.assistant) return false;
    final identity = MessageHistoryIdentity.read(message);
    if (identity.historyStatus != MessageHistoryIdentity.active) return false;
    if (identity.messageId.isEmpty || identity.turnId.isEmpty) return false;
    if (message.metadata?['superseded_by_steer'] == true) return false;
    final hasTerminal = message.metadata?['terminal_work_item_id'] != null;
    switch (message.finishReason) {
      case LLMFinishReason.incomplete:
      case LLMFinishReason.failed:
      case LLMFinishReason.cancelled:
      case LLMFinishReason.toolCalls:
        return false;
      case LLMFinishReason.unknown:
        if (!hasTerminal) return false;
        break;
      case LLMFinishReason.stop:
      case LLMFinishReason.length:
        break;
    }
    final hasContent = message.content?.trim().isNotEmpty == true;
    return hasContent || hasTerminal;
  }

  static List<Message> activePrefixThroughTurn({
    required List<Message> activeMessages,
    required String targetMessageId,
    required String targetTurnId,
  }) {
    var targetIndex = -1;
    for (var i = 0; i < activeMessages.length; i++) {
      final identity = MessageHistoryIdentity.read(activeMessages[i]);
      if (identity.messageId == targetMessageId &&
          identity.turnId == targetTurnId) {
        targetIndex = i;
        break;
      }
    }
    if (targetIndex < 0) return const [];
    var last = targetIndex;
    for (var i = targetIndex; i < activeMessages.length; i++) {
      final identity = MessageHistoryIdentity.read(activeMessages[i]);
      if (identity.turnId == targetTurnId) {
        last = i;
      }
    }
    return activeMessages.sublist(0, last + 1);
  }

  static List<Message> rewritePrefix(List<Message> prefix) {
    final messageIds = <String, String>{};
    final turnIds = <String, String>{};
    final toolIds = <String, String>{};
    return [
      for (final message in prefix)
        _rewrite(message, messageIds, turnIds, toolIds),
    ];
  }

  static Message _rewrite(
    Message message,
    Map<String, String> messageIds,
    Map<String, String> turnIds,
    Map<String, String> toolIds,
  ) {
    final identity = MessageHistoryIdentity.read(message);
    final originId = identity.messageId.isEmpty ? null : identity.messageId;
    final newMessageId = _mapId(
      messageIds,
      identity.messageId.isEmpty ? _uuid.v4() : identity.messageId,
    );
    final newTurnId = _mapId(
      turnIds,
      identity.turnId.isEmpty ? _uuid.v4() : identity.turnId,
    );
    final tools = message.toolCalls
        ?.map(
          (call) => ToolCall(
            id: _mapId(toolIds, call.id),
            name: call.name,
            arguments: Map<String, dynamic>.from(call.arguments),
            providerState: call.providerState,
          ),
        )
        .toList(growable: false);
    final toolCallId = message.toolCallId == null
        ? null
        : _mapId(toolIds, message.toolCallId!);
    final metadata = _rewriteMetadata(
      message.metadata,
      messageId: newMessageId,
      turnId: newTurnId,
      originMessageId: originId,
      toolIds: toolIds,
    );
    return message.copyWith(
      toolCalls: tools,
      toolCallId: toolCallId,
      metadata: metadata,
    );
  }

  static Map<String, dynamic> _rewriteMetadata(
    Map<String, dynamic>? source, {
    required String messageId,
    required String turnId,
    required String? originMessageId,
    required Map<String, String> toolIds,
  }) {
    final metadata = Map<String, dynamic>.from(source ?? const {});
    metadata['message_id'] = messageId;
    metadata['turn_id'] = turnId;
    if (originMessageId != null) {
      metadata['origin_message_id'] = originMessageId;
    }
    final toolCallId = metadata['tool_call_id']?.toString();
    if (toolCallId != null && toolCallId.isNotEmpty) {
      metadata['tool_call_id'] = _mapId(toolIds, toolCallId);
    }
    final steers = metadata['steer_messages'];
    if (steers is List) {
      metadata['steer_messages'] = [
        for (final entry in steers)
          if (entry is Map)
            _rewriteSteer(Map<String, dynamic>.from(entry), turnId)
          else
            entry,
      ];
    }
    return metadata;
  }

  static Map<String, dynamic> _rewriteSteer(
    Map<String, dynamic> entry,
    String turnId,
  ) {
    return {
      ...entry,
      'message_id': _uuid.v4(),
      'turn_id': turnId,
      'origin_message_id': entry['message_id'],
    };
  }

  static String _mapId(Map<String, String> mapped, String source) {
    return mapped.putIfAbsent(source, _uuid.v4);
  }
}
