import '../../core/models/message.dart';
import '../../core/models/agent_response.dart';
import '../../capabilities/models/tool_schema.dart';
import '../../interfaces/platforms/sanad_gateway/capabilities.dart';
import 'llm_request_options.dart';

/// Adapter-owned measurement of the material that contributes input tokens on
/// the provider wire.
///
/// [stableMaterialFingerprint] covers non-conversation input such as
/// instructions and tool schemas. [inputItemFingerprints] preserves provider
/// ordering so a later request can prove that it is a strict extension of the
/// request measured by the provider.
class WireInputMeasurement {
  final int estimatedTokens;
  final String stableMaterialFingerprint;
  final List<String> inputItemFingerprints;

  WireInputMeasurement({
    required this.estimatedTokens,
    required this.stableMaterialFingerprint,
    required List<String> inputItemFingerprints,
  }) : inputItemFingerprints = List.unmodifiable(inputItemFingerprints);

  bool extendsMeasurement(WireInputMeasurement earlier) {
    if (stableMaterialFingerprint != earlier.stableMaterialFingerprint ||
        inputItemFingerprints.length < earlier.inputItemFingerprints.length) {
      return false;
    }
    for (var index = 0; index < earlier.inputItemFingerprints.length; index++) {
      if (inputItemFingerprints[index] !=
          earlier.inputItemFingerprints[index]) {
        return false;
      }
    }
    return true;
  }
}

/// Optional protocol owner for estimating only material placed on the wire.
abstract interface class WireInputTokenEstimator {
  Future<int?> estimateInputTokens(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  });
}

/// Optional stronger contract for adapters that can identify their exact wire
/// prefix, allowing provider-confirmed usage to remain authoritative while
/// only a newly appended suffix is estimated.
abstract interface class WireInputUsageMeasurer {
  Future<WireInputMeasurement?> measureInput(
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
