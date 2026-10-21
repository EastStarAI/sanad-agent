import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import '../../capabilities/models/tool_schema.dart';
import '../../core/models/agent_response.dart';
import '../../core/models/message.dart';
import '../../interfaces/platforms/sanad_gateway/capabilities.dart';
import '../llm_request_dumper.dart';
import '../context/compaction_token_estimator.dart';
import 'base_openai_adapter.dart';
import 'codex_models_service.dart';
import 'codex_responses_codec.dart';
import 'codex_responses_policy.dart';
import 'codex_responses_sse_accumulator.dart';
import 'llm_http_exception.dart';
import 'llm_adapter.dart';
import 'llm_request_options.dart';
import 'models_dev_service.dart';
import 'opencode_session_affinity.dart';
import 'provider_request_transport.dart';
import 'provider_state_rejected_exception.dart';
import '../../core/di.dart';
import '../../core/provider_runtime/provider_instance_repository.dart';
import '../../core/provider_runtime/route_capability_resolver.dart';
import 'tool_result_wire_codec.dart';

/// Stateless adapter for Responses-compatible Codex endpoints.
///
/// Sync and stream share one request codec and one final response normalizer.
class CodexResponsesAdapter extends BaseOpenAIAdapter
    implements
        WireInputTokenEstimator,
        WireInputUsageMeasurer,
        ToolResultMediaCapabilityProvider {
  final _modelsLogger = Logger('CodexResponsesAdapter');
  final CodexModelsService _modelsService;

  @override
  ToolResultMediaCapability get toolResultMediaCapability =>
      ToolResultMediaCapability.imageToolResults;

  CodexResponsesAdapter(
    super.config,
    super.profile, {
    super.client,
    super.modelsDevService,
    super.modelContextLimitLookup,
    super.baseUrlOverride,
    super.apiKeyOverride,
    super.defaultModelOverride,
    super.providerInstanceId,
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
    return (await measureInput(
      history,
      tools: tools,
      modelOverride: modelOverride,
      options: options,
    ))?.estimatedTokens;
  }

  @override
  Future<WireInputMeasurement?> measureInput(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async {
    final verifiedAttachments =
        await ToolResultWireCodec.loadVerifiedUserAttachments(
          history,
          attachmentStore: options.attachmentStore,
        );
    final body = _codec(options).buildRequest(
      history: history,
      model: resolveModel(modelOverride),
      options: options,
      tools: _policy.normalizeTools(tools),
      preloadedAttachments: verifiedAttachments,
    );
    final measured = <String, dynamic>{
      'instructions': body['instructions'],
      'input': body['input'],
      if (body['tools'] != null) 'tools': body['tools'],
    };
    String fingerprint(Object? value) =>
        sha256.convert(utf8.encode(jsonEncode(value))).toString();
    final input = (body['input'] as List?) ?? const [];
    return WireInputMeasurement(
      // Model-visible text is priced from the wire tree (opaque provider state
      // excluded), while images are priced from their canonical dimensions in
      // [history] instead of from the base64 transport that carries them.
      estimatedTokens:
          CompactionTokenEstimator.estimateWirePayload(
            measured,
            opaqueKeys: _opaqueWireKeys,
          ) +
          CompactionTokenEstimator.estimateMediaTokens(history),
      stableMaterialFingerprint: fingerprint({
        'instructions': body['instructions'],
        'tools': body['tools'],
      }),
      inputItemFingerprints: input.map(fingerprint).toList(growable: false),
    );
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
    _validateImageSupportIfNeeded(
      history,
      resolvedModel: resolvedModel,
      options: options,
    );
    final verifiedAttachments =
        await ToolResultWireCodec.loadVerifiedUserAttachments(
          history,
          attachmentStore: options.attachmentStore,
        );
    final provider = providerForModel(resolvedModel);
    final codec = _codec(options);
    final body = codec.buildRequest(
      history: history,
      model: resolvedModel,
      options: options,
      tools: _policy.normalizeTools(tools),
      stream: true,
      preloadedAttachments: verifiedAttachments,
    );
    final stopwatch = Stopwatch()..start();
    final url = Uri.parse('${_normalizedBaseUrl()}/responses');
    final request = http.Request('POST', url)
      ..headers.addAll(_headers(options))
      ..body = jsonEncode(body);
    if (LLMRequestDumper.isEnabled) {
      await LLMRequestDumper.recordActualRequest(
        url: url,
        headers: request.headers,
        body: body,
        requestId: options.requestId,
        provider: provider,
        model: resolvedModel,
        baseUrl: _normalizedBaseUrl(),
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
    late http.StreamedResponse response;
    try {
      response = await transport.send(request, operation: 'generateResponse');
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

    final accumulator = CodexResponsesSseAccumulator();
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
        if (line.trim().isEmpty || line.startsWith('event:')) continue;
        if (!line.startsWith('data:')) continue;
        accumulator.addDataLine(line.substring(5));
        if (accumulator.isDone) break;
      }

      final normalized = codec.normalize(
        accumulator.buildResponse(fallbackModel: resolvedModel),
        fallbackModel: resolvedModel,
        provider: provider,
      );

      if (LLMRequestDumper.isEnabled) {
        await LLMRequestDumper.dumpResponse({
          'status_code': response.statusCode,
          'message': normalized.message.toJson(),
          'finish_reason': normalized.finishReason.name,
          'usage': ?normalized.usage,
        }, requestId: options.requestId,
        statusCode: response.statusCode,
        duration: stopwatch.elapsed,
        finishReason: normalized.finishReason.name,
        );
      }

      return normalized;
    } catch (error) {
      if (LLMRequestDumper.isEnabled) {
        await LLMRequestDumper.dumpResponse({
          'status_code': response.statusCode,
          'error': error.toString(),
        }, requestId: options.requestId,
        statusCode: response.statusCode,
        duration: stopwatch.elapsed,
        finishReason: 'incomplete',
        );
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
    _validateImageSupportIfNeeded(
      history,
      resolvedModel: resolvedModel,
      options: options,
    );
    final verifiedAttachments =
        await ToolResultWireCodec.loadVerifiedUserAttachments(
          history,
          attachmentStore: options.attachmentStore,
        );
    final provider = providerForModel(resolvedModel);
    final codec = _codec(options);
    final body = codec.buildRequest(
      history: history,
      model: resolvedModel,
      options: options,
      tools: _policy.normalizeTools(tools),
      stream: true,
      preloadedAttachments: verifiedAttachments,
    );
    final stopwatch = Stopwatch()..start();
    final url = Uri.parse('${_normalizedBaseUrl()}/responses');
    final request = http.Request('POST', url)
      ..headers.addAll(_headers(options))
      ..body = jsonEncode(body);
    if (LLMRequestDumper.isEnabled) {
      await LLMRequestDumper.recordActualRequest(
        url: url,
        headers: request.headers,
        body: body,
        requestId: options.requestId,
        provider: provider,
        model: resolvedModel,
        baseUrl: _normalizedBaseUrl(),
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

    final accumulator = CodexResponsesSseAccumulator();
    final emittedContent = StringBuffer();
    final emittedThought = StringBuffer();
    final emittedReasoning = StringBuffer();
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
          'message': normalized.message.toJson(),
          'finish_reason': normalized.finishReason.name,
          'usage': ?normalized.usage,
        }, requestId: options.requestId,
        statusCode: response.statusCode,
        duration: stopwatch.elapsed,
        finishReason: normalized.finishReason.name,
        );
      }
    } catch (error) {
      if (LLMRequestDumper.isEnabled) {
        await LLMRequestDumper.dumpResponse({
          'status_code': response.statusCode,
          'error': error.toString(),
        }, requestId: options.requestId,
        statusCode: response.statusCode,
        duration: stopwatch.elapsed,
        finishReason: 'incomplete',
        );
      }
      rethrow;
    } finally {
      if (LLMRequestDumper.isEnabled) {
        LLMRequestDumper.cleanupActiveDump(requestId: options.requestId);
      }
      await transport.dispose();
    }
  }

  /// Wire keys that carry provider-owned opaque state (encrypted reasoning
  /// replay). The provider prices them under its own token models, so text
  /// pricing must skip them instead of charging for the serialized transport.
  static const _opaqueWireKeys = <String>{'encrypted_content'};

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

  Map<String, String> _headers(LLMRequestOptions options) =>
      withOpenCodeSessionAffinity(
        headers: {
          'Content-Type': 'application/json',
          if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
          ...profile.defaultHeaders,
        },
        providerName: profile.name,
        baseUrl: baseUrl,
        sessionId: options.sessionId,
      );

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

  RouteCapabilityProfile _resolveRouteCapabilityProfile({
    required String resolvedModel,
    required LLMRequestOptions options,
  }) {
    final instanceId = options.providerInstanceId ?? providerInstanceId;
    final overrideSnapshot =
        options.routeCapabilityProfile?.rawOverride ??
        options.routeCapabilitySnapshot;
    return options.routeCapabilityProfile ??
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
                baseUrl: _normalizedBaseUrl(),
              ));
  }

  void _validateImageSupportIfNeeded(
    List<Message> history, {
    required String resolvedModel,
    required LLMRequestOptions options,
  }) {
    final hasImages = ToolResultWireCodec.hasImages(history);
    if (!hasImages) return;

    final profileSnapshot = _resolveRouteCapabilityProfile(
      resolvedModel: resolvedModel,
      options: options,
    );

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

  static Map<String, dynamic>? _map(dynamic raw) {
    if (raw is Map<String, dynamic>) return raw;
    if (raw is Map) return raw.map((key, value) => MapEntry('$key', value));
    return null;
  }
}
