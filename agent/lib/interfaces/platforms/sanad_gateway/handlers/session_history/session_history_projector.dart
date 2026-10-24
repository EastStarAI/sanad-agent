import 'dart:convert';

import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/models/user_attachment.dart';
import 'package:sanad_agent/evolution/compaction/model_context_projection.dart';
import 'package:sanad_agent/evolution/db/message_history_identity.dart';
import 'package:sanad_agent/evolution/db/session_message_repository.dart';
import 'package:sanad_agent/evolution/db/terminal_assistant_classifier.dart';
import 'package:sanad_agent/evolution/models/session_history_page.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';

/// Resolves the originating tool call of a durable tool message when the
/// visible page does not hold the assistant turn that requested it.
typedef ToolCallOriginLookup =
    OriginatingToolCallContext? Function(
      String sessionId, {
      required String toolCallId,
      String? turnId,
    });

/// Canonical history rows for one page plus the placements its synthetic rows
/// need.
class SessionHistoryProjection {
  final List<Map<String, dynamic>> messages;
  final Map<int, int> historyStartByMessageRowId;
  final Map<String, dynamic>? latestContextUsage;

  const SessionHistoryProjection({
    required this.messages,
    required this.historyStartByMessageRowId,
    required this.latestContextUsage,
  });
}

/// Projects durable page rows into canonical `session_history` message rows.
///
/// Every runtime input arrives explicitly: `SessionQueryHandler` keeps session
/// lookup, page selection, and envelope assembly, while this projector owns row
/// shapes, stable event ids, terminal classification input, and the latest
/// context-usage projection.
class SessionHistoryProjector {
  final ToolCallOriginLookup toolCallOriginLookup;

  const SessionHistoryProjector({required this.toolCallOriginLookup});

