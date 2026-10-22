import 'package:sanad_agent/core/provider_runtime/provider_instance.dart';

/// Outcome of resolving a user-supplied provider selector.
sealed class ProviderSelectorResult {
  const ProviderSelectorResult();
}

/// Exactly one configured instance matched the selector.
class ProviderSelectorMatch extends ProviderSelectorResult {
  final ProviderInstance instance;

  const ProviderSelectorMatch(this.instance);
}

/// Nothing matched the selector.
class ProviderSelectorUnknown extends ProviderSelectorResult {
  /// Selectors a caller may pass for the current Home, most specific first.
  final List<String> acceptedSelectors;

  const ProviderSelectorUnknown(this.acceptedSelectors);
}

/// More than one instance matched at the same specificity tier.
class ProviderSelectorAmbiguous extends ProviderSelectorResult {
  final List<ProviderInstance> candidates;

  const ProviderSelectorAmbiguous(this.candidates);
}

/// Resolves `--provider` values against configured provider instances.
///
/// A selector is matched at the first tier that produces a hit, which keeps
/// resolution deterministic when a display name happens to equal another
/// instance's template id: instance id, then template id, then display name.
class ProviderSelector {
  const ProviderSelector._();

  /// Selectors accepted for [instances], deduplicated and order-preserving.
  static List<String> acceptedSelectors(List<ProviderInstance> instances) {
    final seen = <String>{};
    final selectors = <String>[];
    void add(String value) {
      final trimmed = value.trim();
      if (trimmed.isEmpty) return;
      if (seen.add(_normalize(trimmed))) selectors.add(trimmed);
    }

    for (final instance in instances) {
      add(instance.id);
      add(instance.templateId);
      add(instance.displayName);
    }
    return selectors;
  }

  /// Selector hints for [instances], one per instance in print order.
  static List<String> instanceSelectors(List<ProviderInstance> instances) =>
      instances.map((instance) => instance.templateId).toList(growable: false);

  /// Resolves [selector] against [instances].
  static ProviderSelectorResult resolve(
    List<ProviderInstance> instances,
    String selector,
  ) {
    final needle = _normalize(selector);
    if (needle.isEmpty) return ProviderSelectorUnknown(acceptedSelectors(instances));

    final tiers = <bool Function(ProviderInstance)>[
      (instance) => _normalize(instance.id) == needle,
      (instance) => _normalize(instance.templateId) == needle,
      (instance) => _normalize(instance.displayName) == needle,
    ];

    for (final matchesTier in tiers) {
      final matches = instances.where(matchesTier).toList(growable: false);
      if (matches.length == 1) return ProviderSelectorMatch(matches.single);
      if (matches.length > 1) return ProviderSelectorAmbiguous(matches);
    }

    return ProviderSelectorUnknown(acceptedSelectors(instances));
  }

  static String _normalize(String value) =>
      value.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
}
