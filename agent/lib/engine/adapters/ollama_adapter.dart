import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:sanad_agent/core/models/model_metadata.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/capabilities.dart';
import '../../core/models/message.dart';
import '../../core/models/agent_response.dart';
import '../../core/models/tool_call.dart';
import '../../capabilities/models/tool_schema.dart';
import 'base_openai_adapter.dart';
import 'llm_request_options.dart';
import 'llm_http_exception.dart';
import 'provider_request_transport.dart';
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
            final lowercaseName = name.toLowerCase();
            final supportsReasoning =
                lowercaseName.contains('gemma') ||
                lowercaseName.contains('deepseek') ||
                lowercaseName.contains('r1');

            final contextLimit =
                config.contextModelLimit(name) ??
                ModelMetadata.getLimitForModel(name);

            options.add(
              ModelOption(
                value: name,
                label: label,
                provider: profile.name,
                contextWindow: contextLimit,
                supportsReasoning: supportsReasoning,
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

    final contextLimit =
        config.contextModelLimit(config.llmModel) ??
        ModelMetadata.getLimitForModel(config.llmModel);
    return [
      ModelOption(
        value: config.llmModel,
        label: _formatOllamaModelLabel(config.llmModel),
        provider: profile.name,
        contextWindow: contextLimit,
        supportsReasoning:
            config.llmModel.toLowerCase().contains('gemma') ||
            config.llmModel.toLowerCase().contains('deepseek'),
      ),
    ];
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

    final configuredLimit = config.contextModelLimit(resolvedModel);
    if (configuredLimit != null) return configuredLimit;

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

    return 4000;
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

    final messages = history.map((m) {
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
            .toList();
      }
      return data;
    }).toList();

    final body = {
      'model': resolvedModel,
      'messages': messages,
      'stream': false,
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
          .toList();
    }

    final transport = ProviderRequestTransport(
      options: options,
      adapterSharedClient: client,
    );
    late http.Response response;
    try {
      response = await transport.post(
        url,
        headers: {
          'Content-Type': 'application/json',
          ...profile.defaultHeaders,
        },
        body: jsonEncode(body),
        operation: 'generateResponse',
      );

      if (response.statusCode == 400) {
        final responseBody = response.body;
        if (responseBody.contains('does not support tools')) {
          body.remove('tools');
          response = await transport.post(
            url,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
            operation: 'generateResponse',
          );
        }
      }
    } finally {
      await transport.dispose();
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

    final messages = history.map((m) {
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
            .toList();
      }
      return data;
    }).toList();

    final transport = ProviderRequestTransport(
      options: options,
      adapterSharedClient: client,
    );
    final request = http.Request('POST', url);
    request.headers['Content-Type'] = 'application/json';
    profile.defaultHeaders.forEach((k, v) => request.headers[k] = v);

    final body = {'model': resolvedModel, 'messages': messages, 'stream': true};

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
          .toList();
    }

    request.body = jsonEncode(body);
    late http.StreamedResponse response;
    try {
      response = await transport.send(request, operation: 'generateStream');
    } catch (_) {
      await transport.dispose();
      rethrow;
    }

    try {
      if (response.statusCode == 400) {
        final errorBody = await response.stream.bytesToString();
        if (errorBody.contains('does not support tools')) {
          body.remove('tools');
          final retryRequest = http.Request('POST', url);
          retryRequest.headers['Content-Type'] = 'application/json';
          retryRequest.body = jsonEncode(body);
          response = await transport.send(
            retryRequest,
            operation: 'generateStream',
          );
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
      await for (final line in transport.decodeSseLines(
        response.stream,
        operation: 'generateStream',
      )) {
        transport.throwIfCancelled(operation: 'generateStream');
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
                  arguments:
                      tc['function']['arguments'] as Map<String, dynamic>,
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
    } finally {
      await transport.dispose();
    }
  }
}