  SessionHistoryProjection project({
    required String sessionId,
    required List<PersistedMessage> persistedMessages,
    required Message? followingMessage,
    required DateTime baseTime,
    required Map<String, dynamic>? sessionMetadata,
    required Map<String, dynamic> activeContinuation,
  }) {
    final messages = persistedMessages
        .map((entry) => entry.message)
        .toList(growable: false);
    final latestContextUsage = _latestContextUsage(sessionMetadata, messages);
    var index = 0;

    final historyMessages = <Map<String, dynamic>>[];
    final historyStartByMessageRowId = <int, int>{};
    final toolResultByCallId = <String, Message>{};
    for (final pm in persistedMessages) {
      final m = pm.message;
      if (m.role == MessageRole.tool &&
          m.toolCallId != null &&
          m.toolCallId!.isNotEmpty) {
        toolResultByCallId[m.toolCallId!] = m;
      }
    }
    final executingToolIds = List<String>.from(
      activeContinuation['currently_executing_tools'] as List? ?? const [],
    );
    final activeToolStartedAt = Map<String, dynamic>.from(
      activeContinuation['tool_started_at'] as Map? ?? const {},
    );
    for (
      var messageIndex = 0;
      messageIndex < persistedMessages.length;
      messageIndex++
    ) {
      final persistedMessage = persistedMessages[messageIndex];
      final message = persistedMessage.message;
      historyStartByMessageRowId[persistedMessage.rowId] =
          historyMessages.length;
      final msgId = ++index;
      final msgTime = baseTime.add(Duration(seconds: msgId)).toIso8601String();

      if (message.role == MessageRole.user) {
        final metadata = message.metadata;
        historyMessages.add({
          'id': msgId,
          'sender': 'user',
          'type': 'user_message',
          'content': message.content ?? '',
          if (message.attachments.isNotEmpty)
            'attachments': UserAttachmentPolicy.publicProjection(
              message.attachments,
            ),
          'created_at': metadata?['received_at'] ?? msgTime,
          'session_id': sessionId,
          ...MessageHistoryIdentity.wireFields(message),
          ...?metadata == null
              ? null
              : {
                  'metadata': metadata,
                  if (metadata['request_id'] != null)
                    'request_id': metadata['request_id'],
                },
        });
        continue;
      }

      if (message.role == MessageRole.assistant &&
          message.metadata?['superseded_by_steer'] == true) {
        final content = _nonEmpty(message.content);
        if (content != null) {
          final runId = message.metadata?['run_id'];
          final modelStepId = message.metadata?['model_step_id'];
          historyMessages.add({
            'id': msgId,
            'sender': 'ai',
            'type': 'thought',
            'content': content,
            'created_at': message.metadata?['received_at'] ?? msgTime,
            'session_id': sessionId,
            'run_id': ?runId,
            'model_step_id': ?modelStepId,
          });
        }
        continue;
      }

      if (message.role == MessageRole.assistant &&
          message.toolCalls != null &&
          message.toolCalls!.isNotEmpty) {
        final runId = message.metadata?['run_id'];
        final modelStepId = message.metadata?['model_step_id'];
        final reasoningContent = _nonEmpty(message.reasoning);
        final thoughtContent =
            _nonEmpty(message.thought) ?? _nonEmpty(message.content);

        if (reasoningContent != null) {
          historyMessages.add({
            'id': msgId,
            'sender': 'ai',
            'type': 'reasoning',
            'content': reasoningContent,
            'run_id': ?runId,
            'model_step_id': ?modelStepId,
            if (message.metadata?['context_usage'] != null)
              'context_usage': message.metadata!['context_usage'],
            'created_at': msgTime,
            'session_id': sessionId,
          });
          index++;
        }
        if (thoughtContent != null && thoughtContent != reasoningContent) {
          final thoughtId = reasoningContent == null ? msgId : index;
          historyMessages.add({
            'id': thoughtId,
            'sender': 'ai',
            'type': 'thought',
            'content': thoughtContent,
            'run_id': ?runId,
            'model_step_id': ?modelStepId,
            if (message.metadata?['context_usage'] != null)
              'context_usage': message.metadata!['context_usage'],
            'created_at': baseTime
                .add(Duration(seconds: thoughtId))
                .toIso8601String(),
            'session_id': sessionId,
          });
          index++;
        }

        for (final toolCall in message.toolCalls!) {
          final isExecuting = executingToolIds.contains(toolCall.id);
          final matchingResult = toolResultByCallId[toolCall.id];
          final startedAt =
              matchingResult?.metadata?['started_at']?.toString() ??
              activeToolStartedAt[toolCall.id]?.toString();
          final toolCreatedAt =
              startedAt ??
              baseTime.add(Duration(seconds: index)).toIso8601String();
          final matchingTerminalAt = matchingResult?.metadata?['terminal_at']
              ?.toString();
          final matchingRuntimeMs = matchingResult?.metadata?['runtime_ms'];

          historyMessages.add({
            'id': index,
            'sender': 'ai',
            'type': 'tool_use',
            'tool': toolCall.name,
            'input': _visibleToolInput(toolCall.name, toolCall.arguments),
            'status': isExecuting ? 'running' : 'done',
            'run_id': ?runId,
            'model_step_id': ?modelStepId,
            'tool_call_id': toolCall.id,
            if (message.metadata?['context_usage'] != null)
              'context_usage': message.metadata!['context_usage'],
            'created_at': toolCreatedAt,
            'started_at': ?startedAt,
            'terminal_at': ?matchingTerminalAt,
            'runtime_ms': ?matchingRuntimeMs,
            'session_id': sessionId,
          });
          index++;
        }
        continue;
      }

      if (message.role == MessageRole.tool) {
        final resolvedToolContext = _resolveToolContext(
          messages,
          message,
          sessionId: sessionId,
        );
        final visibleContent =
            message.metadata?['steer_original_content']?.toString() ??
            message.content ??
            '';
        final isError =
            message.metadata?['is_error'] == true ||
            visibleContent.startsWith('Error:');
        final media = ViewImageMediaProjection.project(
          sessionId: sessionId,
          toolName: resolvedToolContext.toolName,
          toolCallId: resolvedToolContext.toolCallId,
          result: message.toolResult,
        );

        final startedAt = message.metadata?['started_at']?.toString();
        final terminalAt = message.metadata?['terminal_at']?.toString();
        final runtimeMs = message.metadata?['runtime_ms'];
        final resultCreatedAt = terminalAt ?? msgTime;

        historyMessages.add({
          'id': msgId,
          'sender': 'ai',
          'type': 'tool_result',
          'tool': resolvedToolContext.toolName ?? 'Unknown Tool',
          'output': visibleContent,
          'isError': isError,
          // Same key as the live tool_result: the typed outcome (for example
          // permission_denied) so a reopened conversation shows "Not run".
          'errorCode': ?message.toolResult?.errorCodeWire,
          'status':
              message.metadata?['status']?.toString() ??
              (isError ? 'error' : 'done'),
          if (media != null) 'media': media.toPublicJson(),
          if (resolvedToolContext.runId != null)
            'run_id': resolvedToolContext.runId,
          if (resolvedToolContext.modelStepId != null)
            'model_step_id': resolvedToolContext.modelStepId,
          if (resolvedToolContext.toolCallId != null)
            'tool_call_id': resolvedToolContext.toolCallId,
          if (message.metadata?['generation'] != null)
            'generation': message.metadata!['generation'],
          if (message.metadata?['revision'] != null)
            'revision': message.metadata!['revision'],
          if (message.metadata?['reason'] != null)
            'reason': message.metadata!['reason'],
          'started_at': ?startedAt,
          'terminal_at': ?terminalAt,
          'runtime_ms': ?runtimeMs,
          if (message.metadata?['cleanup_outcome'] != null)
            'cleanup_outcome': message.metadata!['cleanup_outcome'],
          'created_at': resultCreatedAt,
          'session_id': sessionId,
        });
        final steerMessages = message.metadata?['steer_messages'];
        if (steerMessages is List) {
          for (final rawSteer in steerMessages) {
            if (rawSteer is! Map) continue;
            final steer = Map<String, dynamic>.from(rawSteer);
            final text = steer['text']?.toString().trim();
            if (text == null || text.isEmpty) continue;
            final steerId = ++index;
            final steerMessageId = steer['message_id']?.toString();
            final steerMetadata = <String, dynamic>{
              'steer': true,
              'input_kind': MessageHistoryIdentity.steer,
              'replay_eligible': false,
              'message_id': ?steerMessageId,
              'turn_id': ?steer['turn_id'],
              'request_id': ?steer['request_id'],
              'received_at': ?steer['received_at'],
            };
            historyMessages.add({
              'id': steerMessageId ?? steerId,
              'sender': 'user',
              'type': 'user_message',
              'content': text,
              'created_at':
                  steer['received_at'] ??
                  baseTime.add(Duration(seconds: steerId)).toIso8601String(),
              'session_id': sessionId,
              'metadata': steerMetadata,
              'input_kind': MessageHistoryIdentity.steer,
              'replay_eligible': false,
              'message_id': ?steerMessageId,
              'turn_id': ?steer['turn_id'],
              'request_id': ?steer['request_id'],
            });
          }
        }
        continue;
      }

      final meta = message.metadata;
      final reasoning = _nonEmpty(message.reasoning);
      final typedThought = _nonEmpty(message.thought);
      final isTerminalAssistant = TerminalAssistantClassifier.isTerminal(
        message,
        next: messageIndex + 1 < persistedMessages.length
            ? persistedMessages[messageIndex + 1].message
            : followingMessage,
      );
      if (reasoning != null) {
        historyMessages.add({
          'id': msgId,
          'sender': 'ai',
          'type': 'reasoning',
          'content': reasoning,
          if (meta?['run_id'] != null) 'run_id': meta!['run_id'],
          if (meta?['model_step_id'] != null)
            'model_step_id': meta!['model_step_id'],
          if (meta?['context_usage'] != null)
            'context_usage': meta!['context_usage'],
          'created_at': msgTime,
          'session_id': sessionId,
        });
        index++;
      }
      if (typedThought != null && typedThought != reasoning) {
        final thoughtId = reasoning == null ? msgId : index;
        historyMessages.add({
          'id': thoughtId,
          'sender': 'ai',
          'type': 'thought',
          'content': typedThought,
          if (meta?['run_id'] != null) 'run_id': meta!['run_id'],
          if (meta?['model_step_id'] != null)
            'model_step_id': meta!['model_step_id'],
          if (meta?['context_usage'] != null)
            'context_usage': meta!['context_usage'],
          'created_at': baseTime
              .add(Duration(seconds: thoughtId))
              .toIso8601String(),
          'session_id': sessionId,
        });
        index++;
      }
      if (!isTerminalAssistant) {
        final thought = _nonEmpty(message.content);
        if (thought != null &&
            thought != reasoning &&
            thought != typedThought) {
          final thoughtId = reasoning == null && typedThought == null
              ? msgId
              : index;
          historyMessages.add({
            'id': thoughtId,
            'sender': 'ai',
            'type': 'thought',
            'content': thought,
            if (meta?['run_id'] != null) 'run_id': meta!['run_id'],
            if (meta?['model_step_id'] != null)
              'model_step_id': meta!['model_step_id'],
            if (meta?['context_usage'] != null)
              'context_usage': meta!['context_usage'],
            'created_at': baseTime
                .add(Duration(seconds: thoughtId))
                .toIso8601String(),
            'session_id': sessionId,
          });
        }
        continue;
      }
      final finalAnswerId = reasoning == null && typedThought == null
          ? msgId
          : index;
      historyMessages.add({
        'id': finalAnswerId,
        'sender': 'ai',
        'type': 'final_answer',
        'content': message.content ?? '',
        'status': 'done',
        'created_at': baseTime
            .add(Duration(seconds: finalAnswerId))
            .toIso8601String(),
        'session_id': sessionId,
        ...MessageHistoryIdentity.wireFields(message),
        if (meta != null) ...{
          if (meta['run_id'] != null) 'run_id': meta['run_id'],
          if (meta['model_step_id'] != null)
            'model_step_id': meta['model_step_id'],
          if (meta['model'] != null) 'model': meta['model'],
          if (meta['model_display'] != null)
            'model_display': meta['model_display'],
          if (meta['provider'] != null) 'provider': meta['provider'],
          if (meta['context_tokens'] != null)
            'context_tokens': meta['context_tokens'],
          if (meta['runtime_ms'] != null) 'runtime_ms': meta['runtime_ms'],
          if (meta['usage'] != null) 'usage': meta['usage'],
          if (meta['context_usage'] != null)
            'context_usage': meta['context_usage'],
        },
      });
    }

    _assignStableHistoryEventIds(
      sessionId: sessionId,
      persistedMessages: persistedMessages,
      historyStartByMessageRowId: historyStartByMessageRowId,
      historyMessages: historyMessages,
    );

    if (latestContextUsage != null &&
        !historyMessages.any((row) => row['context_usage'] != null)) {
      for (final row in historyMessages.reversed) {
        final type = row['type'];
        if (type == 'final_answer' ||
            type == 'tool_use' ||
            type == 'thought' ||
            type == 'reasoning') {
          row['context_usage'] = latestContextUsage;
          break;
        }
      }
    }

    return SessionHistoryProjection(
      messages: historyMessages,
      historyStartByMessageRowId: historyStartByMessageRowId,
      latestContextUsage: latestContextUsage,
    );
  }

