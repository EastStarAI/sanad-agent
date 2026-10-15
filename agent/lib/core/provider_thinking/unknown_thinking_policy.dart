/// Fail-closed thinking policy for unknown/custom routes (Task 43 Gate A).
library;

import 'thinking_control_models.dart';
import 'native_thinking_directive.dart';
import 'provider_thinking_policy.dart';
import 'thinking_policy_context.dart';

class UnknownThinkingPolicy implements ProviderThinkingPolicy {
  @override
  String get policyId => 'unknown';

  @override
  ThinkingControlDescriptor resolveCapability(ThinkingPolicyContext context) {
    return ThinkingControlDescriptor.unknown(
      capabilityRevision: context.capabilityRevision,
      source: 'profile',
    );
  }

  @override
  NativeThinkingDirective resolveDirective(
    ThinkingPolicyContext context,
    String? selectionId,
  ) {
    return const UseProviderDefault();
  }
}
