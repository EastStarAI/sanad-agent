// The single owner of how one model's context window is decided.
//
// Precedence (owner decisions, 2026-11-10):
//   1. user `context.modelLimits[<model>]`  — applied as-is, never capped;
//   2. built-in per-model default           — capped;
//   3. provider evidence (catalog cache, live probe, models.dev, known static
//      metadata)                           — capped;
//   4. nothing known: the cap for a cloud route, the local fallback for a
//      local/self-hosted route (also capped).
//
// The project ships a global cap (`context.maxLimit`, built-in 358000; a user
// value replaces it and `0` disables it) plus a small built-in per-model table.
// No adapter and no consumer may re-apply any of these rules: they call
// [ModelAwareRuntimePolicy.resolveContextWindow] and use the returned value.

import 'builtin_policy_defaults.dart';

/// Which layer answered for an effective context window.
enum ContextWindowSource {
  /// `context.modelLimits` in the user's `config.yaml` (never capped).
  userOverride('user'),

  /// A project built-in per-model default (capped).
  builtInDefault('built-in'),

  /// The revision-matched provider model catalog cache (capped).
  providerCatalog('catalog'),

  /// Live provider metadata, models.dev, or known static model metadata
  /// (capped).
  providerMetadata('provider'),

  /// Nothing is known and a cloud route gets the global cap.
  cloudCap('unknown-cloud-cap'),

  /// Nothing is known and a local/self-hosted route gets the local fallback,
  /// which is still subject to the cap.
  localFallback('unknown-local-fallback'),

  /// Nothing is known, the cap is disabled, and the caller's own conservative
  /// fallback applies (the pre-existing behaviour of `maxLimit: 0`).
  legacyFallback('fallback');

  const ContextWindowSource(this.label);

  /// Stable diagnostic label for this source.
  final String label;
}

/// One provider-owned context window value, before any policy is applied.
///
/// Adapters build it from catalog cache, a live probe, models.dev or known
/// static metadata. It never carries a user override or a built-in default:
/// those are policy layers, not provider evidence.
class ProviderContextWindow {
  final int tokens;
  final ContextWindowSource source;

  const ProviderContextWindow({required this.tokens, required this.source})
    : assert(
        source == ContextWindowSource.providerCatalog ||
            source == ContextWindowSource.providerMetadata,
        'ProviderContextWindow.source must be a provider layer',
      );
}

/// The decided window for one model plus the provenance of the decision.
class ContextWindowResolution {
  /// The normalized model id this resolution applies to.
  final String modelId;

  /// The effective window every consumer must use.
  final int tokens;

  /// The layer that produced the value.
  final ContextWindowSource source;

  /// The value before the cap, when a layer supplied one.
  final int? base;

  /// The effective cap; `0` means the cap is disabled.
  final int cap;

  /// The value the cap lowered, when the cap changed the outcome.
  final int? cappedFrom;

  const ContextWindowResolution({
    required this.modelId,
    required this.tokens,
    required this.source,
    required this.base,
    required this.cap,
    this.cappedFrom,
  });

  /// Whether the cap lowered [base], or replaced an unknown window.
  bool get wasCapped =>
      cappedFrom != null || source == ContextWindowSource.cloudCap;

  /// One-line provenance for diagnostic surfaces, e.g.
  /// `258000 tokens (built-in)` or
  /// `358000 tokens (catalog; capped from 1000000)`.
  String describe() {
    final provenance = StringBuffer(source.label);
    if (cappedFrom != null) provenance.write('; capped from $cappedFrom');
    return '$tokens tokens ($provenance)';
  }

  @override
  String toString() => 'ContextWindowResolution($modelId, ${describe()})';
}

/// Project constants and the shipped default table for context windows.
abstract final class ContextWindowPolicy {
  ContextWindowPolicy._();

  /// Project built-in global cap: the default ceiling for every resolved
  /// window when `context.maxLimit` is absent.
  static const int builtInMaxLimit = 358000;

  /// Window for a local/self-hosted route whose live probe failed and that has
  /// no other evidence. Deliberately far below the global cap: an engine that
  /// refused to report its window is usually much smaller than 358000, and an
  /// oversized request is a provider error rather than a compaction.
  static const int localFallbackLimit = 16000;

  /// Smallest accepted `context.maxLimit`. Below this a window cannot hold the
  /// compaction summary reservation plus a usable request, so such a value is a
  /// configuration error instead of a pressure dial.
  static const int minimumMaxLimit = 8192;

  /// Built-in per-model defaults, keyed by exact normalized model id.
  ///
  /// Both are subject to the global cap; a user `context.modelLimits` entry for
  /// the same key wins as-is and is never capped.
  static const BuiltinModelPolicyDefaults<int> builtinModelLimits =
      BuiltinModelPolicyDefaults<int>(
        section: 'context.modelLimits',
        entries: {
          'gpt-6.1-sol': BuiltinPolicyDefault<int>(
            value: 258000,
            reason:
                'Sol routes advertise a million-token catalog window, but the '
                'project working window is 258000 (the same value the shipped '
                'Sol example already used), so compaction stays predictable.',
            date: '2026-11-10',
          ),
          'deepseek-v4.1-flash': BuiltinPolicyDefault<int>(
            value: 358000,
            reason:
                'The primary OpenCode Go route advertises W=1000000; the '
                'project ceiling of 358000 is the intended working window.',
            date: '2026-11-10',
          ),
        },
      );

  /// The resolution for an already-normalized model id.
  ///
  /// [unknownCloudFallback] is the caller's pre-existing conservative value for
  /// a cloud route with no evidence when the cap is disabled (`maxLimit: 0`);
  /// it never applies while a cap is in force.
  static ContextWindowResolution resolveForNormalizedId({
    required String normalizedModelId,
    required Map<String, int> userModelLimits,
    required BuiltinModelPolicyDefaults<int> builtinModelLimits,
    required int? maxLimit,
    required ProviderContextWindow? providerEvidence,
    required int unknownCloudFallback,
    bool localProvider = false,
  }) {
    final cap = maxLimit ?? builtInMaxLimit;

    ContextWindowResolution decided(
      int base,
      ContextWindowSource source,
    ) {
      final effective = cap == 0 || base <= cap ? base : cap;
      return ContextWindowResolution(
        modelId: normalizedModelId,
        tokens: effective,
        source: source,
        base: base,
        cap: cap,
        cappedFrom: effective == base ? null : base,
      );
    }

    final userLimit = userModelLimits[normalizedModelId];
    if (userLimit != null) {
      return ContextWindowResolution(
        modelId: normalizedModelId,
        tokens: userLimit,
        source: ContextWindowSource.userOverride,
        base: userLimit,
        cap: cap,
      );
    }

    final builtInLimit = builtinModelLimits.valueFor(normalizedModelId);
    if (builtInLimit != null) {
      return decided(builtInLimit, ContextWindowSource.builtInDefault);
    }

    final evidence = providerEvidence;
    if (evidence != null && evidence.tokens > 0) {
      return decided(evidence.tokens, evidence.source);
    }

    if (localProvider) {
      return decided(localFallbackLimit, ContextWindowSource.localFallback);
    }

    if (cap == 0) {
      return ContextWindowResolution(
        modelId: normalizedModelId,
        tokens: unknownCloudFallback,
        source: ContextWindowSource.legacyFallback,
        base: null,
        cap: cap,
      );
    }

    return ContextWindowResolution(
      modelId: normalizedModelId,
      tokens: cap,
      source: ContextWindowSource.cloudCap,
      base: null,
      cap: cap,
      cappedFrom: null,
    );
  }
}