  void _assignStableHistoryEventIds({
    required String sessionId,
    required List<PersistedMessage> persistedMessages,
    required Map<int, int> historyStartByMessageRowId,
    required List<Map<String, dynamic>> historyMessages,
  }) {
    for (
      var messageIndex = 0;
      messageIndex < persistedMessages.length;
      messageIndex++
    ) {
      final persisted = persistedMessages[messageIndex];
      final start = historyStartByMessageRowId[persisted.rowId];
      if (start == null) continue;
      final end = messageIndex + 1 < persistedMessages.length
          ? historyStartByMessageRowId[persistedMessages[messageIndex + 1]
                    .rowId] ??
                historyMessages.length
          : historyMessages.length;
      final ordinals = <String, int>{};
      for (var rowIndex = start; rowIndex < end; rowIndex++) {
        final row = historyMessages[rowIndex];
        final kind = row['type']?.toString() ?? 'event';
        final ordinal = ordinals.update(
          kind,
          (value) => value + 1,
          ifAbsent: () => 0,
        );
        final eventId = SessionHistoryEventId.canonical(
          sessionId: sessionId,
          rowId: persisted.rowId,
          kind: kind,
          ordinal: ordinal,
        );
        row['id'] = eventId;
        row['event_id'] = eventId;
        row['source_message_row_id'] = persisted.rowId;
      }
    }
  }

