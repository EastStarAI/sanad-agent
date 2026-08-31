import '../../core/models/message.dart';
import '../../core/models/agent_response.dart';
import '../../capabilities/models/tool_schema.dart';
import '../../interfaces/platforms/sanad_gateway/capabilities.dart';
import 'llm_request_options.dart';

/// Optional protocol owner for estimating only material placed on the wire.
abstract interface class WireInputTokenEstimator {
  Future<int?> estimateInputTokens(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  });
}

abstract class LLMAdapter {
  Future<int> getContextLimit([String? modelOverride]);

  Future<List<ModelOption>> getAvailableModels();

  Future<AgentResponse> generateResponse(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  });
  Stream<AgentResponse> generateStream(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  });
}
