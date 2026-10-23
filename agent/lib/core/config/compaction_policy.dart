// Context-compaction policy owners extracted from core/config.dart: the
// threshold/target ratio policy, exact per-model overrides, the complete
// post-compaction request target, and the bounded recovery limits.

class CompactionPolicy {
  final double threshold;
  final double targetRatio;

  const CompactionPolicy({required this.threshold, required this.targetRatio});
}

class ModelAwareCompactionPolicy extends CompactionPolicy {
  /// Default bound for one compaction provider pass (summary, repair, chunk
  /// or reduce) to return its complete response (Task 118). Non-streamed
  /// passes cannot report progress, so the normal-turn `connectTimeout`
  /// (90 s) cut slow models whose ~50k-input recovery passes took 60-71 s.
  /// A near-window main pass is several times larger, so the default leaves
  /// room for a full-window pass at that observed throughput while staying
  /// bounded. `config.yaml` `compaction.passTimeoutSeconds` overrides it.
  static const defaultPassTimeout = Duration(seconds: 600);

  final Map<String, CompactionPolicy> models;

  /// Bound for one compaction provider pass to return its whole response.
  final Duration passTimeout;

  const ModelAwareCompactionPolicy({
    required super.threshold,
    required super.targetRatio,
    required this.models,
    this.passTimeout = defaultPassTimeout,
  });

  CompactionPolicy forModel(String normalizedModelId) {
    final override = models[normalizedModelId];
    return override ??
        CompactionPolicy(threshold: threshold, targetRatio: targetRatio);
  }
}

/// Complete post-compaction request target (Task 118 Stage3A).
///
/// The target covers the whole next request (system/runtime instructions,
/// tools, summary, retained tail, media and replay) and is a ratio of the
/// full resolved window `W`, never of the internal usable input budget.
abstract final class CompactionTargetPolicy {
  /// Planning reservation for the summary while the retained tail is chosen,
  /// before the summary exists: the summary instruction asks for about two
  /// pages. A previous summary's measured size replaces it when one exists.
  /// It never enters a reported measurement: the target outcome is decided on
  /// the measured request after the summary is generated.
  static const int summaryReservationTokens = 2048;

  /// The complete-request target for a resolved window `W`.
  static int targetRequestTokens({
    required int windowTokens,
    required double ratio,
  }) => windowTokens <= 0 ? 0 : (windowTokens * ratio).floor();
}

/// Limits of the bounded recovery summarizer that runs when the ordinary
/// provider-backed compaction request overflows (Task 117, 0P-F2).
class CompactionRecoveryPolicy {
  static const defaults = CompactionRecoveryPolicy(
    passBudgetSafetyRatio: 0.80,
    maxChunks: 16,
    minPassBudgetTokens: 512,
    fallbackOutputReservationTokens: 16_384,
  );

  /// Fraction of the effective input budget one recovery pass may use. Kept
  /// below 1 because the estimate is not an exact tokenizer: since Task 118b
  /// non-ASCII text is priced by its encoding, so the margin now covers
  /// tokenizer variance on code, JSON and tool output rather than Arabic and
  /// CJK undercounting.
  final double passBudgetSafetyRatio;

  /// Maximum number of source chunks one recovery may summarize. A source
  /// that needs more fails before any recovery provider call.
  final int maxChunks;

  /// Smallest usable per-pass source budget after the stable system prompt,
  /// tool schemas, and instruction are reserved.
  final int minPassBudgetTokens;

  /// Output reservation assumed for the pre-send fit check of the full
  /// summary pass when no route capability (settings, provider metadata,
  /// models.dev) declares the model's maximum output (Task 118b). It is the
  /// default completion reservation a provider applied when the request set
  /// no output limit (live: 16384). Planning only: compaction never sends an
  /// output cap of its own.
  final int fallbackOutputReservationTokens;

  const CompactionRecoveryPolicy({
    required this.passBudgetSafetyRatio,
    required this.maxChunks,
    required this.minPassBudgetTokens,
    this.fallbackOutputReservationTokens = 16_384,
  });
}