  _ResolvedToolContext _resolveToolContext(
    List<Message> messages,
    Message message, {
    String? sessionId,
  }) {
    var toolCallId =
        message.toolCallId ?? message.metadata?['tool_call_id']?.toString();
    String? toolName;
    String? runId = message.metadata?['run_id']?.toString();
    String? modelStepId = message.metadata?['model_step_id']?.toString();

    if (toolCallId != null && toolCallId.isNotEmpty) {
      for (final previous in messages) {
        if (previous.role != MessageRole.assistant ||
            previous.toolCalls == null) {
          continue;
        }
        for (final toolCall in previous.toolCalls!) {
          if (toolCall.id == toolCallId) {
            toolName = toolCall.name;
            runId ??= previous.metadata?['run_id']?.toString();
            modelStepId ??= previous.metadata?['model_step_id']?.toString();
            break;
          }
        }
        if (toolName != null) {
          break;
        }
      }
      if (toolName == null && sessionId != null && sessionId.isNotEmpty) {
        final origin = toolCallOriginLookup(
          sessionId,
          toolCallId: toolCallId,
          turnId: message.metadata?['turn_id']?.toString(),
        );
        if (origin != null) {
          toolName = origin.toolCall.name;
          runId ??= origin.runId;
          modelStepId ??= origin.modelStepId;
        }
      }
    } else {
      final currentIndex = messages.indexOf(message);
      if (currentIndex != -1) {
        for (var idx = currentIndex - 1; idx >= 0; idx--) {
          final previous = messages[idx];
          if (previous.role == MessageRole.assistant &&
              previous.toolCalls != null &&
              previous.toolCalls!.isNotEmpty) {
            final toolCall = previous.toolCalls!.first;
            toolCallId = toolCall.id;
            toolName = toolCall.name;
            runId ??= previous.metadata?['run_id']?.toString();
            modelStepId ??= previous.metadata?['model_step_id']?.toString();
            break;
          }
        }
      }
    }

    return _ResolvedToolContext(
      toolCallId: toolCallId,
      toolName: toolName,
      runId: runId,
      modelStepId: modelStepId,
    );
  }

