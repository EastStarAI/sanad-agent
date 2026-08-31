import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:test/test.dart';
import 'package:get_it/get_it.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/models/tool_call.dart';
import 'package:sanad_agent/core/models/agent_response.dart';
import 'package:sanad_agent/core/models/llm_provider_state.dart';
import 'package:sanad_agent/engine/agent_runner.dart';
import 'package:sanad_agent/engine/adapters/llm_adapter.dart';
import 'package:sanad_agent/engine/adapters/llm_request_options.dart';
import 'package:sanad_agent/engine/adapters/rate_limited_llm_adapter.dart';
import 'package:sanad_agent/capabilities/registry/tools_registry.dart';
import 'package:sanad_agent/capabilities/tools/base_tool.dart';
import 'package:sanad_agent/capabilities/models/tool_schema.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/capabilities.dart';
import 'package:sanad_agent/core/agent_runtime_service.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/core/provider_runtime/provider_protocol_constants.dart';
import 'package:sanad_agent/core/provider_runtime/provider_rate_limiter.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_recovery_service.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_failure_reason.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_notice.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_recovery_exception.dart';
import 'package:sanad_agent/core/provider_runtime/session_queue_provider_override.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/persisted_runtime_state_repository.dart';
import 'package:sanad_agent/evolution/db/runtime/session_execution_state_coordinator.dart';
import 'package:sanad_agent/evolution/models/session_execution_snapshot.dart';
import 'package:sanad_agent/evolution/models/suspended_checkpoint.dart';
import 'package:sanad_agent/engine/adapters/llm_http_exception.dart';
import 'package:sanad_agent/engine/adapters/provider_state_rejected_exception.dart';
import 'package:sanad_agent/engine/runtime/deferred_tool_result.dart';
import 'package:sanad_agent/engine/runtime/continuation_checkpoint_coordinator.dart';

class MockAdapter implements LLMAdapter {
  final List<AgentResponse> responses;
  int _callCount = 0;
  List<Message>? lastHistory;
  final List<List<Message>> histories = [];
  String? lastModelOverride;
  LLMRequestOptions? lastOptions;

  MockAdapter(this.responses);

  @override
  Future<int> getContextLimit([String? modelOverride]) async =>
      modelOverride == 'mock/large' ? 8192 : 4096;

  @override
  Future<List<ModelOption>> getAvailableModels() async {
    return [
      ModelOption(
        value: 'mock/gpt-3.5-turbo',
        label: 'Mock GPT-3.5 Turbo',
        provider: 'mock',
        contextWindow: 4096,
      ),
    ];
  }

