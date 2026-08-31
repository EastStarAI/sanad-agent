import 'dart:convert';

import '../../capabilities/models/tool_schema.dart';
import '../../core/models/agent_response.dart';
import '../../core/models/llm_provider_state.dart';
import '../../core/models/message.dart';
import '../../core/models/tool_call.dart';
import '../../core/provider_thinking/openai_thinking_wire_codec.dart';
import 'llm_request_options.dart';

class CodexResponsesException implements Exception {
  final String message;
  final String? code;
  final LLMFinishReason finishReason;

  const CodexResponsesException(
    this.message, {
    this.code,
    this.finishReason = LLMFinishReason.failed,
  });

  @override
  String toString() => code == null ? message : '$code: $message';
}

class CodexResponsesCodec {
  static const providerStateNamespace = 'codex_responses';
  static const _maxReplayItemIdLength = 64;
  static final _toolCallLeak = RegExp(
    r'(?:assistant\s+)?to=functions\.[A-Za-z0-9_.-]+',
    caseSensitive: false,
  );
  static const _serverSideToolCallTypes = {
    'web_search_call',
    'file_search_call',
    'code_interpreter_call',
    'image_generation_call',
    'computer_call',
    'local_shell_call',
    'mcp_call',
  };

  final String issuer;
  final String defaultProvider;

  const CodexResponsesCodec({
    required this.issuer,
    required this.defaultProvider,
  });

  Map<String, dynamic> buildRequest({
    required List<Message> history,
    required String model,
    required LLMRequestOptions options,
    List<ToolSchema>? tools,
    bool stream = false,
  }) {
    if (model.trim().isEmpty) {
      throw const FormatException(
        "Codex Responses request 'model' must be non-empty.",
      );
    }

    final instructions = history
        .where((message) => message.role == MessageRole.system)
        .map((message) => message.content?.trim() ?? '')
        .where((content) => content.isNotEmpty)
        .join('\n\n');
    final input = _historyToInput(history);
    final reasoning = <String, dynamic>{};
    OpenAiThinkingWireCodec.applyResponsesReasoning(
      reasoning,
      options.thinkingDirective,
    );
    final body = <String, dynamic>{
      'model': model.trim(),
      'instructions': instructions.isEmpty
          ? 'You are a helpful AI assistant.'
          : instructions,
      'input': input,
      'store': false,
      'include': const ['reasoning.encrypted_content'],
      'reasoning': reasoning,
      if (stream) 'stream': true,
    };
    if (options.maxOutputTokens != null) {
      body['max_output_tokens'] = options.maxOutputTokens;
    }

    if (tools != null && tools.isNotEmpty) {
      body['tools'] = tools
          .map(
            (tool) => <String, dynamic>{
              'type': 'function',
              'name': tool.name,
              'description': tool.description,
              'strict': false,
              'parameters': tool.parameters,
            },
          )
          .toList(growable: false);
    }
    return _preflight(body, allowStream: stream);
  }

  static bool hasEncryptedReasoningReplay(Map<String, dynamic> body) {
    final input = body['input'];
    if (input is! List) return false;
    return input.any((raw) {
      final item = _map(raw);
      return item?['type'] == 'reasoning' &&
          item?['encrypted_content'] is String &&
          (item!['encrypted_content'] as String).isNotEmpty;
    });
  }

