import 'dart:convert';
import 'package:logging/logging.dart';
import 'package:http/http.dart' as http;
import '../../core/config.dart';
import '../../core/models/message.dart';
import '../../core/models/agent_response.dart';
import '../../core/models/tool_call.dart';
import '../../capabilities/models/tool_schema.dart';
import 'llm_adapter.dart';
import '../../core/models/model_metadata.dart';
import '../../core/provider_runtime/provider_model_id.dart';
import '../../interfaces/platforms/sanad_gateway/capabilities.dart';
import 'provider_profile.dart';
import 'llm_http_exception.dart';
import 'llm_request_options.dart';
import 'provider_request_transport.dart';
import 'tagged_reasoning_parser.dart';
import '../llm_request_dumper.dart';
import '../../core/provider_runtime/provider_endpoint_resolver.dart';

class BaseAnthropicAdapter implements LLMAdapter {
  final _logger = Logger('BaseAnthropicAdapter');
  final Config config;
  final ProviderProfile profile;
  final http.Client? client;
  final String? baseUrlOverride;
  final String? apiKeyOverride;
  final String? defaultModelOverride;
  String _availableModelsSource = 'fallback';
  Object? _lastModelsException;

  BaseAnthropicAdapter(
    this.config,
    this.profile, {
    this.client,
    this.baseUrlOverride,
    this.apiKeyOverride,
    this.defaultModelOverride,
  }) {
    _logger.fine(
      'Initializing BaseAnthropicAdapter with profile: ${profile.name}',
    );
  }

  String get _baseUrl {
    final resolved = baseUrlOverride != null
        ? baseUrlOverride!
        : () {
            final configured = config.baseUrlFor(profile);
            if (configured.isNotEmpty &&
                configured != 'https://api.openai.com/v1' &&
                configured != 'https://api.anthropic.com/v1') {
              return configured;
            }
            return profile.defaultBaseUrl ?? 'https://api.anthropic.com';
          }();
    return ProviderEndpointResolver.normalizeBaseUrl(resolved);
  }

  String get _apiKey => apiKeyOverride ?? config.apiKeyFor(profile);
  String get availableModelsSource => _availableModelsSource;
  Object? get lastModelsException => _lastModelsException;

  @override
  Future<List<ModelOption>> getAvailableModels() async {
    final liveModels = await _fetchLiveModels();
    if (liveModels.isNotEmpty) {
      _availableModelsSource = 'live';
      return liveModels;
    }

    final List<ModelOption> options = [];
    final models = _fallbackModelIds();

    for (var m in models) {
      options.add(
        ModelOption(
          value: ProviderModelId.normalize(
            templateId: profile.name,
            protocol: profile.effectiveProtocol,
            rawModelId: m,
          ),
          label: _formatModelLabel(m),
          provider: 'anthropic',
          contextWindow: ModelMetadata.getLimitForModel(m) ?? 200000,
          supportsReasoning: false,
        ),
      );
    }
    _availableModelsSource = 'fallback';
    return options;
  }

  Future<List<ModelOption>> _fetchLiveModels() async {
    _lastModelsException = null;
    final Uri modelsEndpoint;
    try {
      modelsEndpoint = ProviderEndpointResolver.resolveModelsEndpoint(
        _baseUrl,
        profile.effectiveProtocol,
      );
    } catch (error) {
      _lastModelsException = error;
      return const [];
    }
    for (final headers in _modelFetchHeaderCandidates()) {
      try {
        final response = await (client ?? http.Client()).get(
          modelsEndpoint,
          headers: headers,
        );
        if (response.statusCode != 200) {
          _lastModelsException = LlmHttpException.fromResponse(
            response,
            operation: 'getAvailableModels',
          );
          continue;
        }

        final decoded = jsonDecode(response.body);
        final data = decoded['data'] as List?;
        if (data == null || data.isEmpty) {
          _lastModelsException = StateError(
            'Response data is empty or not a list',
          );
          continue;
        }

        _lastModelsException = null;
        return data
            .map((entry) {
              final rawId = (entry as Map)['id']?.toString() ?? '';
              final normalized = ProviderModelId.normalize(
                templateId: profile.name,
                protocol: profile.effectiveProtocol,
                rawModelId: rawId,
              );
              return ModelOption(
                value: normalized,
                label: _formatModelLabel(normalized),
                provider: 'anthropic',
                contextWindow:
                    ModelMetadata.getLimitForModel(normalized) ?? 200000,
                supportsReasoning: false,
              );
            })
            .where((model) => model.value.isNotEmpty)
            .toList(growable: false);
      } catch (e) {
        _logger.fine('Failed to fetch Anthropic-compatible models: $e');
        _lastModelsException = e;
      }
    }
    return const [];
  }

