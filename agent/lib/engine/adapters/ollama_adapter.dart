import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:sanad_agent/core/models/model_metadata.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/capabilities.dart';
import '../../core/models/message.dart';
import '../../core/models/agent_response.dart';
import '../../core/models/tool_call.dart';
import '../../capabilities/models/tool_schema.dart';
import '../../core/provider_thinking/ollama_thinking_probe.dart';
import '../../core/provider_thinking/ollama_thinking_wire_codec.dart';
import 'base_openai_adapter.dart';
import 'llm_request_options.dart';
import 'llm_http_exception.dart';
import 'tagged_reasoning_parser.dart';

class OllamaAdapter extends BaseOpenAIAdapter {
  final _logger = Logger('OllamaAdapter');

  OllamaAdapter(
    super.config,
    super.profile, {
    super.client,
    super.baseUrlOverride,
    super.apiKeyOverride,
  });

  @override
  Future<List<ModelOption>> getAvailableModels() async {
    setLastModelsException(null);
    try {
      final url = Uri.parse('${super.baseUrl}/api/tags');
      final response = await (client ?? http.Client()).get(url);
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final modelsList = data['models'] as List?;
        if (modelsList != null) {
          final List<ModelOption> options = [];
          for (var item in modelsList) {
            final name = item['name'] as String;
            final label = _formatOllamaModelLabel(name);
            final metadata = await _probeModelMetadata(name);
            final supportsReasoning =
                OllamaThinkingProbe.hasThinkingCapability(metadata) ?? false;

            final contextLimit = ModelMetadata.getLimitForModel(name);

            options.add(
              ModelOption(
                value: name,
                label: label,
                provider: profile.name,
                contextWindow: contextLimit,
                supportsReasoning: supportsReasoning,
                modelMetadata: metadata,
              ),
            );
          }
          if (options.isNotEmpty) {
            if (profile.fallbackModels.isNotEmpty) {
              options.sort((a, b) {
                final aId = a.value;
                final bId = b.value;

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
            setAvailableModelsSource('live');
            setLastModelsException(null);
            return options;
          }
        } else {
          setLastModelsException(StateError('Response models is not a list'));
        }
      } else {
        setLastModelsException(
          LlmHttpException.fromResponse(
            response,
            operation: 'getAvailableModels',
          ),
        );
      }
    } catch (e) {
      _logger.warning('Failed to fetch Ollama models: $e');
      setLastModelsException(e);
    }

    final contextLimit = ModelMetadata.getLimitForModel(config.llmModel);
    final metadata = await _probeModelMetadata(config.llmModel);
    return [
      ModelOption(
        value: config.llmModel,
        label: _formatOllamaModelLabel(config.llmModel),
        provider: profile.name,
        contextWindow: contextLimit,
        supportsReasoning:
            OllamaThinkingProbe.hasThinkingCapability(metadata) ?? false,
        modelMetadata: metadata,
      ),
    ];
  }

  Future<Map<String, Object?>> _probeModelMetadata(String modelName) async {
    try {
      final url = Uri.parse('${super.baseUrl}/api/show');
      final response = await (client ?? http.Client()).post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'name': modelName}),
      );
      if (response.statusCode != 200) {
        return const {};
      }
      final data = jsonDecode(response.body);
      if (data is! Map) {
        return const {};
      }
      final showResponse = data.map(
        (key, value) => MapEntry(key.toString(), value),
      );
      final metadata = OllamaThinkingProbe.metadataFromShowResponse(
        showResponse,
      );
      final parameters = showResponse['parameters']?.toString();
      if (parameters != null && parameters.isNotEmpty) {
        return {
          ...metadata,
          'ollama_parameters': parameters,
        };
      }
      return metadata;
    } catch (e) {
      _logger.warning('Failed to probe Ollama model metadata for $modelName: $e');
      return const {};
    }
  }

  String _formatOllamaModelLabel(String name) {
    final parts = name.split(':');
    final mainName = parts[0];
    final tag = parts.length > 1 ? parts[1] : '';

    String capitalize(String s) =>
        s.isEmpty ? '' : '${s[0].toUpperCase()}${s.substring(1)}';

    final mainCapitalized = mainName.split('-').map(capitalize).join(' ');
    if (tag.isNotEmpty && tag != 'latest') {
      return '$mainCapitalized (${capitalize(tag)})';
    }
    return mainCapitalized;
  }

  @override
  Future<int> getContextLimit([String? modelOverride]) async {
    final resolvedModel = super.resolveModel(modelOverride);

    if (config.contextLimit != 4000) return config.contextLimit;

    try {
      final url = Uri.parse('${super.baseUrl}/api/show');
      final response = await (client ?? http.Client()).post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'name': resolvedModel}),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final modelInfo = data['model_info'];
        if (modelInfo != null) {
          for (var entry in modelInfo.entries) {
            if (entry.key.contains('context_length')) {
              return int.tryParse(entry.value.toString()) ?? 4000;
            }
          }
        }
      }
    } catch (e) {
      _logger.warning('Failed to probe Ollama context limit: $e');
    }

    final metadataLimit = ModelMetadata.getLimitForModel(resolvedModel);
    if (metadataLimit != null) return metadataLimit;

    return config.contextLimit;
  }

  Map<String, dynamic> _buildChatBody({
    required String resolvedModel,
    required List<Map<String, dynamic>> messages,
    required LLMRequestOptions options,
    List<ToolSchema>? tools,
    required bool stream,
  }) {
    final body = <String, dynamic>{
      'model': resolvedModel,
      'messages': messages,
      'stream': stream,
    };

    if (tools != null && tools.isNotEmpty) {
      body['tools'] = tools
          .map(
            (t) => {
              'type': 'function',
              'function': {
                'name': t.name,
                'description': t.description,
                'parameters': t.parameters,
              },
            },
          )
          .toList(growable: false);
    }

    OllamaThinkingWireCodec.applyThink(body, options.thinkingDirective);
    return body;
  }

  List<Map<String, dynamic>> _historyToMessages(List<Message> history) {
    return history.map((m) {
      final Map<String, dynamic> data = {
        'role': super.roleToString(m.role),
        'content': m.content ?? '',
      };

      if (m.role == MessageRole.tool && m.toolCallId != null) {
        data['tool_call_id'] = m.toolCallId;
      }
      if (m.toolCalls != null && m.toolCalls!.isNotEmpty) {
        data['tool_calls'] = m.toolCalls!
            .map(
              (tc) => {
                'type': 'function',
                'function': {'name': tc.name, 'arguments': tc.arguments},
              },
            )
            .toList(growable: false);
      }
      return data;
    }).toList(growable: false);
  }

  @override
  Future<AgentResponse> generateResponse(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async {
    final url = Uri.parse('${super.baseUrl}/api/chat');
    final resolvedModel = super.resolveModel(modelOverride);
    final messages = _historyToMessages(history);
    var body = _buildChatBody(
      resolvedModel: resolvedModel,
      messages: messages,
      options: options,
      tools: tools,
      stream: false,
    );

    var response = await (client ?? http.Client()).post(
      url,
      headers: {'Content-Type': 'application/json', ...profile.defaultHeaders},
      body: jsonEncode(body),
    );

    if (response.statusCode == 400) {
      final responseBody = response.body;
      if (responseBody.contains('does not support tools')) {
        body = Map<String, dynamic>.from(body)..remove('tools');
        response = await (client ?? http.Client()).post(
          url,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(body),
        );
      }
    }

    if (response.statusCode != 200) {
      throw LlmHttpException.fromResponse(
        response,
        operation: 'generateResponse',
      );
    }

    final data = jsonDecode(response.body);
    final choice = data['message'];

    final rawContent = choice['content']?.toString() ?? '';
    final structuredReasoning = choice['thinking']?.toString().trim();
    final tagged = splitTaggedReasoning(rawContent);
    final content = tagged.content ?? '';
    final reasoning = structuredReasoning?.isNotEmpty == true
        ? structuredReasoning
        : tagged.reasoning;

    List<ToolCall>? toolCalls;
    final toolCallsData = choice['tool_calls'] as List?;
    toolCalls = toolCallsData
        ?.map(
          (tc) => ToolCall(
            id: tc['id'] ?? '',
            name: tc['function']['name'],
            arguments: tc['function']['arguments'] as Map<String, dynamic>,
          ),
        )
        .toList();

    final usage = {
      'prompt_tokens': data['prompt_eval_count'],
      'completion_tokens': data['eval_count'],
    };

    return AgentResponse(
      message: Message(
        role: MessageRole.assistant,
        content: content,
        toolCalls: toolCalls,
        reasoning: reasoning,
      ),
      isToolCall: toolCalls != null && toolCalls.isNotEmpty,
      usage: usage,
      model: resolvedModel,
      provider: profile.name,
    );
  }

  @override
  Stream<AgentResponse> generateStream(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async* {
    final url = Uri.parse('${super.baseUrl}/api/chat');
    final resolvedModel = super.resolveModel(modelOverride);
    final messages = _historyToMessages(history);

    final httpClient = client ?? http.Client();
    final request = http.Request('POST', url);
    request.headers['Content-Type'] = 'application/json';
    profile.defaultHeaders.forEach((k, v) => request.headers[k] = v);

    var body = _buildChatBody(
      resolvedModel: resolvedModel,
      messages: messages,
      options: options,
      tools: tools,
      stream: true,
    );

    request.body = jsonEncode(body);
    var response = await httpClient.send(request);

    if (response.statusCode == 400) {
      final errorBody = await response.stream.bytesToString();
      if (errorBody.contains('does not support tools')) {
        body = Map<String, dynamic>.from(body)..remove('tools');
        final retryRequest = http.Request('POST', url);
        retryRequest.headers['Content-Type'] = 'application/json';
        retryRequest.body = jsonEncode(body);
        response = await httpClient.send(retryRequest);
      } else {
        throw LlmHttpException.fromStreamedResponse(
          response,
          errorBody,
          operation: 'generateStream',
        );
      }
    }

    if (response.statusCode != 200) {
      final errBody = await response.stream.bytesToString();
      throw LlmHttpException.fromStreamedResponse(
        response,
        errBody,
        operation: 'generateStream',
      );
    }

    final taggedReasoning = TaggedReasoningStreamParser();
    await for (final line
        in response.stream
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
      if (line.trim().isEmpty) continue;

      final data = jsonDecode(line);
      final choice = data['message'];
      if (choice == null) continue;

      final rawContent = choice['content']?.toString() ?? '';
      final structuredReasoning = choice['thinking']?.toString();
      final tagged = structuredReasoning?.isNotEmpty == true
          ? TaggedReasoningText(content: rawContent)
          : taggedReasoning.add(rawContent);
      final done = data['done'] ?? false;

      List<ToolCall>? toolCalls;
      if (choice['tool_calls'] != null) {
        final toolCallsData = choice['tool_calls'] as List;
        toolCalls = toolCallsData
            .map(
              (tc) => ToolCall(
                id: tc['id'] ?? '',
                name: tc['function']['name'],
                arguments: tc['function']['arguments'] as Map<String, dynamic>,
              ),
            )
            .toList();
      }

      Map<String, dynamic>? usage;
      if (data['prompt_eval_count'] != null || data['eval_count'] != null) {
        usage = {
          'prompt_tokens': data['prompt_eval_count'],
          'completion_tokens': data['eval_count'],
        };
      }

      yield AgentResponse(
        message: Message(
          role: MessageRole.assistant,
          content: tagged.content,
          reasoning: structuredReasoning?.isNotEmpty == true
              ? structuredReasoning
              : tagged.reasoning,
          toolCalls: toolCalls,
        ),
        isToolCall: toolCalls != null && toolCalls.isNotEmpty,
        usage: usage,
        model: resolvedModel,
        provider: profile.name,
      );

      if (done) break;
    }

    final pending = taggedReasoning.finish();
    if (pending.content != null || pending.reasoning != null) {
      yield AgentResponse(
        message: Message(
          role: MessageRole.assistant,
          content: pending.content,
          reasoning: pending.reasoning,
        ),
        model: resolvedModel,
        provider: profile.name,
      );
    }
  }
}
