import '../../../../core/config.dart';
import '../../../../core/models/model_metadata.dart';
import '../../../../core/provider_runtime/provider_endpoint_resolver.dart';
import '../../../../core/provider_runtime/provider_model_id.dart';
import '../../../../interfaces/platforms/sanad_gateway/capabilities.dart';
import '../models_dev_service.dart';
import '../provider_profile.dart';

/// Pure model-discovery rules for the OpenAI-compatible adapter (Plan 138-10).
///
/// Every member is a stateless transformation of the inputs it is given: the
/// adapter keeps the transport, the mutable discovery outcome state and the
/// `models.dev` service, and only its own orchestration mutates them. Identity
/// normalization, the fallback catalog, endpoint candidates, label formatting
/// and the agentic/reasoning/context heuristics therefore have exactly one
/// owner.
class OpenAiCompatibleModelDiscovery {
  OpenAiCompatibleModelDiscovery._();

  static String normalizeModelId(
    ProviderProfile profile,
    String rawModelId,
  ) {
    return ProviderModelId.normalize(
      templateId: profile.name,
      protocol: profile.effectiveProtocol,
      rawModelId: rawModelId,
    );
  }

  static String fallbackModelId({
    required Config config,
    required ProviderProfile profile,
    String? defaultModelOverride,
  }) {
    final configured = defaultModelOverride ?? config.llmModel;
    return normalizeModelId(profile, configured);
  }

  static List<ModelOption> fallbackModelOptions({
    required Config config,
    required ProviderProfile profile,
    String? defaultModelOverride,
  }) {
    final merged = <String>[];
    final selected = fallbackModelId(
      config: config,
      profile: profile,
      defaultModelOverride: defaultModelOverride,
    );
    if (selected.isNotEmpty) {
      merged.add(selected);
    }
    for (final model in profile.fallbackModels) {
      final normalized = normalizeModelId(profile, model);
      if (normalized.isNotEmpty && !merged.contains(normalized)) {
        merged.add(normalized);
      }
    }
    if (merged.isEmpty) {
      merged.add(selected);
    }

    return merged
        .map((modelId) {
          final lowered = modelId.toLowerCase();
          return ModelOption(
            value: modelId,
            label: formatModelLabel(modelId),
            provider: profile.name,
            contextWindow: ModelMetadata.getLimitForModel(modelId),
            supportsReasoning:
                lowered.contains('o1') ||
                lowered.contains('o3') ||
                lowered.contains('reasoning'),
          );
        })
        .toList(growable: false);
  }

  static List<Uri> modelsEndpointCandidates(String baseUrl) {
    return ProviderEndpointResolver.resolveOpenAiModelsEndpointCandidates(
      baseUrl,
    );
  }

  static String formatModelLabel(String name) {
    String capitalize(String s) =>
        s.isEmpty ? '' : '${s[0].toUpperCase()}${s.substring(1)}';

    var cleanName = name.contains('/') ? name.split('/').last : name;
    if (cleanName.startsWith('~')) {
      cleanName = cleanName.substring(1);
    }

    return cleanName
        .split('-')
        .map((part) {
          if (part.startsWith('gpt')) {
            return 'GPT${part.substring(3)}';
          }
          return capitalize(part);
        })
        .join(' ');
  }

  static bool isAgenticModel(
    ProviderProfile profile,
    String modelId,
    List<String> agenticModels,
  ) {
    if (profile.isCustom || profile.effectiveAuthFlow == 'custom_endpoint') {
      return true;
    }

    final lowercaseId = modelId.toLowerCase();

    if (agenticModels.isNotEmpty) {
      if (agenticModels.any((m) => m.toLowerCase() == lowercaseId)) {
        return true;
      }
    }

    // Strip namespaces (like openai/, google/, anthropic/) and tildes (~anthropic/)
    var cleanId = lowercaseId.contains('/')
        ? lowercaseId.split('/').last
        : lowercaseId;
    if (cleanId.startsWith('~')) {
      cleanId = cleanId.substring(1);
    }

    // Heuristics fallback
    final matchesKnown =
        cleanId.startsWith('gpt-') ||
        cleanId.startsWith('o1-') ||
        cleanId.startsWith('o3-') ||
        cleanId.startsWith('claude-') ||
        cleanId.contains('deepseek') ||
        cleanId.startsWith('gemma-') ||
        cleanId.startsWith('gemma') ||
        profile.name == 'nvidia' ||
        cleanId.contains('nvidia') ||
        cleanId.contains('nemotron');

    if (matchesKnown) return true;

    return ModelMetadata.getLimitForModel(cleanId) != null;
  }

  static Future<bool> modelSupportsReasoning(
    ModelsDevService? modelsDevService,
    ProviderProfile profile,
    String modelId,
  ) async {
    if (modelsDevService != null) {
      final registryMatch = await modelsDevService.supportsReasoning(
        profile.name,
        modelId,
      );
      if (registryMatch) return true;
    }
    final lowercaseId = modelId.toLowerCase();
    return lowercaseId.contains('o1') ||
        lowercaseId.contains('o3') ||
        lowercaseId.contains('o4') ||
        lowercaseId.contains('gpt-5') ||
        lowercaseId.contains('gpt-6') ||
        lowercaseId.contains('reasoning') ||
        lowercaseId.contains('deepseek-r');
  }

  static Future<int?> modelContextLimit(
    ModelsDevService? modelsDevService,
    ProviderProfile profile,
    String modelId,
  ) async {
    if (modelsDevService != null) {
      return modelsDevService.getContextLimit(profile.name, modelId);
    }
    return ModelMetadata.getLimitForModel(modelId);
  }
}