  static const _anthropicVersion = '2023-06-01';

  List<Map<String, String>> _modelFetchHeaderCandidates() {
    return [_anthropicHeaders(), _anthropicHeaders(useBearerAuth: true)];
  }

  Map<String, String> _anthropicHeaders({bool useBearerAuth = false}) {
    return {
      'Content-Type': 'application/json',
      if (useBearerAuth)
        'Authorization': 'Bearer $_apiKey'
      else
        'x-api-key': _apiKey,
      'anthropic-version': _anthropicVersion,
      ...profile.defaultHeaders,
    };
  }

  List<String> _fallbackModelIds() {
    final merged = <String>[];
    final selected = _resolveModel(defaultModelOverride);
    if (selected.isNotEmpty) {
      merged.add(selected);
    }
    final configuredFallbacks = profile.fallbackModels.isNotEmpty
        ? profile.fallbackModels
        : ['claude-3-5-sonnet-latest', 'claude-3-5-haiku-latest'];
    for (final model in configuredFallbacks) {
      final normalized = ProviderModelId.normalize(
        templateId: profile.name,
        protocol: profile.effectiveProtocol,
        rawModelId: model,
      );
      if (normalized.isNotEmpty && !merged.contains(normalized)) {
        merged.add(normalized);
      }
    }
    return merged;
  }

  String _formatModelLabel(String name) {
    String capitalize(String s) =>
        s.isEmpty ? '' : '${s[0].toUpperCase()}${s.substring(1)}';
    return name.split('-').map(capitalize).join(' ');
  }

  @override
  Future<int> getContextLimit([String? modelOverride]) async {
    final resolvedModel = _resolveModel(modelOverride);
    final configuredLimit = config.contextModelLimit(resolvedModel);
    if (configuredLimit != null) return configuredLimit;
    return ModelMetadata.getLimitForModel(resolvedModel) ?? 200000;
  }

  String _resolveModel(String? override) {
    if (override == null || override.isEmpty) {
      return defaultModelOverride == null || defaultModelOverride!.isEmpty
          ? config.llmModel
          : ProviderModelId.normalize(
              templateId: profile.name,
              protocol: profile.effectiveProtocol,
              rawModelId: defaultModelOverride!,
            );
    }
    return ProviderModelId.normalize(
      templateId: profile.name,
      protocol: profile.effectiveProtocol,
      rawModelId: override,
    );
  }

