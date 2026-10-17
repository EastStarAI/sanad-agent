/// Parses Ollama /api/show probe facts for thinking capability (Task 43 Gate B).
library;

sealed class OllamaThinkingDeclaration {
  const OllamaThinkingDeclaration();
}

class OllamaBooleanThinkingDeclaration extends OllamaThinkingDeclaration {
  final List<bool> values;
  final bool defaultValue;

  const OllamaBooleanThinkingDeclaration({
    required this.values,
    required this.defaultValue,
  });
}

class OllamaLevelThinkingDeclaration extends OllamaThinkingDeclaration {
  final List<String> values;
  final String? defaultValue;

  const OllamaLevelThinkingDeclaration({
    required this.values,
    this.defaultValue,
  });
}

class OllamaThinkingProbe {
  OllamaThinkingProbe._();

  static const capabilitiesMetadataKey = 'ollama_capabilities';
  static const thinkingDeclarationMetadataKey = 'ollama_thinking';

  static List<String>? parseCapabilities(Object? raw) {
    if (raw is! List) {
      return null;
    }
    final list = <String>[];
    for (final entry in raw) {
      if (entry is! String || entry.trim().isEmpty) {
        return null;
      }
      list.add(entry.trim());
    }
    return list;
  }

  static Map<String, Object?> metadataFromShowResponse(
    Map<String, dynamic> showResponse,
  ) {
    final metadata = <String, Object?>{};
    final capabilities = parseCapabilities(showResponse['capabilities']);
    if (capabilities != null) {
      metadata[capabilitiesMetadataKey] = capabilities;
    }
    if (showResponse.containsKey('thinking')) {
      metadata[thinkingDeclarationMetadataKey] = showResponse['thinking'];
    }
    return metadata;
  }

  /// Returns null when probe evidence is absent or malformed.
  static bool? hasThinkingCapability(Map<String, Object?> metadata) {
    final raw = metadata[capabilitiesMetadataKey];
    if (raw == null) {
      return null;
    }
    final capabilities = parseCapabilities(raw);
    if (capabilities == null) {
      return null;
    }
    return capabilities.contains('thinking');
  }

  /// Parses and strictly validates native thinking declaration from metadata.
  /// Returns null if absent or malformed.
  static OllamaThinkingDeclaration? parseThinkingDeclaration(
    Map<String, Object?> metadata,
  ) {
    final raw = metadata[thinkingDeclarationMetadataKey];
    if (raw is! Map) {
      return null;
    }
    final valuesRaw = raw['values'];
    if (valuesRaw is! List || valuesRaw.isEmpty) {
      return null;
    }

    // Check if boolean declaration: all items must be bool
    final isAllBool = valuesRaw.every((v) => v is bool);
    if (isAllBool) {
      final defaultRaw = raw['default'];
      if (defaultRaw is! bool) {
        return null;
      }
      final boolValues = valuesRaw.cast<bool>().toSet().toList();
      if (!boolValues.contains(defaultRaw)) {
        return null;
      }
      return OllamaBooleanThinkingDeclaration(
        values: boolValues,
        defaultValue: defaultRaw,
      );
    }

    // Check if level strings declaration: all items must be non-empty String
    final isAllString = valuesRaw.every(
      (v) => v is String && v.trim().isNotEmpty,
    );
    if (isAllString) {
      final defaultRaw = raw['default'];
      String? defaultString;
      if (defaultRaw != null) {
        if (defaultRaw is! String) {
          return null;
        }
        final trimmed = defaultRaw.trim();
        if (trimmed.isEmpty) {
          return null;
        }
        defaultString = trimmed;
      }
      final stringValues = valuesRaw
          .map((v) => (v as String).trim())
          .toSet()
          .toList(growable: false);
      if (defaultString != null && !stringValues.contains(defaultString)) {
        return null;
      }
      return OllamaLevelThinkingDeclaration(
        values: stringValues,
        defaultValue: defaultString,
      );
    }

    // Mixed or unsupported value types => malformed
    return null;
  }

  /// Level-only thinking models reject boolean off toggles in Ollama.
  static bool requiresLevelOnly(Map<String, Object?> metadata, String modelId) {
    final parameters = metadata['ollama_parameters']?.toString() ?? '';
    if (parameters.contains('think=true') &&
        !parameters.contains('think=false')) {
      return true;
    }
    return false;
  }
}