  AgentResponse normalize(
    Map<String, dynamic> response, {
    required String fallbackModel,
    String? provider,
  }) {
    final status = _normalizedToken(response['status']) ?? 'completed';
    if (status == 'failed' || status == 'cancelled' || status == 'canceled') {
      final error = _map(response['error']);
      final code = error?['code']?.toString().trim();
      final message = error?['message']?.toString().trim();
      throw CodexResponsesException(
        message?.isNotEmpty == true
            ? message!
            : 'Responses API returned status $status.',
        code: code?.isNotEmpty == true ? code : null,
        finishReason: status.startsWith('cancel')
            ? LLMFinishReason.cancelled
            : LLMFinishReason.failed,
      );
    }

    final output = response['output'];
    if (output is! List) {
      throw const FormatException(
        'Responses API response must contain an output list.',
      );
    }

    final contentParts = <String>[];
    final thoughtParts = <String>[];
    final reasoningParts = <String>[];
    final reasoningItems = <Map<String, dynamic>>[];
    final messageItems = <Map<String, dynamic>>[];
    final toolCalls = <ToolCall>[];
    var incomplete = const {
      'queued',
      'in_progress',
      'incomplete',
    }.contains(status);
    var sawCommentary = false;
    var sawFinalPhase = false;
    var sawReasoning = false;

    for (var index = 0; index < output.length; index++) {
      final item = _map(output[index]);
      if (item == null) {
        throw FormatException('Responses output[$index] must be an object.');
      }
      final type =
          item['type']?.toString() ??
          (item.containsKey('content') ? 'message' : null);
      final itemStatus = _normalizedToken(item['status']);
      if (const {'queued', 'in_progress', 'incomplete'}.contains(itemStatus) &&
          !_serverSideToolCallTypes.contains(type)) {
        incomplete = true;
      }

      switch (type) {
        case 'message':
          final phase = _normalizedToken(item['phase']);
          final isCommentary = phase == 'commentary';
          final isAnalysis = phase == 'analysis';
          if (isCommentary) sawCommentary = true;
          if (phase == 'final' || phase == 'final_answer') sawFinalPhase = true;
          final content = item['content'];
          if (content is! List) {
            throw FormatException(
              'Responses message output[$index] must contain a content list.',
            );
          }
          final safeParts = <Map<String, dynamic>>[];
          final itemText = <String>[];
          for (var partIndex = 0; partIndex < content.length; partIndex++) {
            final part = _map(content[partIndex]);
            if (part == null) {
              throw FormatException(
                'Responses output[$index].content[$partIndex] must be an object.',
              );
            }
            final partType = item['role'] == 'assistant'
                ? part['type']?.toString()
                : null;
            if (partType != 'output_text' && partType != 'text') continue;
            final text = part['text']?.toString() ?? '';
            safeParts.add({'type': 'output_text', 'text': text});
            if (text.isNotEmpty) itemText.add(text);
          }
          final joined = itemText.join();
          if (joined.isNotEmpty) {
            if (isCommentary) {
              thoughtParts.add(joined);
            } else if (isAnalysis) {
              reasoningParts.add(joined);
            } else {
              contentParts.add(joined);
            }
          }
          if (safeParts.isNotEmpty) {
            final safeItem = <String, dynamic>{
              'type': 'message',
              'role': 'assistant',
              'status': _messageStatus(itemStatus),
              'content': safeParts,
            };
            final id = _safeReplayId(item['id']);
            if (id != null) safeItem['id'] = id;
            if (phase != null) safeItem['phase'] = phase;
            messageItems.add(safeItem);
          }
        case 'reasoning':
          sawReasoning = true;
          final summary = item['summary'];
          final safeSummary = <Map<String, dynamic>>[];
          if (summary is List) {
            for (final rawPart in summary) {
              final part = _map(rawPart);
              final text = part?['text']?.toString();
              if (text?.isNotEmpty == true) {
                reasoningParts.add(text!);
                safeSummary.add({'type': 'summary_text', 'text': text});
              }
            }
          }
          final directText = item['text']?.toString();
          if (directText?.isNotEmpty == true && safeSummary.isEmpty) {
            reasoningParts.add(directText!);
          }
          final encrypted = item['encrypted_content']?.toString();
          final itemId = item['id']?.toString();
          if (encrypted?.isNotEmpty == true &&
              !(itemId?.startsWith('rs_tmp_') ?? false)) {
            reasoningItems.add({
              'type': 'reasoning',
              'encrypted_content': encrypted,
              if (itemId?.isNotEmpty == true) 'id': itemId,
              'summary': safeSummary,
            });
          }
        case 'function_call':
          if (const {
            'queued',
            'in_progress',
            'incomplete',
          }.contains(itemStatus)) {
            continue;
          }
          toolCalls.add(_functionCall(item, toolCalls.length));
        case 'custom_tool_call':
          if (const {
            'queued',
            'in_progress',
            'incomplete',
          }.contains(itemStatus)) {
            continue;
          }
          toolCalls.add(_customToolCall(item, toolCalls.length));
      }
    }

    var content = contentParts.join('\n').trim();
    if (content.isEmpty && !(sawCommentary && !sawFinalPhase)) {
      final fallback = response['output_text'];
      if (fallback is String) content = fallback.trim();
    }
    final leakedToolCall =
        content.isNotEmpty &&
        toolCalls.isEmpty &&
        _toolCallLeak.hasMatch(content);
    if (leakedToolCall) content = '';

    final thought = thoughtParts
        .where((part) => part.trim().isNotEmpty)
        .join('\n\n')
        .trim();
    final reasoning = reasoningParts
        .where((part) => part.trim().isNotEmpty)
        .join('\n\n')
        .trim();
    final state = reasoningItems.isEmpty && messageItems.isEmpty
        ? null
        : LLMProviderState(
            namespace: providerStateNamespace,
            issuer: issuer,
            data: {
              if (reasoningItems.isNotEmpty) 'reasoning_items': reasoningItems,
              if (messageItems.isNotEmpty) 'message_items': messageItems,
            },
          );

    final finishReason = toolCalls.isNotEmpty
        ? LLMFinishReason.toolCalls
        : leakedToolCall ||
              incomplete ||
              (sawCommentary && !sawFinalPhase) ||
              ((sawReasoning ||
                      reasoningItems.isNotEmpty ||
                      reasoning.isNotEmpty) &&
                  content.isEmpty)
        ? LLMFinishReason.incomplete
        : LLMFinishReason.stop;
    final usage = _normalizeUsage(response['usage']);
    final model = response['model']?.toString().trim();

    return AgentResponse(
      message: Message(
        role: MessageRole.assistant,
        content: content.isEmpty ? null : content,
        thought: thought.isEmpty ? null : thought,
        reasoning: reasoning.isEmpty ? null : reasoning,
        toolCalls: toolCalls.isEmpty ? null : toolCalls,
        providerState: state,
        metadata: {
          if (response['id'] != null) 'response_id': response['id'],
          'response_status': status,
          if (response['incomplete_details'] != null)
            'incomplete_details': response['incomplete_details'],
        },
      ),
      isToolCall: toolCalls.isNotEmpty,
      usage: usage,
      model: model?.isNotEmpty == true ? model : fallbackModel,
      provider: provider ?? defaultProvider,
      finishReason: finishReason,
    );
  }

