import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:http/http.dart' as http;

import '../../core/config.dart';
import '../../core/models/message.dart';
import '../../core/models/agent_response.dart';
import '../../core/models/tool_call.dart';
import '../../core/models/llm_provider_state.dart';
import '../../capabilities/models/tool_schema.dart';
import 'llm_adapter.dart';
import '../../core/models/model_metadata.dart';
import '../../core/di.dart';
import '../../core/provider_runtime/provider_instance_repository.dart';
import '../../core/provider_runtime/provider_model_id.dart';
import '../../interfaces/platforms/sanad_gateway/capabilities.dart';
import '../../core/provider_runtime/route_capability_resolver.dart';
import 'provider_profile.dart';
import 'llm_http_exception.dart';
import '../../core/provider_thinking/anthropic_thinking_wire_codec.dart';
import 'llm_request_options.dart';
import 'models_dev_service.dart';
import 'opencode_session_affinity.dart';
import 'provider_request_transport.dart';
import 'tagged_reasoning_parser.dart';
import 'tool_result_wire_codec.dart';
import 'chat_reasoning_replay_policy.dart';
import 'provider_history_projection_exception.dart';
import 'user_attachment_wire_discloser.dart';
import '../llm_request_dumper.dart';
import '../../core/provider_runtime/provider_endpoint_resolver.dart';

