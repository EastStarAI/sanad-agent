/// Context handed to a [ProviderThinkingPolicy] for capability resolution.
library;

class ThinkingPolicyContext {
  final String providerInstanceId;
  final String templateId;
  final String protocol;
  final String apiMode;
  final String modelId;
  final bool? supportsReasoningOutput;
  final String capabilityRevision;
  final Map<String, Object?> modelMetadata;

  const ThinkingPolicyContext({
    required this.providerInstanceId,
    required this.templateId,
    required this.protocol,
    required this.apiMode,
    required this.modelId,
    this.supportsReasoningOutput,
    this.capabilityRevision = 'unknown',
    this.modelMetadata = const {},
  });

  ThinkingPolicyContext copyWith({
    String? providerInstanceId,
    String? templateId,
    String? protocol,
    String? apiMode,
    String? modelId,
    bool? supportsReasoningOutput,
    String? capabilityRevision,
    Map<String, Object?>? modelMetadata,
  }) {
    return ThinkingPolicyContext(
      providerInstanceId: providerInstanceId ?? this.providerInstanceId,
      templateId: templateId ?? this.templateId,
      protocol: protocol ?? this.protocol,
      apiMode: apiMode ?? this.apiMode,
      modelId: modelId ?? this.modelId,
      supportsReasoningOutput:
          supportsReasoningOutput ?? this.supportsReasoningOutput,
      capabilityRevision: capabilityRevision ?? this.capabilityRevision,
      modelMetadata: modelMetadata ?? this.modelMetadata,
    );
  }
}
