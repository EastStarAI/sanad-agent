import 'dart:convert';
import 'package:logging/logging.dart';
import 'package:http/http.dart' as http;
import '../../core/config.dart';
import '../../core/models/message.dart';
import '../../core/models/agent_response.dart';
import '../../core/models/llm_provider_state.dart';
import '../../core/models/tool_call.dart';
import '../../capabilities/models/tool_schema.dart';
import 'llm_adapter.dart';
import '../../core/models/model_metadata.dart';
import '../../core/provider_runtime/provider_endpoint_resolver.dart';
import '../../core/provider_runtime/provider_model_id.dart';
import '../../interfaces/platforms/sanad_gateway/capabilities.dart';
import 'provider_profile.dart';
import 'models_dev_service.dart';
import 'llm_http_exception.dart';
import 'llm_request_options.dart';
import 'tagged_reasoning_parser.dart';
import '../llm_request_dumper.dart';

class BaseOpenAIAdapter implements LLMAdapter {
  final _logger = Logger('BaseOpenAIAdapter');
  final Config config;
  final ProviderProfile profile;
  final http.Client? client;
  final ModelsDevService? modelsDevService;
  final String? baseUrlOverride;
  final String? apiKeyOverride;
  final String? defaultModelOverride;
  String _availableModelsSource = 'fallback';
  Object? _lastModelsException;

  BaseOpenAIAdapter(
    this.config,
    this.profile, {
    this.client,
    this.modelsDevService,
    this.baseUrlOverride,
    this.apiKeyOverride,
    this.defaultModelOverride,
  });

  String get _baseUrl => ProviderEndpointResolver.normalizeBaseUrl(
    baseUrlOverride ?? config.baseUrlFor(profile),
  );
  String get _apiKey => apiKeyOverride ?? config.apiKeyFor(profile);

  // Public accessors for subclasses (Strategy Pattern)
  String get baseUrl => _baseUrl;
  String get apiKey => _apiKey;
  String get availableModelsSource => _availableModelsSource;
  Object? get lastModelsException => _lastModelsException;
  void setLastModelsException(Object? exception) =>
      _lastModelsException = exception;
  void setAvailableModelsSource(String source) =>
      _availableModelsSource = source;
  List<ModelOption> fallbackModelOptions() => _fallbackModelOptions();
  String resolveModel(String? override) => _resolveModel(override);
  String providerForModel(String model) => _providerForModel(model);
  Map<String, dynamic>? tryDecodeToolArguments(String args) =>
      _tryDecodeToolArguments(args);
  String roleToString(MessageRole role) => _roleToString(role);

