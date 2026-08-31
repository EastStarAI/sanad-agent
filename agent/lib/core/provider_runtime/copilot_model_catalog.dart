/// Parsed, policy-filtered Copilot `/models` entry.
class CopilotLiveModel {
  final String id;
  final int? contextLimit;
  final bool vision;
  final bool reasoningEffort;

  const CopilotLiveModel({
    required this.id,
    this.contextLimit,
    this.vision = false,
    this.reasoningEffort = false,
  });
}

/// Filters GitHub Copilot live models to those Sanad can actually run.
///
/// Drops enterprise-disabled or unconfigured SKUs (`policy.state`), models
/// that cannot stream or call tools, and entries hidden from the model picker.
class CopilotModelCatalog {
  CopilotModelCatalog._();

  static const enabledPolicy = 'enabled';

  static List<CopilotLiveModel> parseList(dynamic payload) {
    if (payload is! Map) return const [];
    final data = payload['data'];
    if (data is! List) return const [];
    final models = <CopilotLiveModel>[];
    for (final item in data) {
      final parsed = tryParse(item);
      if (parsed != null) models.add(parsed);
    }
    return models;
  }

  static CopilotLiveModel? tryParse(dynamic item) {
    if (item is! Map) return null;
    final id = item['id']?.toString().trim() ?? '';
    if (id.isEmpty) return null;
    if (item['model_picker_enabled'] == false) return null;

    final policy = item['policy'];
    if (policy is Map) {
      final state = policy['state']?.toString().trim().toLowerCase() ?? '';
      if (state.isNotEmpty && state != enabledPolicy) return null;
    }

    Map<Object?, Object?>? supports;
    Map<Object?, Object?>? limits;
    final capabilities = item['capabilities'];
    if (capabilities is Map) {
      final rawSupports = capabilities['supports'];
      if (rawSupports is Map) supports = rawSupports;
      final rawLimits = capabilities['limits'];
      if (rawLimits is Map) limits = rawLimits;
    }
    if (supports != null) {
      if (supports['tool_calls'] == false) return null;
      if (supports['streaming'] == false) return null;
    }

    int? contextLimit;
    if (limits != null) {
      for (final key in const [
        'max_context_window_tokens',
        'max_prompt_tokens',
        'max_tokens',
      ]) {
        final value = limits[key];
        if (value is num && value > 0) {
          contextLimit = value.toInt();
          break;
        }
      }
    }

    return CopilotLiveModel(
      id: id,
      contextLimit: contextLimit,
      vision: supports?['vision'] == true,
      reasoningEffort: supports?['reasoning_effort'] == true,
    );
  }
}