class BaseAnthropicAdapter
    implements LLMAdapter, ToolResultMediaCapabilityProvider {
  final _logger = Logger('BaseAnthropicAdapter');
  final Config config;
  final ProviderProfile profile;
  final String? providerInstanceId;
  final http.Client? client;
  final ModelContextLimitLookup? modelContextLimitLookup;
  final String? baseUrlOverride;
  final String? apiKeyOverride;
  final String? defaultModelOverride;
  String _availableModelsSource = 'fallback';
  Object? _lastModelsException;

  BaseAnthropicAdapter(
    this.config,
    this.profile, {
    this.providerInstanceId,
    this.client,
    this.modelContextLimitLookup,
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
  ToolResultMediaCapability get toolResultMediaCapability =>
      ToolResultMediaCapability.imageToolResults;

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
            .whereType<Map>()
            .map((entry) {
              final rawId = entry['id']?.toString() ?? '';
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
                modelMetadata: Map<String, Object?>.from(
                  entry.map((k, v) => MapEntry(k.toString(), v)),
                ),
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

  Map<String, String> _anthropicHeaders({
    bool useBearerAuth = false,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) {
    return withOpenCodeSessionAffinity(
      headers: {
        'Content-Type': 'application/json',
        if (useBearerAuth)
          'Authorization': 'Bearer $_apiKey'
        else
          'x-api-key': _apiKey,
        'anthropic-version': _anthropicVersion,
        ...profile.defaultHeaders,
      },
      providerName: profile.name,
      baseUrl: _baseUrl,
      sessionId: options.sessionId,
    );
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
    final catalogLimit = modelContextLimitLookup?.call(resolvedModel);
    if (catalogLimit != null) return catalogLimit;
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
    final stopwatch = Stopwatch()..start();

    final body = await _buildRequestBody(
      history,
      resolvedModel: resolvedModel,
      tools: tools,
      options: options,
    );

    if (LLMRequestDumper.isEnabled) {
      await LLMRequestDumper.recordActualRequest(
        url: url,
        headers: _anthropicHeaders(options: options),
        body: body,
        requestId: options.requestId,
        provider: profile.name,
        model: resolvedModel,
        baseUrl: _baseUrl,
        protocol: profile.effectiveProtocol,
        stream: false,
        safeOptions: options.toSafeDumpOptions(
          stream: false,
          protocol: profile.effectiveProtocol,
        ),
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
        headers: _anthropicHeaders(options: options),
        body: jsonEncode(body),
        operation: 'generateResponse',
      );
    } catch (error) {
      if (LLMRequestDumper.isEnabled) {
        await LLMRequestDumper.recordError(
          error,
          requestId: options.requestId,
          duration: stopwatch.elapsed,
        );
      }
      rethrow;
    } finally {
      await transport.dispose();
    }

    _logger.info('LLM Response status: ${response.statusCode}');
    if (LLMRequestDumper.isEnabled) {
      String? finishReason;
      if (response.statusCode == 200) {
        try {
          final data = jsonDecode(response.body);
          finishReason = data['stop_reason']?.toString();
        } catch (_) {}
      }
      await LLMRequestDumper.dumpResponse(
        response.body,
        requestId: options.requestId,
        statusCode: response.statusCode,
        duration: stopwatch.elapsed,
        finishReason: finishReason,
      );
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
    final signedThinking = <Map<String, dynamic>>[];

    for (var block in contentBlocks) {
      final type = block['type'];
      if (type == 'text') {
        content += block['text'] as String? ?? '';
      } else if (type == 'thinking') {
        reasoning += block['thinking'] as String? ?? '';
        _addSignedThinking(
          signedThinking,
          thinking: block['thinking']?.toString() ?? '',
          signature: block['signature']?.toString(),
        );
      } else if (type == 'redacted_thinking') {
        _addRedactedThinking(signedThinking, block['data']?.toString());
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
        providerState: _thinkingState(
          signedThinking,
          options: options,
          resolvedModel: resolvedModel,
        ),
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
    final stopwatch = Stopwatch()..start();

    final body = await _buildRequestBody(
      history,
      resolvedModel: resolvedModel,
      tools: tools,
      options: options,
      stream: true,
    );

    if (LLMRequestDumper.isEnabled) {
      await LLMRequestDumper.recordActualRequest(
        url: url,
        headers: _anthropicHeaders(options: options),
        body: body,
        requestId: options.requestId,
        provider: profile.name,
        model: resolvedModel,
        baseUrl: _baseUrl,
        protocol: profile.effectiveProtocol,
        stream: true,
        safeOptions: options.toSafeDumpOptions(
          stream: true,
          protocol: profile.effectiveProtocol,
        ),
      );
    }

    final transport = ProviderRequestTransport(
      options: options,
      adapterSharedClient: client,
    );
    final request = http.Request('POST', url);
    request.headers.addAll(_anthropicHeaders(options: options));
    request.body = jsonEncode(body);

    late http.StreamedResponse response;
    try {
      response = await transport.send(request, operation: 'generateStream');
    } catch (error) {
      if (LLMRequestDumper.isEnabled) {
        await LLMRequestDumper.recordError(
          error,
          requestId: options.requestId,
          duration: stopwatch.elapsed,
        );
      }
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
          }, requestId: options.requestId,
          statusCode: response.statusCode,
          duration: stopwatch.elapsed,
          );
        }
        throw LlmHttpException.fromStreamedResponse(
          response,
          err,
          operation: 'generateStream',
        );
      }

      final partialToolCalls = <int, _PartialClaudeToolCall>{};
      final completedToolCalls = <ToolCall>[];
      final taggedReasoning = TaggedReasoningStreamParser();
      Map<String, dynamic>? finalUsage;
      LLMFinishReason? streamFinishReason;
      final contentBuffer = StringBuffer();
      final reasoningBuffer = StringBuffer();
      final thinkingBlocks = <int, _PartialThinkingBlock>{};

      try {
        await for (final line in transport.decodeSseLines(
          response.stream,
          operation: 'generateStream',
        )) {
          transport.throwIfCancelled(operation: 'generateStream');
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
                } else if (block != null &&
                    block['type'] == 'redacted_thinking') {
                  thinkingBlocks[index] = _PartialThinkingBlock()
                    ..redactedData = block['data']?.toString();
                } else if (block != null && block['type'] == 'thinking') {
                  final partialThinking = thinkingBlocks[index] =
                      _PartialThinkingBlock();
                  final initialSignature = block['signature']?.toString();
                  if (initialSignature != null) {
                    partialThinking.signature.write(initialSignature);
                  }
                  final initial = block['thinking']?.toString();
                  if (initial != null) partialThinking.thinking.write(initial);
                  if (initial != null && initial.isNotEmpty) {
                    reasoningBuffer.write(initial);
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
                    if (tagged.content != null) {
                      contentBuffer.write(tagged.content);
                    }
                    if (tagged.reasoning != null) {
                      reasoningBuffer.write(tagged.reasoning);
                    }
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
                  } else if (deltaType == 'signature_delta') {
                    final signature = delta['signature']?.toString();
                    if (signature != null) {
                      thinkingBlocks[index]?.signature.write(signature);
                    }
                  } else if (deltaType == 'thinking_delta') {
                    final chunk = delta['thinking']?.toString();
                    if (chunk != null) {
                      thinkingBlocks[index]?.thinking.write(chunk);
                    }
                    if (chunk != null && chunk.isNotEmpty) {
                      reasoningBuffer.write(chunk);
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
        final pendingTagged = taggedReasoning.finish();
        if (pendingTagged.content != null || pendingTagged.reasoning != null) {
          if (pendingTagged.content != null) {
            contentBuffer.write(pendingTagged.content);
          }
          if (pendingTagged.reasoning != null) {
            reasoningBuffer.write(pendingTagged.reasoning);
          }
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

        final signedThinking = <Map<String, dynamic>>[];
        for (final index in thinkingBlocks.keys.toList()..sort()) {
          final block = thinkingBlocks[index]!;
          if (block.redactedData != null) {
            _addRedactedThinking(signedThinking, block.redactedData);
          } else {
            _addSignedThinking(
              signedThinking,
              thinking: block.thinking.toString(),
              signature: block.signature.toString(),
            );
          }
        }
        final thinkingState = _thinkingState(
          signedThinking,
          options: options,
          resolvedModel: resolvedModel,
        );

        if (completedToolCalls.isNotEmpty) {
          yield AgentResponse(
            message: Message(
              role: MessageRole.assistant,
              content: '',
              toolCalls: completedToolCalls,
              providerState: thinkingState,
            ),
            isToolCall: true,
            usage: finalUsage,
            model: resolvedModel,
            provider: 'anthropic',
            finishReason: streamFinishReason ?? LLMFinishReason.toolCalls,
          );
        } else if (finalUsage != null || thinkingState != null) {
          yield AgentResponse(
            message: Message(
              role: MessageRole.assistant,
              content: '',
              providerState: thinkingState,
            ),
            isToolCall: false,
            usage: finalUsage,
            model: resolvedModel,
            provider: 'anthropic',
            finishReason: streamFinishReason ?? LLMFinishReason.stop,
          );
        }

        if (LLMRequestDumper.isEnabled) {
          final effectiveFinishReason = completedToolCalls.isNotEmpty
              ? (streamFinishReason ?? LLMFinishReason.toolCalls)
              : (streamFinishReason ?? LLMFinishReason.stop);
          await LLMRequestDumper.dumpResponse({
            'status_code': response.statusCode,
            'message': {
              'role': 'assistant',
              'content': contentBuffer.toString(),
              if (reasoningBuffer.isNotEmpty)
                'reasoning': reasoningBuffer.toString(),
              if (completedToolCalls.isNotEmpty)
                'tool_calls': completedToolCalls
                    .map((tc) => tc.toJson())
                    .toList(),
            },
            'finish_reason': effectiveFinishReason.name,
            'usage': ?finalUsage,
          }, requestId: options.requestId,
          statusCode: response.statusCode,
          duration: stopwatch.elapsed,
          finishReason: effectiveFinishReason.name,
          );
        }
      } catch (e) {
        if (LLMRequestDumper.isEnabled) {
          await LLMRequestDumper.dumpResponse({
            'status_code': response.statusCode,
            if (contentBuffer.isNotEmpty ||
                reasoningBuffer.isNotEmpty ||
                partialToolCalls.isNotEmpty ||
                completedToolCalls.isNotEmpty)
              'partial_message': {
                'role': 'assistant',
                if (contentBuffer.isNotEmpty)
                  'content': contentBuffer.toString(),
                if (reasoningBuffer.isNotEmpty)
                  'reasoning': reasoningBuffer.toString(),
                if (completedToolCalls.isNotEmpty)
                  'tool_calls': completedToolCalls
                      .map((tc) => tc.toJson())
                      .toList(),
                if (partialToolCalls.isNotEmpty)
                  'partial_tool_calls': partialToolCalls.values
                      .map(
                        (p) => {
                          if (p.id != null) 'id': p.id,
                          if (p.name != null) 'name': p.name,
                          'arguments': p.argumentsBuffer.toString(),
                        },
                      )
                      .toList(),
              },
            'error': e.toString(),
          }, requestId: options.requestId,
          statusCode: response.statusCode,
          duration: stopwatch.elapsed,
          finishReason: 'incomplete',
          );
        }
        rethrow;
      }
    } finally {
      if (LLMRequestDumper.isEnabled) {
        LLMRequestDumper.cleanupActiveDump(requestId: options.requestId);
      }
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
  List<Map<String, dynamic>> _buildAnthropicMessages(
    List<Message> history, {
    Map<String, String>? verifiedAttachments,
    required LLMRequestOptions options,
    required String resolvedModel,
  }) {
    final issuer = _stateIssuer(options);
    final nonSystem = history
        .where((m) => m.role != MessageRole.system)
        .toList();

    // First pass: convert each message to its wire representation.
    final wireMessages = <Map<String, dynamic>>[];
    for (final m in nonSystem) {
      if (m.role == MessageRole.tool) {
        final toolUseId = m.toolCallId?.trim() ?? '';
        if (toolUseId.isEmpty) {
          throw const FormatException(
            'Anthropic tool result is missing toolCallId.',
          );
        }
        wireMessages.add({
          'role': 'user',
          'content': [
            {
              'type': 'tool_result',
              'tool_use_id': toolUseId,
              'content': ToolResultWireCodec.anthropicContent(m),
              if (m.toolResult?.isError == true) 'is_error': true,
            },
          ],
        });
      } else if (m.role == MessageRole.assistant) {
        final List<dynamic> contentList = [
          // Signed thinking replays first, and only to its exact issuer and
          // model; foreign or unsigned thinking is never sent (Task 116 D5).
          if (ProviderStateProvenance.isSameRoute(
            m,
            namespace: thinkingStateNamespace,
            issuer: issuer,
            resolvedModel: resolvedModel,
            normalizeModel: _resolveModel,
          ))
            ..._replayableThinking(m.providerState!),
        ];
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
        final List<dynamic> userParts = [];
        dynamic content;
        if (m.attachments.isNotEmpty) {
          final partition = UserAttachmentWireDiscloser.partition(
            m.attachments,
          );
          final effectiveText = UserAttachmentWireDiscloser.discloseContent(
            originalContent: m.content,
            nonSafeAttachments: partition.disclosedFiles,
            attachmentStore: options.attachmentStore,
          );
          for (final att in partition.safeImages) {
            final b64 =
                verifiedAttachments?[att.id] ??
                ToolResultWireCodec.userAttachmentBase64(
                  att,
                  preloadedBase64: verifiedAttachments,
                );
            if (b64 != null) {
              userParts.add({
                'type': 'image',
                'source': {
                  'type': 'base64',
                  'media_type': att.mimeType,
                  'data': b64,
                },
              });
            }
          }
          if (partition.hasSafeImages && userParts.isNotEmpty) {
            if (effectiveText.isNotEmpty) {
              userParts.insert(0, {'type': 'text', 'text': effectiveText});
            }
            content = userParts;
          } else {
            content = effectiveText;
          }
        } else {
          content = m.content ?? '';
        }
        wireMessages.add({'role': 'user', 'content': content});
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

    // Third pass: a tool_use without a matching tool_result cannot be sent
    // and must not be silently dropped (canonical meaning would change), so
    // the request fails closed before dispatch (Task 116 D5).
    var unpairedToolCalls = 0;
    for (final wm in wireMessages) {
      if (wm['role'] != 'assistant') continue;
      final content = wm['content'];
      if (content is! List) continue;
      for (final block in content) {
        if (block is Map && block['type'] == 'tool_use') {
          final id = block['id']?.toString();
          if (id == null || !answeredToolUseIds.contains(id)) {
            unpairedToolCalls++;
          }
        }
      }
    }
    if (unpairedToolCalls > 0) {
      throw ProviderHistoryProjectionException(
        route:
            '${options.providerInstanceId ?? providerInstanceId ?? profile.name}'
            '/$resolvedModel',
        reasonCode: ProviderHistoryProjectionException.unpairedToolCall,
        affectedCount: unpairedToolCalls,
      );
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

  Future<Map<String, dynamic>> _buildRequestBody(
    List<Message> history, {
    required String resolvedModel,
    required LLMRequestOptions options,
    List<ToolSchema>? tools,
    bool stream = false,
  }) async {
    final hasImages = ToolResultWireCodec.hasImages(history);
    if (hasImages) {
      final instanceId = options.providerInstanceId ?? providerInstanceId;
      final overrideSnapshot =
          options.routeCapabilityProfile?.rawOverride ??
          options.routeCapabilitySnapshot;
      final profileSnapshot =
          options.routeCapabilityProfile ??
          (overrideSnapshot != null
              ? RouteCapabilityProfile(
                  providerInstanceId: instanceId ?? profile.name,
                  modelId: resolvedModel,
                  imageSupport: overrideSnapshot.supportsImageInput == true
                      ? RouteImageSupport.supported
                      : (overrideSnapshot.supportsImageInput == false
                            ? RouteImageSupport.unsupported
                            : RouteImageSupport.unknown),
                  evidenceSource: 'snapshot',
                  rawOverride: overrideSnapshot,
                )
              : RouteCapabilityResolver(
                  instances: getIt.isRegistered<ProviderInstanceRepository>()
                      ? getIt<ProviderInstanceRepository>()
                      : null,
                  config: config,
                  modelsDevService: getIt.isRegistered<ModelsDevService>()
                      ? getIt<ModelsDevService>()
                      : null,
                ).resolveSync(
                  providerInstanceId: instanceId ?? profile.name,
                  modelId: resolvedModel,
                  baseUrl: _baseUrl,
                ));

      if (profileSnapshot.imageSupport == RouteImageSupport.unsupported) {
        throw LocalImageCapabilityException(
          modelId: resolvedModel,
          imageSupport: RouteImageSupport.unsupported,
        );
      } else if (profileSnapshot.imageSupport == RouteImageSupport.unknown) {
        throw LocalImageCapabilityException(
          modelId: resolvedModel,
          imageSupport: RouteImageSupport.unknown,
        );
      }
    }

    final verifiedAttachments =
        await ToolResultWireCodec.loadVerifiedUserAttachments(
          history,
          attachmentStore: options.attachmentStore,
        );

    // Extract system messages.
    String? systemPrompt;
    final systemMessages = history.where((m) => m.role == MessageRole.system);
    if (systemMessages.isNotEmpty) {
      systemPrompt = systemMessages.map((m) => m.content ?? '').join('\n');
    }

    final formattedMessages = _buildAnthropicMessages(
      history,
      verifiedAttachments: verifiedAttachments,
      options: options,
      resolvedModel: resolvedModel,
    );

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

    AnthropicThinkingWireCodec.applyThinking(body, options.thinkingDirective);
    return body;
  }

  /// Namespace for issuer-bound Anthropic thinking blocks (Task 116 D5).
  static const thinkingStateNamespace = 'anthropic_messages';
  static const thinkingBlocksKey = 'thinking_blocks';

  String _stateIssuer(LLMRequestOptions options) {
    final instance =
        options.providerInstanceId ?? providerInstanceId ?? profile.name;
    final endpoint = _baseUrl.replaceFirst(RegExp(r'/+$'), '');
    return '$instance|${profile.effectiveProtocol}|$endpoint';
  }

  /// Only signed thinking is replayable; unsigned text is visible reasoning.
  static void _addSignedThinking(
    List<Map<String, dynamic>> blocks, {
    required String thinking,
    required String? signature,
  }) {
    if (signature == null || signature.isEmpty) return;
    blocks.add({
      'type': 'thinking',
      'thinking': thinking,
      'signature': signature,
    });
  }

  static void _addRedactedThinking(
    List<Map<String, dynamic>> blocks,
    String? data,
  ) {
    if (data == null || data.isEmpty) return;
    blocks.add({'type': 'redacted_thinking', 'data': data});
  }

  LLMProviderState? _thinkingState(
    List<Map<String, dynamic>> blocks, {
    required LLMRequestOptions options,
    required String resolvedModel,
  }) {
    if (blocks.isEmpty) return null;
    return LLMProviderState(
      namespace: thinkingStateNamespace,
      issuer: _stateIssuer(options),
      data: {
        thinkingBlocksKey: blocks,
        ProviderStateProvenance.issuerModelKey: resolvedModel,
      },
    );
  }

  static List<Map<String, dynamic>> _replayableThinking(
    LLMProviderState state,
  ) {
    final raw = state.data[thinkingBlocksKey];
    if (raw is! List) return const [];
    return [
      for (final block in raw)
        if (block is Map &&
            ((block['type'] == 'thinking' &&
                    block['signature'] is String &&
                    (block['signature'] as String).isNotEmpty) ||
                (block['type'] == 'redacted_thinking' &&
                    block['data'] is String)))
          Map<String, dynamic>.from(block),
    ];
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
      case 'pause_turn':
        return LLMFinishReason.incomplete;
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

class _PartialThinkingBlock {
  final StringBuffer thinking = StringBuffer();
  final StringBuffer signature = StringBuffer();
  String? redactedData;
}

class _PartialClaudeToolCall {
  String? id;
  String? name;
  final StringBuffer argumentsBuffer = StringBuffer();
}
