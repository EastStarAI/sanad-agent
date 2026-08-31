import 'package:sanad_agent/capabilities/models/tool_schema.dart';
import 'package:sanad_agent/core/models/agent_response.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/provider_runtime/copilot_credential_lifecycle.dart';
import 'package:sanad_agent/engine/adapters/llm_adapter.dart';
import 'package:sanad_agent/engine/adapters/llm_http_exception.dart';
import 'package:sanad_agent/engine/adapters/llm_request_options.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/capabilities.dart';

/// Copilot-specific wrapper that refreshes the instance token before a model
/// request and retries exactly once after a 401.
class CopilotAuthRecoveryAdapter implements LLMAdapter {
  final LLMAdapter Function() _rebuild;
  final CopilotCredentialLifecycle _lifecycle;
  final String instanceId;
  LLMAdapter _inner;

  CopilotAuthRecoveryAdapter({
    required LLMAdapter inner,
    required LLMAdapter Function() rebuild,
    required CopilotCredentialLifecycle lifecycle,
    required this.instanceId,
  }) : _inner = inner,
       _rebuild = rebuild,
       _lifecycle = lifecycle;

  LLMAdapter get inner => _inner;

  @override
  Future<int> getContextLimit([String? modelOverride]) =>
      _inner.getContextLimit(modelOverride);

  @override
  Future<List<ModelOption>> getAvailableModels() async {
    await _prepare();
    return _withRecovery(() => _inner.getAvailableModels());
  }

  @override
  Future<AgentResponse> generateResponse(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async {
    await _prepare();
    return _withRecovery(
      () => _inner.generateResponse(
        history,
        tools: tools,
        modelOverride: modelOverride,
        options: options,
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
    await _prepare();
    var emitted = false;
    try {
      await for (final event in _inner.generateStream(
        history,
        tools: tools,
        modelOverride: modelOverride,
        options: options,
      )) {
        emitted = true;
        yield event;
      }
    } on LlmHttpException catch (error) {
      if (emitted || error.statusCode != 401) rethrow;
      final recovered = await _lifecycle.recoverUnauthorized(instanceId);
      if (!recovered) rethrow;
      _inner = _rebuild();
      try {
        await for (final event in _inner.generateStream(
          history,
          tools: tools,
          modelOverride: modelOverride,
          options: options,
        )) {
          yield event;
        }
      } on LlmHttpException catch (retryError) {
        if (retryError.statusCode == 401) {
          await _lifecycle.markReloginRequired(instanceId);
        }
        rethrow;
      }
    }
  }

  Future<void> _prepare() async {
    final refreshed = await _lifecycle.ensureFresh(instanceId);
    if (refreshed) {
      _inner = _rebuild();
    }
  }

  Future<T> _withRecovery<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on LlmHttpException catch (error) {
      if (error.statusCode != 401) rethrow;
      final recovered = await _lifecycle.recoverUnauthorized(instanceId);
      if (!recovered) rethrow;
      _inner = _rebuild();
      try {
        return await action();
      } on LlmHttpException catch (retryError) {
        if (retryError.statusCode == 401) {
          await _lifecycle.markReloginRequired(instanceId);
        }
        rethrow;
      }
    }
  }
}