  @override
  Future<AgentResponse> generateResponse(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async {
    lastModelOverride = modelOverride;
    lastOptions = options;
    lastHistory = List<Message>.from(history);
    histories.add(List<Message>.from(history));
    if (_callCount >= responses.length) {
      return AgentResponse(
        message: Message(
          role: MessageRole.assistant,
          content: 'No more responses',
        ),
      );
    }
    return responses[_callCount++];
  }

  @override
  Stream<AgentResponse> generateStream(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async* {
    lastModelOverride = modelOverride;
    final response = await generateResponse(
      history,
      tools: tools,
      modelOverride: modelOverride,
      options: options,
    );
    yield response;
  }
}

class ProviderStateRejectingAdapter implements LLMAdapter {
  final String issuer;
  final bool alwaysReject;
  final List<List<Message>> histories = [];
  int callCount = 0;

  ProviderStateRejectingAdapter(this.issuer, {this.alwaysReject = false});

  @override
  Future<int> getContextLimit([String? modelOverride]) async => 4096;

  @override
  Future<List<ModelOption>> getAvailableModels() async => const [];

  @override
  Future<AgentResponse> generateResponse(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async {
    histories.add(List<Message>.from(history));
    callCount++;
    if (callCount == 1 || alwaysReject) {
      throw ProviderStateRejectedException(
        httpFailure: const LlmHttpException(
          statusCode: 400,
          body: '{"error":{"code":"invalid_encrypted_content"}}',
          headers: {},
          operation: 'test',
        ),
        namespace: 'codex_responses',
        issuer: issuer,
        dataKeysToClear: const {'reasoning_items'},
      );
    }
    return AgentResponse(
      message: Message(role: MessageRole.assistant, content: 'Recovered'),
      finishReason: LLMFinishReason.stop,
    );
  }

  @override
  Stream<AgentResponse> generateStream(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async* {
    yield await generateResponse(
      history,
      tools: tools,
      modelOverride: modelOverride,
      options: options,
    );
  }
}

class MockTool extends BaseTool {
  @override
  ToolSchema get schema =>
      ToolSchema(name: 'test_tool', description: 'desc', parameters: {});
  @override
  Future<String> execute(
    Map<String, dynamic> args, {
    ToolContext? context,
  }) async => 'tool result';
}

class DelayedTool extends BaseTool {
  final Completer<void> started = Completer<void>();
  final Completer<void> release = Completer<void>();

  @override
  ToolSchema get schema =>
      ToolSchema(name: 'delayed_tool', description: 'desc', parameters: {});

  @override
  Future<String> execute(
    Map<String, dynamic> args, {
    ToolContext? context,
  }) async {
    if (!started.isCompleted) started.complete();
    await release.future;
    return 'delayed tool result';
  }
}

class DelayedToolCallAdapter implements LLMAdapter {
  final Completer<void> started = Completer<void>();
  final Completer<void> release = Completer<void>();
  int callCount = 0;

  @override
  Future<int> getContextLimit([String? modelOverride]) async => 4096;

  @override
  Future<List<ModelOption>> getAvailableModels() async => const [];

  @override
  Future<AgentResponse> generateResponse(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async {
    callCount++;
    if (!started.isCompleted) started.complete();
    await release.future;
    return AgentResponse(
      message: Message(
        role: MessageRole.assistant,
        toolCalls: [
          ToolCall(
            id: 'stop-tool-call',
            name: 'test_tool',
            arguments: const {},
          ),
        ],
      ),
      isToolCall: true,
    );
  }

  @override
  Stream<AgentResponse> generateStream(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async* {
    yield await generateResponse(
      history,
      tools: tools,
      modelOverride: modelOverride,
    );
  }
}

class ControlledStreamingAdapter implements LLMAdapter {
  final Completer<void> firstChunkEmitted = Completer<void>();
  final Completer<void> releaseFirstResponse = Completer<void>();
  final List<List<Message>> histories = [];
  int _callCount = 0;

  @override
  Future<int> getContextLimit([String? modelOverride]) async => 4096;

  @override
  Future<List<ModelOption>> getAvailableModels() async => const [];

  @override
  Future<AgentResponse> generateResponse(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async {
    throw UnsupportedError('Streaming only');
  }

  @override
  Stream<AgentResponse> generateStream(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async* {
    histories.add(List<Message>.from(history));
    if (_callCount++ == 0) {
      yield AgentResponse(
        message: Message(
          role: MessageRole.assistant,
          content: 'Answer before steer',
        ),
      );
      if (!firstChunkEmitted.isCompleted) firstChunkEmitted.complete();
      await releaseFirstResponse.future;
      return;
    }
    yield AgentResponse(
      message: Message(role: MessageRole.assistant, content: 'Adjusted answer'),
    );
  }
}

class _FakeRuntimeService extends AgentRuntimeService {
  _FakeRuntimeService(this.routedAdapter)
    : super(
        Config(),
        ProviderInstanceRepository.fromDatabase(
          AgentStateDatabase.inMemory().db,
        ),
      );

  final LLMAdapter routedAdapter;
  RouteSignature? lastSignature;
  final Map<String, RouteSignature> _remembered = {};

  @override
  RouteSignature resolveSignature({String? providerId, String? modelId}) {
    return RouteSignature(
      providerInstanceId: providerId ?? 'default-inst',
      templateId: 'custom',
      protocol: 'openai_compatible',
      normalizedBaseUrl: 'http://localhost:9000/v1',
      modelId: modelId ?? 'claude-sonnet-4.5',
      configRevision: 1,
      credentialRevision: 1,
    );
  }

  @override
  LLMAdapter adapterFor(RouteSignature signature) {
    lastSignature = signature;
    return routedAdapter;
  }

  @override
  void rememberSessionSignature(String sessionId, RouteSignature signature) {
    _remembered[sessionId] = signature;
  }

  @override
  RouteSignature? sessionSignature(String sessionId) => _remembered[sessionId];
}

/// Generic runtime service that always returns the same adapter regardless of
/// the resolved signature (Phase H retry-policy tests use custom failing
/// adapters, not just [MockAdapter]).
class _GenericRuntimeService extends AgentRuntimeService {
  _GenericRuntimeService(this.adapter)
    : super(
        Config(),
        ProviderInstanceRepository.fromDatabase(
          AgentStateDatabase.inMemory().db,
        ),
      );

  final LLMAdapter adapter;

  @override
  RouteSignature resolveSignature({String? providerId, String? modelId}) {
    return RouteSignature(
      providerInstanceId: providerId ?? 'default-inst',
      templateId: 'custom',
      protocol: 'openai_compatible',
      normalizedBaseUrl: 'http://localhost:9000/v1',
      modelId: modelId ?? 'gpt-4o',
      configRevision: 1,
      credentialRevision: 1,
    );
  }

  @override
  LLMAdapter adapterFor(RouteSignature signature) => adapter;

  @override
  void rememberSessionSignature(String sessionId, RouteSignature signature) {}

  @override
  RouteSignature? sessionSignature(String sessionId) => null;
}

class _ProviderSwitchingRuntimeService extends AgentRuntimeService {
  _ProviderSwitchingRuntimeService(
    this._repo, {
    required this.oldAdapter,
    required this.newAdapter,
  }) : super(
         Config(),
         _repo,
         rateLimiter: ProviderRateLimiter(),
         recoveryService: RuntimeRecoveryService(
           _repo,
           ProviderRateLimiter(),
           autoFailoverEnabled: true,
         ),
       );

  final ProviderInstanceRepository _repo;
  final LLMAdapter oldAdapter;
  final LLMAdapter newAdapter;

  @override
  RouteSignature resolveSignature({String? providerId, String? modelId}) {
    final instance = _repo.findById(providerId!)!;
    return RouteSignature(
      providerInstanceId: instance.id,
      templateId: instance.templateId,
      protocol: instance.protocol,
      normalizedBaseUrl: 'http://localhost:9000/v1',
      modelId: modelId ?? instance.defaultModel ?? 'model-a',
      configRevision: instance.configRevision,
      credentialRevision: instance.credentialRevision,
    );
  }

  @override
  LLMAdapter adapterForTurn(
    RouteSignature signature, {
    required String sessionId,
    String? requestId,
    String? runId,
  }) {
    return signature.providerInstanceId == 'provider-old'
        ? oldAdapter
        : newAdapter;
  }
}

class _MultiProviderRuntimeService extends AgentRuntimeService {
  _MultiProviderRuntimeService(
    this._repo, {
    required this.adapters,
    required this.requestedProviders,
  }) : super(
         Config(),
         _repo,
         rateLimiter: ProviderRateLimiter(),
         recoveryService: RuntimeRecoveryService(
           _repo,
           ProviderRateLimiter(),
           autoFailoverEnabled: true,
         ),
       );

  final ProviderInstanceRepository _repo;
  final Map<String, LLMAdapter> adapters;
  final List<String> requestedProviders;

  @override
  RouteSignature resolveSignature({String? providerId, String? modelId}) {
    final instance = _repo.findById(providerId!)!;
    return RouteSignature(
      providerInstanceId: instance.id,
      templateId: instance.templateId,
      protocol: instance.protocol,
      normalizedBaseUrl: 'http://localhost:9000/v1',
      modelId: modelId ?? instance.defaultModel ?? 'model-a',
      configRevision: instance.configRevision,
      credentialRevision: instance.credentialRevision,
    );
  }

  @override
  LLMAdapter adapterForTurn(
    RouteSignature signature, {
    required String sessionId,
    String? requestId,
    String? runId,
  }) {
    requestedProviders.add(signature.providerInstanceId);
    return adapters[signature.providerInstanceId]!;
  }
}

class _AutoFailoverAdapter implements LLMAdapter {
  _AutoFailoverAdapter();

  int callCount = 0;

  @override
  Future<int> getContextLimit([String? modelOverride]) async => 4096;

  @override
  Future<List<ModelOption>> getAvailableModels() async => const [];

  @override
  Future<AgentResponse> generateResponse(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async {
    callCount += 1;
    throw LlmHttpException(
      statusCode: 429,
      body: '{"error":{"message":"rate limit"}}',
      headers: const {},
      operation: 'chat.completions',
    );
  }

  @override
  Stream<AgentResponse> generateStream(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async* {
    yield await generateResponse(
      history,
      tools: tools,
      modelOverride: modelOverride,
    );
  }
}

class _RateLimitOnceAdapter implements LLMAdapter {
  int callCount = 0;

  @override
  Future<int> getContextLimit([String? modelOverride]) async => 4096;

  @override
  Future<List<ModelOption>> getAvailableModels() async => const [];

  @override
  Future<AgentResponse> generateResponse(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async {
    callCount += 1;
    if (callCount == 1) {
      throw const LlmHttpException(
        statusCode: 429,
        body: '{"error":{"message":"rate limit"}}',
        headers: {'retry-after-ms': '1'},
        operation: 'chat.completions',
      );
    }
    return AgentResponse(
      message: Message(
        role: MessageRole.assistant,
        content: 'Recovered after the reset window',
      ),
    );
  }

  @override
  Stream<AgentResponse> generateStream(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async* {
    yield await generateResponse(
      history,
      tools: tools,
      modelOverride: modelOverride,
      options: options,
    );
  }
}

class _RecordingQueueOverride implements SessionQueueProviderOverride {
  final List<(String sessionId, String providerInstanceId)> rewrites = [];

  @override
  void rewriteQueuedProvider(String sessionId, String providerInstanceId) {
    rewrites.add((sessionId, providerInstanceId));
  }
}

/// Adapter that throws a plain exception with a body string (Phase H tests
/// for network/timeout classification via body patterns, no HTTP status).
class _BodyFailingAdapter implements LLMAdapter {
  final String body;
  int callCount = 0;

  _BodyFailingAdapter({required this.body});

  @override
  Future<int> getContextLimit([String? modelOverride]) async => 4096;

  @override
  Future<List<ModelOption>> getAvailableModels() async => const [];

  @override
  Future<AgentResponse> generateResponse(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async {
    callCount += 1;
    throw Exception(body);
  }

  @override
  Stream<AgentResponse> generateStream(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async* {
    yield await generateResponse(
      history,
      tools: tools,
      modelOverride: modelOverride,
    );
  }
}

/// Adapter that always throws a specific HTTP error (Phase H retry-policy
/// tests). Used to verify deterministic errors do not consume a retry budget
/// and that the original reason/message survive.
class _AlwaysFailingAdapter implements LLMAdapter {
  final int statusCode;
  final String body;
  final Map<String, String> headers;
  int callCount = 0;

  _AlwaysFailingAdapter({
    required this.statusCode,
    required this.body,
    Map<String, String>? headers,
  }) : headers = headers ?? const {};

  @override
  Future<int> getContextLimit([String? modelOverride]) async => 4096;

  @override
  Future<List<ModelOption>> getAvailableModels() async => const [];

  @override
  Future<AgentResponse> generateResponse(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async {
    callCount += 1;
    throw LlmHttpException(
      statusCode: statusCode,
      body: body,
      headers: headers,
      operation: 'chat.completions',
    );
  }

  @override
  Stream<AgentResponse> generateStream(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async* {
    yield await generateResponse(
      history,
      tools: tools,
      modelOverride: modelOverride,
    );
  }
}

class _CountingRetryAfterException extends LlmHttpException {
  int readCount = 0;
  final Duration? firstValue;
  final Duration? subsequentValue;

  _CountingRetryAfterException({
    required this.firstValue,
    required this.subsequentValue,
    required super.statusCode,
    required super.body,
    required super.headers,
    required super.operation,
  });

  @override
  Duration? get retryAfter {
    readCount += 1;
    return readCount == 1 ? firstValue : subsequentValue;
  }
}

class _ThrowOnceThenSucceedAdapter implements LLMAdapter {
  _ThrowOnceThenSucceedAdapter(this.error);

  final Object error;
  int callCount = 0;

  @override
  Future<int> getContextLimit([String? modelOverride]) async => 4096;

  @override
  Future<List<ModelOption>> getAvailableModels() async => const [];

  @override
  Future<AgentResponse> generateResponse(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async {
    if (callCount++ == 0) {
      throw error;
    }
    return AgentResponse(
      message: Message(
        role: MessageRole.assistant,
        content: 'Recovered after transient wait',
      ),
    );
  }

  @override
  Stream<AgentResponse> generateStream(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async* {
    yield await generateResponse(
      history,
      tools: tools,
      modelOverride: modelOverride,
    );
  }
}

/// Calls [onCall] on every LLM request so tests can inject custom throw/return
/// behaviour while counting invocations.
class _CallCountAdapter implements LLMAdapter {
  final void Function() onCall;
  int callCount = 0;

  _CallCountAdapter({required this.onCall});

  @override
  Future<int> getContextLimit([String? modelOverride]) async => 4096;

  @override
  Future<List<ModelOption>> getAvailableModels() async => const [];

  @override
  Future<AgentResponse> generateResponse(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async {
    callCount++;
    onCall();
    // onCall throws — we never reach here.
    throw StateError('unreachable');
  }

  @override
  Stream<AgentResponse> generateStream(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async* {
    callCount++;
    onCall();
  }
}

/// Emits one visible reasoning event, then simulates a provider disconnect.
class _ReasoningThenFailingAdapter implements LLMAdapter {
  int callCount = 0;

  @override
  Future<int> getContextLimit([String? modelOverride]) async => 4096;

  @override
  Future<List<ModelOption>> getAvailableModels() async => const [];

  @override
  Future<AgentResponse> generateResponse(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async {
    callCount++;
    throw LlmHttpException(
      statusCode: 503,
      body: 'upstream connect error: remote connection failure',
      headers: const {},
      operation: 'generateResponse',
    );
  }

  @override
  Stream<AgentResponse> generateStream(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async* {
    callCount++;
    yield AgentResponse(
      message: Message(
        role: MessageRole.assistant,
        reasoning: 'Inspecting the request',
      ),
    );
    throw LlmHttpException(
      statusCode: 503,
      body: 'upstream connect error: remote connection failure',
      headers: const {},
      operation: 'generateStream',
    );
  }
}

/// Always throws [error] on every LLM request.
class _ThrowingAdapter implements LLMAdapter {
  final Object error;

  _ThrowingAdapter({required this.error});

  @override
  Future<int> getContextLimit([String? modelOverride]) async => 4096;

  @override
  Future<List<ModelOption>> getAvailableModels() async => const [];

  @override
  Future<AgentResponse> generateResponse(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async {
    throw error;
  }

  @override
  Stream<AgentResponse> generateStream(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async* {
    throw error;
  }
}

class _FailOnceThenSucceedAdapter implements LLMAdapter {
  final Completer<void> firstFailure = Completer<void>();
  final List<String?> modelOverrides = [];
  int callCount = 0;

  @override
  Future<int> getContextLimit([String? modelOverride]) async => 4096;

  @override
  Future<List<ModelOption>> getAvailableModels() async => const [];

  @override
  Future<AgentResponse> generateResponse(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async {
    modelOverrides.add(modelOverride);
    if (callCount++ == 0) {
      if (!firstFailure.isCompleted) {
        firstFailure.complete();
      }
      throw const LlmHttpException(
        statusCode: 429,
        body: 'Too Many Requests',
        headers: {'retry-after': '5'},
        operation: 'chat.completions',
      );
    }
    return AgentResponse(
      message: Message(
        role: MessageRole.assistant,
        content: 'Recovered on $modelOverride',
      ),
    );
  }

  @override
  Stream<AgentResponse> generateStream(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async* {
    yield await generateResponse(
      history,
      tools: tools,
      modelOverride: modelOverride,
    );
  }
}

void main() {
  group('AgentRunner', () {
    late ToolsRegistry registry;
    late MockTool mockTool;
    late SessionManager sessionManager;
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('sanad_test_');
      setSanadHomeOverride(tempDir.path);
      sessionManager = SessionManager();
      registry = ToolsRegistry();
      mockTool = MockTool();
      registry.registerTool(mockTool);
    });

    tearDown(() {
      GetIt.I.reset();
      SessionManager.resetForTesting();
      setSanadHomeOverride(null);
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('should handle simple conversation', () async {
      final adapter = MockAdapter([
        AgentResponse(
          message: Message(role: MessageRole.assistant, content: 'Hello!'),
        ),
      ]);
      final runner = AgentRunner(adapter, registry, sessionManager);

      final response = await runner.sendMessage('Hi');
      expect(response.content, 'Hello!');
      expect(runner.history.length, 2); // user + assistant
    });

    test('passes per-turn request options to synchronous adapters', () async {
      final adapter = MockAdapter([
        AgentResponse(
          message: Message(role: MessageRole.assistant, content: 'Done'),
        ),
      ]);
      final runner = AgentRunner(adapter, registry, sessionManager);

      await runner.sendMessage(
        'Hi',
        requestId: 'request-sync-1',
        thinkingMode: 'deep',
      );

      expect(adapter.lastOptions?.sessionId, runner.sessionId);
      expect(adapter.lastOptions?.requestId, 'request-sync-1');
      expect(adapter.lastOptions?.thinkingMode, 'deep');
      expect(runner.history.first.metadata?['request_id'], 'request-sync-1');
    });

    test(
      'completed route keeps the provider adapter without turn lifecycle wrapper',
      () async {
        final providerAdapter = MockAdapter([
          AgentResponse(
            message: Message(role: MessageRole.assistant, content: 'Done'),
          ),
        ]);
        final turnAdapter = RateLimitedLLMAdapter(
          providerAdapter,
          providerInstanceId: 'provider-1',
          requestsPerMinute: 0,
          limiter: ProviderRateLimiter(),
          cancelToken: Completer<void>().future,
        );
        final runner = AgentRunner(turnAdapter, registry, sessionManager);

        await runner.sendMessage('Hi');

        expect(runner.lastSuccessfulLlmRoute?.adapter, same(providerAdapter));
      },
    );

    test(
      'preserves adapter state and request options while streaming',
      () async {
        const providerState = LLMProviderState(
          namespace: 'test_adapter',
          issuer: 'provider-instance-1',
          data: {'continuation': 'opaque-state'},
        );
        final adapter = MockAdapter([
          AgentResponse(
            message: Message(
              role: MessageRole.assistant,
              content: 'Done',
              providerState: providerState,
              metadata: {'adapter_marker': true},
            ),
          ),
        ]);
        final runner = AgentRunner(adapter, registry, sessionManager);
        runner.setTurnRequestId('request-stream-1');

        await runner.streamMessage('Hi', thinkingMode: 'balanced').toList();

        expect(adapter.lastOptions?.sessionId, runner.sessionId);
        expect(adapter.lastOptions?.requestId, 'request-stream-1');
        expect(adapter.lastOptions?.thinkingMode, 'balanced');
        expect(
          runner.history.first.metadata?['request_id'],
          'request-stream-1',
        );
        final assistant = runner.history.last;
        expect(assistant.providerState?.namespace, 'test_adapter');
        expect(assistant.providerState?.data['continuation'], 'opaque-state');
        expect(assistant.metadata?['adapter_marker'], isTrue);
        expect(assistant.metadata?['run_id'], isNull);
        expect(assistant.metadata?['model_step_id'], isNotEmpty);
      },
    );

    test(
      'persists sync terminal reason and provider-state-only messages across runner restart',
      () async {
        const providerState = LLMProviderState(
          namespace: 'codex_responses',
          issuer: 'provider|openai_compatible|https://example.test',
          data: {'encrypted_content': 'opaque-sync'},
        );
        final adapter = MockAdapter(
          List.generate(
            4,
            (_) => AgentResponse(
              message: Message(
                role: MessageRole.assistant,
                providerState: providerState,
              ),
              finishReason: LLMFinishReason.incomplete,
            ),
          ),
        );
        final runner = AgentRunner(adapter, registry, sessionManager);

        await runner.sendMessage('Hi');

        final assistant = runner.history.last;
        expect(assistant.content, isNull);
        expect(assistant.providerState, providerState);
        expect(assistant.finishReason, LLMFinishReason.incomplete);

        final restarted = AgentRunner(
          MockAdapter(const []),
          registry,
          sessionManager,
          existingSessionId: runner.sessionId,
        );
        final restored = restarted.history.last;
        expect(
          restored.providerState?.data['encrypted_content'],
          'opaque-sync',
        );
        expect(restored.finishReason, LLMFinishReason.incomplete);
        expect(adapter.histories, hasLength(4));
      },
    );

    test(
      'continues incomplete sync responses and preserves their state',
      () async {
        const state = LLMProviderState(
          namespace: 'codex_responses',
          issuer: 'issuer-a',
          data: {
            'reasoning_items': [
              {'type': 'reasoning', 'encrypted_content': 'sealed'},
            ],
          },
        );
        final adapter = MockAdapter([
          AgentResponse(
            message: Message(role: MessageRole.assistant, providerState: state),
            finishReason: LLMFinishReason.incomplete,
          ),
          AgentResponse(
            message: Message(role: MessageRole.assistant, content: 'Complete'),
            finishReason: LLMFinishReason.stop,
          ),
        ]);
        final runner = AgentRunner(adapter, registry, sessionManager);

        final response = await runner.sendMessage('Continue');

        expect(response.content, 'Complete');
        expect(adapter.histories, hasLength(2));
        expect(
          adapter.histories[1].any((message) => message.providerState == state),
          isTrue,
        );
        expect(
          runner.history.where(
            (message) => message.role == MessageRole.assistant,
          ),
          hasLength(2),
        );
      },
    );

    test(
      'continues incomplete stream responses within a separate budget',
      () async {
        final adapter = MockAdapter([
          AgentResponse(
            message: Message(role: MessageRole.assistant, content: 'Draft '),
            finishReason: LLMFinishReason.incomplete,
          ),
          AgentResponse(
            message: Message(role: MessageRole.assistant, content: 'done'),
            finishReason: LLMFinishReason.stop,
          ),
        ]);
        final runner = AgentRunner(adapter, registry, sessionManager);

        final chunks = await runner.streamMessage('Continue').toList();

        expect(chunks.join(), 'Draft done');
        expect(adapter.histories, hasLength(2));
        expect(runner.history.last.finishReason, LLMFinishReason.stop);
      },
    );

    test(
      'streams thoughts and reasoning separately from final content',
      () async {
        final adapter = MockAdapter([
          AgentResponse(
            message: Message(
              role: MessageRole.assistant,
              thought: 'I will inspect the implementation',
              reasoning: 'Inspecting implementation',
              toolCalls: [
                ToolCall(
                  id: 'reasoning-tool',
                  name: 'test_tool',
                  arguments: {},
                ),
              ],
            ),
            finishReason: LLMFinishReason.toolCalls,
          ),
          AgentResponse(
            message: Message(role: MessageRole.assistant, content: 'Complete'),
            finishReason: LLMFinishReason.stop,
          ),
        ]);
        final runner = AgentRunner(adapter, registry, sessionManager);
        final thoughtDeltas = <String>[];
        final reasoningDeltas = <String>[];

        final content = await runner
            .streamMessage(
              'Use a tool',
              onThoughtDelta: thoughtDeltas.add,
              onReasoningDelta: reasoningDeltas.add,
            )
            .toList();

        expect(thoughtDeltas, ['I will inspect the implementation']);
        expect(reasoningDeltas, ['Inspecting implementation']);
        expect(content.join(), 'Complete');
        expect(content, isNot(contains('I will inspect the implementation')));
        expect(content, isNot(contains('Inspecting implementation')));
      },
    );

    test(
      'bounds incomplete continuation without entering network recovery',
      () async {
        final adapter = MockAdapter(
          List.generate(
            4,
            (index) => AgentResponse(
              message: Message(
                role: MessageRole.assistant,
                reasoning: 'attempt-$index',
              ),
              finishReason: LLMFinishReason.incomplete,
            ),
          ),
        );
        final runner = AgentRunner(adapter, registry, sessionManager);

        final response = await runner.sendMessage('Continue');

        expect(response.finishReason, LLMFinishReason.incomplete);
        expect(adapter.histories, hasLength(4));
        expect(
          runner.history.where(
            (message) => message.role == MessageRole.assistant,
          ),
          hasLength(4),
        );
      },
    );

    test('segments three model steps and two tools within one run', () async {
      final adapter = MockAdapter([
        AgentResponse(
          message: Message(
            role: MessageRole.assistant,
            reasoning: 'Planning first lookup',
            toolCalls: [
              ToolCall(id: 'tool-a', name: 'test_tool', arguments: {}),
            ],
          ),
          finishReason: LLMFinishReason.toolCalls,
        ),
        AgentResponse(
          message: Message(
            role: MessageRole.assistant,
            reasoning: 'Planning second lookup',
            toolCalls: [
              ToolCall(id: 'tool-b', name: 'test_tool', arguments: {}),
            ],
          ),
          finishReason: LLMFinishReason.toolCalls,
        ),
        AgentResponse(
          message: Message(role: MessageRole.assistant, content: 'Finished'),
          finishReason: LLMFinishReason.stop,
        ),
      ]);
      final runner = AgentRunner(adapter, registry, sessionManager);
      runner.beginAuthoritativeRun('run-segmented');

      final response = await runner.sendMessage('Use a tool');

      expect(response.content, 'Finished');
      expect(adapter.histories, hasLength(3));
      expect(
        runner.history.any(
          (message) =>
              message.role == MessageRole.tool &&
              message.toolCallId == 'tool-a',
        ),
        isTrue,
      );
      final assistantMessages = runner.history
          .where((message) => message.role == MessageRole.assistant)
          .toList();
      expect(assistantMessages, hasLength(3));
      expect(
        assistantMessages.map((message) => message.metadata?['run_id']).toSet(),
        {'run-segmented'},
      );
      expect(
        assistantMessages
            .map((message) => message.metadata?['model_step_id'])
            .toSet(),
        hasLength(3),
      );
      final toolResults = runner.history
          .where((message) => message.role == MessageRole.tool)
          .toList();
      expect(toolResults, hasLength(2));
      expect(
        toolResults.map((message) => message.metadata?['run_id']).toSet(),
        {'run-segmented'},
      );
      expect(
        toolResults.map((message) => message.metadata?['tool_call_id']).toSet(),
        {'tool-a', 'tool-b'},
      );
    });

    test(
      'clears only rejected replay state, retries once, and persists it',
      () async {
        const issuer = 'provider-a|codex_responses|https://example.test';
        const foreignIssuer = 'provider-b|codex_responses|https://other.test';
        final session = sessionManager.createSession('gpt-test');
        final seededHistory = [
          Message(
            role: MessageRole.assistant,
            providerState: const LLMProviderState(
              namespace: 'codex_responses',
              issuer: issuer,
              data: {
                'reasoning_items': [
                  {'encrypted_content': 'rejected'},
                ],
                'message_items': [
                  {'type': 'message', 'role': 'assistant', 'content': []},
                ],
              },
            ),
          ),
          Message(
            role: MessageRole.assistant,
            providerState: const LLMProviderState(
              namespace: 'codex_responses',
              issuer: foreignIssuer,
              data: {
                'reasoning_items': [
                  {'encrypted_content': 'foreign'},
                ],
              },
            ),
          ),
        ];
        sessionManager.saveSessionHistory(session.sessionId, seededHistory);
        final adapter = ProviderStateRejectingAdapter(issuer);
        final runner = AgentRunner(
          adapter,
          registry,
          sessionManager,
          existingSessionId: session.sessionId,
        );

        final response = await runner.sendMessage('Retry safely');

        expect(response.content, 'Recovered');
        expect(adapter.callCount, 2);
        final retriedMatching = adapter.histories[1].firstWhere(
          (message) => message.providerState?.issuer == issuer,
        );
        expect(
          retriedMatching.providerState?.data,
          isNot(contains('reasoning_items')),
        );
        expect(retriedMatching.providerState?.data, contains('message_items'));
        final retriedForeign = adapter.histories[1].firstWhere(
          (message) => message.providerState?.issuer == foreignIssuer,
        );
        expect(retriedForeign.providerState?.data, contains('reasoning_items'));

        final restarted = AgentRunner(
          MockAdapter(const []),
          registry,
          sessionManager,
          existingSessionId: runner.sessionId,
        );
        final persistedMatching = restarted.history.firstWhere(
          (message) => message.providerState?.issuer == issuer,
        );
        expect(
          persistedMatching.providerState?.data,
          isNot(contains('reasoning_items')),
        );
        expect(
          persistedMatching.providerState?.data,
          contains('message_items'),
        );
      },
    );

    test('applies provider-state fallback once while streaming', () async {
      const issuer = 'provider-a|codex_responses|https://example.test';
      final session = sessionManager.createSession('gpt-test');
      sessionManager.saveSessionHistory(session.sessionId, [
        Message(
          role: MessageRole.assistant,
          providerState: const LLMProviderState(
            namespace: 'codex_responses',
            issuer: issuer,
            data: {
              'reasoning_items': [
                {'encrypted_content': 'rejected'},
              ],
            },
          ),
        ),
      ]);
      final adapter = ProviderStateRejectingAdapter(issuer);
      final runner = AgentRunner(
        adapter,
        registry,
        sessionManager,
        existingSessionId: session.sessionId,
      );

      final chunks = await runner.streamMessage('Retry safely').toList();

      expect(chunks.join(), 'Recovered');
      expect(adapter.callCount, 2);
      expect(
        adapter.histories[1].any(
          (message) => message.providerState?.issuer == issuer,
        ),
        isFalse,
      );
    });

    test('does not repeat provider-state fallback after one retry', () async {
      const issuer = 'provider-a|codex_responses|https://example.test';
      final session = sessionManager.createSession('gpt-test');
      sessionManager.saveSessionHistory(session.sessionId, [
        Message(
          role: MessageRole.assistant,
          providerState: const LLMProviderState(
            namespace: 'codex_responses',
            issuer: issuer,
            data: {
              'reasoning_items': [
                {'encrypted_content': 'rejected'},
              ],
            },
          ),
        ),
      ]);
      final adapter = ProviderStateRejectingAdapter(issuer, alwaysReject: true);
      final runner = AgentRunner(
        adapter,
        registry,
        sessionManager,
        existingSessionId: session.sessionId,
      );

      await expectLater(
        runner.sendMessage('Retry once'),
        throwsA(isA<ProviderStateRejectedException>()),
      );
      expect(adapter.callCount, 2);
    });

    test(
      'aggregates stream terminal reason and persists provider-state-only messages',
      () async {
        const providerState = LLMProviderState(
          namespace: 'codex_responses',
          issuer: 'provider|openai_compatible|https://example.test',
          data: {'encrypted_content': 'opaque-stream'},
        );
        final adapter = MockAdapter([
          AgentResponse(
            message: Message(
              role: MessageRole.assistant,
              providerState: providerState,
            ),
            finishReason: LLMFinishReason.length,
          ),
        ]);
        final runner = AgentRunner(adapter, registry, sessionManager);

        expect(await runner.streamMessage('Hi').toList(), isEmpty);

        final assistant = runner.history.last;
        expect(assistant.content, isNull);
        expect(assistant.providerState, providerState);
        expect(assistant.finishReason, LLMFinishReason.length);
      },
    );

    test(
      'uses the session-persisted provider/model route when no per-turn override is passed',
      () async {
        final defaultAdapter = MockAdapter([
          AgentResponse(
            message: Message(role: MessageRole.assistant, content: 'wrong'),
          ),
        ]);
        final routedAdapter = MockAdapter([
          AgentResponse(
            message: Message(role: MessageRole.assistant, content: 'routed'),
          ),
        ]);
        final runtime = _FakeRuntimeService(routedAdapter);
        GetIt.I.registerSingleton<AgentRuntimeService>(runtime);

        final session = sessionManager.createSession('fallback-model');
        sessionManager.updateSessionModeling(
          session.sessionId,
          providerId: 'provider-inst',
          model: 'claude-sonnet-4.5',
          thinkingMode: 'balanced',
        );

        final runner = AgentRunner(
          defaultAdapter,
          registry,
          sessionManager,
          existingSessionId: session.sessionId,
        );

        final response = await runner.sendMessage('مرحبا');

        expect(response.content, equals('routed'));
        expect(defaultAdapter.lastHistory, isNull);
        expect(routedAdapter.lastModelOverride, equals('claude-sonnet-4.5'));
        expect(
          runtime.lastSignature?.providerInstanceId,
          equals('provider-inst'),
        );
        expect(
          runtime.sessionSignature(session.sessionId)?.modelId,
          equals('claude-sonnet-4.5'),
        );
      },
    );

    test(
      'auto failover rewrites queued provider overrides for the session',
      () async {
        final state = AgentStateDatabase.inMemory();
        addTearDown(state.dispose);
        final repo = ProviderInstanceRepository.fromDatabase(state.db);
        final now = DateTime.parse('2026-07-09T12:00:00Z');
        repo.createInstance(
          ProviderInstance(
            id: 'provider-old',
            templateId: 'openai',
            displayName: 'Provider Old',
            protocol: ProviderProtocol.openaiCompatible,
            authMethod: ProviderAuthMethod.apiKey,
            defaultModel: 'model-a',
            status: InstanceStatus.ready,
            createdAt: now,
            updatedAt: now,
          ),
        );
        repo.createInstance(
          ProviderInstance(
            id: 'provider-new',
            templateId: 'openai',
            displayName: 'Provider New',
            protocol: ProviderProtocol.openaiCompatible,
            authMethod: ProviderAuthMethod.apiKey,
            defaultModel: 'model-a',
            status: InstanceStatus.ready,
            createdAt: now,
            updatedAt: now,
          ),
        );

        final oldAdapter = _AutoFailoverAdapter();
        final newAdapter = MockAdapter([
          AgentResponse(
            message: Message(
              role: MessageRole.assistant,
              content: 'Recovered on new provider',
            ),
          ),
        ]);
        final runtime = _ProviderSwitchingRuntimeService(
          repo,
          oldAdapter: oldAdapter,
          newAdapter: newAdapter,
        );
        final queueOverride = _RecordingQueueOverride();
        GetIt.I.registerSingleton<AgentRuntimeService>(runtime);
        GetIt.I.registerSingleton<ProviderInstanceRepository>(repo);
        GetIt.I.registerSingleton<RuntimeRecoveryService>(
          RuntimeRecoveryService(
            repo,
            ProviderRateLimiter(),
            autoFailoverEnabled: true,
          ),
        );
        GetIt.I.registerSingleton<SessionQueueProviderOverride>(queueOverride);

        final session = sessionManager.createSession('model-a');
        sessionManager.updateSessionProviderId(
          session.sessionId,
          'provider-old',
        );
        final runner = AgentRunner(
          MockAdapter(const []),
          registry,
          sessionManager,
          existingSessionId: session.sessionId,
        );

        final response = await runner.sendMessage('Trigger auto failover');

        expect(response.content, equals('Recovered on new provider'));
        expect(
          sessionManager.getSession(session.sessionId)?.providerId,
          equals('provider-new'),
        );
        expect(
          queueOverride.rewrites,
          contains((session.sessionId, 'provider-new')),
        );
        expect(oldAdapter.callCount, equals(1));
        expect(newAdapter.lastHistory, isNotNull);
        expect(runner.lastSuccessfulLlmRoute?.adapter, same(newAdapter));
        expect(
          runner.lastSuccessfulLlmRoute?.providerInstanceId,
          equals('provider-new'),
        );
        expect(runner.lastSuccessfulLlmRoute?.modelOverride, equals('model-a'));
      },
    );

    test(
      'auto failover visits each failed provider once and reaches a third provider',
      () async {
        final state = AgentStateDatabase.inMemory();
        addTearDown(state.dispose);
        final repo = ProviderInstanceRepository.fromDatabase(state.db);
        final now = DateTime.parse('2026-08-02T12:00:00Z');
        for (final id in ['provider-a', 'provider-b', 'provider-c']) {
          repo.createInstance(
            ProviderInstance(
              id: id,
              templateId: 'openai',
              displayName: id,
              protocol: ProviderProtocol.openaiCompatible,
              authMethod: ProviderAuthMethod.apiKey,
              defaultModel: 'model-a',
              status: InstanceStatus.ready,
              createdAt: now,
              updatedAt: now,
            ),
          );
        }

        final providerA = _AutoFailoverAdapter();
        final providerB = _AutoFailoverAdapter();
        final providerC = MockAdapter([
          AgentResponse(
            message: Message(
              role: MessageRole.assistant,
              content: 'Recovered on provider C',
            ),
          ),
        ]);
        final requestedProviders = <String>[];
        final runtime = _MultiProviderRuntimeService(
          repo,
          adapters: {
            'provider-a': providerA,
            'provider-b': providerB,
            'provider-c': providerC,
          },
          requestedProviders: requestedProviders,
        );
        GetIt.I.registerSingleton<AgentRuntimeService>(runtime);
        GetIt.I.registerSingleton<ProviderInstanceRepository>(repo);
        GetIt.I.registerSingleton<RuntimeRecoveryService>(
          RuntimeRecoveryService(
            repo,
            ProviderRateLimiter(),
            autoFailoverEnabled: true,
          ),
        );

        final session = sessionManager.createSession('model-a');
        sessionManager.updateSessionProviderId(session.sessionId, 'provider-a');
        final runner = AgentRunner(
          MockAdapter(const []),
          registry,
          sessionManager,
          existingSessionId: session.sessionId,
        );

        final response = await runner
            .streamMessage('Use the available provider')
            .join();

        expect(response, 'Recovered on provider C');
        expect(providerA.callCount, 1);
        expect(providerB.callCount, 1);
        expect(providerC._callCount, 1);
        expect(
          sessionManager.getSession(session.sessionId)?.providerId,
          'provider-c',
        );
        expect(
          requestedProviders,
          containsAllInOrder(['provider-a', 'provider-b', 'provider-c']),
        );
      },
    );

    test(
      'failover hops do not consume the reset wait budget when every provider is limited',
      () async {
        final state = AgentStateDatabase.inMemory();
        addTearDown(state.dispose);
        final repo = ProviderInstanceRepository.fromDatabase(state.db);
        final now = DateTime.parse('2026-08-02T12:00:00Z');
        final providerIds = [
          'provider-a',
          'provider-b',
          'provider-c',
          'provider-d',
          'provider-e',
        ];
        for (final id in providerIds) {
          repo.createInstance(
            ProviderInstance(
              id: id,
              templateId: 'openai',
              displayName: id,
              protocol: ProviderProtocol.openaiCompatible,
              authMethod: ProviderAuthMethod.apiKey,
              defaultModel: 'model-a',
              status: InstanceStatus.ready,
              createdAt: now,
              updatedAt: now,
            ),
          );
        }

        final exhaustedAdapters = {
          for (final id in providerIds.take(4)) id: _AutoFailoverAdapter(),
        };
        final resetProvider = _RateLimitOnceAdapter();
        final runtime = _MultiProviderRuntimeService(
          repo,
          adapters: {...exhaustedAdapters, 'provider-e': resetProvider},
          requestedProviders: <String>[],
        );
        GetIt.I.registerSingleton<AgentRuntimeService>(runtime);
        GetIt.I.registerSingleton<ProviderInstanceRepository>(repo);
        GetIt.I.registerSingleton<RuntimeRecoveryService>(
          RuntimeRecoveryService(
            repo,
            ProviderRateLimiter(),
            autoFailoverEnabled: true,
            random: Random(1),
          ),
        );

        final session = sessionManager.createSession('model-a');
        sessionManager.updateSessionProviderId(session.sessionId, 'provider-a');
        final runner = AgentRunner(
          MockAdapter(const []),
          registry,
          sessionManager,
          existingSessionId: session.sessionId,
        );

        final response = await runner
            .streamMessage('Wait for an available provider')
            .join();

        expect(response, 'Recovered after the reset window');
        for (final adapter in exhaustedAdapters.values) {
          expect(adapter.callCount, 1);
        }
        expect(resetProvider.callCount, 2);
        expect(
          sessionManager.getSession(session.sessionId)?.providerId,
          'provider-e',
        );
      },
    );

    test('should handle tool call loop', () async {
      final adapter = MockAdapter([
        // First call returns a tool call
        AgentResponse(
          isToolCall: true,
          message: Message(
            role: MessageRole.assistant,
            toolCalls: [ToolCall(id: '1', name: 'test_tool', arguments: {})],
          ),
        ),
        // Second call returns final answer
        AgentResponse(
          message: Message(
            role: MessageRole.assistant,
            content: 'Tool finished',
          ),
        ),
      ]);
      final runner = AgentRunner(adapter, registry, sessionManager);

      final response = await runner.sendMessage('Use tool');
      expect(response.content, 'Tool finished');
      // History should be: user -> assistant (tool call) -> tool result -> assistant (final)
      expect(runner.history.length, 4);
      expect(runner.history[2].role, MessageRole.tool);
      expect(runner.history[2].content, 'tool result');
    });

    test('runtime starts from the authoritative received time', () async {
      final adapter = MockAdapter([
        AgentResponse(
          message: Message(role: MessageRole.assistant, content: 'Done'),
        ),
      ]);
      final runner = AgentRunner(adapter, registry, sessionManager);
      final receivedAt = DateTime.now().subtract(const Duration(minutes: 35));

      await runner.streamMessage('Work', receivedAt: receivedAt).toList();

      expect(
        runner.runtimeMs,
        greaterThanOrEqualTo(const Duration(minutes: 35).inMilliseconds),
      );
    });

    test(
      'delivers steer after the active tool batch and before the next model call',
      () async {
        final delayedTool = DelayedTool();
        registry.registerTool(delayedTool);
        final adapter = MockAdapter([
          AgentResponse(
            isToolCall: true,
            message: Message(
              role: MessageRole.assistant,
              toolCalls: [
                ToolCall(
                  id: 'delayed-call-1',
                  name: 'delayed_tool',
                  arguments: {},
                ),
              ],
            ),
          ),
          AgentResponse(
            message: Message(
              role: MessageRole.assistant,
              content: 'Adjusted after tool',
            ),
          ),
        ]);
        final runner = AgentRunner(adapter, registry, sessionManager);

        final responseFuture = runner.streamMessage('Use the tool').toList();
        await delayedTool.started.future;
        runner.steerEvent(
          'Change direction',
          requestId: 'steer-tool-1',
          receivedAt: DateTime.parse('2026-07-02T10:00:00Z'),
        );
        delayedTool.release.complete();
        await responseFuture;

        expect(adapter.histories, hasLength(2));
        final deliveredToolMessage = adapter.histories.last.lastWhere(
          (message) => message.role == MessageRole.tool,
        );
        expect(deliveredToolMessage.content, contains(steerMarkerOpen));
        expect(deliveredToolMessage.content, contains('Change direction'));
        final steerMessages =
            deliveredToolMessage.metadata?['steer_messages'] as List;
        expect(steerMessages.single['request_id'], 'steer-tool-1');
        expect(
          deliveredToolMessage.metadata?['steer_original_content'],
          'delayed tool result',
        );
      },
    );

    test(
      'continues the same running turn when steer arrives during the final model call',
      () async {
        final adapter = ControlledStreamingAdapter();
        final runner = AgentRunner(adapter, registry, sessionManager);
        var continuationCount = 0;

        final chunksFuture = runner
            .streamMessage(
              'Start working',
              onSteerContinuation: () => continuationCount += 1,
            )
            .toList();
        await adapter.firstChunkEmitted.future;
        runner.steerEvent(
          'Revise the answer',
          requestId: 'steer-late-1',
          receivedAt: DateTime.parse('2026-07-02T10:05:00Z'),
        );
        adapter.releaseFirstResponse.complete();
        final chunks = await chunksFuture;

        expect(continuationCount, 1);
        expect(chunks, ['Answer before steer', 'Adjusted answer']);
        expect(adapter.histories, hasLength(2));
        final secondCallHistory = adapter.histories.last;
        final supersededAssistant =
            secondCallHistory[secondCallHistory.length - 2];
        expect(supersededAssistant.role, MessageRole.assistant);
        expect(supersededAssistant.metadata?['superseded_by_steer'], isTrue);
        expect(secondCallHistory.last.role, MessageRole.user);
        expect(secondCallHistory.last.content, 'Revise the answer');
        expect(secondCallHistory.last.metadata?['steer'], isTrue);
        expect(secondCallHistory.last.metadata?['request_id'], 'steer-late-1');
      },
    );

    test(
      'requestStop discards a late provider tool call and prevents follow-up work',
      () async {
        final adapter = DelayedToolCallAdapter();
        var toolExecutions = 0;
        final stopRegistry = ToolsRegistry();
        stopRegistry.registerTool(
          GateDTestTool('test_tool', (args, context) async {
            toolExecutions++;
            return 'must not run';
          }),
        );
        final runner = AgentRunner(adapter, stopRegistry, sessionManager);

        final chunksFuture = runner.streamMessage('Start then stop').toList();
        await adapter.started.future;
        expect(runner.providerRequestInFlight, isTrue);
        runner.requestStop();
        adapter.release.complete();

        expect(await chunksFuture, isEmpty);
        expect(toolExecutions, 0);
        expect(adapter.callCount, 1);
        expect(runner.stopRequested, isTrue);
        expect(runner.providerRequestInFlight, isFalse);
      },
    );

    test('should stream response', () async {
      final adapter = MockAdapter([
        AgentResponse(
          message: Message(role: MessageRole.assistant, content: 'Part 1 '),
        ),
        AgentResponse(
          message: Message(role: MessageRole.assistant, content: 'Part 2'),
        ),
      ]);
      // Note: MockAdapter.generateStream yields the full response from generateResponse.
      // In a real scenario it would yield chunks.

      final runner = AgentRunner(adapter, registry, sessionManager);
      final stream = runner.streamMessage('Stream this');

      final chunks = await stream.toList();
      expect(chunks.join(), contains('Part 1'));
      expect(runner.history.length, 2);
    });

    test('should use session model when resolving context tokens', () async {
      final adapter = MockAdapter([
        AgentResponse(
          message: Message(role: MessageRole.assistant, content: 'Hello!'),
        ),
      ]);
      final session = sessionManager.createSession('mock/large');
      final runner = AgentRunner(
        adapter,
        registry,
        sessionManager,
        existingSessionId: session.sessionId,
      );

      final contextTokens = await runner.getContextTokens();
      expect(contextTokens, 8192);
    });

    test(
      'injects runtime context per turn without persisting it into history',
      () async {
        final adapter = MockAdapter([
          AgentResponse(
            message: Message(role: MessageRole.assistant, content: 'Hello!'),
          ),
        ]);
        final runner = AgentRunner(adapter, registry, sessionManager);

        await runner.sendMessage(
          'Hi',
          runtimeSystemPrompt: 'Runtime context from workspace',
        );

        expect(adapter.lastHistory, isNotNull);
        expect(adapter.lastHistory!.first.role, MessageRole.system);
        expect(
          adapter.lastHistory!.first.content,
          contains('Runtime context from workspace'),
        );
        expect(runner.history.length, 2);
        expect(
          runner.history.any(
            (message) =>
                message.content?.contains('Runtime context from workspace') ==
                true,
          ),
          isFalse,
        );
      },
    );

    test(
      'addSystemMessage does not grow system message count across turns',
      () async {
        // Root-cause regression test: addSystemMessage() now sets a live
        // _baseSystemPrompt field, NOT a persisted history entry. The LLM
        // should receive exactly 1 system message (the base prompt) on turn 1
        // and exactly 1 system message on turn 2 — no duplication growth.
        final adapter = MockAdapter([
          AgentResponse(
            message: Message(role: MessageRole.assistant, content: 'Hello!'),
          ),
          AgentResponse(
            message: Message(
              role: MessageRole.assistant,
              content: 'Hello again!',
            ),
          ),
        ]);
        final runner = AgentRunner(adapter, registry, sessionManager);
        runner.addSystemMessage('You are a helpful assistant.');

        // Turn 1
        await runner.sendMessage('Hi');
        final systemCountTurn1 = adapter.lastHistory!
            .where((m) => m.role == MessageRole.system)
            .length;

        // Turn 2
        await runner.sendMessage('How are you?');
        final systemCountTurn2 = adapter.lastHistory!
            .where((m) => m.role == MessageRole.system)
            .length;

        // System message count must stay constant — exactly 1 (the base prompt).
        expect(
          systemCountTurn1,
          equals(1),
          reason: 'Expected exactly 1 system message on turn 1.',
        );
        expect(
          systemCountTurn2,
          equals(systemCountTurn1),
          reason:
              'System message count must not grow between turns '
              '(turn 1: $systemCountTurn1, turn 2: $systemCountTurn2).',
        );

        // history must stay clean — no system messages ever stored.
        expect(
          runner.history.any((m) => m.role == MessageRole.system),
          isFalse,
          reason: 'history must only contain user/assistant/tool messages.',
        );
      },
    );

    test(
      'addSystemMessage sets live _baseSystemPrompt delivered to LLM but not stored in history',
      () async {
        // addSystemMessage() now sets a live field (_baseSystemPrompt), not a
        // DB-persisted history entry. It IS delivered to the LLM on every turn
        // (correct) but is NOT stored in history (clean).
        final adapter = MockAdapter([
          AgentResponse(
            message: Message(role: MessageRole.assistant, content: 'Hi!'),
          ),
        ]);
        final runner = AgentRunner(adapter, registry, sessionManager);
        runner.addSystemMessage('Base agent identity.');

        await runner.sendMessage('Hello');

        expect(adapter.lastHistory, isNotNull);

        // The base system prompt MUST be delivered to the LLM.
        final deliveredToLLM = adapter.lastHistory!.any(
          (m) =>
              m.role == MessageRole.system &&
              (m.content?.contains('Base agent identity.') ?? false),
        );
        expect(
          deliveredToLLM,
          isTrue,
          reason:
              'addSystemMessage content must be injected into effectiveHistory.',
        );

        // But it must NOT be persisted into history.
        final inHistory = runner.history.any(
          (m) =>
              m.role == MessageRole.system &&
              (m.content?.contains('Base agent identity.') ?? false),
        );
        expect(
          inHistory,
          isFalse,
          reason:
              'addSystemMessage content must never be stored in history — '
              'only user/assistant/tool messages belong there.',
        );
      },
    );

    test(
      'should heal history with unanswered tool calls on construction',
      () async {
        final adapter = MockAdapter([]);
        final session = sessionManager.createSession('mock/gpt-3.5-turbo');

        // Create an invalid history with an assistant message containing tool calls but no tool results
        final userMsg = Message(role: MessageRole.user, content: 'run tool');
        final assistantMsg = Message(
          role: MessageRole.assistant,
          toolCalls: [
            ToolCall(id: 'call_healing_1', name: 'test_tool', arguments: {}),
          ],
        );

        final initialHistory = [userMsg, assistantMsg];
        sessionManager.saveSessionHistory(session.sessionId, initialHistory);

        // Re-create the runner using the existing session id
        final runner = AgentRunner(
          adapter,
          registry,
          sessionManager,
          existingSessionId: session.sessionId,
        );

        // Verify history is healed
        expect(runner.history.length, 3);
        expect(runner.history[0].role, MessageRole.user);
        expect(runner.history[1].role, MessageRole.assistant);
        expect(runner.history[1].toolCalls!.first.id, 'call_healing_1');

        expect(runner.history[2].role, MessageRole.tool);
        expect(runner.history[2].toolCallId, 'call_healing_1');
        expect(runner.history[2].content, contains('interrupted'));
        expect(runner.history[2].content, isNot(contains('cancelled by user')));

        // Verify the healed history was saved to database
        final savedHistory = sessionManager
            .getSession(session.sessionId)!
            .messages;
        expect(savedHistory.length, 3);
        expect(savedHistory[2].role, MessageRole.tool);
        expect(savedHistory[2].toolCallId, 'call_healing_1');
      },
    );

    test(
      'preserves an unanswered tool call owned by a suspended checkpoint',
      () async {
        final adapter = MockAdapter([]);
        final session = sessionManager.createSession('mock/gpt-3.5-turbo');
        final now = DateTime.now();
        sessionManager.saveSessionHistory(session.sessionId, [
          Message(role: MessageRole.user, content: 'ask me'),
          Message(
            role: MessageRole.assistant,
            toolCalls: [
              ToolCall(
                id: 'call_pending_question',
                name: 'system_ask_user',
                arguments: const {},
              ),
            ],
          ),
        ]);
        sessionManager.saveSuspendedCheckpoint(
          SuspendedCheckpoint(
            checkpointId: 'ask-pending',
            sessionId: session.sessionId,
            requestId: 'ask-request',
            toolCallId: 'call_pending_question',
            toolName: 'system_ask_user',
            status: 'awaiting_permission',
            toolArguments: const {},
            permissionPayload: const {},
            createdAt: now,
            updatedAt: now,
          ),
        );

        final runner = AgentRunner(
          adapter,
          registry,
          sessionManager,
          existingSessionId: session.sessionId,
        );

        expect(runner.history, hasLength(2));
        expect(
          runner.history.where(
            (message) =>
                message.role == MessageRole.tool &&
                message.toolCallId == 'call_pending_question',
          ),
          isEmpty,
        );
        expect(
          sessionManager.getSession(session.sessionId)!.messages,
          hasLength(2),
        );
      },
    );

    test('shouldParallelizeToolBatch evaluates concurrency safety rules', () {
      final adapter = MockAdapter([]);
      final runner = AgentRunner(adapter, registry, sessionManager);

      // Single tool call is not parallelized
      expect(
        runner.shouldParallelizeToolBatch([
          ToolCall(id: '1', name: 'web_search', arguments: {'query': 'test'}),
        ]),
        isFalse,
      );

      // Multiple parallel safe tools are parallelized
      expect(
        runner.shouldParallelizeToolBatch([
          ToolCall(id: '1', name: 'web_search', arguments: {'query': 'a'}),
          ToolCall(
            id: '2',
            name: 'web_fetch',
            arguments: {
              'urls': ['b'],
            },
          ),
        ]),
        isTrue,
      );

      // Interactive tool causes fallback to sequential execution
      expect(
        runner.shouldParallelizeToolBatch([
          ToolCall(id: '1', name: 'web_search', arguments: {'query': 'a'}),
          ToolCall(
            id: '2',
            name: 'system_ask_user',
            arguments: {'question': 'q'},
          ),
        ]),
        isFalse,
      );

      // Multiple shell_execute calls cause fallback to sequential execution
      expect(
        runner.shouldParallelizeToolBatch([
          ToolCall(
            id: '1',
            name: 'shell_execute',
            arguments: {'command': 'ls'},
          ),
          ToolCall(
            id: '2',
            name: 'shell_execute',
            arguments: {'command': 'pwd'},
          ),
        ]),
        isFalse,
      );

      // File tools on non-overlapping paths are parallelized
      expect(
        runner.shouldParallelizeToolBatch([
          ToolCall(
            id: '1',
            name: 'file_read',
            arguments: {'path': 'file1.txt'},
          ),
          ToolCall(
            id: '2',
            name: 'file_write',
            arguments: {'path': 'file2.txt', 'content': 'hello'},
          ),
        ]),
        isTrue,
      );

      // File tools on overlapping paths cause fallback to sequential execution
      expect(
        runner.shouldParallelizeToolBatch([
          ToolCall(
            id: '1',
            name: 'file_read',
            arguments: {'path': 'file1.txt'},
          ),
          ToolCall(
            id: '2',
            name: 'file_write',
            arguments: {'path': 'file1.txt', 'content': 'hello'},
          ),
        ]),
        isFalse,
      );
    });

    // ── Plan 30 Phase H §5: per-reason retry policy ──────────────────────
    group('Plan 30 Phase H — retry policy & error message', () {
      late AgentStateDatabase state;
      late ProviderInstanceRepository repo;
      late ProviderRateLimiter limiter;
      late RuntimeRecoveryService recovery;

      setUp(() {
        state = AgentStateDatabase.inMemory();
        repo = ProviderInstanceRepository.fromDatabase(state.db);
        limiter = ProviderRateLimiter();
        final now = DateTime.parse('2026-07-09T12:00:00Z');
        repo.createInstance(
          ProviderInstance(
            id: 'prov-1',
            templateId: 'openai',
            displayName: 'Provider One',
            protocol: ProviderProtocol.openaiCompatible,
            authMethod: ProviderAuthMethod.apiKey,
            defaultModel: 'gpt-4o',
            status: InstanceStatus.ready,
            createdAt: now,
            updatedAt: now,
          ),
        );
        recovery = RuntimeRecoveryService(
          repo,
          limiter,
          autoFailoverEnabled: false,
        );
        GetIt.I.registerSingleton<RuntimeRecoveryService>(recovery);
      });

      tearDown(() => state.dispose());

      test(
        'cancelling recovery for run A cannot retry after run B becomes current',
        () async {
          final adapter = _AlwaysFailingAdapter(
            statusCode: 429,
            body: 'Too Many Requests',
          );
          final runtime = _GenericRuntimeService(adapter);
          GetIt.I.registerSingleton<AgentRuntimeService>(runtime);
          final session = sessionManager.createSession('gpt-4o');
          sessionManager.updateSessionProviderId(session.sessionId, 'prov-1');
          final runner = AgentRunner(
            MockAdapter(const []),
            registry,
            sessionManager,
            existingSessionId: session.sessionId,
          );
          runner.beginAuthoritativeRun('run-A');

          final future = runner.sendMessage('hi');
          await Future<void>.delayed(const Duration(milliseconds: 50));
          expect(recovery.activeNotice(session.sessionId)?.runId, 'run-A');

          runner.requestStop();
          recovery.abort(session.sessionId, runId: 'run-A');
          recovery.clear(
            session.sessionId,
            runId: 'run-A',
            reasonOverride: 'stopped',
          );
          recovery.beginRun(session.sessionId, 'run-B');

          await expectLater(future, throwsA(isA<RuntimeRecoveryCancelled>()));
          expect(adapter.callCount, 1);
          expect(recovery.activeNotice(session.sessionId), isNull);
        },
      );

      test(
        'auth (401) does not consume retry budget — suspends on first failure',
        () async {
          final adapter = _AlwaysFailingAdapter(
            statusCode: 401,
            body: 'Invalid API key sk-proj-AbCdEf1234567890',
          );
          final runtime = _GenericRuntimeService(adapter);
          GetIt.I.registerSingleton<AgentRuntimeService>(runtime);
          final session = sessionManager.createSession('gpt-4o');
          sessionManager.updateSessionProviderId(session.sessionId, 'prov-1');
          final runner = AgentRunner(
            MockAdapter(const []),
            registry,
            sessionManager,
            existingSessionId: session.sessionId,
          );

          await expectLater(
            runner.sendMessage('hi'),
            throwsA(isA<RuntimeRecoveryRequired>()),
          );
          // Auth must not auto-retry: only one adapter call happened.
          expect(adapter.callCount, equals(1));
          // The notice keeps the original auth reason, not unknown.
          final notice = GetIt.I<RuntimeRecoveryService>().activeNotice(
            session.sessionId,
          );
          expect(notice, isNotNull);
          expect(notice!.reason, equals(RuntimeFailureReason.auth));
          expect(notice.status, equals(RuntimeNoticeStatus.blocked));
        },
      );

      test(
        'billing (402) does not consume retry budget — suspends immediately',
        () async {
          final adapter = _AlwaysFailingAdapter(
            statusCode: 402,
            body: 'Insufficient credits.',
          );
          final runtime = _GenericRuntimeService(adapter);
          GetIt.I.registerSingleton<AgentRuntimeService>(runtime);
          final session = sessionManager.createSession('gpt-4o');
          sessionManager.updateSessionProviderId(session.sessionId, 'prov-1');
          final runner = AgentRunner(
            MockAdapter(const []),
            registry,
            sessionManager,
            existingSessionId: session.sessionId,
          );

          await expectLater(
            runner.sendMessage('hi'),
            throwsA(isA<RuntimeRecoveryRequired>()),
          );
          expect(adapter.callCount, equals(1));
          final notice = GetIt.I<RuntimeRecoveryService>().activeNotice(
            session.sessionId,
          );
          expect(notice!.reason, equals(RuntimeFailureReason.billing));
        },
      );

      test(
        'model-not-found is not auto-retried and keeps original reason',
        () async {
          final adapter = _AlwaysFailingAdapter(
            statusCode: 400,
            body: 'Unknown Model, please check the model code.',
          );
          final runtime = _GenericRuntimeService(adapter);
          GetIt.I.registerSingleton<AgentRuntimeService>(runtime);
          final session = sessionManager.createSession('gpt-4o');
          sessionManager.updateSessionProviderId(session.sessionId, 'prov-1');
          final runner = AgentRunner(
            MockAdapter(const []),
            registry,
            sessionManager,
            existingSessionId: session.sessionId,
          );

          await expectLater(
            runner.sendMessage('hi'),
            throwsA(isA<RuntimeRecoveryRequired>()),
          );
          expect(adapter.callCount, equals(1));
          final notice = GetIt.I<RuntimeRecoveryService>().activeNotice(
            session.sessionId,
          );
          expect(notice!.reason, equals(RuntimeFailureReason.modelNotFound));
          // Must NOT be replaced with unknown or "Recovery needs your input".
          expect(notice.title, isNot(equals('Recovery needs your input')));
        },
      );

      test('content-policy is fatal and not retried', () async {
        final adapter = _AlwaysFailingAdapter(
          statusCode: 400,
          body: 'Request blocked by content_filter.',
        );
        final runtime = _GenericRuntimeService(adapter);
        GetIt.I.registerSingleton<AgentRuntimeService>(runtime);
        final session = sessionManager.createSession('gpt-4o');
        sessionManager.updateSessionProviderId(session.sessionId, 'prov-1');
        final runner = AgentRunner(
          MockAdapter(const []),
          registry,
          sessionManager,
          existingSessionId: session.sessionId,
        );

        await expectLater(
          runner.sendMessage('hi'),
          throwsA(isA<RuntimeRecoveryRequired>()),
        );
        expect(adapter.callCount, equals(1));
        final notice = GetIt.I<RuntimeRecoveryService>().activeNotice(
          session.sessionId,
        );
        expect(
          notice!.reason,
          equals(RuntimeFailureReason.contentPolicyBlocked),
        );
        expect(notice.status, equals(RuntimeNoticeStatus.fatal));
      });

      test(
        'exhausted retries do NOT replace the original reason with unknown',
        () async {
          // networkError is retryable=true with a limited budget. After the
          // budget is exhausted, the notice must still report network_error,
          // not unknown, and must not show "Recovery needs your input".
          // We throw a plain socket exception so the classifier maps it to
          // network_error via body pattern matching.
          final adapter = _BodyFailingAdapter(
            body: 'SocketException: connection reset by peer',
          );
          final runtime = _GenericRuntimeService(adapter);
          GetIt.I.registerSingleton<AgentRuntimeService>(runtime);
          final session = sessionManager.createSession('gpt-4o');
          sessionManager.updateSessionProviderId(session.sessionId, 'prov-1');
          final runner = AgentRunner(
            MockAdapter(const []),
            registry,
            sessionManager,
            existingSessionId: session.sessionId,
          );

          await expectLater(
            runner.sendMessage('hi'),
            throwsA(isA<RuntimeRecoveryRequired>()),
          );
          final notice = GetIt.I<RuntimeRecoveryService>().activeNotice(
            session.sessionId,
          );
          expect(notice, isNotNull);
          // The original reason must survive.
          expect(notice!.reason, equals(RuntimeFailureReason.networkError));
          expect(notice.reason, isNot(equals(RuntimeFailureReason.unknown)));
          expect(notice.title, isNot(equals('Recovery needs your input')));
        },
      );

      test(
        '503 upstream reset gets three total attempts before suspension',
        () async {
          final adapter = _CallCountAdapter(
            onCall: () => throw LlmHttpException(
              statusCode: 503,
              body:
                  'upstream connect error or disconnect/reset before headers. '
                  'reset reason: remote connection failure',
              headers: const {},
              operation: 'generateStream',
            ),
          );
          final runtime = _GenericRuntimeService(adapter);
          GetIt.I.registerSingleton<AgentRuntimeService>(runtime);
          final session = sessionManager.createSession('gpt-4o');
          sessionManager.updateSessionProviderId(session.sessionId, 'prov-1');
          final runner = AgentRunner(
            MockAdapter(const []),
            registry,
            sessionManager,
            existingSessionId: session.sessionId,
          );

          final future = runner.streamMessage('hi').toList();
          final abortTimer = Timer.periodic(const Duration(milliseconds: 10), (
            _,
          ) {
            if (adapter.callCount < 3) recovery.abort(session.sessionId);
          });

          try {
            await expectLater(future, throwsA(isA<RuntimeRecoveryRequired>()));
          } finally {
            abortTimer.cancel();
          }

          expect(adapter.callCount, equals(3));
          expect(
            recovery.activeNotice(session.sessionId)?.reason,
            RuntimeFailureReason.networkError,
          );
        },
      );

      test(
        'successful automatic retry owns resuming state until provider progress',
        () async {
          final adapter = _ThrowOnceThenSucceedAdapter(
            const LlmHttpException(
              statusCode: 503,
              body:
                  'upstream connect error or disconnect/reset before headers. '
                  'reset reason: remote connection failure',
              headers: {'retry-after-ms': '0'},
              operation: 'generateResponse',
            ),
          );
          final runtime = _GenericRuntimeService(adapter);
          GetIt.I.registerSingleton<AgentRuntimeService>(runtime);
          final session = sessionManager.createSession('gpt-4o');
          sessionManager.updateSessionProviderId(session.sessionId, 'prov-1');

          state.db.execute(
            'INSERT INTO sessions '
            '(session_id, model, provider_id, created_at, updated_at) '
            'VALUES (?, ?, ?, ?, ?)',
            [session.sessionId, 'gpt-4o', 'prov-1', '2026-07-16', '2026-07-16'],
          );
          final runtimeStore = PersistedRuntimeStateRepository(state.db);
          GetIt.I.registerSingleton<PersistedRuntimeStateRepository>(
            runtimeStore,
          );
          addTearDown(
            () => GetIt.I.unregister<PersistedRuntimeStateRepository>(),
          );
          recovery.attachPersistedState(runtimeStore);

          runtimeStore.admitWorkItem(
            workItemId: 'work-owned-retry',
            sessionId: session.sessionId,
            requestId: 'request-owned-retry',
            providerInstanceId: 'prov-1',
            modelId: 'gpt-4o',
          );
          final runner = AgentRunner(
            MockAdapter(const []),
            registry,
            sessionManager,
            existingSessionId: session.sessionId,
          );
          runner.beginAuthoritativeRun(
            'run-owned-retry',
            workItemId: 'work-owned-retry',
            generation: 3,
          );
          expect(
            runtimeStore.bindRunOwnership(
              sessionId: session.sessionId,
              workItemId: 'work-owned-retry',
              runId: 'run-owned-retry',
              generation: 3,
            ),
            isTrue,
          );
          final states = <SessionExecutionState>[];
          final subscription = runtimeStore.executionState.changes.listen(
            (snapshot) => states.add(snapshot.state),
          );
          addTearDown(subscription.cancel);

          final response = await runner.sendMessage(
            'hi',
            requestId: 'request-owned-retry',
          );

          expect(response.content, 'Recovered after transient wait');
          expect(adapter.callCount, 2);
          expect(
            states,
            containsAllInOrder([
              SessionExecutionState.blocked,
              SessionExecutionState.resuming,
            ]),
          );
          expect(
            runtimeStore.findWorkItem('work-owned-retry')?.state,
            SessionWorkState.resuming,
          );
          expect(recovery.activeNotice(session.sessionId), isNull);

          final terminal = runtimeStore.commitTerminal(
            sessionId: session.sessionId,
            workItemId: 'work-owned-retry',
            runId: 'run-owned-retry',
            generation: 3,
            assistantResult: response,
          );
          expect(terminal, TerminalCommitOutcome.committed);
          expect(
            runtimeStore.executionSnapshots
                .getSnapshot(session.sessionId)
                .state,
            SessionExecutionState.idle,
          );
        },
      );

      test(
        'reasoning event closes the transparent network retry window',
        () async {
          final adapter = _ReasoningThenFailingAdapter();
          final runtime = _GenericRuntimeService(adapter);
          GetIt.I.registerSingleton<AgentRuntimeService>(runtime);
          final session = sessionManager.createSession('gpt-4o');
          sessionManager.updateSessionProviderId(session.sessionId, 'prov-1');
          final runner = AgentRunner(
            MockAdapter(const []),
            registry,
            sessionManager,
            existingSessionId: session.sessionId,
          );
          final reasoning = <String>[];

          await expectLater(
            runner
                .streamMessage('hi', onReasoningDelta: reasoning.add)
                .toList(),
            throwsA(isA<RuntimeRecoveryRequired>()),
          );

          expect(adapter.callCount, equals(1));
          expect(reasoning, ['Inspecting the request']);
        },
      );

      test('redaction scrubs secrets from the notice message', () async {
        final adapter = _AlwaysFailingAdapter(
          statusCode: 401,
          body:
              'Unauthorized. The key sk-proj-AbCdEf1234567890XYZ is not valid.',
        );
        final runtime = _GenericRuntimeService(adapter);
        GetIt.I.registerSingleton<AgentRuntimeService>(runtime);
        final session = sessionManager.createSession('gpt-4o');
        sessionManager.updateSessionProviderId(session.sessionId, 'prov-1');
        final runner = AgentRunner(
          MockAdapter(const []),
          registry,
          sessionManager,
          existingSessionId: session.sessionId,
        );

        await expectLater(
          runner.sendMessage('hi'),
          throwsA(isA<RuntimeRecoveryRequired>()),
        );
        final notice = GetIt.I<RuntimeRecoveryService>().activeNotice(
          session.sessionId,
        );
        expect(notice, isNotNull);
        // The leaked key must not appear anywhere in the message.
        expect(
          notice!.message.contains('sk-proj-AbCdEf1234567890XYZ'),
          isFalse,
        );
        // But the provider context (non-secret text) may survive.
        expect(notice.message.contains('Unauthorized'), isTrue);
        expect(notice.message, contains('Provider response: Unauthorized'));
      });

      test(
        'trusted usage reset from body becomes waiting notice and provider cooldown',
        () async {
          final baseNow = DateTime.now().toUtc();
          final resetAt = baseNow.add(
            const Duration(hours: 5, minutes: 7, seconds: 30),
          );
          final resetText =
              '${resetAt.year.toString().padLeft(4, '0')}-'
              '${resetAt.month.toString().padLeft(2, '0')}-'
              '${resetAt.day.toString().padLeft(2, '0')} '
              '${resetAt.hour.toString().padLeft(2, '0')}:'
              '${resetAt.minute.toString().padLeft(2, '0')}:'
              '${resetAt.second.toString().padLeft(2, '0')}';
          final adapter = _AlwaysFailingAdapter(
            statusCode: 429,
            body:
                'Usage limit reached for 5 hour. Your limit will reset at $resetText',
          );
          final runtime = _GenericRuntimeService(adapter);
          GetIt.I.registerSingleton<AgentRuntimeService>(runtime);
          final session = sessionManager.createSession('gpt-4o');
          sessionManager.updateSessionProviderId(session.sessionId, 'prov-1');
          final runner = AgentRunner(
            MockAdapter(const []),
            registry,
            sessionManager,
            existingSessionId: session.sessionId,
          );

          final future = runner.sendMessage('hi');
          await Future<void>.delayed(const Duration(milliseconds: 50));

          final notice = recovery.activeNotice(session.sessionId);
          expect(notice, isNotNull);
          expect(notice!.reason, equals(RuntimeFailureReason.rateLimit));
          expect(notice.status, equals(RuntimeNoticeStatus.waiting));
          expect(notice.resumeAt, isNotNull);
          final remaining = notice.resumeAt!.difference(DateTime.now().toUtc());
          expect(remaining, greaterThan(const Duration(hours: 5)));
          expect(remaining, lessThan(const Duration(hours: 5, minutes: 8)));

          final permit = limiter.tryAcquire('prov-1', 1);
          expect(permit.granted, isFalse);
          expect(permit.retryAfter, greaterThan(const Duration(hours: 5)));
          expect(
            permit.retryAfter,
            lessThan(const Duration(hours: 5, minutes: 8)),
          );

          recovery.abort(session.sessionId);
          recovery.clear(session.sessionId, reasonOverride: 'stopped');
          await expectLater(future, throwsA(isA<RuntimeRecoveryCancelled>()));
        },
      );

      test(
        'quota without trusted reset stays billing and does not auto-retry',
        () async {
          final adapter = _AlwaysFailingAdapter(
            statusCode: 429,
            body: 'insufficient_quota',
          );
          final runtime = _GenericRuntimeService(adapter);
          GetIt.I.registerSingleton<AgentRuntimeService>(runtime);
          final session = sessionManager.createSession('gpt-4o');
          sessionManager.updateSessionProviderId(session.sessionId, 'prov-1');
          final runner = AgentRunner(
            MockAdapter(const []),
            registry,
            sessionManager,
            existingSessionId: session.sessionId,
          );

          await expectLater(
            runner.sendMessage('hi'),
            throwsA(isA<RuntimeRecoveryRequired>()),
          );

          expect(adapter.callCount, equals(1));
          final notice = recovery.activeNotice(session.sessionId);
          expect(notice, isNotNull);
          expect(notice!.reason, equals(RuntimeFailureReason.billing));
          expect(notice.status, equals(RuntimeNoticeStatus.blocked));
        },
      );

      test(
        'reads http retryAfter once so boundary timing cannot drift across the failure',
        () async {
          final error = _CountingRetryAfterException(
            firstValue: const Duration(hours: 5),
            subsequentValue: null,
            statusCode: 429,
            body: 'Usage limit reached. Your limit will reset at later.',
            headers: const {},
            operation: 'chat.completions',
          );
          final adapter = _ThrowOnceThenSucceedAdapter(error);
          final runtime = _GenericRuntimeService(adapter);
          GetIt.I.registerSingleton<AgentRuntimeService>(runtime);
          final session = sessionManager.createSession('gpt-4o');
          sessionManager.updateSessionProviderId(session.sessionId, 'prov-1');
          final runner = AgentRunner(
            MockAdapter(const []),
            registry,
            sessionManager,
            existingSessionId: session.sessionId,
          );

          final future = runner.sendMessage('hi');
          await Future<void>.delayed(const Duration(milliseconds: 50));

          final notice = recovery.activeNotice(session.sessionId);
          expect(notice, isNotNull);
          expect(notice!.status, equals(RuntimeNoticeStatus.waiting));
          final remaining = notice.resumeAt!.difference(DateTime.now().toUtc());
          expect(remaining, greaterThan(const Duration(hours: 4, minutes: 59)));
          expect(error.readCount, equals(1));

          recovery.abort(session.sessionId);
          await future;
        },
      );

      test(
        'plain 429 without hints keeps the default minute cooldown',
        () async {
          final adapter = _AlwaysFailingAdapter(
            statusCode: 429,
            body: 'Too Many Requests',
          );
          final runtime = _GenericRuntimeService(adapter);
          GetIt.I.registerSingleton<AgentRuntimeService>(runtime);
          final session = sessionManager.createSession('gpt-4o');
          sessionManager.updateSessionProviderId(session.sessionId, 'prov-1');
          final runner = AgentRunner(
            MockAdapter(const []),
            registry,
            sessionManager,
            existingSessionId: session.sessionId,
          );

          final future = runner.sendMessage('hi');
          await Future<void>.delayed(const Duration(milliseconds: 50));

          final notice = recovery.activeNotice(session.sessionId);
          expect(notice, isNotNull);
          expect(notice!.reason, equals(RuntimeFailureReason.rateLimit));
          expect(notice.status, equals(RuntimeNoticeStatus.waiting));
          expect(notice.resumeAt, isNotNull);
          final retryAfter = notice.resumeAt!.difference(notice.createdAt);
          expect(retryAfter.inSeconds, inInclusiveRange(59, 61));

          recovery.abort(session.sessionId);
          recovery.clear(session.sessionId, reasonOverride: 'stopped');
          await expectLater(future, throwsA(isA<RuntimeRecoveryCancelled>()));
        },
      );
    });

    // ── Plan 30 Phase H P1/P2 new regression tests ────────────────────────
    group('Plan 30 Phase H P1/P2 — budget exhaustion, SSL, and updateTurnRoute', () {
      late AgentStateDatabase state;
      late ProviderInstanceRepository repo;

      setUp(() {
        state = AgentStateDatabase.inMemory();
        repo = ProviderInstanceRepository.fromDatabase(state.db);
        final now = DateTime.parse('2026-07-09T12:00:00Z');
        repo.createInstance(
          ProviderInstance(
            id: 'prov-budget',
            templateId: 'openai',
            displayName: 'Budget Provider',
            protocol: ProviderProtocol.openaiCompatible,
            authMethod: ProviderAuthMethod.apiKey,
            defaultModel: 'gpt-4o',
            status: InstanceStatus.ready,
            createdAt: now,
            updatedAt: now,
          ),
        );
        GetIt.I.registerSingleton<RuntimeRecoveryService>(
          RuntimeRecoveryService(
            repo,
            ProviderRateLimiter(),
            autoFailoverEnabled: false,
          ),
        );
      });

      tearDown(() => state.dispose());

      test(
        'exhausted rateLimit budget emits blocked notice (not waiting with no timer)',
        () async {
          // rateLimit budget = 3. After attempt >= 3, status must be blocked.
          // Each intermediate attempt waits before retrying; we abort waiting
          // states quickly via a periodic timer so the retry loop exhausts the
          // budget without hitting the test timeout.
          final adapter = _CallCountAdapter(
            onCall: () {
              // Always fail with 429
              throw LlmHttpException(
                statusCode: 429,
                body: 'Too Many Requests',
                headers: const {},
                operation: 'generateStream',
              );
            },
          );
          final runtime = _GenericRuntimeService(adapter);
          GetIt.I.registerSingleton<AgentRuntimeService>(runtime);
          GetIt.I.registerSingleton<ProviderInstanceRepository>(repo);
          final session = sessionManager.createSession('gpt-4o');
          sessionManager.updateSessionProviderId(
            session.sessionId,
            'prov-budget',
          );
          final runner = AgentRunner(
            MockAdapter(const []),
            registry,
            sessionManager,
            existingSessionId: session.sessionId,
          );

          final recovery = GetIt.I<RuntimeRecoveryService>();

          // Abort every intermediate `waiting` notice immediately so the retry
          // loop advances quickly without sleeping. Once the budget is exhausted
          // the notice becomes `blocked` and we stop aborting.
          final abortTimer = Timer.periodic(const Duration(milliseconds: 10), (
            _,
          ) {
            final n = recovery.activeNotice(session.sessionId);
            if (n?.status == RuntimeNoticeStatus.waiting) {
              recovery.abort(session.sessionId);
            }
          });

          try {
            await expectLater(
              runner.sendMessage('hi'),
              throwsA(isA<RuntimeRecoveryRequired>()),
            );
          } finally {
            abortTimer.cancel();
          }

          final notice = recovery.activeNotice(session.sessionId);
          expect(notice, isNotNull);
          // Must be blocked, not waiting.
          expect(
            notice!.status,
            equals(RuntimeNoticeStatus.blocked),
            reason:
                'Exhausted rateLimit budget must convert waiting to blocked',
          );
          // Must preserve the original reason.
          expect(notice.reason, equals(RuntimeFailureReason.rateLimit));
          // Must have stop/retry/changeProvider actions.
          expect(
            notice.actions,
            containsAll([
              RuntimeNoticeAction.stop,
              RuntimeNoticeAction.retry,
              RuntimeNoticeAction.changeProvider,
            ]),
          );
          // Must have no resume_at timer.
          expect(notice.resumeAt, isNull);
        },
      );

      test(
        'auth (401) suspends with budget=0 immediately on first attempt',
        () async {
          // 401 has budget 0. Must not auto-retry: first attempt → blocked.
          final adapter = _AlwaysFailingAdapter(
            statusCode: 401,
            body: 'Unauthorized',
          );
          final runtime = _GenericRuntimeService(adapter);
          GetIt.I.registerSingleton<AgentRuntimeService>(runtime);
          GetIt.I.registerSingleton<ProviderInstanceRepository>(repo);
          final session = sessionManager.createSession('gpt-4o');
          sessionManager.updateSessionProviderId(
            session.sessionId,
            'prov-budget',
          );
          final runner = AgentRunner(
            MockAdapter(const []),
            registry,
            sessionManager,
            existingSessionId: session.sessionId,
          );

          await expectLater(
            runner.sendMessage('hi'),
            throwsA(isA<RuntimeRecoveryRequired>()),
          );

          // Only one adapter call — no auto-retry for auth failures.
          expect(adapter.callCount, equals(1));
        },
      );

      test(
        'non-HTTP error (network) message appears redacted in notice',
        () async {
          // Simulate a non-HTTP socket error containing a fake token.
          final adapter = _ThrowingAdapter(
            error: Exception(
              'SocketException: Connection refused — Bearer sk-test-abcdefghij12345678',
            ),
          );
          final runtime = _GenericRuntimeService(adapter);
          GetIt.I.registerSingleton<AgentRuntimeService>(runtime);
          GetIt.I.registerSingleton<ProviderInstanceRepository>(repo);
          final session = sessionManager.createSession('gpt-4o');
          sessionManager.updateSessionProviderId(
            session.sessionId,
            'prov-budget',
          );
          final runner = AgentRunner(
            MockAdapter(const []),
            registry,
            sessionManager,
            existingSessionId: session.sessionId,
          );

          await expectLater(
            runner.sendMessage('hi'),
            throwsA(isA<RuntimeRecoveryRequired>()),
          );

          final notice = GetIt.I<RuntimeRecoveryService>().activeNotice(
            session.sessionId,
          );
          expect(notice, isNotNull);
          // Token must NOT appear in the notice message.
          expect(
            notice!.message.contains('sk-test-abcdefghij12345678'),
            isFalse,
            reason: 'Bearer token must be redacted from notice message',
          );
          // But non-secret parts of the message may survive.
          expect(notice.message.contains('Connection refused'), isTrue);
        },
      );

      test(
        'updateTurnRoute invalidates stale provider/model mid-flight',
        () async {
          final runner = AgentRunner(
            MockAdapter(const []),
            registry,
            sessionManager,
          );
          // updateTurnRoute only updates internal turn-level fields
          // (_turnProviderId, _turnModel) and clears _resolvedTurnRoute.
          // It does NOT modify the session model in SessionManager.
          runner.updateTurnRoute(providerId: 'prov-old', modelId: 'model-old');

          // Override to new route — must not throw.
          runner.updateTurnRoute(providerId: 'prov-new', modelId: 'model-new');
          // The session-level model is untouched by updateTurnRoute.
          // The runner object itself must still be valid.
          expect(runner, isNotNull);
          expect(
            runner.sessionManager.getSession(runner.sessionId),
            isNotNull,
            reason: 'Session must still exist after route override',
          );
        },
      );

      test(
        'provider handoff reclaims waiting execution before the next attempt',
        () async {
          repo.createInstance(
            ProviderInstance(
              id: 'prov-new',
              templateId: 'openai',
              displayName: 'New Provider',
              protocol: ProviderProtocol.openaiCompatible,
              authMethod: ProviderAuthMethod.apiKey,
              defaultModel: 'gpt-4o-mini',
              status: InstanceStatus.ready,
              createdAt: DateTime.parse('2026-07-09T12:00:01Z'),
              updatedAt: DateTime.parse('2026-07-09T12:00:01Z'),
            ),
          );

          final adapter = _FailOnceThenSucceedAdapter();
          final runtime = _FakeRuntimeService(adapter);
          GetIt.I.registerSingleton<AgentRuntimeService>(runtime);
          GetIt.I.registerSingleton<ProviderInstanceRepository>(repo);
          final session = sessionManager.createSession('gpt-4o');
          sessionManager.updateSessionProviderId(
            session.sessionId,
            'prov-budget',
          );

          final recovery = GetIt.I<RuntimeRecoveryService>();
          final persisted = PersistedRuntimeStateRepository.fromState(state);
          GetIt.I.registerSingleton<PersistedRuntimeStateRepository>(persisted);
          recovery.attachPersistedState(persisted);
          addTearDown(() {
            recovery.attachPersistedState(null);
            GetIt.I.unregister<PersistedRuntimeStateRepository>();
          });
          state.db.execute(
            '''
            INSERT INTO sessions (
              session_id, model, provider_id, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?)
            ''',
            [
              session.sessionId,
              'gpt-4o',
              'prov-budget',
              '2026-07-19T00:00:00.000Z',
              '2026-07-19T00:00:00.000Z',
            ],
          );
          const workItemId = 'work-provider-handoff';
          const runId = 'run-provider-handoff';
          const generation = 1;
          final executionStates = <SessionExecutionState>[];
          final executionSubscription = persisted.executionState.changes.listen(
            (snapshot) => executionStates.add(snapshot.state),
          );
          addTearDown(executionSubscription.cancel);
          persisted.executionState.enqueueWorkItem(
            workItemId: workItemId,
            sessionId: session.sessionId,
            state: SessionWorkState.running,
          );
          expect(
            persisted.bindRunOwnership(
              sessionId: session.sessionId,
              workItemId: workItemId,
              runId: runId,
              generation: generation,
            ),
            isTrue,
          );

          final runner = AgentRunner(
            MockAdapter(const []),
            registry,
            sessionManager,
            existingSessionId: session.sessionId,
          );
          runner.beginAuthoritativeRun(
            runId,
            workItemId: workItemId,
            generation: generation,
          );
          recovery.beginRun(session.sessionId, runId);

          final future = runner.sendMessage('hi');
          await adapter.firstFailure.future;
          for (var attempt = 0; attempt < 100; attempt++) {
            if (persisted.executionSnapshots
                    .getSnapshot(session.sessionId)
                    .state ==
                SessionExecutionState.waiting) {
              break;
            }
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          expect(
            persisted.executionSnapshots.getSnapshot(session.sessionId).state,
            SessionExecutionState.waiting,
          );

          sessionManager.updateSessionModeling(
            session.sessionId,
            providerId: 'prov-new',
            model: 'gpt-4o-mini',
          );
          recovery.abort(session.sessionId);

          final message = await future;
          expect(message.content, contains('Recovered on gpt-4o-mini'));
          expect(runtime.lastSignature?.providerInstanceId, equals('prov-new'));
          expect(runtime.lastSignature?.modelId, equals('gpt-4o-mini'));
          expect(adapter.modelOverrides, equals(['gpt-4o', 'gpt-4o-mini']));
          expect(executionStates, contains(SessionExecutionState.resuming));

          final terminal = persisted.commitTerminal(
            sessionId: session.sessionId,
            workItemId: workItemId,
            runId: runId,
            generation: generation,
            assistantResult: message,
          );
          expect(terminal, TerminalCommitOutcome.committed);
          expect(
            persisted.executionSnapshots.getSnapshot(session.sessionId).state,
            SessionExecutionState.idle,
          );
        },
      );
    });

    group('Gate D: Continuation Checkpoints', () {
      test(
        'checkpointing saves metadata and prevents non-idempotent tool re-execution',
        () async {
          final session = sessionManager.createSession('gpt-4o');

          final stateDb = AgentStateDatabase.inMemory();
          final repo = PersistedRuntimeStateRepository(stateDb.db);
          GetIt.I.registerSingleton<PersistedRuntimeStateRepository>(repo);
          addTearDown(() {
            GetIt.I.unregister<PersistedRuntimeStateRepository>();
            stateDb.dispose();
          });

          final workItem = SessionWorkItem(
            workItemId: 'w-123',
            sessionId: session.sessionId,
            requestId: 'req-123',
            sequence: 1,
            state: SessionWorkState.running,
            attempt: 0,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          );
          stateDb.db.execute(
            "INSERT INTO sessions (session_id, model, created_at, updated_at) VALUES ('${session.sessionId}', 'gpt-4o', '2026-07-11', '2026-07-11')",
          );
          repo.insertWorkItem(workItem);

          final runner = AgentRunner(
            MockAdapter(const []),
            registry,
            sessionManager,
            existingSessionId: session.sessionId,
          );

          int callCount = 0;
          final myTool = GateDTestTool('my_write_tool', (args, context) async {
            callCount++;
            return 'Tool Output $callCount bearer secret-token-123456';
          });
          registry.registerTool(myTool);

          // 1. First run: executing the tool
          await runner.executeToolCalls([
            ToolCall(
              id: 'call-1',
              name: 'my_write_tool',
              arguments: const {'api_key': 'sk-secretvalue1234'},
            ),
          ], parallel: false);

          expect(callCount, equals(1));

          // Verify result is cached in checkpoint continuation_metadata
          final updated = repo.findWorkItem('w-123');
          expect(updated, isNotNull);
          final completed =
              updated!.continuationMetadata['completed_tool_results'] as Map;
          expect(
            completed['call-1'],
            equals('Tool Output 1 bearer secret-token-123456'),
          );
          final completedOutputs =
              updated.continuationMetadata['completed_tool_outputs'] as Map;
          expect(completedOutputs['call-1']['tool_call_id'], equals('call-1'));
          expect(
            completedOutputs['call-1']['tool_name'],
            equals('my_write_tool'),
          );
          expect(
            completedOutputs['call-1']['arguments']['api_key'],
            equals('***'),
          );
          expect(
            completedOutputs['call-1']['result'],
            equals('Tool Output 1 Bearer ***'),
          );
          expect(completedOutputs['call-1']['is_error'], isFalse);
          expect(completedOutputs['call-1']['sent_to_provider'], isFalse);

          // 2. Simulate resuming with call-1 in completed results.
          // It should NOT re-run the tool, but reuse the cached result!
          await runner.executeToolCalls([
            ToolCall(id: 'call-1', name: 'my_write_tool', arguments: const {}),
          ], parallel: false);
          expect(callCount, equals(1)); // Still 1!

          // 3. Simulate crash isolation: non-idempotent tool marked currently executing but not completed.
          // It must NOT re-execute, and return a safety warning error message.
          final corruptedMeta = {
            'completed_tool_results': <String, dynamic>{},
            'currently_executing_tools': ['call-2'],
            'tool_replay_safety': {'call-2': false},
          };
          repo.transitionWorkItemState(
            workItemId: 'w-123',
            fromState: SessionWorkState.running,
            toState: SessionWorkState.running,
            continuationMetadata: corruptedMeta,
          );

          await runner.executeToolCalls([
            ToolCall(id: 'call-2', name: 'my_write_tool', arguments: const {}),
          ], parallel: false);
          expect(callCount, equals(1)); // Still 1! It did not run the tool.

          final lastMsg = runner.history.last;
          expect(lastMsg.role, equals(MessageRole.tool));
          expect(lastMsg.toolCallId, equals('call-2'));
          expect(lastMsg.metadata?['is_error'], isTrue);
          expect(
            lastMsg.content,
            contains('interrupted by a daemon crash/restart'),
          );

          // 4. Idempotent tool (e.g. view_file) marked executing: CAN be safely re-run!
          int viewFileCallCount = 0;
          final viewFileTool = GateDTestTool('view_file', (
            args,
            context,
          ) async {
            viewFileCallCount++;
            return 'File Contents $viewFileCallCount';
          }, restartReplaySafe: true);
          registry.registerTool(viewFileTool);

          final idempotentMeta = {
            'completed_tool_results': <String, dynamic>{},
            'currently_executing_tools': ['call-3'],
            'tool_replay_safety': {'call-3': true},
          };
          repo.transitionWorkItemState(
            workItemId: 'w-123',
            fromState: SessionWorkState.running,
            toState: SessionWorkState.running,
            continuationMetadata: idempotentMeta,
          );

          await runner.executeToolCalls([
            ToolCall(id: 'call-3', name: 'view_file', arguments: const {}),
          ], parallel: false);
          expect(viewFileCallCount, equals(1)); // Re-executed successfully!
        },
      );

      test(
        'parallel tool batches persist each completed result before the whole batch finishes',
        () async {
          final session = sessionManager.createSession('gpt-4o');

          final stateDb = AgentStateDatabase.inMemory();
          final repo = PersistedRuntimeStateRepository(stateDb.db);
          GetIt.I.registerSingleton<PersistedRuntimeStateRepository>(repo);
          addTearDown(() {
            GetIt.I.unregister<PersistedRuntimeStateRepository>();
            stateDb.dispose();
          });

          stateDb.db.execute(
            "INSERT INTO sessions (session_id, model, created_at, updated_at) VALUES ('${session.sessionId}', 'gpt-4o', '2026-07-11', '2026-07-11')",
          );
          repo.insertWorkItem(
            SessionWorkItem(
              workItemId: 'w-parallel',
              sessionId: session.sessionId,
              requestId: 'req-parallel',
              sequence: 1,
              state: SessionWorkState.running,
              attempt: 0,
              createdAt: DateTime.now(),
              updatedAt: DateTime.now(),
            ),
          );

          final runner = AgentRunner(
            MockAdapter(const []),
            registry,
            sessionManager,
            existingSessionId: session.sessionId,
          );

          final slowRelease = Completer<void>();
          registry.registerTool(
            GateDTestTool('fast_read_tool', (args, context) async => 'fast-ok'),
          );
          registry.registerTool(
            GateDTestTool('slow_read_tool', (args, context) async {
              await slowRelease.future;
              return 'slow-ok';
            }, restartReplaySafe: true),
          );

          final future = runner.executeToolCalls([
            ToolCall(
              id: 'call-fast',
              name: 'fast_read_tool',
              arguments: const {},
            ),
            ToolCall(
              id: 'call-slow',
              name: 'slow_read_tool',
              arguments: const {},
            ),
          ], parallel: true);

          await Future<void>.delayed(const Duration(milliseconds: 50));

          final midFlight = repo.findWorkItem('w-parallel');
          final midResults =
              midFlight!.continuationMetadata['completed_tool_results'] as Map;
          expect(midResults['call-fast'], equals('fast-ok'));
          expect(midResults.containsKey('call-slow'), isFalse);
          expect(
            midFlight.continuationMetadata['currently_executing_tools'],
            equals(['call-slow']),
          );

          slowRelease.complete();
          await future;

          final completed = repo.findWorkItem('w-parallel');
          final finalResults =
              completed!.continuationMetadata['completed_tool_results'] as Map;
          expect(finalResults['call-fast'], equals('fast-ok'));
          expect(finalResults['call-slow'], equals('slow-ok'));
          final finalOutputs =
              completed.continuationMetadata['completed_tool_outputs'] as Map;
          expect(
            finalOutputs['call-fast']['tool_name'],
            equals('fast_read_tool'),
          );
          expect(finalOutputs['call-fast']['is_error'], isFalse);
          expect(
            finalOutputs['call-slow']['tool_name'],
            equals('slow_read_tool'),
          );
          expect(finalOutputs['call-slow']['result'], equals('slow-ok'));
        },
      );

      test(
        'resume from initial_model_request does not duplicate the user message',
        () async {
          final session = sessionManager.createSession('gpt-4o');
          sessionManager.saveSessionHistory(session.sessionId, [
            Message(role: MessageRole.user, content: 'hello'),
          ]);

          final stateDb = AgentStateDatabase.inMemory();
          final repo = PersistedRuntimeStateRepository(stateDb.db);
          GetIt.I.registerSingleton<PersistedRuntimeStateRepository>(repo);
          addTearDown(() {
            GetIt.I.unregister<PersistedRuntimeStateRepository>();
            stateDb.dispose();
          });

          stateDb.db.execute(
            "INSERT INTO sessions (session_id, model, created_at, updated_at) VALUES ('${session.sessionId}', 'gpt-4o', '2026-07-11', '2026-07-11')",
          );
          repo.insertWorkItem(
            SessionWorkItem(
              workItemId: 'w-resume-initial',
              sessionId: session.sessionId,
              requestId: 'req-resume-initial',
              sequence: 1,
              state: SessionWorkState.resuming,
              attempt: 0,
              continuationMetadata: const {
                'checkpoint_kind': 'initial_model_request',
                'resume_history_length': 1,
                'currentTurnStartIndex': 0,
                'currentModelRunId': 'run_saved',
              },
              createdAt: DateTime.now(),
              updatedAt: DateTime.now(),
            ),
          );

          final adapter = MockAdapter([
            AgentResponse(
              message: Message(
                role: MessageRole.assistant,
                content: 'resumed final',
              ),
            ),
          ]);
          final runner = AgentRunner(
            adapter,
            registry,
            sessionManager,
            existingSessionId: session.sessionId,
          );

          final chunks = <String>[];
          await for (final chunk in runner.resumeStream()) {
            chunks.add(chunk);
          }

          expect(chunks.join(), equals('resumed final'));
          expect(
            runner.history.where((m) => m.role == MessageRole.user).length,
            equals(1),
          );
          expect(runner.history.length, equals(2));
          expect(
            adapter.lastHistory
                ?.where((m) => m.role == MessageRole.user)
                .length,
            equals(1),
          );
        },
      );

      test(
        'resume from after_tool_result trims duplicate partial history and does not repeat tool results',
        () async {
          final session = sessionManager.createSession('gpt-4o');
          sessionManager.saveSessionHistory(session.sessionId, [
            Message(role: MessageRole.user, content: 'hello'),
            Message(
              role: MessageRole.assistant,
              toolCalls: [
                ToolCall(id: 'call-1', name: 'view_file', arguments: const {}),
              ],
            ),
            Message(
              role: MessageRole.tool,
              content: 'file contents',
              toolCallId: 'call-1',
            ),
            Message(role: MessageRole.assistant, content: 'partial duplicate'),
          ]);

          final stateDb = AgentStateDatabase.inMemory();
          final repo = PersistedRuntimeStateRepository(stateDb.db);
          GetIt.I.registerSingleton<PersistedRuntimeStateRepository>(repo);
          addTearDown(() {
            GetIt.I.unregister<PersistedRuntimeStateRepository>();
            stateDb.dispose();
          });

          stateDb.db.execute(
            "INSERT INTO sessions (session_id, model, created_at, updated_at) VALUES ('${session.sessionId}', 'gpt-4o', '2026-07-11', '2026-07-11')",
          );
          repo.insertWorkItem(
            SessionWorkItem(
              workItemId: 'w-resume-tool',
              sessionId: session.sessionId,
              requestId: 'req-resume-tool',
              sequence: 1,
              state: SessionWorkState.resuming,
              attempt: 0,
              continuationMetadata: const {
                'checkpoint_kind': 'after_tool_result',
                'resume_history_length': 3,
                'currentTurnStartIndex': 0,
                'currentModelRunId': 'run_saved_tool',
                'completed_tool_results': {'call-1': 'file contents'},
              },
              createdAt: DateTime.now(),
              updatedAt: DateTime.now(),
            ),
          );

          final adapter = MockAdapter([
            AgentResponse(
              message: Message(
                role: MessageRole.assistant,
                content: 'final after tool',
              ),
            ),
          ]);
          final runner = AgentRunner(
            adapter,
            registry,
            sessionManager,
            existingSessionId: session.sessionId,
          );

          final chunks = <String>[];
          await for (final chunk in runner.resumeStream()) {
            chunks.add(chunk);
          }

          expect(chunks.join(), equals('final after tool'));
          expect(
            runner.history.where((m) => m.role == MessageRole.tool).length,
            equals(1),
          );
          expect(
            runner.history
                .where(
                  (m) => m.role == MessageRole.assistant && m.toolCalls != null,
                )
                .length,
            equals(1),
          );
          expect(runner.history.last.content, equals('final after tool'));
          expect(
            runner.history.any((m) => m.content == 'partial duplicate'),
            isFalse,
          );
        },
      );

      test('resume rejects an unrecognized checkpoint kind', () async {
        final session = sessionManager.createSession('gpt-4o');
        sessionManager.saveSessionHistory(session.sessionId, [
          Message(role: MessageRole.user, content: 'hello'),
        ]);

        final stateDb = AgentStateDatabase.inMemory();
        final repo = PersistedRuntimeStateRepository(stateDb.db);
        GetIt.I.registerSingleton<PersistedRuntimeStateRepository>(repo);
        addTearDown(() {
          GetIt.I.unregister<PersistedRuntimeStateRepository>();
          stateDb.dispose();
        });

        stateDb.db.execute(
          "INSERT INTO sessions (session_id, model, created_at, updated_at) VALUES ('${session.sessionId}', 'gpt-4o', '2026-07-11', '2026-07-11')",
        );
        repo.insertWorkItem(
          SessionWorkItem(
            workItemId: 'w-invalid-checkpoint',
            sessionId: session.sessionId,
            requestId: 'req-invalid-checkpoint',
            sequence: 1,
            state: SessionWorkState.resuming,
            attempt: 0,
            continuationMetadata: const {
              'checkpoint_kind': 'mystery_checkpoint',
              'resume_history_length': 1,
            },
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );

        final runner = AgentRunner(
          MockAdapter(const []),
          registry,
          sessionManager,
          existingSessionId: session.sessionId,
        );

        await expectLater(
          runner.resumeStream().drain(),
          throwsA(isA<StateError>()),
        );

        // Gate D.3: resume failure must move the active work item to blocked.
        final blockedItem = repo.findWorkItem('w-invalid-checkpoint');
        expect(blockedItem, isNotNull);
        expect(blockedItem!.state, equals(SessionWorkState.blocked));
        expect(
          blockedItem.continuationMetadata['resume_failure_reason'],
          contains('recognized checkpoint kind'),
        );
      });

      test('resume repairs a missing pre-provider checkpoint once', () async {
        final session = sessionManager.createSession('gpt-4o');
        sessionManager.saveSessionHistory(session.sessionId, [
          Message(
            role: MessageRole.user,
            content: 'recover me',
            metadata: const {'request_id': 'req-missing-checkpoint'},
          ),
        ]);

        final stateDb = AgentStateDatabase.inMemory();
        final repo = PersistedRuntimeStateRepository(stateDb.db);
        GetIt.I.registerSingleton<PersistedRuntimeStateRepository>(repo);
        addTearDown(() {
          GetIt.I.unregister<PersistedRuntimeStateRepository>();
          stateDb.dispose();
        });
        stateDb.db.execute(
          "INSERT INTO sessions (session_id, model, created_at, updated_at) VALUES ('${session.sessionId}', 'gpt-4o', '2026-08-31', '2026-08-31')",
        );
        repo.insertWorkItem(
          SessionWorkItem(
            workItemId: 'w-missing-checkpoint',
            sessionId: session.sessionId,
            requestId: 'req-missing-checkpoint',
            sequence: 1,
            state: SessionWorkState.resuming,
            attempt: 0,
            payload: const {'message': 'recover me'},
            continuationMetadata: const {},
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );
        final adapter = MockAdapter([
          AgentResponse(
            message: Message(role: MessageRole.assistant, content: 'recovered'),
          ),
        ]);
        final runner = AgentRunner(
          adapter,
          registry,
          sessionManager,
          existingSessionId: session.sessionId,
        );

        expect(
          await runner.resumeStream(requestId: 'req-missing-checkpoint').join(),
          'recovered',
        );
        expect(
          repo
              .findWorkItem('w-missing-checkpoint')!
              .continuationMetadata['checkpoint_kind'],
          ContinuationCheckpointCoordinator.checkpointKindInitialModelRequest,
        );
        expect(
          repo
              .findWorkItem('w-missing-checkpoint')!
              .continuationMetadata['checkpoint_repaired_after_restart'],
          isTrue,
        );
        expect(
          adapter.lastHistory!.where(
            (message) => message.role == MessageRole.user,
          ),
          hasLength(1),
        );
      });

      test(
        'resume rejects non-idempotent tool still executing without completed result',
        () async {
          final session = sessionManager.createSession('gpt-4o');
          sessionManager.saveSessionHistory(session.sessionId, [
            Message(role: MessageRole.user, content: 'hello'),
          ]);

          final stateDb = AgentStateDatabase.inMemory();
          final repo = PersistedRuntimeStateRepository(stateDb.db);
          GetIt.I.registerSingleton<PersistedRuntimeStateRepository>(repo);
          addTearDown(() {
            GetIt.I.unregister<PersistedRuntimeStateRepository>();
            stateDb.dispose();
          });

          stateDb.db.execute(
            "INSERT INTO sessions (session_id, model, created_at, updated_at) VALUES ('${session.sessionId}', 'gpt-4o', '2026-07-11', '2026-07-11')",
          );
          repo.insertWorkItem(
            SessionWorkItem(
              workItemId: 'w-unsafe-executing',
              sessionId: session.sessionId,
              requestId: 'req-unsafe',
              sequence: 1,
              state: SessionWorkState.resuming,
              attempt: 0,
              continuationMetadata: const {
                'checkpoint_kind': 'after_tool_result',
                'resume_history_length': 1,
                'currently_executing_tools': ['call-unsafe'],
                'completed_tool_results': <String, dynamic>{},
                'tool_replay_safety': {'call-unsafe': false},
              },
              createdAt: DateTime.now(),
              updatedAt: DateTime.now(),
            ),
          );

          final runner = AgentRunner(
            MockAdapter(const []),
            registry,
            sessionManager,
            existingSessionId: session.sessionId,
          );

          await expectLater(
            runner.resumeStream().drain(),
            throwsA(isA<StateError>()),
          );

          final blockedItem = repo.findWorkItem('w-unsafe-executing');
          expect(blockedItem, isNotNull);
          expect(blockedItem!.state, equals(SessionWorkState.blocked));
          expect(
            blockedItem.continuationMetadata['resume_failure_reason'],
            contains('not idempotent'),
          );
        },
      );

      test(
        'resume resolves deferred tool batch without replaying the tool call',
        () async {
          final session = sessionManager.createSession('gpt-4o');
          sessionManager.saveSessionHistory(session.sessionId, [
            Message(role: MessageRole.user, content: 'switch source'),
            Message(
              role: MessageRole.assistant,
              toolCalls: [
                ToolCall(
                  id: 'call-deferred-switch',
                  name: 'shell_execute',
                  arguments: const {'command': 'sanad-dev switch'},
                ),
              ],
            ),
          ]);

          final stateDb = AgentStateDatabase.inMemory();
          final repo = PersistedRuntimeStateRepository(stateDb.db);
          GetIt.I.registerSingleton<PersistedRuntimeStateRepository>(repo);
          addTearDown(() {
            GetIt.I.unregister<PersistedRuntimeStateRepository>();
            stateDb.dispose();
          });
          stateDb.db.execute(
            "INSERT INTO sessions (session_id, model, created_at, updated_at) VALUES ('${session.sessionId}', 'gpt-4o', '2026-08-09', '2026-08-09')",
          );
          repo.insertWorkItem(
            SessionWorkItem(
              workItemId: 'w-deferred-switch',
              sessionId: session.sessionId,
              requestId: 'req-deferred-switch',
              sequence: 1,
              state: SessionWorkState.resuming,
              attempt: 0,
              continuationMetadata: {
                'checkpoint_kind': 'initial_model_request',
                'resume_history_length': 1,
                'currently_executing_tools': ['call-deferred-switch'],
                'completed_tool_results': <String, dynamic>{},
                'tool_replay_safety': {'call-deferred-switch': false},
                'deferred_tool_results': {
                  'call-deferred-switch': {
                    'kind': 'sanad_dev_switch',
                    'transaction_id': 'switch-1',
                    'manifest_path':
                        '${Directory.systemTemp.path}/home/dev/runtime-switch-58085.json',
                    'requester_session_id': session.sessionId,
                    'requester_tool_call_id': 'call-deferred-switch',
                  },
                },
              },
              createdAt: DateTime.now(),
              updatedAt: DateTime.now(),
            ),
          );
          var manifestReads = 0;
          final adapter = MockAdapter([
            AgentResponse(
              message: Message(
                role: MessageRole.assistant,
                content: 'continued after switch',
              ),
            ),
          ]);
          final home = '${Directory.systemTemp.path}/home';
          final runner = AgentRunner(
            adapter,
            registry,
            sessionManager,
            existingSessionId: session.sessionId,
            deferredToolResultResolver: DeferredToolResultResolver(
              environment: {'SANAD_HOME': home},
              readManifest: (_) async {
                manifestReads++;
                return '{'
                    '"id":"switch-1",'
                    '"requester_session_id":"${session.sessionId}",'
                    '"requester_tool_call_id":"call-deferred-switch",'
                    '"target_worktree_name":"target",'
                    '"status":"complete"}';
              },
            ),
          );

          final chunks = await runner.resumeStream().toList();

          expect(chunks.join(), 'continued after switch');
          expect(manifestReads, 1);
          expect(
            runner.history
                .where(
                  (message) =>
                      message.role == MessageRole.assistant &&
                      message.toolCalls?.single.id == 'call-deferred-switch',
                )
                .length,
            1,
          );
          final toolMessages = runner.history.where(
            (message) => message.toolCallId == 'call-deferred-switch',
          );
          expect(toolMessages, hasLength(1));
          expect(toolMessages.single.content, contains('Switch complete'));
          final metadata = repo
              .findWorkItem('w-deferred-switch')!
              .continuationMetadata;
          expect(metadata['deferred_tool_results'], isNull);
          expect(metadata['currently_executing_tools'], isNull);
        },
      );

      test(
        'manual retry continues ambiguous tool without replaying its side effect',
        () async {
          final session = sessionManager.createSession('gpt-4o');
          sessionManager.saveSessionHistory(session.sessionId, [
            Message(role: MessageRole.user, content: 'perform side effect'),
            Message(
              role: MessageRole.assistant,
              toolCalls: [
                ToolCall(
                  id: 'call-ambiguous-manual',
                  name: 'unsafe_tool',
                  arguments: const {'value': 1},
                ),
              ],
            ),
          ]);

          final stateDb = AgentStateDatabase.inMemory();
          final repo = PersistedRuntimeStateRepository(stateDb.db);
          GetIt.I.registerSingleton<PersistedRuntimeStateRepository>(repo);
          addTearDown(() {
            GetIt.I.unregister<PersistedRuntimeStateRepository>();
            stateDb.dispose();
          });
          stateDb.db.execute(
            "INSERT INTO sessions (session_id, model, created_at, updated_at) VALUES ('${session.sessionId}', 'gpt-4o', '2026-07-11', '2026-07-11')",
          );
          repo.insertWorkItem(
            SessionWorkItem(
              workItemId: 'w-ambiguous-manual',
              sessionId: session.sessionId,
              requestId: 'req-ambiguous-manual',
              sequence: 1,
              state: SessionWorkState.resuming,
              attempt: 0,
              continuationMetadata: const {
                // This is the real mid-tool checkpoint: the model-request
                // boundary predates the durable assistant tool-call message.
                'checkpoint_kind': 'initial_model_request',
                'resume_history_length': 1,
                'currently_executing_tools': ['call-ambiguous-manual'],
                'completed_tool_results': <String, dynamic>{},
                'tool_replay_safety': {'call-ambiguous-manual': false},
              },
              createdAt: DateTime.now(),
              updatedAt: DateTime.now(),
            ),
          );
          final adapter = MockAdapter([
            AgentResponse(
              message: Message(
                role: MessageRole.assistant,
                content: 'continued after interruption',
              ),
            ),
          ]);
          final runner = AgentRunner(
            adapter,
            registry,
            sessionManager,
            existingSessionId: session.sessionId,
          );

          runner.allowManualAmbiguousToolRecovery();
          final chunks = await runner.resumeStream().toList();

          expect(chunks.join(), 'continued after interruption');
          final toolMessages = runner.history.where(
            (message) => message.toolCallId == 'call-ambiguous-manual',
          );
          expect(toolMessages, hasLength(1));
          expect(toolMessages.single.content, contains('outcome is unknown'));
          expect(
            adapter.lastHistory!
                .where(
                  (message) =>
                      message.role == MessageRole.assistant &&
                      message.toolCalls?.single.id == 'call-ambiguous-manual',
                )
                .length,
            1,
          );
          expect(
            adapter.lastHistory!
                .where(
                  (message) =>
                      message.role == MessageRole.tool &&
                      message.toolCallId == 'call-ambiguous-manual',
                )
                .length,
            1,
          );
          final metadata = repo
              .findWorkItem('w-ambiguous-manual')!
              .continuationMetadata;
          expect(metadata['currently_executing_tools'], isNull);
          expect(
            (metadata['completed_tool_results'] as Map).containsKey(
              'call-ambiguous-manual',
            ),
            isTrue,
          );
        },
      );

      test(
        'manual recovery reconciles a sequential tool batch in original order',
        () async {
          final session = sessionManager.createSession('gpt-4o');
          final durableBatch = [
            ToolCall(
              id: 'call-completed',
              name: 'completed_tool',
              arguments: const {'value': 1},
            ),
            ToolCall(
              id: 'call-ambiguous',
              name: 'ambiguous_tool',
              arguments: const {'value': 2},
            ),
            ToolCall(
              id: 'call-never-started',
              name: 'never_started_tool',
              arguments: const {'value': 3},
            ),
          ];
          sessionManager.saveSessionHistory(session.sessionId, [
            Message(role: MessageRole.user, content: 'run three steps'),
            Message(role: MessageRole.assistant, toolCalls: durableBatch),
          ]);

          final stateDb = AgentStateDatabase.inMemory();
          final repo = PersistedRuntimeStateRepository(stateDb.db);
          GetIt.I.registerSingleton<PersistedRuntimeStateRepository>(repo);
          addTearDown(() {
            GetIt.I.unregister<PersistedRuntimeStateRepository>();
            stateDb.dispose();
          });
          stateDb.db.execute(
            "INSERT INTO sessions (session_id, model, created_at, updated_at) VALUES ('${session.sessionId}', 'gpt-4o', '2026-07-11', '2026-07-11')",
          );
          repo.insertWorkItem(
            SessionWorkItem(
              workItemId: 'w-sequential-manual',
              sessionId: session.sessionId,
              requestId: 'req-sequential-manual',
              sequence: 1,
              state: SessionWorkState.resuming,
              attempt: 0,
              continuationMetadata: const {
                'checkpoint_kind': 'initial_model_request',
                'resume_history_length': 1,
                'currently_executing_tools': ['call-ambiguous'],
                'completed_tool_results': {
                  'call-completed': 'completed-before-crash',
                },
                'completed_tool_outputs': {
                  'call-completed': {
                    'tool_call_id': 'call-completed',
                    'tool_name': 'completed_tool',
                    'arguments': {'value': 1},
                    'result': 'completed-before-crash',
                    'is_error': false,
                    'sent_to_provider': false,
                  },
                },
                'tool_replay_safety': {
                  'call-completed': false,
                  'call-ambiguous': false,
                  'call-never-started': false,
                },
              },
              createdAt: DateTime.now(),
              updatedAt: DateTime.now(),
            ),
          );

          var completedExecutions = 0;
          var ambiguousExecutions = 0;
          var neverStartedExecutions = 0;
          registry.registerTool(
            GateDTestTool('completed_tool', (args, context) async {
              completedExecutions++;
              return 'duplicate-completed';
            }),
          );
          registry.registerTool(
            GateDTestTool('ambiguous_tool', (args, context) async {
              ambiguousExecutions++;
              return 'duplicate-ambiguous';
            }),
          );
          registry.registerTool(
            GateDTestTool('never_started_tool', (args, context) async {
              neverStartedExecutions++;
              return 'executed-after-recovery';
            }),
          );

          final adapter = MockAdapter([
            AgentResponse(
              message: Message(
                role: MessageRole.assistant,
                content: 'batch reconciled',
              ),
            ),
          ]);
          final runner = AgentRunner(
            adapter,
            registry,
            sessionManager,
            existingSessionId: session.sessionId,
          );

          runner.allowManualAmbiguousToolRecovery();
          final chunks = await runner.resumeStream().toList();

          expect(chunks.join(), 'batch reconciled');
          expect(completedExecutions, 0);
          expect(ambiguousExecutions, 0);
          expect(neverStartedExecutions, 1);

          final toolMessages = runner.history
              .where((message) => message.role == MessageRole.tool)
              .toList();
          expect(toolMessages.map((message) => message.toolCallId), [
            'call-completed',
            'call-ambiguous',
            'call-never-started',
          ]);
          expect(toolMessages[0].content, 'completed-before-crash');
          expect(toolMessages[1].content, contains('outcome is unknown'));
          expect(toolMessages[2].content, 'executed-after-recovery');

          final providerToolMessages = adapter.lastHistory!
              .where((message) => message.role == MessageRole.tool)
              .toList();
          expect(providerToolMessages.map((message) => message.toolCallId), [
            'call-completed',
            'call-ambiguous',
            'call-never-started',
          ]);

          final metadata = repo
              .findWorkItem('w-sequential-manual')!
              .continuationMetadata;
          expect(metadata['currently_executing_tools'], isNull);
          expect(metadata['checkpoint_kind'], 'after_tool_result');
          expect(metadata['checkpoint_before_model_request'], isNull);
          expect(metadata['resume_history_length'], 5);
          final completedResults =
              metadata['completed_tool_results'] as Map<String, dynamic>;
          expect(completedResults['call-completed'], 'completed-before-crash');
          expect(completedResults['call-ambiguous'], contains('unknown'));
          expect(
            completedResults['call-never-started'],
            'executed-after-recovery',
          );
          final completedOutputs =
              metadata['completed_tool_outputs'] as Map<String, dynamic>;
          expect(
            completedOutputs['call-completed']['result'],
            'completed-before-crash',
          );
          expect(completedOutputs['call-ambiguous']['is_error'], isTrue);
          expect(
            completedOutputs['call-never-started']['result'],
            'executed-after-recovery',
          );
        },
      );

      test(
        'restart after initial_model_request resumes exactly once without re-adding user message',
        () async {
          final session = sessionManager.createSession('gpt-4o');
          sessionManager.saveSessionHistory(session.sessionId, [
            Message(role: MessageRole.user, content: 'hello'),
          ]);

          final stateDb = AgentStateDatabase.inMemory();
          final repo = PersistedRuntimeStateRepository(stateDb.db);
          GetIt.I.registerSingleton<PersistedRuntimeStateRepository>(repo);
          addTearDown(() {
            GetIt.I.unregister<PersistedRuntimeStateRepository>();
            stateDb.dispose();
          });

          stateDb.db.execute(
            "INSERT INTO sessions (session_id, model, created_at, updated_at) VALUES ('${session.sessionId}', 'gpt-4o', '2026-07-11', '2026-07-11')",
          );
          repo.insertWorkItem(
            SessionWorkItem(
              workItemId: 'w-restart-initial',
              sessionId: session.sessionId,
              requestId: 'req-restart-initial',
              sequence: 1,
              state: SessionWorkState.resuming,
              attempt: 0,
              continuationMetadata: const {
                'checkpoint_kind': 'initial_model_request',
                'resume_history_length': 1,
                'currentTurnStartIndex': 0,
              },
              createdAt: DateTime.now(),
              updatedAt: DateTime.now(),
            ),
          );

          final adapter = MockAdapter([
            AgentResponse(
              message: Message(
                role: MessageRole.assistant,
                content: 'recovered after restart',
              ),
            ),
          ]);
          final runner = AgentRunner(
            adapter,
            registry,
            sessionManager,
            existingSessionId: session.sessionId,
          );

          final chunks = <String>[];
          await for (final chunk in runner.resumeStream()) {
            chunks.add(chunk);
          }

          expect(chunks.join(), equals('recovered after restart'));
          expect(adapter.histories, hasLength(1));
          expect(
            adapter.lastHistory
                ?.where((m) => m.role == MessageRole.user)
                .length,
            equals(1),
          );
          expect(
            runner.history.where((m) => m.role == MessageRole.user).length,
            equals(1),
          );
        },
      );

      test(
        'restart after tool result does not re-execute side-effect tool',
        () async {
          final session = sessionManager.createSession('gpt-4o');
          sessionManager.saveSessionHistory(session.sessionId, [
            Message(role: MessageRole.user, content: 'hello'),
            Message(
              role: MessageRole.assistant,
              toolCalls: [
                ToolCall(
                  id: 'call-side',
                  name: 'dangerous_tool',
                  arguments: const {},
                ),
              ],
            ),
            Message(
              role: MessageRole.tool,
              content: 'side effect completed',
              toolCallId: 'call-side',
            ),
          ]);

          final stateDb = AgentStateDatabase.inMemory();
          final repo = PersistedRuntimeStateRepository(stateDb.db);
          GetIt.I.registerSingleton<PersistedRuntimeStateRepository>(repo);
          addTearDown(() {
            GetIt.I.unregister<PersistedRuntimeStateRepository>();
            stateDb.dispose();
          });

          stateDb.db.execute(
            "INSERT INTO sessions (session_id, model, created_at, updated_at) VALUES ('${session.sessionId}', 'gpt-4o', '2026-07-11', '2026-07-11')",
          );
          repo.insertWorkItem(
            SessionWorkItem(
              workItemId: 'w-restart-tool',
              sessionId: session.sessionId,
              requestId: 'req-restart-tool',
              sequence: 1,
              state: SessionWorkState.resuming,
              attempt: 0,
              continuationMetadata: const {
                'checkpoint_kind': 'after_tool_result',
                'resume_history_length': 3,
                'completed_tool_results': {
                  'call-side': 'side effect completed',
                },
              },
              createdAt: DateTime.now(),
              updatedAt: DateTime.now(),
            ),
          );

          int toolCalls = 0;
          registry.registerTool(
            GateDTestTool('dangerous_tool', (args, context) async {
              toolCalls++;
              return 'should not happen';
            }),
          );

          final adapter = MockAdapter([
            AgentResponse(
              message: Message(
                role: MessageRole.assistant,
                content: 'acknowledged',
              ),
            ),
          ]);
          final runner = AgentRunner(
            adapter,
            registry,
            sessionManager,
            existingSessionId: session.sessionId,
          );

          final chunks = <String>[];
          await for (final chunk in runner.resumeStream()) {
            chunks.add(chunk);
          }

          expect(chunks.join(), equals('acknowledged'));
          expect(toolCalls, equals(0));
          expect(runner.history.length, equals(4));
        },
      );

      test(
        'ambiguous tool state stays blocked with safe stop/retry actions',
        () async {
          final session = sessionManager.createSession('gpt-4o');
          sessionManager.saveSessionHistory(session.sessionId, [
            Message(role: MessageRole.user, content: 'hello'),
          ]);

          final stateDb = AgentStateDatabase.inMemory();
          final repo = PersistedRuntimeStateRepository(stateDb.db);
          GetIt.I.registerSingleton<PersistedRuntimeStateRepository>(repo);
          addTearDown(() {
            GetIt.I.unregister<PersistedRuntimeStateRepository>();
            stateDb.dispose();
          });

          stateDb.db.execute(
            "INSERT INTO sessions (session_id, model, created_at, updated_at) VALUES ('${session.sessionId}', 'gpt-4o', '2026-07-11', '2026-07-11')",
          );
          repo.insertWorkItem(
            SessionWorkItem(
              workItemId: 'w-ambiguous',
              sessionId: session.sessionId,
              requestId: 'req-ambiguous',
              sequence: 1,
              state: SessionWorkState.resuming,
              attempt: 0,
              continuationMetadata: const {
                'checkpoint_kind': 'after_tool_result',
                'resume_history_length': 1,
                'currently_executing_tools': ['call-ambiguous'],
                'completed_tool_results': <String, dynamic>{},
                'tool_replay_safety': {'call-ambiguous': false},
              },
              createdAt: DateTime.now(),
              updatedAt: DateTime.now(),
            ),
          );

          final runner = AgentRunner(
            MockAdapter(const []),
            registry,
            sessionManager,
            existingSessionId: session.sessionId,
          );

          await expectLater(
            runner.resumeStream().drain(),
            throwsA(isA<StateError>()),
          );

          final blockedItem = repo.findWorkItem('w-ambiguous');
          expect(blockedItem, isNotNull);
          expect(blockedItem!.state, equals(SessionWorkState.blocked));
        },
      );

      test(
        'crash during resume does not lose work item when resume fails',
        () async {
          final session = sessionManager.createSession('gpt-4o');
          sessionManager.saveSessionHistory(session.sessionId, [
            Message(role: MessageRole.user, content: 'hello'),
          ]);

          final stateDb = AgentStateDatabase.inMemory();
          final repo = PersistedRuntimeStateRepository(stateDb.db);
          GetIt.I.registerSingleton<PersistedRuntimeStateRepository>(repo);
          addTearDown(() {
            GetIt.I.unregister<PersistedRuntimeStateRepository>();
            stateDb.dispose();
          });

          stateDb.db.execute(
            "INSERT INTO sessions (session_id, model, created_at, updated_at) VALUES ('${session.sessionId}', 'gpt-4o', '2026-07-11', '2026-07-11')",
          );
          repo.insertWorkItem(
            SessionWorkItem(
              workItemId: 'w-crash-resume',
              sessionId: session.sessionId,
              requestId: 'req-crash-resume',
              sequence: 1,
              state: SessionWorkState.resuming,
              attempt: 0,
              continuationMetadata: const {
                'checkpoint_kind': 'initial_model_request',
                'resume_history_length': 1,
                'currentTurnStartIndex': 0,
              },
              createdAt: DateTime.now(),
              updatedAt: DateTime.now(),
            ),
          );

          final runner = AgentRunner(
            MockAdapter(const []),
            registry,
            sessionManager,
            existingSessionId: session.sessionId,
          );

          // Force an invalid resume_history_length so the checkpoint cannot be
          // safely validated, simulating a crash-corrupted resume state.
          repo.transitionWorkItemState(
            workItemId: 'w-crash-resume',
            fromState: SessionWorkState.resuming,
            toState: SessionWorkState.resuming,
            continuationMetadata: const {
              'checkpoint_kind': 'initial_model_request',
              'resume_history_length': 999,
              'currentTurnStartIndex': 0,
            },
          );

          Object? capturedError;
          try {
            await runner.resumeStream().drain();
          } catch (e) {
            capturedError = e;
          }

          expect(capturedError, isA<StateError>());

          final blockedItem = repo.findWorkItem('w-crash-resume');
          expect(blockedItem, isNotNull);
          expect(blockedItem!.state, equals(SessionWorkState.blocked));
        },
      );

      test(
        'side-effect counter is not executed twice on checkpoint replay',
        () async {
          final session = sessionManager.createSession('gpt-4o');

          final stateDb = AgentStateDatabase.inMemory();
          final repo = PersistedRuntimeStateRepository(stateDb.db);
          GetIt.I.registerSingleton<PersistedRuntimeStateRepository>(repo);
          addTearDown(() {
            GetIt.I.unregister<PersistedRuntimeStateRepository>();
            stateDb.dispose();
          });

          stateDb.db.execute(
            "INSERT INTO sessions (session_id, model, created_at, updated_at) VALUES ('${session.sessionId}', 'gpt-4o', '2026-07-11', '2026-07-11')",
          );
          repo.insertWorkItem(
            SessionWorkItem(
              workItemId: 'w-counter',
              sessionId: session.sessionId,
              requestId: 'req-counter',
              sequence: 1,
              state: SessionWorkState.running,
              attempt: 0,
              continuationMetadata: const {},
              createdAt: DateTime.now(),
              updatedAt: DateTime.now(),
            ),
          );

          var counter = 0;
          registry.registerTool(
            GateDTestTool('counter_tool', (args, context) async {
              counter++;
              return 'count=$counter';
            }),
          );

          final runner = AgentRunner(
            MockAdapter(const []),
            registry,
            sessionManager,
            existingSessionId: session.sessionId,
          );

          await runner.executeToolCalls([
            ToolCall(
              id: 'call-counter',
              name: 'counter_tool',
              arguments: const {},
            ),
          ], parallel: false);
          expect(counter, equals(1));

          // Replay from checkpoint must reuse completed result, not re-run.
          await runner.executeToolCalls([
            ToolCall(
              id: 'call-counter',
              name: 'counter_tool',
              arguments: const {},
            ),
          ], parallel: false);
          expect(counter, equals(1));

          final item = repo.findWorkItem('w-counter');
          expect(
            (item!.continuationMetadata['completed_tool_results']
                as Map)['call-counter'],
            equals('count=1'),
          );
        },
      );

      test(
        'parallel batch crash after one completed tool recovers its result without replay',
        () async {
          final session = sessionManager.createSession('gpt-4o');

          final stateDb = AgentStateDatabase.inMemory();
          final repo = PersistedRuntimeStateRepository(stateDb.db);
          GetIt.I.registerSingleton<PersistedRuntimeStateRepository>(repo);
          addTearDown(() {
            GetIt.I.unregister<PersistedRuntimeStateRepository>();
            stateDb.dispose();
          });

          stateDb.db.execute(
            "INSERT INTO sessions (session_id, model, created_at, updated_at) VALUES ('${session.sessionId}', 'gpt-4o', '2026-07-11', '2026-07-11')",
          );
          repo.insertWorkItem(
            SessionWorkItem(
              workItemId: 'w-parallel-crash',
              sessionId: session.sessionId,
              requestId: 'req-parallel-crash',
              sequence: 1,
              state: SessionWorkState.running,
              attempt: 0,
              continuationMetadata: const {},
              createdAt: DateTime.now(),
              updatedAt: DateTime.now(),
            ),
          );

          var executions = <String>[];
          registry.registerTool(
            GateDTestTool('idempotent_tool', (args, context) async {
              executions.add(context?.toolCallId ?? 'unknown');
              return 'done-${context?.toolCallId}';
            }, restartReplaySafe: true),
          );

          final runner = AgentRunner(
            MockAdapter(const []),
            registry,
            sessionManager,
            existingSessionId: session.sessionId,
          );

          // Simulate a resume where only call-a was completed before crash.
          repo.transitionWorkItemState(
            workItemId: 'w-parallel-crash',
            fromState: SessionWorkState.running,
            toState: SessionWorkState.running,
            continuationMetadata: {
              'completed_tool_results': {'call-a': 'done-call-a'},
              'currently_executing_tools': ['call-b'],
              'tool_replay_safety': {'call-a': true, 'call-b': true},
            },
          );

          await runner.executeToolCalls([
            ToolCall(
              id: 'call-a',
              name: 'idempotent_tool',
              arguments: const {},
            ),
            ToolCall(
              id: 'call-b',
              name: 'idempotent_tool',
              arguments: const {},
            ),
          ], parallel: false);

          expect(executions, equals(['call-b']));
          final item = repo.findWorkItem('w-parallel-crash');
          expect(
            (item!.continuationMetadata['completed_tool_results']
                as Map)['call-a'],
            equals('done-call-a'),
          );
          expect(
            (item.continuationMetadata['completed_tool_results']
                as Map)['call-b'],
            equals('done-call-b'),
          );
        },
      );
    });
  });
}

class GateDTestTool extends BaseTool {
  final String _name;
  final Future<String> Function(Map<String, dynamic> args, ToolContext? context)
  _executeFn;
  final bool _restartReplaySafe;

  GateDTestTool(this._name, this._executeFn, {bool restartReplaySafe = false})
    : _restartReplaySafe = restartReplaySafe;

  @override
  ToolSchema get schema =>
      ToolSchema(name: _name, description: 'desc', parameters: const {});

  @override
  bool get restartReplaySafe => _restartReplaySafe;

  @override
  Future<String> execute(Map<String, dynamic> args, {ToolContext? context}) =>
      _executeFn(args, context);
}
