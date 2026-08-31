import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import '../../capabilities/models/tool_schema.dart';
import '../../core/models/agent_response.dart';
import '../../core/models/message.dart';
import '../../interfaces/platforms/sanad_gateway/capabilities.dart';
import '../llm_request_dumper.dart';
import 'base_openai_adapter.dart';
import 'codex_models_service.dart';
import 'codex_responses_codec.dart';
import 'codex_responses_policy.dart';
import 'codex_responses_sse_accumulator.dart';
import 'llm_http_exception.dart';
import 'llm_adapter.dart';
import 'llm_request_options.dart';
import 'provider_request_transport.dart';
import 'provider_state_rejected_exception.dart';

/// Stateless adapter for Responses-compatible Codex endpoints.
///
/// Sync and stream share one request codec and one final response normalizer.
class CodexResponsesAdapter extends BaseOpenAIAdapter
    implements WireInputTokenEstimator {
  final _modelsLogger = Logger('CodexResponsesAdapter');
  final CodexModelsService _modelsService;

  CodexResponsesAdapter(
    super.config,
    super.profile, {
    super.client,
    super.baseUrlOverride,
    super.apiKeyOverride,
    super.defaultModelOverride,
    CodexModelsService? modelsService,
  }) : _modelsService = modelsService ?? CodexModelsService();

  @override
  Future<List<ModelOption>> getAvailableModels() async {
    setLastModelsException(null);
    if (profile.name != 'openai-codex') {
      return super.getAvailableModels();
    }

    final httpClient = client ?? http.Client();
    final ownsClient = client == null;
    try {
      final models = await _modelsService.fetch(
        client: httpClient,
        baseUrl: baseUrl,
        accessToken: apiKey,
        provider: profile.name,
      );
      setAvailableModelsSource('live');
      _modelsLogger.info(
        'Codex model discovery succeeded (${models.length} models)',
      );
      return models;
    } catch (error) {
      setAvailableModelsSource('fallback');
      setLastModelsException(error);
      _modelsLogger.warning('Codex model discovery failed: $error');
      return fallbackModelOptions();
    } finally {
      if (ownsClient) httpClient.close();
    }
  }

  @override
  Future<int?> estimateInputTokens(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async {
    final body = _codec(options).buildRequest(
      history: history,
      model: resolveModel(modelOverride),
      options: options,
      tools: _policy.normalizeTools(tools),
    );
    final measured = <String, dynamic>{
      'instructions': body['instructions'],
      'input': body['input'],
      if (body['tools'] != null) 'tools': body['tools'],
    };
    return (jsonEncode(measured).length / 4).ceil();
  }

  @override
  Future<AgentResponse> generateResponse(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async {
    // Codex Responses API requires stream=true on every request. We send a
    // streaming request and consume the SSE events internally, returning one
    // complete AgentResponse — identical contract to a non-streaming call.
    final resolvedModel = resolveModel(modelOverride);
    final provider = providerForModel(resolvedModel);
    final codec = _codec(options);
    final body = codec.buildRequest(
      history: history,
      model: resolvedModel,
      options: options,
      tools: _policy.normalizeTools(tools),
      stream: true,
    );
    final url = Uri.parse('${_normalizedBaseUrl()}/responses');
    final request = http.Request('POST', url)
      ..headers.addAll(_headers())
      ..body = jsonEncode(body);
    if (LLMRequestDumper.isEnabled) {
      await LLMRequestDumper.recordActualRequest(
        url: url,
        headers: request.headers,
        body: body,
      );
    }

    final transport = ProviderRequestTransport(
      options: options,
      adapterSharedClient: client,
    );
    late http.StreamedResponse response;
    try {
      response = await transport.send(request, operation: 'generateResponse');
    } catch (_) {
      await transport.dispose();
      rethrow;
    }

    final accumulator = CodexResponsesSseAccumulator();
    final capturedLines = <String>[];
    try {
      if (response.statusCode != 200) {
        final errorBody = await response.stream.bytesToString();
        final failure = LlmHttpException.fromStreamedResponse(
          response,
          errorBody,
          operation: 'generateResponse',
        );
        throw _providerStateFailureOrHttp(failure, body, codec);
      }

      await for (final line in transport.decodeSseLines(
        response.stream,
        operation: 'generateResponse',
      )) {
        transport.throwIfCancelled(operation: 'generateResponse');
        capturedLines.add(line);
        if (line.trim().isEmpty || line.startsWith('event:')) continue;
        if (!line.startsWith('data:')) continue;
        accumulator.addDataLine(line.substring(5));
        if (accumulator.isDone) break;
      }

      if (LLMRequestDumper.isEnabled) {
        await LLMRequestDumper.dumpResponse({
          'status_code': response.statusCode,
          'stream_lines': capturedLines,
        });
      }

      return codec.normalize(
        accumulator.buildResponse(fallbackModel: resolvedModel),
        fallbackModel: resolvedModel,
        provider: provider,
      );
    } catch (error) {
      if (LLMRequestDumper.isEnabled) {
        await LLMRequestDumper.dumpResponse({
          'status_code': response.statusCode,
          'stream_lines': capturedLines,
          'error': error.toString(),
        });
      }
      rethrow;
    } finally {
      await transport.dispose();
    }
  }

  @override
  Stream<AgentResponse> generateStream(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async* {
    final resolvedModel = resolveModel(modelOverride);
    final provider = providerForModel(resolvedModel);
    final codec = _codec(options);
    final body = codec.buildRequest(
      history: history,
      model: resolvedModel,
      options: options,
      tools: _policy.normalizeTools(tools),
      stream: true,
    );
    final url = Uri.parse('${_normalizedBaseUrl()}/responses');
    final request = http.Request('POST', url)
      ..headers.addAll(_headers())
      ..body = jsonEncode(body);
    if (LLMRequestDumper.isEnabled) {
      await LLMRequestDumper.recordActualRequest(
        url: url,
        headers: request.headers,
        body: body,
      );
    }

    final transport = ProviderRequestTransport(
      options: options,
      adapterSharedClient: client,
    );
    late http.StreamedResponse response;
    try {
      response = await transport.send(request, operation: 'generateStream');
    } catch (_) {
      await transport.dispose();
      rethrow;
    }

    final accumulator = CodexResponsesSseAccumulator();
    final emittedContent = StringBuffer();
    final emittedThought = StringBuffer();
    final emittedReasoning = StringBuffer();
    final capturedLines = <String>[];
    try {
      if (response.statusCode != 200) {
        final errorBody = await response.stream.bytesToString();
        final failure = LlmHttpException.fromStreamedResponse(
          response,
          errorBody,
          operation: 'generateStream',
        );
        throw _providerStateFailureOrHttp(failure, body, codec);
      }

      await for (final line in transport.decodeSseLines(
        response.stream,
        operation: 'generateStream',
      )) {
        transport.throwIfCancelled(operation: 'generateStream');
        capturedLines.add(line);
        if (line.trim().isEmpty || line.startsWith('event:')) continue;
        if (!line.startsWith('data:')) continue;
        final delta = accumulator.addDataLine(line.substring(5));
        if (delta.content case final content?) {
          emittedContent.write(content);
          yield AgentResponse(
            message: Message(role: MessageRole.assistant, content: content),
            model: resolvedModel,
            provider: provider,
          );
        }
        if (delta.thought case final thought?) {
          emittedThought.write(thought);
          yield AgentResponse(
            message: Message(role: MessageRole.assistant, thought: thought),
            model: resolvedModel,
            provider: provider,
          );
        }
        if (delta.reasoning case final reasoning?) {
          emittedReasoning.write(reasoning);
          yield AgentResponse(
            message: Message(role: MessageRole.assistant, reasoning: reasoning),
            model: resolvedModel,
            provider: provider,
          );
        }
        if (accumulator.isDone) break;
      }

      final normalized = codec.normalize(
        accumulator.buildResponse(fallbackModel: resolvedModel),
        fallbackModel: resolvedModel,
        provider: provider,
      );
      final remainingContent = _remaining(
        normalized.message.content,
        emittedContent.toString(),
      );
      final remainingThought = _remaining(
        normalized.message.thought,
        emittedThought.toString(),
      );
      final remainingReasoning = _remaining(
        normalized.message.reasoning,
        emittedReasoning.toString(),
      );
      yield AgentResponse(
        message: Message(
          role: MessageRole.assistant,
          content: remainingContent,
          thought: remainingThought,
          reasoning: remainingReasoning,
          toolCalls: normalized.message.toolCalls,
          providerState: normalized.message.providerState,
          metadata: normalized.message.metadata,
        ),
        isToolCall: normalized.message.toolCalls?.isNotEmpty ?? false,
        usage: normalized.usage,
        model: normalized.model,
        provider: normalized.provider,
        finishReason: normalized.finishReason,
      );

      if (LLMRequestDumper.isEnabled) {
        await LLMRequestDumper.dumpResponse({
          'status_code': response.statusCode,
          'stream_lines': capturedLines,
        });
      }
    } catch (error) {
      if (LLMRequestDumper.isEnabled) {
        await LLMRequestDumper.dumpResponse({
          'status_code': response.statusCode,
          'stream_lines': capturedLines,
          'error': error.toString(),
        });
      }
      rethrow;
    } finally {
      await transport.dispose();
    }
  }

  CodexResponsesCodec _codec(LLMRequestOptions options) {
    final instance = options.providerInstanceId ?? profile.name;
    return CodexResponsesCodec(
      issuer: '$instance|${profile.apiMode}|${_normalizedBaseUrl()}',
      defaultProvider: profile.name,
    );
  }

  CodexResponsesPolicy get _policy => CodexResponsesPolicy.forProfile(profile);

  Object _providerStateFailureOrHttp(
    LlmHttpException failure,
    Map<String, dynamic> body,
    CodexResponsesCodec codec,
  ) {
    if (!_isInvalidEncryptedContent(failure.body) ||
        !CodexResponsesCodec.hasEncryptedReasoningReplay(body)) {
      return failure;
    }
    return ProviderStateRejectedException(
      httpFailure: failure,
      namespace: CodexResponsesCodec.providerStateNamespace,
      issuer: codec.issuer,
      dataKeysToClear: const {'reasoning_items'},
    );
  }

  static bool _isInvalidEncryptedContent(String body) {
    try {
      final decoded = jsonDecode(body);
      final root = _map(decoded);
      final error = _map(root?['error']);
      final code = error?['code']?.toString().trim().toLowerCase();
      if (code == 'invalid_encrypted_content') return true;
    } catch (_) {
      // Some compatible endpoints return text or an unexpected error shape.
    }
    return body.toLowerCase().contains('invalid_encrypted_content');
  }

  String _normalizedBaseUrl() => baseUrl.replaceFirst(RegExp(r'/+$'), '');

  Map<String, String> _headers() => {
    'Content-Type': 'application/json',
    if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
    ...profile.defaultHeaders,
  };

  static String? _remaining(String? complete, String emitted) {
    if (complete == null || complete.isEmpty) return null;
    if (emitted.isEmpty) return complete;
    if (complete == emitted) return null;
    if (complete.startsWith(emitted)) {
      final suffix = complete.substring(emitted.length);
      return suffix.isEmpty ? null : suffix;
    }
    return null;
  }

  static Map<String, dynamic>? _map(dynamic raw) {
    if (raw is Map<String, dynamic>) return raw;
    if (raw is Map) return raw.map((key, value) => MapEntry('$key', value));
    return null;
  }
}
