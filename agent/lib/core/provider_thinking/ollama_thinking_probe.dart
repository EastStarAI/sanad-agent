/// Parses Ollama /api/show probe facts for thinking capability (Task 43 Gate B).
library;

class OllamaThinkingProbe {
  OllamaThinkingProbe._();

  static const capabilitiesMetadataKey = 'ollama_capabilities';

  static List<String> parseCapabilities(Object? raw) {
    if (raw is! List) {
      return const [];
    }
    return raw.map((entry) => entry.toString()).toList(growable: false);
  }

  static Map<String, Object?> metadataFromShowResponse(
    Map<String, dynamic> showResponse,
  ) {
    return {
      capabilitiesMetadataKey: parseCapabilities(showResponse['capabilities']),
    };
  }

  /// Returns null when probe evidence is absent.
  static bool? hasThinkingCapability(Map<String, Object?> metadata) {
    if (!metadata.containsKey(capabilitiesMetadataKey)) {
      return null;
    }
    final capabilities = parseCapabilities(metadata[capabilitiesMetadataKey]);
    return capabilities.contains('thinking');
  }

  /// Level-only thinking models reject boolean off toggles in Ollama.
  static bool requiresLevelOnly(Map<String, Object?> metadata, String modelId) {
    final parameters = metadata['ollama_parameters']?.toString() ?? '';
    if (parameters.contains('think=true') && !parameters.contains('think=false')) {
      return true;
    }
    return modelId.toLowerCase().contains('gpt-oss');
  }
}
