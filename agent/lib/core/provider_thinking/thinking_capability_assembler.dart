/// Assembles per-model thinking capability descriptors (Task 43 Gate B).
library;

import 'package:sanad_agent/core/provider_runtime/provider_instance.dart';
import 'package:sanad_agent/core/provider_thinking/provider_thinking_policy.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_control_models.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_control_stale_evidence.dart';
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
        templateId: instance.templateId,
        isCustom: instance.isCustom,
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
        'nim_kimi_thinking' => ThinkingControlKind.toggle,
        'nim_qwen_thinking' => ThinkingControlKind.effort,
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
              'nim_kimi_thinking' || 'nim_qwen_thinking' =>
                rawVal == false ||
                    (rawVal is String &&
                        (rawVal.trim().toLowerCase() == 'off' ||
                            rawVal.trim().toLowerCase() == 'false' ||
                            rawVal.trim().toLowerCase() == 'none')),
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
              budgetTokens: _declaredBudgetTokens(override.wire ?? '', rawVal),
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
            templateId: instance.templateId,
            isCustom: instance.isCustom,
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
        'nim_kimi_thinking' => ThinkingControlKind.toggle,
        'nim_qwen_thinking' => ThinkingControlKind.effort,
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
              'nim_kimi_thinking' || 'nim_qwen_thinking' =>
                rawVal == false ||
                    (rawVal is String &&
                        (rawVal.trim().toLowerCase() == 'off' ||
                            rawVal.trim().toLowerCase() == 'false' ||
                            rawVal.trim().toLowerCase() == 'none')),
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
              budgetTokens: _declaredBudgetTokens(wire, rawVal),
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

  /// Positive token budget a declared option value requests, or `null`.
  ///
  /// Mirrors the selection resolver's own per-wire admission rule so the
  /// advertised metadata and the dispatched directive can never disagree about
  /// which values are budgets. `anthropic_budget` option values are integers of
  /// at least 1024 (the declaration parser enforces this, so a smaller or
  /// non-numeric value never reaches here); a `google_thinking` option value is
  /// any positive number, while its documented `0` remains the disable and is
  /// therefore not a budget. A numeric value on any other wire is not a budget.
  static int? _declaredBudgetTokens(String wire, Object? rawValue) {
    if (rawValue is! num) return null;
    final tokens = rawValue.toInt();
    return switch (wire) {
      'anthropic_budget' => tokens >= 1024 ? tokens : null,
      'google_thinking' => tokens > 0 ? tokens : null,
      _ => null,
    };
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

  /// Rebuilds cached thinking descriptors after a failed model-list refresh.
  ///
  /// The failure branch must never hand a previously cached descriptor straight
  /// back to the route. Every cached model is re-derived against the *current*
  /// authority: the active Home configuration, the instance's config/credential
  /// revision, the route protocol, the actual API mode and the model's own
  /// persisted discovery metadata.
  ///
  /// A descriptor survives only when all of the following hold:
  /// * the persisted descriptor was `supported` and is not already invalidated
  ///   (`live_probe_failed`, `cache_stale`, `stale_live_evidence`);
  /// * the reconstruction is `supported` from intrinsic model-owned evidence
  ///   (`profile` catalog facts or a model-only `config_override`). Endpoint
  ///   declarations are route-owned evidence: a failed model-list refresh cannot
  ///   revalidate them, so they are never silently reclassified as intrinsic
  ///   support and stay unresolved until a successful refresh;
  /// * the reconstruction carries the *same* capability revision, so a removed or
  ///   changed override, an incompatible route/API mode, or a config/credential
  ///   revision change fails closed instead of resurrecting stale controls.
  ///
  /// Live probe/discovery evidence keeps its authoritative failure provenance,
  /// and every other model stays `live_probe_failed` unknown until a successful
  /// refresh rebuilds it.
  List<ModelOption> markProbeFailed({
    required ProviderInstance instance,
    required List<ModelOption> models,
  }) {
    return models
        .map((model) {
          final cached = model.thinkingControl;
          if (cached == null ||
              cached.status != ThinkingCapabilityStatus.supported ||
              ThinkingControlStaleEvidence.isInvalidated(cached)) {
            return _probeFailedModel(instance: instance, model: model);
          }

          final rebuilt = assemble(instance: instance, model: model);
          if (rebuilt.status != ThinkingCapabilityStatus.supported) {
            return _probeFailedModel(instance: instance, model: model);
          }
          if (!_modelOwnedSources.contains(rebuilt.source)) {
            return _probeFailedModel(instance: instance, model: model);
          }
          if (rebuilt.capabilityRevision != cached.capabilityRevision) {
            return _probeFailedModel(instance: instance, model: model);
          }
          return model.copyWith(thinkingControl: rebuilt);
        })
        .toList(growable: false);
  }

  /// Intrinsic model-owned evidence that survives a failed endpoint model-list
  /// refresh when the current authority reconstructs it under an unchanged
  /// revision. Route-owned endpoint declarations are deliberately excluded.
  static const _modelOwnedSources = {'profile', 'config_override'};

  ModelOption _probeFailedModel({
    required ProviderInstance instance,
    required ModelOption model,
  }) {
    return model.copyWith(
      thinkingControl: ThinkingControlDescriptor.unknown(
        capabilityRevision:
            '${instance.configRevision}:${instance.credentialRevision}:probe_failed:${model.value}',
        source: 'live_probe_failed',
      ),
    );
  }
}
