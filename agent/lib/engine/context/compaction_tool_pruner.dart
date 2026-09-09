import 'dart:convert';

import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/models/tool_call.dart';

import 'compaction_token_estimator.dart';
import 'compaction_tail_selector.dart';

/// Deterministic tool/media pruning for summary input and projection-only
/// copies (Plan 53c Gates C1–C2). Never mutates canonical persisted messages.
class CompactionToolPruner {
  final int maxToolResultChars;
  final int maxArgumentChars;

  const CompactionToolPruner({
    this.maxToolResultChars = 1200,
    this.maxArgumentChars = 400,
  });

  /// Prunes compressible head messages for summarizer input.
  /// Messages at or after [protectedTailStartRowId] stay verbatim.
  List<IndexedConversationMessage> pruneSourceMessages(
    List<IndexedConversationMessage> messages, {
    required int protectedTailStartRowId,
  }) {
    return [
      for (final entry in messages)
        if (entry.rowId >= protectedTailStartRowId)
          entry
        else
          IndexedConversationMessage(
            rowId: entry.rowId,
            message: _pruneMessage(entry.message, forSummarizer: true),
          ),
    ];
  }

  /// Projection-only pruning for oversized recent tool/media payloads.
  ///
  /// Used when a single retained-tail message exceeds the tail budget so the
  /// engine can still emit a measurable candidate instead of a no-op.
  List<IndexedConversationMessage> pruneOversizedForProjection(
    List<IndexedConversationMessage> messages,
  ) {
    return [
      for (final entry in messages)
        IndexedConversationMessage(
          rowId: entry.rowId,
          message: _pruneMessage(entry.message, forSummarizer: false),
        ),
    ];
  }

  Message _pruneMessage(Message message, {required bool forSummarizer}) {
    if (message.role == MessageRole.tool ||
        message.role == MessageRole.user ||
        message.role == MessageRole.assistant) {
      final content = message.content ?? '';
      final mediaDescription = _mediaDescription(message);
      if (mediaDescription != null && forSummarizer) {
        return message.copyWith(content: mediaDescription);
      }
      if (message.role == MessageRole.tool &&
          content.length > maxToolResultChars) {
        final prefix = content.substring(0, maxToolResultChars);
        final status = _toolStatusHint(content);
        return message.copyWith(
          content:
              '$prefix… [truncated for compaction; tool_call_id=${message.toolCallId ?? 'unknown'}; $status]',
        );
      }
    }
    if (message.role == MessageRole.assistant &&
        message.toolCalls != null &&
        message.toolCalls!.isNotEmpty) {
      final calls = message.toolCalls!.map((call) {
        final encoded = jsonEncode(call.arguments);
        if (encoded.length <= maxArgumentChars) {
          return call;
        }
        return ToolCall(
          id: call.id,
          name: call.name,
          arguments: {
            '_truncated': true,
            'name': call.name,
            'preview': encoded.substring(0, maxArgumentChars),
          },
          providerState: call.providerState,
        );
      }).toList();
      return message.copyWith(toolCalls: calls);
    }
    return message;
  }

  String? _mediaDescription(Message message) {
    final content = message.content ?? '';
    final mediaBytes = message.metadata?['media_bytes'];
    if (mediaBytes is int && mediaBytes > 0) {
      return '[media omitted for compaction summary: $mediaBytes bytes]';
    }
    final dataUri = RegExp(
      r'^data:([^;]+);base64,',
      caseSensitive: false,
    ).firstMatch(content.trim());
    if (dataUri != null) {
      return '[media omitted for compaction summary: ${dataUri.group(1)} data-uri]';
    }
    return null;
  }

  String _toolStatusHint(String content) {
    final lower = content.toLowerCase();
    if (lower.contains('error') || lower.contains('failed')) {
      return 'status=error';
    }
    return 'status=ok';
  }

  int estimatePruningSavings(
    List<IndexedConversationMessage> original,
    List<IndexedConversationMessage> pruned,
  ) {
    final before = CompactionTokenEstimator.estimateMessages(
      original.map((entry) => entry.message),
    );
    final after = CompactionTokenEstimator.estimateMessages(
      pruned.map((entry) => entry.message),
    );
    return before - after;
  }
}