  List<Map<String, dynamic>> _historyToInput(List<Message> history) {
    final input = <Map<String, dynamic>>[];
    final seenReasoningIds = <String>{};
    for (final message in history) {
      if (message.role == MessageRole.system) continue;
      if (message.role == MessageRole.tool) {
        final callId = message.toolCallId?.trim() ?? '';
        if (callId.isEmpty) {
          throw const FormatException(
            'Codex Responses tool output is missing toolCallId.',
          );
        }
        input.add({
          'type': 'function_call_output',
          'call_id': callId,
          'output': message.content ?? '',
        });
        continue;
      }

      if (message.role == MessageRole.user) {
        input.add({
          'role': 'user',
          'content': [
            {'type': 'input_text', 'text': message.content ?? ''},
          ],
        });
        continue;
      }

      var replayedReasoning = false;
      var replayedMessages = false;
      final state = message.providerState;
      if (state?.namespace == providerStateNamespace &&
          state?.issuer == issuer) {
        final rawReasoning = state!.data['reasoning_items'];
        if (rawReasoning is List) {
          for (final raw in rawReasoning) {
            final item = _map(raw);
            final encrypted = item?['encrypted_content']?.toString();
            if (encrypted?.isNotEmpty != true) continue;
            final id = item?['id']?.toString();
            if (id?.isNotEmpty == true && !seenReasoningIds.add(id!)) continue;
            input.add({
              'type': 'reasoning',
              'encrypted_content': encrypted,
              'summary': _safeSummary(item?['summary']),
            });
            replayedReasoning = true;
          }
        }
        final rawMessages = state.data['message_items'];
        if (rawMessages is List) {
          for (final raw in rawMessages) {
            final replay = _safeMessageReplay(raw);
            if (replay == null) continue;
            input.add(replay);
            replayedMessages = true;
          }
        }
      }

      if (!replayedMessages && message.content != null) {
        input.add({
          'role': 'assistant',
          'content': [
            {'type': 'output_text', 'text': message.content},
          ],
        });
      } else if (!replayedMessages && replayedReasoning) {
        input.add({
          'role': 'assistant',
          'content': const [
            {'type': 'output_text', 'text': ''},
          ],
        });
      }

      for (final toolCall in message.toolCalls ?? const <ToolCall>[]) {
        if (toolCall.id.trim().isEmpty || toolCall.name.trim().isEmpty) {
          throw const FormatException(
            'Codex Responses function call requires id and name.',
          );
        }
        input.add({
          'type': 'function_call',
          'call_id': toolCall.id.trim(),
          'name': toolCall.name.trim(),
          'arguments': jsonEncode(toolCall.arguments),
        });
      }
    }
    return input;
  }

