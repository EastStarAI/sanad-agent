/// Assembles per-model thinking capability descriptors (Task 43 Gate B).
library;

import 'package:sanad_agent/core/provider_runtime/provider_instance.dart';
import 'package:sanad_agent/core/provider_thinking/provider_thinking_policy.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_control_models.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_policy_context.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_route_policy.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/capabilities.dart';

class ThinkingCapabilityAssembler {
  final ProviderThinkingRegistry _registry;

  ThinkingCapabilityAssembler(this._registry);

  ThinkingControlDescriptor assemble({
    required ProviderInstance instance,
    required ModelOption model,
    DateTime? observedAt,
    String? evidenceSource,
  }) {
    final template = ThinkingRoutePolicy.resolveTemplate(instance);
    final policyId = template.effectiveThinkingPolicyId;
    final policy = _registry.resolveForTemplate(thinkingPolicyId: policyId);
    final capabilityRevision =
        '${instance.configRevision}:${instance.credentialRevision}:$policyId:${model.value}';

    final descriptor = policy.resolveCapability(
      ThinkingPolicyContext(
        providerInstanceId: instance.id,
        templateId: instance.templateId,
        protocol: instance.protocol,
        apiMode: ThinkingRoutePolicy.apiModeFor(instance, template),
        modelId: model.value,
        supportsReasoningOutput: model.supportsReasoningOutput,
        capabilityRevision: capabilityRevision,
        modelMetadata: model.modelMetadata,
      ),
    );

    return descriptor.copyWith(
      source: evidenceSource ?? descriptor.source,
      observedAt: observedAt ?? descriptor.observedAt,
    );
  }

  ModelOption enrich({
    required ProviderInstance instance,
    required ModelOption model,
    DateTime? observedAt,
    String? evidenceSource,
  }) {
    final thinkingControl = assemble(
      instance: instance,
      model: model,
      observedAt: observedAt,
      evidenceSource: evidenceSource,
    );
    return model.copyWith(thinkingControl: thinkingControl);
  }

  List<ModelOption> enrichAll({
    required ProviderInstance instance,
    required List<ModelOption> models,
    DateTime? observedAt,
    String? evidenceSource,
  }) {
    return models
        .map(
          (model) => enrich(
            instance: instance,
            model: model,
            observedAt: observedAt,
            evidenceSource: evidenceSource,
          ),
        )
        .toList(growable: false);
  }

  /// Marks cached models unknown after a transient live probe failure.
  List<ModelOption> markProbeFailed({
    required ProviderInstance instance,
    required List<ModelOption> models,
  }) {
    return models
        .map(
          (model) => model.copyWith(
            thinkingControl: ThinkingControlDescriptor.unknown(
              capabilityRevision:
                  '${instance.configRevision}:${instance.credentialRevision}:probe_failed:${model.value}',
              source: 'live_probe_failed',
            ),
          ),
        )
        .toList(growable: false);
  }
}