  static String _visibleToolInput(String name, Map<String, dynamic> arguments) {
    if (name != 'view_image') return jsonEncode(arguments);
    return jsonEncode({
      'path': '[local image path redacted]',
      if (arguments['detail'] != null) 'detail': arguments['detail'],
    });
  }

  static String? _nonEmpty(String? value) {
    final normalized = value?.trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }

  static Map<String, dynamic>? _latestContextUsage(
    Map<String, dynamic>? sessionMetadata,
    List<Message> messages,
  ) {
    final projected = sessionMetadata?['context_usage'];
    if (projected is Map) {
      return Map<String, dynamic>.from(projected);
    }

    for (final message in messages.reversed) {
      if (message.role != MessageRole.assistant) continue;
      final metadata = message.metadata;
      final stored = metadata?['context_usage'];
      if (stored is Map) return Map<String, dynamic>.from(stored);
      final usage = metadata?['usage'];
      if (usage is! Map) continue;

      int? read(List<String> keys) {
        for (final key in keys) {
          final value = usage[key];
          if (value is num && value >= 0) return value.toInt();
        }
        return null;
      }

      final inputTokens = read(const [
        'input_tokens',
        'prompt_tokens',
        'input',
      ]);
      final outputTokens = read(const [
        'output_tokens',
        'completion_tokens',
        'output',
      ]);
      final totalTokens = read(const ['total_tokens', 'total']);
      final cachedTokens = read(const [
        'cached_tokens',
        'cache_read_input_tokens',
        'cache_read',
      ]);
      final reasoningTokens = read(const ['reasoning_tokens']);
      final snapshot = <String, dynamic>{
        'input_tokens': ?inputTokens,
        'output_tokens': ?outputTokens,
        'total_tokens': ?totalTokens,
        'cached_tokens': ?cachedTokens,
        'reasoning_tokens': ?reasoningTokens,
        if (metadata?['context_tokens'] is num)
          'context_window_tokens': (metadata!['context_tokens'] as num).toInt(),
        if (metadata?['model'] != null) 'model_id': metadata!['model'],
        if (metadata?['provider'] != null)
          'provider_instance_id': metadata!['provider'],
        if (metadata?['run_id'] != null) 'run_id': metadata!['run_id'],
        if (metadata?['model_step_id'] != null)
          'model_step_id': metadata!['model_step_id'],
      };
      if (snapshot.isNotEmpty) return snapshot;
    }
    return null;
  }
}

class _ResolvedToolContext {
  final String? toolCallId;
  final String? toolName;
  final String? runId;
  final String? modelStepId;

  const _ResolvedToolContext({
    required this.toolCallId,
    required this.toolName,
    required this.runId,
    required this.modelStepId,
  });
}
