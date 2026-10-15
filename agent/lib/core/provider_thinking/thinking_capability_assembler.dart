/// Assembles per-model thinking capability descriptors (Task 43 Gate B).
library;

import 'package:sanad_agent/core/provider_runtime/provider_instance.dart';
import 'package:sanad_agent/core/provider_thinking/provider_thinking_policy.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_control_models.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_policy_context.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_route_policy.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/capabilities.dart';

import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/provider_thinking/openai_reasoning_models.dart';

class ThinkingCapabilityAssembler {
  final ProviderThinkingRegistry _registry;
  final Config? _config;

  ThinkingCapabilityAssembler(this._registry, [this._config]);

  ThinkingControlDescriptor assemble({
    required ProviderInstance instance,
    required ModelOption model,
    DateTime? observedAt,
    String? evidenceSource,
  }) {
    final override = _config?.modelAwarePolicy
        .capabilityOverrideFor(model.value)
        ?.thinkingControl;

    if (override != null) {
      if (override.status == ThinkingCapabilityStatus.unsupported) {
        return ThinkingControlDescriptor.unsupported(
          capabilityRevision:
              '${instance.configRevision}:${instance.credentialRevision}:override_${override.fingerprint}:${model.value}',
          source: evidenceSource ?? 'config_override',
          observedAt: observedAt,
        );
      }
      if (override.status == ThinkingCapabilityStatus.unknown) {
        return ThinkingControlDescriptor.unknown(
          capabilityRevision:
              '${instance.configRevision}:${instance.credentialRevision}:override_${override.fingerprint}:${model.value}',
          source: evidenceSource ?? 'config_override',
          observedAt: observedAt,
        );
      }

      final template = ThinkingRoutePolicy.resolveTemplate(instance);
      final apiMode = ThinkingRoutePolicy.apiModeFor(instance, template);
      if (!ThinkingRoutePolicy.isWireCompatible(
        wire: override.wire!,
        protocol: instance.protocol,
        apiMode: apiMode,
      )) {
        return ThinkingControlDescriptor.unsupported(
          capabilityRevision:
              '${instance.configRevision}:${instance.credentialRevision}:override_incompatible_${override.fingerprint}:${model.value}',
          source: evidenceSource ?? 'config_override',
          observedAt: observedAt,
        );
      }

      final kind = switch (override.wire) {
        'openai_chat_effort' ||
        'codex_responses_effort' => ThinkingControlKind.effort,
        'anthropic_adaptive' => ThinkingControlKind.adaptive,
        'anthropic_budget' => ThinkingControlKind.tokenBudget,
        'toggle_effort' => ThinkingControlKind.toggle,
        'google_thinking' => ThinkingControlKind.level,
        _ => ThinkingControlKind.effort,
      };

      final options = override.options.entries
          .map((entry) {
            final id = entry.key;
            final rawVal = entry.value;
            final label = _labelForOption(id);
            final canWireDisable = switch (override.wire) {
              'openai_chat_effort' ||
              'codex_responses_effort' => rawVal == 'none' || rawVal == 'off',
              'toggle_effort' =>
                rawVal == false || rawVal == 'off' || rawVal == 'none',
              'anthropic_adaptive' =>
                rawVal == false || rawVal == 'off' || rawVal == 'none',
              'google_thinking' =>
                rawVal == 0 || rawVal == 'off' || rawVal == 'none',
              _ => false,
            };
            final isOff =
                canWireDisable &&
                (rawVal == false ||
                    rawVal == 0 ||
                    rawVal == 'none' ||
                    rawVal == 'off');
            const isProviderDefault = false;
            return ThinkingControlOption(
              id: id,
              label: label,
              isOff: isOff,
              isProviderDefault: isProviderDefault,
            );
          })
          .toList(growable: false);

      return ThinkingControlDescriptor(
        status: ThinkingCapabilityStatus.supported,
        kind: kind,
        options: options,
        defaultOptionId: override.defaultOption,
        capabilityRevision:
            '${instance.configRevision}:${instance.credentialRevision}:override_${override.fingerprint}:${model.value}',
        source: evidenceSource ?? 'config_override',
        observedAt: observedAt,
      );
    }

    // Tier 2: Declared endpoint thinking controls
    // Raw endpoint declaration ONLY from actual endpoint item saved in modelMetadata by adapter discovery.
    // No enriched thinking_control ever becomes raw endpoint evidence!
    final rawDeclared = model.modelMetadata['thinking_control'];
    final declaredOverride = ThinkingControlOverride.tryParse(rawDeclared);

    if (declaredOverride != null) {
      final declaredRev =
          '${instance.configRevision}:${instance.credentialRevision}:declared_${declaredOverride.fingerprint}:${model.value}';

      if (declaredOverride.status == ThinkingCapabilityStatus.unsupported) {
        return ThinkingControlDescriptor.unsupported(
          capabilityRevision: declaredRev,
          source: evidenceSource ?? 'endpoint_declared',
          observedAt: observedAt,
        );
      }
      if (declaredOverride.status == ThinkingCapabilityStatus.unknown) {
        return ThinkingControlDescriptor.unknown(
          capabilityRevision: declaredRev,
          source: evidenceSource ?? 'endpoint_declared',
          observedAt: observedAt,
        );
      }

      // Check route/API wire compatibility
      final template = ThinkingRoutePolicy.resolveTemplate(instance);
      final apiMode = ThinkingRoutePolicy.apiModeFor(instance, template);
      final wire = declaredOverride.wire;
      if (wire == null ||
          !ThinkingRoutePolicy.isWireCompatible(
            wire: wire,
            protocol: instance.protocol,
            apiMode: apiMode,
          )) {
        return ThinkingControlDescriptor.unsupported(
          capabilityRevision:
              '${instance.configRevision}:${instance.credentialRevision}:declared_incompatible_${declaredOverride.fingerprint}:${model.value}',
          source: evidenceSource ?? 'endpoint_declared',
          observedAt: observedAt,
        );
      }

      final kind = switch (wire) {
        'openai_chat_effort' ||
        'codex_responses_effort' => ThinkingControlKind.effort,
        'anthropic_adaptive' => ThinkingControlKind.adaptive,
        'anthropic_budget' => ThinkingControlKind.tokenBudget,
        'toggle_effort' => ThinkingControlKind.toggle,
        'google_thinking' => ThinkingControlKind.level,
        _ => null,
      };

      if (kind == null) {
        return ThinkingControlDescriptor.unknown(
          capabilityRevision: declaredRev,
          source: evidenceSource ?? 'endpoint_declared',
          observedAt: observedAt,
        );
      }

      final options = declaredOverride.options.entries
          .map((entry) {
            final id = entry.key;
            final rawVal = entry.value;
            final label = _labelForOption(id);
            final canWireDisable = switch (wire) {
              'openai_chat_effort' ||
              'codex_responses_effort' => rawVal == 'none' || rawVal == 'off',
              'toggle_effort' =>
                rawVal == false || rawVal == 'off' || rawVal == 'none',
              'anthropic_adaptive' =>
                rawVal == false || rawVal == 'off' || rawVal == 'none',
              'google_thinking' =>
                rawVal == 0 || rawVal == 'off' || rawVal == 'none',
              _ => false,
            };
            final isOff =
                canWireDisable &&
                (rawVal == false ||
                    rawVal == 0 ||
                    rawVal == 'none' ||
                    rawVal == 'off');
            const isProviderDefault = false;
            return ThinkingControlOption(
              id: id,
              label: label,
              isOff: isOff,
              isProviderDefault: isProviderDefault,
            );
          })
          .toList(growable: false);

      return ThinkingControlDescriptor(
        status: ThinkingCapabilityStatus.supported,
        kind: kind,
        options: options,
        defaultOptionId: declaredOverride.defaultOption,
        capabilityRevision: declaredRev,
        source: evidenceSource ?? 'endpoint_declared',
        observedAt: observedAt,
      );
    }

    // Tier 3: Trusted exact native mapping
    final template = ThinkingRoutePolicy.resolveTemplate(instance);
    final policyId = ThinkingRoutePolicy.policyIdFor(
      instance,
      modelId: model.value,
    );
    if (policyId != ThinkingRoutePolicy.unknownPolicyId) {
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

      if (descriptor.status != ThinkingCapabilityStatus.unknown) {
        return descriptor.copyWith(
          source: evidenceSource ?? descriptor.source,
          observedAt: observedAt ?? descriptor.observedAt,
        );
      }
    }

    // Tier 4: Custom routes or unknown templates without override or declared metadata
    return ThinkingControlDescriptor.unknown(
      capabilityRevision:
          '${instance.configRevision}:${instance.credentialRevision}:unknown:${model.value}',
      source: evidenceSource ?? 'unconfigured',
      observedAt: observedAt,
    );
  }

  static String _labelForOption(String id) {
    final lower = id.toLowerCase();
    if (openAiEffortTierLabels.containsKey(lower)) {
      return openAiEffortTierLabels[lower]!;
    }
    if (lower == 'off' || lower == 'none') return 'Off';
    if (lower == 'on') return 'On';
    if (id.isEmpty) return id;
    return id[0].toUpperCase() + id.substring(1);
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
