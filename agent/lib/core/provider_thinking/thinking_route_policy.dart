/// Fail-closed thinking policy resolution for provider routes (Task 43 Gate A).
library;

import '../provider_runtime/provider_instance.dart';
import '../provider_runtime/provider_protocol_constants.dart';
import '../../engine/adapters/provider_profile.dart';

class ThinkingRoutePolicy {
  ThinkingRoutePolicy._();

  static const unknownPolicyId = 'unknown';

  /// Resolves the thinking policy id for [instance].
  ///
  /// Unknown template ids fail closed to [unknownPolicyId] per Plan 29 §3.10.
  static String policyIdFor(ProviderInstance instance) {
    return resolveTemplate(instance).effectiveThinkingPolicyId;
  }

  /// Resolves the effective provider template for thinking policy lookup.
  static ProviderProfile resolveTemplate(ProviderInstance instance) {
    return instance.template ?? _unknownTemplate(instance);
  }

  /// Effective wire api mode for thinking policy context.
  static String apiModeFor(ProviderInstance instance, ProviderProfile template) {
    if (instance.isCustom) {
      return instance.protocol == ProviderProtocol.anthropicCompatible
          ? 'anthropic_messages'
          : 'chat_completions';
    }
    return template.apiMode;
  }

  static ProviderProfile _unknownTemplate(ProviderInstance instance) {
    return ProviderProfile(
      name: instance.templateId,
      protocol: instance.protocol,
      thinkingPolicyId: unknownPolicyId,
    );
  }
}