  @override
  Future<List<ModelOption>> getAvailableModels() async {
    _lastModelsException = null;
    final List<Uri> candidates;
    try {
      candidates = _modelsEndpointCandidates();
    } catch (error) {
      _lastModelsException = error;
      _availableModelsSource = 'fallback';
      return _fallbackModelOptions();
    }
    for (final url in candidates) {
      try {
        final response = await _get(
          url,
          headers: {
            if (_apiKey.isNotEmpty) 'Authorization': 'Bearer $_apiKey',
            ...profile.defaultHeaders,
          },
        );
        if (response.statusCode != 200) {
          _lastModelsException = LlmHttpException.fromResponse(
            response,
            operation: 'getAvailableModels',
          );
          continue;
        }

        final data = jsonDecode(response.body);
        final modelsList = data['data'] as List?;
        if (modelsList == null) {
          _lastModelsException = StateError(
            'Response data is not a list of models',
          );
          continue;
        }

        final List<ModelOption> options = [];
        final agenticModels = modelsDevService != null
            ? await modelsDevService!.listAgenticModels(profile.name)
            : <String>[];

        for (var item in modelsList) {
          final id = item['id'] as String;
          final normalizedId = _normalizeModelId(id);

          if (!_isAgenticModel(normalizedId, agenticModels)) {
            continue;
          }

          final label = _formatModelLabel(normalizedId);
          final supportsReasoning = await _modelSupportsReasoning(normalizedId);

          int? contextLimit;
          if (item is Map) {
            final possibleKeys = [
              'context_window',
              'context_length',
              'context_size',
              'max_context_length',
              'max_position_embeddings',
              'max_model_len',
              'max_input_tokens',
              'max_sequence_length',
              'max_seq_len',
              'n_ctx_train',
              'n_ctx',
              'ctx_size',
            ];
            for (final key in possibleKeys) {
              final val = item[key];
              if (val is num && val > 0) {
                contextLimit = val.toInt();
                break;
              }
            }
          }
          contextLimit ??= await _modelContextLimit(normalizedId);

          options.add(
            ModelOption(
              value: normalizedId,
              label: label,
              provider: profile.name,
              contextWindow: contextLimit,
              supportsReasoning: supportsReasoning,
            ),
          );
        }
        if (options.isNotEmpty) {
          _availableModelsSource = 'live';
          _lastModelsException = null;
          if (profile.fallbackModels.isNotEmpty) {
            options.sort((a, b) {
              var aId = a.value;
              var bId = b.value;

              if (aId.startsWith('~')) aId = aId.substring(1);
              if (bId.startsWith('~')) bId = bId.substring(1);

              final aIndex = profile.fallbackModels.indexOf(aId);
              final bIndex = profile.fallbackModels.indexOf(bId);

              if (aIndex != -1 && bIndex != -1) {
                return aIndex.compareTo(bIndex);
              } else if (aIndex != -1) {
                return -1;
              } else if (bIndex != -1) {
                return 1;
              }
              return 0;
            });
          }
          return options;
        }
      } catch (e) {
        _logger.warning('Failed to fetch standard models from $url: $e');
        _lastModelsException = e;
      }
    }

    // Fallback: return at least the current configured model
    _availableModelsSource = 'fallback';
    return _fallbackModelOptions();
  }

  String _normalizeModelId(String rawModelId) {
    return ProviderModelId.normalize(
      templateId: profile.name,
      protocol: profile.effectiveProtocol,
      rawModelId: rawModelId,
    );
  }

  String _fallbackModelId() {
    final configured = defaultModelOverride ?? config.llmModel;
    return _normalizeModelId(configured);
  }

  List<ModelOption> _fallbackModelOptions() {
    final merged = <String>[];
    final selected = _fallbackModelId();
    if (selected.isNotEmpty) {
      merged.add(selected);
    }
    for (final model in profile.fallbackModels) {
      final normalized = _normalizeModelId(model);
      if (normalized.isNotEmpty && !merged.contains(normalized)) {
        merged.add(normalized);
      }
    }
    if (merged.isEmpty) {
      merged.add(selected);
    }

    return merged
        .map((modelId) {
          final lowered = modelId.toLowerCase();
          return ModelOption(
            value: modelId,
            label: _formatModelLabel(modelId),
            provider: profile.name,
            contextWindow: ModelMetadata.getLimitForModel(modelId),
            supportsReasoning:
                lowered.contains('o1') ||
                lowered.contains('o3') ||
                lowered.contains('reasoning'),
          );
        })
        .toList(growable: false);
  }

  List<Uri> _modelsEndpointCandidates() {
    return ProviderEndpointResolver.resolveOpenAiModelsEndpointCandidates(
      _baseUrl,
    );
  }

  String _formatModelLabel(String name) {
    String capitalize(String s) =>
        s.isEmpty ? '' : '${s[0].toUpperCase()}${s.substring(1)}';

    var cleanName = name.contains('/') ? name.split('/').last : name;
    if (cleanName.startsWith('~')) {
      cleanName = cleanName.substring(1);
    }

    return cleanName
        .split('-')
        .map((part) {
          if (part.startsWith('gpt')) {
            return 'GPT${part.substring(3)}';
          }
          return capitalize(part);
        })
        .join(' ');
  }

