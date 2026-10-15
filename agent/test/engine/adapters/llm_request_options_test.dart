import 'package:test/test.dart';

import 'package:sanad_agent/capabilities/models/tool_schema.dart';
import 'package:sanad_agent/core/models/agent_response.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/provider_thinking/native_thinking_directive.dart';
import 'package:sanad_agent/core/provider_runtime/provider_rate_limiter.dart';
import 'package:sanad_agent/engine/adapters/llm_adapter.dart';
import 'package:sanad_agent/engine/adapters/llm_request_options.dart';
import 'package:sanad_agent/engine/adapters/rate_limited_llm_adapter.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/capabilities.dart';

class _CapturingAdapter implements LLMAdapter {
  LLMRequestOptions? responseOptions;
  LLMRequestOptions? streamOptions;

  @override
  Future<AgentResponse> generateResponse(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async {
    responseOptions = options;
    return AgentResponse(
      message: Message(role: MessageRole.assistant, content: 'response'),
    );
  }

  @override
  Stream<AgentResponse> generateStream(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async* {
    streamOptions = options;
    yield AgentResponse(
      message: Message(role: MessageRole.assistant, content: 'stream'),
    );
  }

  @override
  Future<int> getContextLimit([String? modelOverride]) async => 4096;

  @override
  Future<List<ModelOption>> getAvailableModels() async => [];
}

void main() {
  test('rate-limited wrapper forwards request options unchanged', () async {
    final inner = _CapturingAdapter();
    final adapter = RateLimitedLLMAdapter(
      inner,
      providerInstanceId: 'provider-1',
      requestsPerMinute: 0,
      limiter: ProviderRateLimiter(),
    );
    const options = LLMRequestOptions(
      sessionId: 'session-1',
      requestId: 'request-1',
      providerInstanceId: 'provider-1',
      thinkingMode: 'deep',
      timeout: Duration(seconds: 30),
      maxOutputTokens: 2048,
    );
    final history = [Message(role: MessageRole.user, content: 'Hello')];

    await adapter.generateResponse(history, options: options);
    await adapter.generateStream(history, options: options).toList();

    expect(identical(inner.responseOptions, options), isTrue);
    expect(identical(inner.streamOptions, options), isTrue);
  });

  test(
    'rate-limited wrapper forwards resolved thinking directives unchanged',
    () async {
      final inner = _CapturingAdapter();
      final adapter = RateLimitedLLMAdapter(
        inner,
        providerInstanceId: 'provider-1',
        requestsPerMinute: 0,
        limiter: ProviderRateLimiter(),
      );
      const chatDirective = OpenAiEffortDirective('medium');
      const responsesDirective = ResponsesReasoningDirective(
        effort: 'high',
        summary: 'auto',
      );
      const chatOptions = LLMRequestOptions(
        sessionId: 'session-1',
        requestId: 'request-chat',
        providerInstanceId: 'provider-1',
        thinkingMode: 'balanced',
        thinkingDirective: chatDirective,
      );
      const responsesOptions = LLMRequestOptions(
        sessionId: 'session-1',
        requestId: 'request-responses',
        providerInstanceId: 'provider-1',
        thinkingMode: 'deep',
        thinkingDirective: responsesDirective,
      );
      final history = [Message(role: MessageRole.user, content: 'Hello')];

      await adapter.generateResponse(history, options: chatOptions);
      await adapter.generateStream(history, options: responsesOptions).toList();

      expect(identical(inner.responseOptions, chatOptions), isTrue);
      expect(
        identical(inner.responseOptions!.thinkingDirective, chatDirective),
        isTrue,
      );
      expect(identical(inner.streamOptions, responsesOptions), isTrue);
      expect(
        identical(inner.streamOptions!.thinkingDirective, responsesDirective),
        isTrue,
      );
    },
  );
}