  Map<String, dynamic> _preflight(
    Map<String, dynamic> body, {
    required bool allowStream,
  }) {
    if (body['store'] != false) {
      throw const FormatException('Codex Responses requires store=false.');
    }
    if (body['input'] is! List) {
      throw const FormatException('Codex Responses input must be a list.');
    }
    if (!allowStream && body.containsKey('stream')) {
      throw const FormatException('Unexpected stream flag in sync request.');
    }
    if (body['max_output_tokens'] case final num value when value <= 0) {
      throw const FormatException('max_output_tokens must be positive.');
    }

    final input = body['input'] as List;
    for (var index = 0; index < input.length; index++) {
      final item = _map(input[index]);
      if (item == null) {
        throw FormatException(
          'Codex Responses input[$index] must be an object.',
        );
      }
      final type = item['type'];
      if (type == 'reasoning') {
        if (item['encrypted_content'] is! String ||
            (item['encrypted_content'] as String).isEmpty) {
          throw FormatException(
            'Reasoning input[$index] is missing encrypted_content.',
          );
        }
        if (item.containsKey('id')) {
          throw FormatException(
            'Reasoning input[$index] must not replay id with store=false.',
          );
        }
      } else if (type == 'function_call') {
        _requireNonEmpty(item, 'call_id', index);
        _requireNonEmpty(item, 'name', index);
        final decoded = _decodeObject(item['arguments']?.toString() ?? '');
        if (decoded == null) {
          throw FormatException(
            'Function input[$index] arguments must be a JSON object.',
          );
        }
      } else if (type == 'function_call_output') {
        _requireNonEmpty(item, 'call_id', index);
        if (item['output'] is! String) {
          throw FormatException('Function output[$index] must be a string.');
        }
      } else if (type == 'message') {
        if (item['role'] != 'assistant' || item['content'] is! List) {
          throw FormatException(
            'Message input[$index] must be an assistant content list.',
          );
        }
      } else if (item['role'] == 'user' || item['role'] == 'assistant') {
        if (item['content'] is! List) {
          throw FormatException('Role input[$index] content must be a list.');
        }
      } else {
        throw FormatException('Unsupported Codex Responses input[$index].');
      }
    }

    final tools = body['tools'];
    if (tools != null) {
      if (tools is! List) {
        throw const FormatException('Codex Responses tools must be a list.');
      }
      for (var index = 0; index < tools.length; index++) {
        final tool = _map(tools[index]);
        if (tool == null || tool['type'] != 'function') {
          throw FormatException(
            'Codex Responses tools[$index] must be a function.',
          );
        }
        _requireNonEmpty(tool, 'name', index);
        if (tool['parameters'] is! Map) {
          throw FormatException(
            'Codex Responses tools[$index] parameters must be an object.',
          );
        }
      }
    }
    return body;
  }

  ToolCall _functionCall(Map<String, dynamic> item, int index) {
    final name = item['name']?.toString().trim() ?? '';
    if (name.isEmpty) {
      throw const FormatException('Responses function_call is missing name.');
    }
    final argumentsText = item['arguments'] is String
        ? item['arguments'] as String
        : jsonEncode(item['arguments'] ?? const <String, dynamic>{});
    final arguments = _decodeObject(argumentsText);
    if (arguments == null) {
      throw FormatException('Malformed arguments for Responses tool $name.');
    }
    final itemId = item['id']?.toString().trim();
    final callId = _callId(item['call_id'], name, argumentsText, index, itemId);
    return ToolCall(
      id: callId,
      name: name,
      arguments: arguments,
      providerState: itemId?.isNotEmpty == true
          ? LLMProviderState(
              namespace: providerStateNamespace,
              issuer: issuer,
              data: {'response_item_id': itemId},
            )
          : null,
    );
  }

