/// Exact evidenced `gpt-oss` reasoning-effort fixtures (Plan77 G4).
///
/// The `gpt-oss` open-weight family documents three reasoning efforts (`low`,
/// `medium`, `high`). That is an intrinsic model fact keyed by the exact model
/// id, exactly like every other vendor catalog: this class deliberately takes no
/// provider-kind or template argument and contains no allowlist, because the
/// model-only contract makes intrinsic facts independent of the configured
/// provider instance. Wire compatibility belongs to the existing
/// route/policy/API-mode boundary, so the fact is advertised only where the
/// active mode carries the compatible Chat `reasoning_effort` field.
///
/// The family documentation does not prove that any particular hosted endpoint
/// serves these models, and llama.cpp's server documents that a request
/// `reasoning_effort` is disabled for `none` and otherwise forwarded to the
/// Jinja chat template — so no route is claimed or denied here. Arbitrary
/// templates without a compatible Chat wire stay unresolved through the existing
/// mode boundary.
library;

class GptOssModelCatalog {
  GptOssModelCatalog._();

  /// Documented finite reasoning efforts for the family.
  static const effortOptionIds = ['low', 'medium', 'high'];

  /// Exact documented model ids, including NVIDIA NIM's namespaced ids.
  static const groundedModelIds = {
    'gpt-oss-120b',
    'gpt-oss-20b',
    'openai/gpt-oss-120b',
    'openai/gpt-oss-20b',
  };

  /// Whether this exact model id is a grounded `gpt-oss` reasoning model.
  static bool isGroundedModelId(String modelId) =>
      groundedModelIds.contains(modelId.trim());

  /// Documented finite effort options for [modelId].
  static List<String> effortOptionIdsForModel(String modelId) =>
      isGroundedModelId(modelId) ? effortOptionIds : const [];

  static bool allowsEffortId({
    required String modelId,
    required String effortId,
  }) => effortOptionIdsForModel(modelId).contains(effortId.trim());

  /// No documented default effort is advertised for the family, so omission
  /// stays provider-managed.
  static String? defaultEffortIdForModel(String modelId) => null;

  static String labelForEffortId(String effortId) {
    return switch (effortId) {
      'low' => 'Low',
      'medium' => 'Medium',
      'high' => 'High',
      _ => effortId,
    };
  }
}