  bool _isAgenticModel(String modelId, List<String> agenticModels) {
    if (profile.isCustom || profile.effectiveAuthFlow == 'custom_endpoint') {
      return true;
    }

    final lowercaseId = modelId.toLowerCase();

    if (agenticModels.isNotEmpty) {
      if (agenticModels.any((m) => m.toLowerCase() == lowercaseId)) {
        return true;
      }
    }

    // Strip namespaces (like openai/, google/, anthropic/) and tildes (~anthropic/)
    var cleanId = lowercaseId.contains('/')
        ? lowercaseId.split('/').last
        : lowercaseId;
    if (cleanId.startsWith('~')) {
      cleanId = cleanId.substring(1);
    }

    // Heuristics fallback
    final matchesKnown =
        cleanId.startsWith('gpt-') ||
        cleanId.startsWith('o1-') ||
        cleanId.startsWith('o3-') ||
        cleanId.startsWith('claude-') ||
        cleanId.contains('deepseek') ||
        cleanId.startsWith('gemma-') ||
        cleanId.startsWith('gemma') ||
        profile.name == 'nvidia' ||
        cleanId.contains('nvidia') ||
        cleanId.contains('nemotron');

    if (matchesKnown) return true;

    return ModelMetadata.getLimitForModel(cleanId) != null;
  }

  Future<bool> _modelSupportsReasoning(String modelId) async {
    if (modelsDevService != null) {
      final registryMatch = await modelsDevService!.supportsReasoning(
        profile.name,
        modelId,
      );
      if (registryMatch) return true;
    }
    final lowercaseId = modelId.toLowerCase();
    return lowercaseId.contains('o1') ||
        lowercaseId.contains('o3') ||
        lowercaseId.contains('o4') ||
        lowercaseId.contains('gpt-5') ||
        lowercaseId.contains('gpt-6') ||
        lowercaseId.contains('reasoning') ||
        lowercaseId.contains('deepseek-r');
  }

  Future<int?> _modelContextLimit(String modelId) async {
    if (modelsDevService != null) {
      return modelsDevService!.getContextLimit(profile.name, modelId);
    }
    return ModelMetadata.getLimitForModel(modelId);
  }

  @override
  Future<int> getContextLimit([String? modelOverride]) async {
    final resolvedModel = _resolveModel(modelOverride);

    if (config.contextLimit != 4000) return config.contextLimit;

    // 1. LM Studio local probe (reference-style)
    if (profile.name == 'lm-studio') {
      try {
        final cleanBase = baseUrl.replaceAll('/v1', '').replaceAll('/v1/', '');
        final url = Uri.parse('$cleanBase/api/v1/models');
        final response = await _get(url, timeout: const Duration(seconds: 2));
        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          final models = data['models'] as List?;
          if (models != null) {
            for (var model in models) {
              if (model is Map) {
                final key = model['key'] ?? model['id'];
                if (key == resolvedModel) {
                  final loadedInstances = model['loaded_instances'] as List?;
                  if (loadedInstances != null && loadedInstances.isNotEmpty) {
                    final config = loadedInstances.first['config'];
                    if (config is Map) {
                      final ctxLen = config['context_length'];
                      if (ctxLen is num && ctxLen > 0) {
                        return ctxLen.toInt();
                      }
                    }
                  }
                }
              }
            }
          }
        }
      } catch (e) {
        _logger.warning('Failed to probe LM Studio context limit: $e');
      }
    }