  @override
  Future<AgentResponse> generateResponse(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async {
    final url = ProviderEndpointResolver.resolveChatEndpoint(
      _baseUrl,
      profile.effectiveProtocol,
    );
    final resolvedModel = _resolveModel(modelOverride);

    final body = _buildRequestBody(
      history,
      resolvedModel: resolvedModel,
      tools: tools,
      options: options,
    );

    if (LLMRequestDumper.isEnabled) {
      await LLMRequestDumper.recordActualRequest(
        url: url,
        headers: _anthropicHeaders(),
        body: body,
      );
    }

    final transport = ProviderRequestTransport(
      options: options,
      adapterSharedClient: client,
    );
    late http.Response response;
    try {
      response = await transport.post(
        url,
        headers: _anthropicHeaders(),
        body: jsonEncode(body),
        operation: 'generateResponse',
      );
    } finally {
      await transport.dispose();
    }

    _logger.info('LLM Response status: ${response.statusCode}');
    if (LLMRequestDumper.isEnabled) {
      await LLMRequestDumper.dumpResponse(response.body);
    }

    if (response.statusCode != 200) {
      throw LlmHttpException.fromResponse(
        response,
        operation: 'generateResponse',
      );
    }

    final data = jsonDecode(response.body);
    final contentBlocks = data['content'] as List;

    String content = '';
    String reasoning = '';
    List<ToolCall>? toolCalls;

    for (var block in contentBlocks) {
      final type = block['type'];
      if (type == 'text') {
        content += block['text'] as String? ?? '';
      } else if (type == 'thinking') {
        reasoning += block['thinking'] as String? ?? '';
      } else if (type == 'tool_use') {
        toolCalls ??= [];
        toolCalls.add(
          ToolCall(
            id: block['id'],
            name: block['name'],
            arguments: block['input'] as Map<String, dynamic>? ?? {},
          ),
        );
      }
    }

    final tagged = splitTaggedReasoning(content);
    content = tagged.content ?? '';
    if (reasoning.trim().isEmpty && tagged.reasoning != null) {
      reasoning = tagged.reasoning!;
    }

    final usageData = data['usage'] as Map<String, dynamic>?;
    final usage = usageData == null
        ? null
        : _normalizeAnthropicUsage(usageData);

    final finishReason = _normalizeFinishReason(
      data['stop_reason'],
      hasToolCalls: toolCalls != null && toolCalls.isNotEmpty,
    );

    return AgentResponse(
      message: Message(
        role: MessageRole.assistant,
        content: content,
        reasoning: reasoning.trim().isEmpty ? null : reasoning,
        toolCalls: toolCalls,
      ),
      isToolCall: toolCalls != null && toolCalls.isNotEmpty,
      usage: usage,
      model: resolvedModel,
      provider: 'anthropic',
      finishReason: finishReason,
    );
  }

  @override
  Stream<AgentResponse> generateStream(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async* {
    final url = ProviderEndpointResolver.resolveChatEndpoint(
      _baseUrl,
      profile.effectiveProtocol,
    );
    final resolvedModel = _resolveModel(modelOverride);

    final body = _buildRequestBody(
      history,
      resolvedModel: resolvedModel,
      tools: tools,
      options: options,
      stream: true,
    );

    if (LLMRequestDumper.isEnabled) {
      await LLMRequestDumper.recordActualRequest(
        url: url,
        headers: _anthropicHeaders(),
        body: body,
      );
    }

    final transport = ProviderRequestTransport(
      options: options,
      adapterSharedClient: client,
    );
    final request = http.Request('POST', url);
    request.headers.addAll(_anthropicHeaders());
    request.body = jsonEncode(body);

    late http.StreamedResponse response;
    try {
      response = await transport.send(request, operation: 'generateStream');
    } catch (_) {
      await transport.dispose();
      rethrow;
    }

    try {
      _logger.info(
        'LLM Stream Response started (status: ${response.statusCode})',
      );

      if (response.statusCode != 200) {
        final err = await response.stream.bytesToString();
        if (LLMRequestDumper.isEnabled) {
          await LLMRequestDumper.dumpResponse({
            'status_code': response.statusCode,
            'error': err,
          });
        }
        throw LlmHttpException.fromStreamedResponse(
          response,
          err,
          operation: 'generateStream',
        );
      }

      final partialToolCalls = <int, _PartialClaudeToolCall>{};
      final taggedReasoning = TaggedReasoningStreamParser();
      Map<String, dynamic>? finalUsage;
      final List<String> accumulatedStreamLines = [];
      LLMFinishReason? streamFinishReason;

      try {
        await for (final line in transport.decodeSseLines(
          response.stream,
          operation: 'generateStream',
        )) {
          transport.throwIfCancelled(operation: 'generateStream');
          accumulatedStreamLines.add(line);
          final trimmed = line.trim();
          if (trimmed.isEmpty) continue;

          if (trimmed.startsWith('data: ')) {
            final dataStr = trimmed.substring(6).trim();
            if (dataStr.isEmpty) continue;

            try {
              final data = jsonDecode(dataStr);
              final eventType = data['type'] as String?;

              // Anthropic streams errors as `event: error` payloads carrying
              // `{type: "error", error: {type, message}}`. Treat them as HTTP
              // failures so the runtime classifier can handle them.
              if (eventType == 'error') {
                final err = data['error'];
                final errMap = err is Map<String, dynamic>
                    ? err
                    : <String, dynamic>{};
                final structuredError = {
                  'error': {
                    if (errMap['type'] != null) 'type': errMap['type'],
                    if (errMap['code'] != null) 'code': errMap['code'],
                    if (errMap['message'] != null) 'message': errMap['message'],
                  },
                };
                throw LlmHttpException(
                  statusCode: response.statusCode,
                  body: jsonEncode(structuredError),
                  headers: response.headers,
                  operation: 'generateStream',
                );
              }
              final otherError = data['error'];
              if (otherError is Map<String, dynamic>) {
                final code = otherError['code'];
                final statusCode = code is int
                    ? code
                    : int.tryParse(code?.toString() ?? '') ??
                          response.statusCode;
                final structuredError = {
                  'error': {
                    if (otherError['type'] != null) 'type': otherError['type'],
                    if (otherError['code'] != null) 'code': otherError['code'],
                    if (otherError['message'] != null)
                      'message': otherError['message'],
                  },
                };
                throw LlmHttpException(
                  statusCode: statusCode,
                  body: jsonEncode(structuredError),
                  headers: response.headers,
                  operation: 'generateStream',
                );
              }

              if (eventType == 'message_start') {
                final message = data['message'];
                final usageData = message is Map ? message['usage'] : null;
                if (usageData is Map) {
                  finalUsage = _normalizeAnthropicUsage(
                    Map<String, dynamic>.from(usageData),
                  );
                }
              } else if (eventType == 'content_block_start') {
                final index = data['index'] as int;
                final block = data['content_block'];
                if (block != null && block['type'] == 'tool_use') {
                  partialToolCalls[index] = _PartialClaudeToolCall()
                    ..id = block['id']
                    ..name = block['name'];
                } else if (block != null && block['type'] == 'thinking') {
                  final initial = block['thinking']?.toString();
                  if (initial != null && initial.isNotEmpty) {
                    yield AgentResponse(
                      message: Message(
                        role: MessageRole.assistant,
                        reasoning: initial,
                      ),
                      model: resolvedModel,
                      provider: 'anthropic',
                    );
                  }
                }
              } else if (eventType == 'content_block_delta') {
                final index = data['index'] as int;
                final delta = data['delta'];
                if (delta != null) {
                  final deltaType = delta['type'];
                  if (deltaType == 'text_delta') {
                    final chunk = delta['text'] as String;
                    final tagged = taggedReasoning.add(chunk);
                    yield AgentResponse(
                      message: Message(
                        role: MessageRole.assistant,
                        content: tagged.content,
                        reasoning: tagged.reasoning,
                      ),
                      isToolCall: false,
                      model: resolvedModel,
                      provider: 'anthropic',
                    );
                  } else if (deltaType == 'thinking_delta') {
                    final chunk = delta['thinking']?.toString();
                    if (chunk != null && chunk.isNotEmpty) {
                      yield AgentResponse(
                        message: Message(
                          role: MessageRole.assistant,
                          reasoning: chunk,
                        ),
                        model: resolvedModel,
                        provider: 'anthropic',
                      );
                    }
                  } else if (deltaType == 'input_json_delta') {
                    final chunk = delta['partial_json'] as String;
                    partialToolCalls[index]?.argumentsBuffer.write(chunk);
                  }
                }
              } else if (eventType == 'message_delta') {
                final usageData = data['usage'] as Map<String, dynamic>?;
                if (usageData != null) {
                  finalUsage = {
                    ...?finalUsage,
                    ..._normalizeAnthropicUsage(usageData),
                  };
                }
                final deltaData = data['delta'];
                if (deltaData is Map) {
                  streamFinishReason = _normalizeFinishReason(
                    deltaData['stop_reason'],
                    hasToolCalls: partialToolCalls.isNotEmpty,
                  );
                }
              }
            } on LlmHttpException {
              rethrow;
            } catch (_) {}
          }
        }
        if (LLMRequestDumper.isEnabled) {
          await LLMRequestDumper.dumpResponse({
            'status_code': response.statusCode,
            'stream_lines': accumulatedStreamLines,
          });
        }
      } catch (e) {
        if (LLMRequestDumper.isEnabled) {
          await LLMRequestDumper.dumpResponse({
            'status_code': response.statusCode,
            'stream_lines': accumulatedStreamLines,
            'error': e.toString(),
          });
        }
        rethrow;
      }

      final pendingTagged = taggedReasoning.finish();
      if (pendingTagged.content != null || pendingTagged.reasoning != null) {
        yield AgentResponse(
          message: Message(
            role: MessageRole.assistant,
            content: pendingTagged.content,
            reasoning: pendingTagged.reasoning,
          ),
          model: resolvedModel,
          provider: 'anthropic',
        );
      }

      final completedToolCalls = <ToolCall>[];
      for (final partial in partialToolCalls.values) {
        Map<String, dynamic> args = {};
        try {
          args = jsonDecode(partial.argumentsBuffer.toString());
        } catch (_) {}
        completedToolCalls.add(
          ToolCall(
            id: partial.id ?? '',
            name: partial.name ?? '',
            arguments: args,
          ),
        );
      }

      if (completedToolCalls.isNotEmpty) {
        yield AgentResponse(
          message: Message(
            role: MessageRole.assistant,
            content: '',
            toolCalls: completedToolCalls,
          ),
          isToolCall: true,
          usage: finalUsage,
          model: resolvedModel,
          provider: 'anthropic',
          finishReason: streamFinishReason ?? LLMFinishReason.toolCalls,
        );
      } else if (finalUsage != null) {
        yield AgentResponse(
          message: Message(role: MessageRole.assistant, content: ''),
          isToolCall: false,
          usage: finalUsage,
          model: resolvedModel,
          provider: 'anthropic',
          finishReason: streamFinishReason ?? LLMFinishReason.stop,
        );
      }
    } finally {
      await transport.dispose();
    }
  }

  // ─── Shared helpers ───────────────────────────────────────────────

  /// Converts the internal [Message] list into the Anthropic Messages API
  /// wire format.
  ///
  /// Key rules enforced here to prevent `TOOL_USE_RESULT_MISMATCH` and
  /// alternation errors:
  /// 1. Consecutive `tool` messages are **merged** into a single `user`
  ///    message containing multiple `tool_result` blocks.
  /// 2. Every `tool_use` id emitted by an assistant message **must** have
  ///    a matching `tool_result` in the following user message; orphan
  ///    tool-uses are stripped to avoid 400 errors from Bedrock/Claude.
  /// 3. Messages are forced to alternate user/assistant. Adjacent
  ///    same-role messages are merged.
  List<Map<String, dynamic>> _buildAnthropicMessages(List<Message> history) {
    final nonSystem = history
        .where((m) => m.role != MessageRole.system)
        .toList();

    // First pass: convert each message to its wire representation.
    final wireMessages = <Map<String, dynamic>>[];
    for (final m in nonSystem) {
      if (m.role == MessageRole.tool) {
        wireMessages.add({
          'role': 'user',
          'content': [
            {
              'type': 'tool_result',
              'tool_use_id': m.toolCallId ?? '',
              'content': m.content ?? '',
            },
          ],
        });
      } else if (m.role == MessageRole.assistant) {
        final List<dynamic> contentList = [];
        if (m.content != null && m.content!.isNotEmpty) {
          contentList.add({'type': 'text', 'text': m.content!});
        }
        if (m.toolCalls != null && m.toolCalls!.isNotEmpty) {
          for (var tc in m.toolCalls!) {
            contentList.add({
              'type': 'tool_use',
              'id': tc.id,
              'name': tc.name,
              'input': tc.arguments,
            });
          }
        }
        wireMessages.add({
          'role': 'assistant',
          'content': contentList.length == 1 && contentList[0]['type'] == 'text'
              ? m.content!
              : contentList,
        });
      } else {
        wireMessages.add({'role': 'user', 'content': m.content ?? ''});
      }
    }

    // Second pass: collect all tool_result IDs we have results for.
    final answeredToolUseIds = <String>{};
    for (final wm in wireMessages) {
      if (wm['role'] == 'user') {
        final content = wm['content'];
        if (content is List) {
          for (final block in content) {
            if (block is Map &&
                block['type'] == 'tool_result' &&
                block['tool_use_id'] != null) {
              answeredToolUseIds.add(block['tool_use_id'].toString());
            }
          }
        }
      }
    }

    // Third pass: strip orphan tool_use blocks from assistant messages
    // whose IDs have no matching tool_result anywhere in the history.
    for (final wm in wireMessages) {
      if (wm['role'] == 'assistant') {
        final content = wm['content'];
        if (content is List) {
          final filtered = <dynamic>[];
          for (final block in content) {
            if (block is Map && block['type'] == 'tool_use') {
              final id = block['id']?.toString();
              if (id != null && !answeredToolUseIds.contains(id)) {
                continue; // strip orphan tool_use
              }
            }
            filtered.add(block);
          }
          if (filtered.isEmpty) {
            // All content was orphan tool_use; keep minimal text.
            wm['content'] = '';
          } else if (filtered.length == 1 &&
              filtered[0] is Map &&
              filtered[0]['type'] == 'text') {
            wm['content'] = filtered[0]['text'];
          } else {
            wm['content'] = filtered;
          }
        }
      }
    }

    // Fourth pass: merge consecutive same-role messages.
    final merged = <Map<String, dynamic>>[];
    for (final wm in wireMessages) {
      if (merged.isNotEmpty && merged.last['role'] == wm['role']) {
        merged.last = _mergeSameRoleMessages(merged.last, wm);
      } else {
        merged.add(Map<String, dynamic>.from(wm));
      }
    }

    // Ensure conversation starts with a user message (Anthropic requirement).
    if (merged.isNotEmpty && merged.first['role'] != 'user') {
      merged.insert(0, {'role': 'user', 'content': ''});
    }

    return merged;
  }

  /// Merges two consecutive messages of the same role into one.
  Map<String, dynamic> _mergeSameRoleMessages(
    Map<String, dynamic> a,
    Map<String, dynamic> b,
  ) {
    final mergedContent = <dynamic>[];
    for (final src in [a, b]) {
      final content = src['content'];
      if (content is String) {
        if (content.isNotEmpty) {
          mergedContent.add({'type': 'text', 'text': content});
        }
      } else if (content is List) {
        mergedContent.addAll(content);
      }
    }

    if (mergedContent.isEmpty) {
      return {'role': a['role'], 'content': ''};
    }
    if (mergedContent.length == 1 &&
        mergedContent[0] is Map &&
        mergedContent[0]['type'] == 'text') {
      return {'role': a['role'], 'content': mergedContent[0]['text']};
    }
    return {'role': a['role'], 'content': mergedContent};
  }

  Map<String, dynamic> _buildRequestBody(
    List<Message> history, {
    required String resolvedModel,
    required LLMRequestOptions options,
    List<ToolSchema>? tools,
    bool stream = false,
  }) {
    // Extract system messages.
    String? systemPrompt;
    final systemMessages = history.where((m) => m.role == MessageRole.system);
    if (systemMessages.isNotEmpty) {
      systemPrompt = systemMessages.map((m) => m.content ?? '').join('\n');
    }

    final formattedMessages = _buildAnthropicMessages(history);

    final body = <String, dynamic>{
      'model': resolvedModel,
      'messages': formattedMessages,
      'max_tokens': options.maxOutputTokens ?? 4096,
      if (stream) 'stream': true,
    };
    if (systemPrompt != null) {
      body['system'] = systemPrompt;
    }

    if (tools != null && tools.isNotEmpty) {
      body['tools'] = tools
          .map(
            (t) => {
              'name': t.name,
              'description': t.description,
              'input_schema': t.parameters,
            },
          )
          .toList(growable: false);
    }
    return body;
  }

  LLMFinishReason _normalizeFinishReason(
    dynamic rawStopReason, {
    required bool hasToolCalls,
  }) {
    switch (rawStopReason?.toString()) {
      case 'end_turn':
        return LLMFinishReason.stop;
      case 'tool_use':
        return LLMFinishReason.toolCalls;
      case 'max_tokens':
        return LLMFinishReason.length;
      case 'stop_sequence':
        return LLMFinishReason.stop;
      default:
        return hasToolCalls
            ? LLMFinishReason.toolCalls
            : LLMFinishReason.unknown;
    }
  }
}

Map<String, dynamic> _normalizeAnthropicUsage(Map<String, dynamic> usage) => {
  'prompt_tokens': ?usage['input_tokens'],
  'completion_tokens': ?usage['output_tokens'],
  'cache_read_input_tokens': ?usage['cache_read_input_tokens'],
  'cache_creation_input_tokens': ?usage['cache_creation_input_tokens'],
};

class _PartialClaudeToolCall {
  String? id;
  String? name;
  final StringBuffer argumentsBuffer = StringBuffer();
}
