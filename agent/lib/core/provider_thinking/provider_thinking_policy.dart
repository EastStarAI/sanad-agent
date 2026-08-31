/// Provider thinking policy contract and registry (Task 43 Gate A).
library;

import 'thinking_control_models.dart';
import 'native_thinking_directive.dart';
import 'thinking_policy_context.dart';

/// Resolves thinking capability and native directives for one provider route.
abstract interface class ProviderThinkingPolicy {
  /// Stable policy id referenced by provider templates.
  String get policyId;

  /// Computes the descriptor advertised for [context].
  ThinkingControlDescriptor resolveCapability(ThinkingPolicyContext context);

  /// Resolves a stored selection id into a typed native directive.
  ///
  /// [selectionId] null/empty means provider default by omission.
  NativeThinkingDirective resolveDirective(
    ThinkingPolicyContext context,
    String? selectionId,
  );
}

/// Registry of per-policy thinking policies. This is the single authority for
/// which policy owns a provider route's thinking controls.
class ProviderThinkingRegistry {
  final Map<String, ProviderThinkingPolicy> _byPolicyId = {};
  final ProviderThinkingPolicy _fallbackPolicy;

  ProviderThinkingRegistry({required ProviderThinkingPolicy fallbackPolicy})
    : _fallbackPolicy = fallbackPolicy;

  void register(ProviderThinkingPolicy policy) {
    _byPolicyId[policy.policyId] = policy;
  }

  ProviderThinkingPolicy policyFor(String policyId) {
    return _byPolicyId[policyId] ?? _fallbackPolicy;
  }

  ProviderThinkingPolicy resolveForTemplate({
    required String thinkingPolicyId,
  }) {
    return policyFor(thinkingPolicyId);
  }

  List<String> get registeredPolicyIds =>
      _byPolicyId.keys.toList(growable: false);
}
