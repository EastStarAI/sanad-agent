/// Validates thinking selections against the active route descriptor.
library;

import 'package:sanad_agent/core/provider_runtime/provider_instance.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/core/provider_thinking/native_thinking_directive.dart';
import 'package:sanad_agent/core/provider_thinking/provider_thinking_policy.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_capability_assembler.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_control_cache_resolver.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_control_models.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_policy_context.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_control_stale_evidence.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_route_policy.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_selection_aliases.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_selection_errors.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/capabilities.dart';

class ThinkingSelectionResolution {
  final String? selectionId;
  final ThinkingControlDescriptor descriptor;
  final NativeThinkingDirective directive;

  const ThinkingSelectionResolution({
    required this.selectionId,
    required this.descriptor,
    required this.directive,
  });
}

class ThinkingSelectionResolver {
  final ProviderInstanceRepository _instances;
  final ThinkingControlCacheResolver _cacheResolver;
  final ThinkingCapabilityAssembler _assembler;
  final ProviderThinkingRegistry _registry;

  ThinkingSelectionResolver({
    required ProviderInstanceRepository instances,
    required ThinkingControlCacheResolver cacheResolver,
    required ThinkingCapabilityAssembler assembler,
    required ProviderThinkingRegistry registry,
  }) : _instances = instances,
       _cacheResolver = cacheResolver,
       _assembler = assembler,
       _registry = registry;

  ThinkingSelectionResolution resolve({
    required String providerInstanceId,
    required String modelId,
    required String? selectionId,
  }) {
    final instance = _instances.findById(providerInstanceId);
    if (instance == null) {
      throw ThinkingSelectionException(
        code: ThinkingSelectionErrorCode.instanceNotFound,
        message: 'Provider instance not found for thinking validation.',
      );
    }

    final model = _modelForRoute(instance: instance, modelId: modelId);
    final descriptor = _descriptorForRoute(instance: instance, model: model);
    final trimmed = selectionId?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      return _buildResolution(
        instance: instance,
        model: model,
        descriptor: descriptor,
        selectionId: null,
      );
    }

    if (descriptor.status == ThinkingCapabilityStatus.unsupported) {
      throw ThinkingSelectionException(
        code: ThinkingSelectionErrorCode.capabilityUnsupported,
        message: 'Thinking controls are unsupported for the active model route.',
      );
    }
    if (descriptor.status == ThinkingCapabilityStatus.unknown) {
      throw ThinkingSelectionException(
        code: ThinkingSelectionErrorCode.capabilityUnknown,
        message: 'Thinking controls are unavailable for the active model route.',
      );
    }

    final resolvedSelectionId =
        migrateLegacyThinkingSelectionId(
          selectionId: trimmed,
          descriptor: descriptor,
        ) ??
        trimmed;

    if (!descriptor.containsOptionId(resolvedSelectionId)) {
      throw ThinkingSelectionException(
        code: ThinkingSelectionErrorCode.optionUnavailable,
        message: 'The selected thinking option is unavailable for this route.',
      );
    }

    return _buildResolution(
      instance: instance,
      model: model,
      descriptor: descriptor,
      selectionId: resolvedSelectionId,
    );
  }

  ThinkingSelectionResolution _buildResolution({
    required ProviderInstance instance,
    required ModelOption model,
    required ThinkingControlDescriptor descriptor,
    required String? selectionId,
  }) {
    final template = ThinkingRoutePolicy.resolveTemplate(instance);
    final policyId = template.effectiveThinkingPolicyId;
    final policy = _registry.resolveForTemplate(thinkingPolicyId: policyId);
    final context = ThinkingPolicyContext(
      providerInstanceId: instance.id,
      templateId: instance.templateId,
      protocol: instance.protocol,
      apiMode: ThinkingRoutePolicy.apiModeFor(instance, template),
      modelId: model.value,
      supportsReasoningOutput: model.supportsReasoningOutput,
      capabilityRevision: descriptor.capabilityRevision,
      modelMetadata: model.modelMetadata,
    );
    final directive = policy.resolveDirective(context, selectionId);
    if (selectionId != null && directive is UseProviderDefault) {
      throw ThinkingSelectionException(
        code: ThinkingSelectionErrorCode.optionUnavailable,
        message: 'The selected thinking option is unavailable for this route.',
      );
    }
    return ThinkingSelectionResolution(
      selectionId: selectionId,
      descriptor: descriptor,
      directive: directive,
    );
  }

  ModelOption _modelForRoute({
    required ProviderInstance instance,
    required String modelId,
  }) {
    final cached = _cacheResolver.resolve(
      providerInstanceId: instance.id,
      modelId: modelId,
      templateId: instance.templateId,
      protocol: instance.protocol,
      configRevision: instance.configRevision,
      credentialRevision: instance.credentialRevision,
    );
    if (cached != null) {
      return ModelOption.fromJson({
        'value': modelId,
        'label': modelId,
        'thinking_control': cached,
      });
    }
    return ModelOption(value: modelId, label: modelId);
  }

  ThinkingControlDescriptor _descriptorForRoute({
    required ProviderInstance instance,
    required ModelOption model,
  }) {
    final fresh = _assembler.assemble(instance: instance, model: model);
    final cached = model.thinkingControl;
    if (cached == null) {
      return fresh;
    }
    if (cached.capabilityRevision != fresh.capabilityRevision) {
      return fresh;
    }
    if (ThinkingControlStaleEvidence.isStale(cached)) {
      return ThinkingControlStaleEvidence.freshUnknown(
        capabilityRevision: fresh.capabilityRevision,
      );
    }
    return cached;
  }
}