    // 2. llama.cpp local probe (reference-style)
    if (profile.name == 'llama-cpp') {
      try {
        final cleanBase = baseUrl.replaceAll('/v1', '').replaceAll('/v1/', '');
        final urls = [
          Uri.parse('$baseUrl/props'),
          Uri.parse('$cleanBase/v1/props'),
          Uri.parse('$cleanBase/props'),
        ];
        for (final url in urls) {
          try {
            final response = await _get(
              url,
              timeout: const Duration(seconds: 2),
            );
            if (response.statusCode == 200) {
              final data = jsonDecode(response.body);
              final nCtx = data['default_generation_settings']?['n_ctx'];
              if (nCtx is num && nCtx > 0) {
                return nCtx.toInt();
              }
            }
          } catch (_) {}
        }
      } catch (e) {
        _logger.warning('Failed to probe llama.cpp context limit: $e');
      }
    }

    if (modelsDevService != null) {
      final limit = await modelsDevService!.getContextLimit(
        profile.name,
        resolvedModel,
      );
      if (limit != null) return limit;
    }

    final metadataLimit = ModelMetadata.getLimitForModel(resolvedModel);
    if (metadataLimit != null) return metadataLimit;

    return config.contextLimit;
  }

  String _resolveModel(String? override) {
    if (override == null || override.isEmpty) {
      return _fallbackModelId();
    }
    return _normalizeModelId(override);
  }

  @override
  Future<AgentResponse> generateResponse(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async {
    final url = Uri.parse('$_baseUrl/chat/completions');
    final resolvedModel = _resolveModel(modelOverride);
    final body = await _buildRequestBody(
      history,
      tools: tools,
      resolvedModel: resolvedModel,
      options: options,
    );
    final headers = _requestHeaders();
    if (LLMRequestDumper.isEnabled) {
      await LLMRequestDumper.recordActualRequest(
        url: url,
        headers: headers,
        body: body,
      );
    }

    final httpClient = client ?? http.Client();
    final ownsClient = client == null;
    late http.Response response;
    try {
      response = await _withTimeout(
        httpClient.post(url, headers: headers, body: jsonEncode(body)),
        options.timeout,
      );
    } finally {
      if (ownsClient) httpClient.close();
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

    final data = _asStringMap(jsonDecode(response.body));
    final choices = data?['choices'];
    if (choices is! List || choices.isEmpty) {
      throw const FormatException('Chat completion response has no choices.');
    }
    final choiceEnvelope = _asStringMap(choices.first);
    final choice = _asStringMap(choiceEnvelope?['message']);
    if (choiceEnvelope == null || choice == null) {
      throw const FormatException('Chat completion choice has no message.');
    }

    final structuredReasoning = _extractStructuredReasoning(choice);
    final tagged = splitTaggedReasoning(choice['content']?.toString() ?? '');
    final reasoning = structuredReasoning.visibleText ?? tagged.reasoning;
    final content = tagged.content;
    final toolCalls = _parseToolCalls(choice['tool_calls']);
    final usage = _asStringMap(data?['usage']);
    final finishReason = _normalizeFinishReason(
      choiceEnvelope['finish_reason'],
      hasToolCalls: toolCalls.isNotEmpty,
    );
    final providerState = _providerStateForReasoningDetails(
      structuredReasoning.details,
      options,
    );

    return AgentResponse(
      message: Message(
        role: MessageRole.assistant,
        content: content,
        toolCalls: toolCalls.isEmpty ? null : toolCalls,
        reasoning: reasoning,
        providerState: providerState,
      ),
      isToolCall: toolCalls.isNotEmpty,
      usage: usage,
      model: resolvedModel,
      provider: _providerForModel(resolvedModel),
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
    final url = Uri.parse('$_baseUrl/chat/completions');
    final resolvedModel = _resolveModel(modelOverride);
    final httpClient = client ?? http.Client();
    final ownsClient = client == null;
    final request = http.Request('POST', url);
    request.headers.addAll(_requestHeaders());
    final body = await _buildRequestBody(
      history,
      tools: tools,
      resolvedModel: resolvedModel,
      options: options,
      stream: true,
    );

    if (LLMRequestDumper.isEnabled) {
      await LLMRequestDumper.recordActualRequest(
        url: url,
        headers: request.headers,
        body: body,
      );
    }

    request.body = jsonEncode(body);
    late http.StreamedResponse response;
    try {
      response = await _withTimeout(httpClient.send(request), options.timeout);
    } catch (_) {
      if (ownsClient) httpClient.close();
      rethrow;
    }

    try {
      _logger.info(
        'LLM Stream Response started (status: ${response.statusCode})',
      );

      if (response.statusCode != 200) {
        final errBody = await response.stream.bytesToString();
        if (LLMRequestDumper.isEnabled) {
          await LLMRequestDumper.dumpResponse({
            'status_code': response.statusCode,
            'error': errBody,
          });
        }
        throw LlmHttpException.fromStreamedResponse(
          response,
          errBody,
          operation: 'generateStream',
        );
      }

      final partialToolCalls = <int, _PartialToolCall>{};
      final reasoningDetails = <dynamic>[];
      final tagFallback = TaggedReasoningStreamParser();
      final List<String> accumulatedStreamLines = [];
      var emittedProviderState = false;

      try {
        await for (final line
            in response.stream
                .transform(utf8.decoder)
                .transform(const LineSplitter())) {
          accumulatedStreamLines.add(line);
          if (line.trim().isEmpty) continue;

          if (line.startsWith('data:')) {
            final dataStr = line.substring(5).trim();
            if (dataStr == '[DONE]') break;

            final data = _asStringMap(jsonDecode(dataStr));
            if (data == null) continue;
            // Some providers (NVIDIA NIM, Vertex AI) return HTTP 200 but embed a
            // provider-side error in the SSE payload. Surface it as an
            // LlmHttpException so the runtime classifier can handle it
            // identically to a non-2xx HTTP failure.
            final errorObj = data['error'];
            if (errorObj is Map<String, dynamic>) {
              final code = errorObj['code'];
              final statusCode = code is int
                  ? code
                  : int.tryParse(code?.toString() ?? '') ?? response.statusCode;
              final structuredError = {
                'error': {
                  if (errorObj['type'] != null) 'type': errorObj['type'],
                  if (errorObj['code'] != null) 'code': errorObj['code'],
                  if (errorObj['message'] != null)
                    'message': errorObj['message'],
                },
              };
              throw LlmHttpException(
                statusCode: statusCode,
                body: jsonEncode(structuredError),
                headers: response.headers,
                operation: 'generateStream',
              );
            }

            final usage = _asStringMap(data['usage']);

            if (data['choices'] == null || (data['choices'] as List).isEmpty) {
              if (usage != null) {
                yield AgentResponse(
                  message: Message(role: MessageRole.assistant, content: ''),
                  isToolCall: false,
                  usage: usage,
                  model: resolvedModel,
                  provider: _providerForModel(resolvedModel),
                  finishReason: LLMFinishReason.unknown,
                );
              }
              continue;
            }

            final choice = _asStringMap((data['choices'] as List).first);
            final delta = _asStringMap(choice?['delta']);
            if (delta == null) continue;

            final structuredReasoning = _extractStructuredReasoning(delta);
            reasoningDetails.addAll(structuredReasoning.details);
            final contentChunk = delta['content']?.toString();
            final taggedChunk = contentChunk == null
                ? const TaggedReasoningText()
                : tagFallback.add(contentChunk);

            if (delta['tool_calls'] != null) {
              final List<dynamic> tcList = delta['tool_calls'];
              for (var i = 0; i < tcList.length; i++) {
                final tc = _asStringMap(tcList[i]);
                if (tc == null) {
                  throw const FormatException(
                    'Malformed streamed chat completion tool call.',
                  );
                }
                final index = (tc['index'] as num?)?.toInt() ?? i;
                final function = _asStringMap(tc['function']);
                final partial = partialToolCalls.putIfAbsent(
                  index,
                  () => _PartialToolCall(),
                );
                partial.append(
                  id: tc['id']?.toString(),
                  name: function?['name']?.toString(),
                  argumentsChunk: function?['arguments']?.toString(),
                );
              }
            }

            final finishReason = _normalizeFinishReason(
              choice?['finish_reason'],
              hasToolCalls: false,
            );
            final providerState = finishReason == LLMFinishReason.unknown
                ? null
                : _providerStateForReasoningDetails(reasoningDetails, options);
            if (providerState != null) emittedProviderState = true;

            if (taggedChunk.content != null ||
                taggedChunk.reasoning != null ||
                structuredReasoning.visibleText != null ||
                usage != null ||
                finishReason != LLMFinishReason.unknown) {
              yield AgentResponse(
                message: Message(
                  role: MessageRole.assistant,
                  content: taggedChunk.content,
                  reasoning:
                      structuredReasoning.visibleText ?? taggedChunk.reasoning,
                  providerState: providerState,
                ),
                isToolCall: false,
                usage: usage,
                model: resolvedModel,
                provider: _providerForModel(resolvedModel),
                finishReason: finishReason,
              );
            }
          }
        }

        final pendingTagged = tagFallback.finish();
        if (pendingTagged.content != null || pendingTagged.reasoning != null) {
          yield AgentResponse(
            message: Message(
              role: MessageRole.assistant,
              content: pendingTagged.content,
              reasoning: pendingTagged.reasoning,
            ),
            model: resolvedModel,
            provider: _providerForModel(resolvedModel),
          );
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

      final completedToolCalls = <ToolCall>[];
      for (final entry in partialToolCalls.entries) {
        final partial = entry.value;
        final decodedArguments = _tryDecodeToolArguments(
          partial.argumentsBuffer.toString(),
        );
        if (decodedArguments == null) {
          throw FormatException(
            'Malformed arguments for streamed tool ${partial.name ?? '<unknown>'}.',
          );
        }
        completedToolCalls.add(
          ToolCall(
            id: partial.id ?? '',
            name: partial.name ?? '',
            arguments: decodedArguments,
          ),
        );
      }

      if (completedToolCalls.isNotEmpty) {
        final providerState = _providerStateForReasoningDetails(
          reasoningDetails,
          options,
        );
        if (providerState != null) emittedProviderState = true;
        yield AgentResponse(
          message: Message(
            role: MessageRole.assistant,
            content: '',
            toolCalls: completedToolCalls,
            providerState: providerState,
          ),
          isToolCall: true,
          usage: null,
          model: resolvedModel,
          provider: _providerForModel(resolvedModel),
          finishReason: LLMFinishReason.toolCalls,
        );
      }

      if (!emittedProviderState && reasoningDetails.isNotEmpty) {
        yield AgentResponse(
          message: Message(
            role: MessageRole.assistant,
            providerState: _providerStateForReasoningDetails(
              reasoningDetails,
              options,
            ),
          ),
          model: resolvedModel,
          provider: _providerForModel(resolvedModel),
        );
      }
    } finally {
      if (ownsClient) httpClient.close();
    }
  }

  static const _providerStateNamespace = 'openai_chat_completions';

  Future<Map<String, dynamic>> _buildRequestBody(
    List<Message> history, {
    required String resolvedModel,
    required LLMRequestOptions options,
    List<ToolSchema>? tools,
    bool stream = false,
  }) async {
    final body = <String, dynamic>{
      'model': resolvedModel,
      'messages': history
          .map((message) => _messageToWire(message, options))
          .toList(growable: false),
      if (stream) 'stream': true,
      if (stream) 'stream_options': const {'include_usage': true},
      if (options.maxOutputTokens != null)
        'max_completion_tokens': options.maxOutputTokens,
    };

    final effort = _normalizeReasoningEffort(options.thinkingMode);
    if (effort != null && await _modelSupportsReasoning(resolvedModel)) {
      body['reasoning_effort'] = effort;
    }

    if (tools != null && tools.isNotEmpty) {
      body['tools'] = tools
          .map(
            (tool) => {
              'type': 'function',
              'function': {
                'name': tool.name,
                'description': tool.description,
                'parameters': tool.parameters,
              },
            },
          )
          .toList(growable: false);
    }
    return body;
  }

  Map<String, dynamic> _messageToWire(
    Message message,
    LLMRequestOptions options,
  ) {
    final data = <String, dynamic>{
      'role': _roleToString(message.role),
      'content': message.content ?? '',
    };
    if (message.toolCalls != null) {
      data['tool_calls'] = message.toolCalls!
          .map(
            (toolCall) => {
              'id': toolCall.id,
              'type': 'function',
              'function': {
                'name': toolCall.name,
                'arguments': jsonEncode(toolCall.arguments),
              },
            },
          )
          .toList(growable: false);
    }
    if (message.toolCallId != null) {
      data['tool_call_id'] = message.toolCallId;
    }

    final state = message.providerState;
    if (state?.namespace == _providerStateNamespace &&
        state?.issuer == _stateIssuer(options) &&
        state?.data['reasoning_details'] is List) {
      data['reasoning_details'] = state!.data['reasoning_details'];
    }
    return data;
  }

  Map<String, String> _requestHeaders() => {
    'Content-Type': 'application/json',
    if (_apiKey.isNotEmpty) 'Authorization': 'Bearer $_apiKey',
    ...profile.defaultHeaders,
  };

  String _stateIssuer(LLMRequestOptions options) {
    final instance = options.providerInstanceId ?? profile.name;
    final endpoint = _baseUrl.replaceFirst(RegExp(r'/+$'), '');
    return '$instance|${profile.effectiveProtocol}|$endpoint';
  }

  LLMProviderState? _providerStateForReasoningDetails(
    List<dynamic> details,
    LLMRequestOptions options,
  ) {
    if (details.isEmpty) return null;
    return LLMProviderState(
      namespace: _providerStateNamespace,
      issuer: _stateIssuer(options),
      data: {'reasoning_details': details},
    );
  }

  _StructuredReasoning _extractStructuredReasoning(
    Map<String, dynamic> payload,
  ) {
    final details = <dynamic>[];
    final visible = <String>[];

    void collectVisible(dynamic value) {
      if (value is String) {
        if (value.trim().isNotEmpty) visible.add(value);
        return;
      }
      if (value is List) {
        for (final item in value) {
          collectVisible(item);
        }
        return;
      }
      final map = _asStringMap(value);
      if (map == null) return;
      for (final key in const ['text', 'content', 'summary']) {
        if (map.containsKey(key)) collectVisible(map[key]);
      }
    }

    final rawDetails = payload['reasoning_details'];
    if (rawDetails is List) {
      details.addAll(rawDetails);
    } else if (rawDetails != null) {
      details.add(rawDetails);
    }

    final reasoningContent = payload['reasoning_content'];
    final reasoning = payload['reasoning'];
    if (reasoningContent != null) {
      collectVisible(reasoningContent);
    } else if (reasoning != null) {
      collectVisible(reasoning);
    } else if (rawDetails != null) {
      collectVisible(rawDetails);
    }

    return _StructuredReasoning(
      visibleText: visible.isEmpty ? null : visible.join(),
      details: details,
    );
  }

  List<ToolCall> _parseToolCalls(dynamic rawToolCalls) {
    if (rawToolCalls is! List) return const [];
    return rawToolCalls
        .map((rawToolCall) {
          final toolCall = _asStringMap(rawToolCall);
          final function = _asStringMap(toolCall?['function']);
          if (toolCall == null || function == null) {
            throw const FormatException('Malformed chat completion tool call.');
          }
          final rawArguments = function['arguments']?.toString() ?? '';
          final arguments = _tryDecodeToolArguments(rawArguments);
          if (arguments == null) {
            throw FormatException(
              'Malformed arguments for tool ${function['name'] ?? '<unknown>'}.',
            );
          }
          return ToolCall(
            id: toolCall['id']?.toString() ?? '',
            name: function['name']?.toString() ?? '',
            arguments: arguments,
          );
        })
        .toList(growable: false);
  }

  LLMFinishReason _normalizeFinishReason(
    dynamic rawFinishReason, {
    required bool hasToolCalls,
  }) {
    switch (rawFinishReason?.toString()) {
      case 'stop':
        return LLMFinishReason.stop;
      case 'tool_calls':
      case 'function_call':
        return LLMFinishReason.toolCalls;
      case 'length':
      case 'max_tokens':
        return LLMFinishReason.length;
      case 'incomplete':
        return LLMFinishReason.incomplete;
      case 'content_filter':
      case 'error':
        return LLMFinishReason.failed;
      case 'cancelled':
      case 'canceled':
        return LLMFinishReason.cancelled;
      default:
        return hasToolCalls
            ? LLMFinishReason.toolCalls
            : LLMFinishReason.unknown;
    }
  }

  String? _normalizeReasoningEffort(String? thinkingMode) {
    switch (thinkingMode?.trim().toLowerCase()) {
      case 'fast':
        return 'low';
      case 'balanced':
      case 'normal':
        return 'medium';
      case 'deep':
        return 'high';
      case 'none':
      case 'minimal':
      case 'low':
      case 'medium':
      case 'high':
      case 'xhigh':
      case 'max':
        return thinkingMode!.trim().toLowerCase();
      default:
        return null;
    }
  }

  Future<T> _withTimeout<T>(Future<T> future, Duration? timeout) =>
      timeout == null ? future : future.timeout(timeout);

  Future<http.Response> _get(
    Uri url, {
    Map<String, String>? headers,
    Duration? timeout,
  }) async {
    final httpClient = client ?? http.Client();
    try {
      return await _withTimeout(httpClient.get(url, headers: headers), timeout);
    } finally {
      if (client == null) httpClient.close();
    }
  }

  Map<String, dynamic>? _asStringMap(dynamic value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) {
      return value.map((key, item) => MapEntry(key.toString(), item));
    }
    return null;
  }

  String _roleToString(MessageRole role) {
    switch (role) {
      case MessageRole.system:
        return 'system';
      case MessageRole.user:
        return 'user';
      case MessageRole.assistant:
        return 'assistant';
      case MessageRole.tool:
        return 'tool';
    }
  }

  String _providerForModel(String modelName) {
    final normalized = modelName.startsWith('openai/')
        ? modelName.substring('openai/'.length)
        : modelName;

    if (normalized.contains('/')) {
      return normalized.split('/').first;
    }
    return profile.name;
  }

  Map<String, dynamic>? _tryDecodeToolArguments(String rawArguments) {
    if (rawArguments.trim().isEmpty) {
      return {};
    }

    try {
      final decoded = jsonDecode(rawArguments);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      if (decoded is Map) {
        return decoded.map((key, value) => MapEntry(key.toString(), value));
      }
    } catch (_) {
      return null;
    }
    return null;
  }
}

class _PartialToolCall {
  String? id;
  String? name;
  final StringBuffer argumentsBuffer = StringBuffer();

  void append({String? id, String? name, String? argumentsChunk}) {
    if (id != null && id.isNotEmpty) {
      this.id = id;
    }
    if (name != null && name.isNotEmpty) {
      this.name = name;
    }
    if (argumentsChunk != null && argumentsChunk.isNotEmpty) {
      argumentsBuffer.write(argumentsChunk);
    }
  }
}

class _StructuredReasoning {
  final String? visibleText;
  final List<dynamic> details;

  const _StructuredReasoning({this.visibleText, this.details = const []});
}