  ToolCall _customToolCall(Map<String, dynamic> item, int index) {
    final name = item['name']?.toString().trim() ?? '';
    if (name.isEmpty) {
      throw const FormatException(
        'Responses custom_tool_call is missing name.',
      );
    }
    final input = item['input'];
    final inputText = input is String ? input : jsonEncode(input ?? '');
    final arguments = _decodeObject(inputText) ?? {'input': inputText};
    final itemId = item['id']?.toString().trim();
    final callId = _callId(item['call_id'], name, inputText, index, itemId);
    return ToolCall(
      id: callId,
      name: name,
      arguments: arguments,
      providerState: itemId?.isNotEmpty == true
          ? LLMProviderState(
              namespace: providerStateNamespace,
              issuer: issuer,
              data: {'response_item_id': itemId, 'type': 'custom_tool_call'},
            )
          : null,
    );
  }

  String _callId(
    dynamic rawCallId,
    String name,
    String arguments,
    int index,
    String? itemId,
  ) {
    final callId = rawCallId?.toString().trim();
    if (callId?.isNotEmpty == true) return callId!;
    if (itemId?.startsWith('fc_') == true && itemId!.length > 3) {
      return 'call_${itemId.substring(3)}';
    }
    return 'call_${_fnv1a('$name:$arguments:$index')}';
  }

  static String _fnv1a(String value) {
    var hash = 0xcbf29ce484222325;
    for (final byte in utf8.encode(value)) {
      hash ^= byte;
      hash = (hash * 0x100000001b3) & 0xffffffffffffffff;
    }
    return hash.toRadixString(16).padLeft(16, '0').substring(0, 12);
  }

  static Map<String, dynamic>? _normalizeUsage(dynamic raw) {
    final usage = _map(raw);
    if (usage == null) return null;
    final normalized = Map<String, dynamic>.from(usage);
    final outputDetails = _map(usage['output_tokens_details']);
    final reasoningTokens = outputDetails?['reasoning_tokens'];
    if (reasoningTokens is num) {
      normalized['reasoning_tokens'] = reasoningTokens.toInt();
    }
    return normalized;
  }

  static Map<String, dynamic>? _safeMessageReplay(dynamic raw) {
    final item = _map(raw);
    if (item?['type'] != 'message' || item?['role'] != 'assistant') return null;
    final content = item?['content'];
    if (content is! List) return null;
    final parts = <Map<String, dynamic>>[];
    for (final rawPart in content) {
      final part = _map(rawPart);
      final type = part?['type']?.toString();
      if (type != 'output_text' && type != 'text') continue;
      parts.add({
        'type': 'output_text',
        'text': part?['text']?.toString() ?? '',
      });
    }
    if (parts.isEmpty) return null;
    final id = _safeReplayId(item?['id']);
    final phase = _normalizedToken(item?['phase']);
    final replay = <String, dynamic>{
      'type': 'message',
      'role': 'assistant',
      'status': _messageStatus(_normalizedToken(item?['status'])),
      'content': parts,
    };
    if (id != null) replay['id'] = id;
    if (phase != null) replay['phase'] = phase;
    return replay;
  }

  static List<Map<String, dynamic>> _safeSummary(dynamic raw) {
    if (raw is! List) return const [];
    return [
      for (final rawPart in raw)
        if (_map(rawPart)?['text'] != null)
          {'type': 'summary_text', 'text': _map(rawPart)!['text'].toString()},
    ];
  }

  static String? _safeReplayId(dynamic raw) {
    final id = raw?.toString().trim();
    if (id == null || id.isEmpty || id.length > _maxReplayItemIdLength) {
      return null;
    }
    return id;
  }

  static String _messageStatus(String? value) =>
      const {'completed', 'incomplete', 'in_progress'}.contains(value)
      ? value!
      : 'completed';

  static String? _normalizedToken(dynamic raw) {
    final value = raw?.toString().trim().toLowerCase();
    if (value == null || value.isEmpty) return null;
    return value.replaceAll('-', '_').replaceAll(' ', '_');
  }

  static void _requireNonEmpty(
    Map<String, dynamic> item,
    String key,
    int index,
  ) {
    if (item[key] is! String || (item[key] as String).trim().isEmpty) {
      throw FormatException('Codex Responses item[$index] is missing $key.');
    }
  }

  static Map<String, dynamic>? _decodeObject(String raw) {
    try {
      final decoded = jsonDecode(raw);
      return _map(decoded);
    } catch (_) {
      return null;
    }
  }

  static Map<String, dynamic>? _map(dynamic raw) {
    if (raw is Map<String, dynamic>) return raw;
    if (raw is Map) return raw.map((key, value) => MapEntry('$key', value));
    return null;
  }
}
