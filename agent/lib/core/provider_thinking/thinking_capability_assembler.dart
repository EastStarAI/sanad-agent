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
import 'package:sanad_agent/core/provider_thinking/models_dev_thinking_evidence.dart';
import 'package:sanad_agent/core/provider_thinking/shipped_thinking_defaults.dart';

/// The capability layer that owns one route/model, resolved once and shared by
/// the assembler (descriptor) and the selection resolver (directive), so both
/// always agree on which record answers.
sealed class ThinkingCapabilityLayer {
  const ThinkingCapabilityLayer();
}

/// Layers 1-3: a finite `thinking_control` record (user settings, a
/// provider-declared record, or a shipped default) applied as a whole.
final class ThinkingControlRecordLayer extends ThinkingCapabilityLayer {
  final ThinkingControlOverride control;
  final String source;
  final String revisionTag;

  /// Whether the record's declared default marks its option as the provider
  /// default (shipped defaults carry documented native defaults).
  final bool marksProviderDefault;

  const ThinkingControlRecordLayer({
    required this.control,
    required this.source,
    required this.revisionTag,
    this.marksProviderDefault = false,
  });
}

/// Layer 2b: a provider-reported native item schema read by a policy.
final class ThinkingNativePolicyLayer extends ThinkingCapabilityLayer {
  final ThinkingControlDescriptor descriptor;
  const ThinkingNativePolicyLayer(this.descriptor);
}

/// Layers 4-5: a models.dev entry (serving vendor, then canonical model).
final class ThinkingModelsDevLayer extends ThinkingCapabilityLayer {
  final ModelsDevThinkingEvidence evidence;
  final ModelsDevThinkingWire wire;

  /// Whether the evidence is the canonical-model entry (layer 5).
  final bool isCanonical;
  const ThinkingModelsDevLayer(
    this.evidence,
    this.wire, {
    this.isCanonical = false,
  });
}

/// No layer reports anything for the route: `unknown`.
final class ThinkingNoLayer extends ThinkingCapabilityLayer {
  const ThinkingNoLayer();
}

/// Capability authority is layered, in strict order. The first layer with a
/// record for the exact model id wins as a whole (no field mixing):
/// 1. user settings: `model_capabilities` in `$SANAD_HOME/config.yaml`;
/// 2. provider-reported metadata for the exact route: the endpoint
///    `thinking_control` declaration written by provider-owned discovery
///    parsers, then native item schemas read by provider-reported policies
///    (Codex `supported_reasoning_levels`, the Ollama live probe);
/// 3. shipped defaults generated from `agent/model_capability_defaults.yaml`
///    (data with a documentation source per entry, never Dart logic);
/// 4. the serving vendor's exact models.dev entry;
/// 5. the models.dev entry named by that entry's `canonical_model_id`, only
///    when layer 4 reports no `reasoning_options`;
/// otherwise `unknown`.
class ThinkingCapabilityAssembler {
  final ProviderThinkingRegistry _registry;
  final Config? _config;
  final ModelsDevEntryLookup? _modelsDevLookup;
  final ShippedThinkingDefaults _shippedDefaults;

  ThinkingCapabilityAssembler(
    this._registry, [
    this._config,
    this._modelsDevLookup,
    ShippedThinkingDefaults? shippedDefaults,
  ]) : _shippedDefaults = shippedDefaults ?? const ShippedThinkingDefaults();

  /// Policies whose capability comes only from provider-reported item
  /// metadata. Every other policy id is a wire-dialect label, not an authority.
  static const providerReportedPolicyIds = {
    'ollama_live',
    'openai_chat_effort',
    'codex_responses_effort',
  };

  String _revision(ProviderInstance instance, String tag, String modelId) =>
      '${instance.configRevision}:${instance.credentialRevision}:$tag:$modelId';

  /// Resolves the single layer that owns [model] on [instance].
  ThinkingCapabilityLayer resolveLayer({
    required ProviderInstance instance,
    required ModelOption model,
  }) {
    final override = _config?.modelAwarePolicy
        .capabilityOverrideFor(model.value)
        ?.thinkingControl;
    if (override != null) {
      return ThinkingControlRecordLayer(
        control: override,
        source: 'config_override',
        revisionTag: 'override_${override.fingerprint}',
      );
    }
    final declared = ThinkingControlOverride.tryParse(
      model.modelMetadata['thinking_control'],
    );
    if (declared != null) {
      return ThinkingControlRecordLayer(
        control: declared,
        source: 'endpoint_declared',
        revisionTag: 'declared_${declared.fingerprint}',
      );
    }
    final native = _providerReportedNative(instance: instance, model: model);
    if (native != null) return ThinkingNativePolicyLayer(native);
    final shipped = _shippedDefaults.controlFor(instance, model.value);
    if (shipped != null) {
      return ThinkingControlRecordLayer(
        control: shipped,
        source: shippedDefaultSource,
        revisionTag: 'shipped_${shipped.fingerprint}',
        marksProviderDefault: true,
      );
    }
    final modelsDev = _modelsDevEvidence(instance: instance, model: model);
    if (modelsDev != null) return modelsDev;
    return const ThinkingNoLayer();
  }

  static const shippedDefaultSource = 'shipped_default';

  /// `default_source` ids for the layers that can declare a default.
  static const providerReportedDefaultSource = 'provider_reported';
  static const modelsDevCanonicalDefaultSource = 'models_dev_canonical';

  /// The models.dev layer for this route, when it is the owning layer.
  ThinkingModelsDevLayer? modelsDevLayer({
    required ProviderInstance instance,
    required ModelOption model,
  }) {
    final layer = resolveLayer(instance: instance, model: model);
    return layer is ThinkingModelsDevLayer ? layer : null;
  }

  /// The descriptor a provider-reported native item schema yields for this
  /// route, or `null` when the item reports nothing.
  ThinkingControlDescriptor? _providerReportedNative({
    required ProviderInstance instance,
    required ModelOption model,
  }) {
    final template = ThinkingRoutePolicy.resolveTemplate(instance);
    final policyId = ThinkingRoutePolicy.policyIdFor(
      instance,
      modelId: model.value,
    );
    if (!providerReportedPolicyIds.contains(policyId)) return null;
    final descriptor = _registry
        .resolveForTemplate(thinkingPolicyId: policyId)
        .resolveCapability(
          ThinkingPolicyContext(
            providerInstanceId: instance.id,
            templateId: instance.templateId,
            protocol: instance.protocol,
            apiMode: ThinkingRoutePolicy.apiModeFor(instance, template),
            modelId: model.value,
            supportsReasoningOutput: model.supportsReasoningOutput,
            capabilityRevision: _revision(instance, policyId, model.value),
            modelMetadata: model.modelMetadata,
          ),
        );
    return descriptor.status == ThinkingCapabilityStatus.unknown
        ? null
        : descriptor;
  }

  /// Layers 4-5: the serving vendor's exact entry, then (only when that entry
  /// reports no `reasoning_options`) the entry its `canonical_model_id` names.
  ThinkingModelsDevLayer? _modelsDevEvidence({
    required ProviderInstance instance,
    required ModelOption model,
  }) {
    final lookup = _modelsDevLookup;
    if (lookup == null || instance.isCustom) return null;
    final wire = ModelsDevThinkingWire.forRoute(instance);
    if (wire == null) return null;
    final vendorEntry = lookup(instance.templateId, model.value);
    final vendor = ModelsDevThinkingEvidence.tryParse(vendorEntry);
    if (vendorEntry != null && vendorEntry['reasoning_options'] != null) {
      return vendor == null ? null : ThinkingModelsDevLayer(vendor, wire);
    }
    final canonical = ModelsDevThinkingEvidence.canonicalModelId(vendorEntry);
    if (canonical != null) {
      final canonicalEvidence = ModelsDevThinkingEvidence.tryParse(
        lookup(canonical.vendor, canonical.modelId),
      );
      if (canonicalEvidence != null) {
        return ThinkingModelsDevLayer(
          canonicalEvidence,
          wire,
          isCanonical: true,
        );
      }
    }
    return vendor == null ? null : ThinkingModelsDevLayer(vendor, wire);
  }

  ThinkingControlDescriptor assemble({
    required ProviderInstance instance,
    required ModelOption model,
    DateTime? observedAt,
    String? evidenceSource,
  }) {
    final layer = resolveLayer(instance: instance, model: model);
    final descriptor = _assembleLayer(
      layer,
      instance: instance,
      model: model,
      observedAt: observedAt,
      evidenceSource: evidenceSource,
    );
    return _withDefault(descriptor, layer, instance: instance, model: model);
  }

  /// The `default_source` id of the winning [layer] itself.
  static String _layerDefaultSource(ThinkingCapabilityLayer layer) =>
      switch (layer) {
        ThinkingControlRecordLayer(:final source) => source,
        ThinkingNativePolicyLayer() => providerReportedDefaultSource,
        ThinkingModelsDevLayer(:final isCanonical) =>
          isCanonical
              ? modelsDevCanonicalDefaultSource
              : ModelsDevThinkingEvidence.sourceId,
        ThinkingNoLayer() => 'unconfigured',
      };

  /// Records where [descriptor]'s default came from and, when the winning
  /// layer declares options but no default, fills it from the next layer (in
  /// precedence order, skipping the winner) that declares a default for the
  /// same exact model id — only when that default is one of the winning
  /// options. Options always come from the winning layer alone.
  ThinkingControlDescriptor _withDefault(
    ThinkingControlDescriptor descriptor,
    ThinkingCapabilityLayer layer, {
    required ProviderInstance instance,
    required ModelOption model,
  }) {
    if (!descriptor.isSelectable) return descriptor;
    final own = descriptor.defaultOptionId;
    if (own != null) {
      return descriptor.copyWith(defaultSource: _layerDefaultSource(layer));
    }
    for (final donor in _defaultDonors(
      layer,
      instance: instance,
      model: model,
    )) {
      final id = donor.defaultId?.trim();
      if (id == null || id.isEmpty || !descriptor.containsOptionId(id)) {
        continue;
      }
      return descriptor.copyWith(
        options: [
          for (final option in descriptor.options)
            option.id == id
                ? ThinkingControlOption(
                    id: option.id,
                    label: option.label,
                    isOff: option.isOff,
                    isProviderDefault: true,
                    budgetTokens: option.budgetTokens,
                  )
                : option,
        ],
        defaultOptionId: id,
        defaultSource: donor.source,
        capabilityRevision:
            '${descriptor.capabilityRevision}+default_${donor.source}_$id',
      );
    }
    return descriptor;
  }

  /// Default donors below (or withheld above) the winning [layer], in
  /// precedence order: the shipped record regardless of its route class, then
  /// the models.dev serving-vendor entry, then its canonical entry.
  Iterable<({String source, String? defaultId})> _defaultDonors(
    ThinkingCapabilityLayer layer, {
    required ProviderInstance instance,
    required ModelOption model,
  }) sync* {
    final shippedWon =
        layer is ThinkingControlRecordLayer &&
        layer.source == shippedDefaultSource;
    if (!shippedWon) {
      yield (
        source: shippedDefaultSource,
        defaultId: _shippedDefaults.declaredDefaultFor(model.value),
      );
    }
    final lookup = _modelsDevLookup;
    if (lookup == null ||
        instance.isCustom ||
        ModelsDevThinkingWire.forRoute(instance) == null) {
      return;
    }
    final vendorEntry = lookup(instance.templateId, model.value);
    yield (
      source: ModelsDevThinkingEvidence.sourceId,
      defaultId: ModelsDevThinkingEvidence.tryParse(vendorEntry)?.defaultEffort,
    );
    final canonical = ModelsDevThinkingEvidence.canonicalModelId(vendorEntry);
    if (canonical != null) {
      yield (
        source: modelsDevCanonicalDefaultSource,
        defaultId: ModelsDevThinkingEvidence.tryParse(
          lookup(canonical.vendor, canonical.modelId),
        )?.defaultEffort,
      );
    }
  }

  ThinkingControlDescriptor _assembleLayer(
    ThinkingCapabilityLayer layer, {
    required ProviderInstance instance,
    required ModelOption model,
    DateTime? observedAt,
    String? evidenceSource,
  }) {
    switch (layer) {
      case ThinkingControlRecordLayer():
        return _recordDescriptor(
          layer,
          instance: instance,
          modelId: model.value,
          observedAt: observedAt,
          evidenceSource: evidenceSource,
        );
      case ThinkingNativePolicyLayer(:final descriptor):
        return descriptor.copyWith(
          source: evidenceSource ?? descriptor.source,
          observedAt: observedAt ?? descriptor.observedAt,
        );
      case ThinkingModelsDevLayer(:final evidence, :final wire):
        final descriptor = evidence.descriptorFor(
          wire: wire,
          capabilityRevision: _revision(
            instance,
            'models_dev_${evidence.fingerprint}_${wire.name}',
            model.value,
          ),
        );
        return descriptor.copyWith(
          source: evidenceSource ?? descriptor.source,
          observedAt: observedAt,
        );
      case ThinkingNoLayer():
        return ThinkingControlDescriptor.unknown(
          capabilityRevision: _revision(instance, 'unknown', model.value),
          source: evidenceSource ?? 'unconfigured',
          observedAt: observedAt,
        );
    }
  }

  /// Builds the descriptor for one finite record applied as a whole.
  ThinkingControlDescriptor _recordDescriptor(
    ThinkingControlRecordLayer layer, {
    required ProviderInstance instance,
    required String modelId,
    DateTime? observedAt,
    String? evidenceSource,
  }) {
    final control = layer.control;
    final source = evidenceSource ?? layer.source;
    final revision = _revision(instance, layer.revisionTag, modelId);
    if (control.status == ThinkingCapabilityStatus.unsupported) {
      return ThinkingControlDescriptor.unsupported(
        capabilityRevision: revision,
        source: source,
        observedAt: observedAt,
      );
    }
    if (control.status == ThinkingCapabilityStatus.unknown) {
      return ThinkingControlDescriptor.unknown(
        capabilityRevision: revision,
        source: source,
        observedAt: observedAt,
      );
    }
    final template = ThinkingRoutePolicy.resolveTemplate(instance);
    final apiMode = ThinkingRoutePolicy.apiModeFor(instance, template);
    final wire = control.wire;
    if (wire == null ||
        !ThinkingRoutePolicy.isWireCompatible(
          wire: wire,
          protocol: instance.protocol,
          apiMode: apiMode,
          templateId: instance.templateId,
          isCustom: instance.isCustom,
        )) {
      return ThinkingControlDescriptor.unsupported(
        capabilityRevision: _revision(
          instance,
          layer.revisionTag.replaceFirst('_', '_incompatible_'),
          modelId,
        ),
        source: source,
        observedAt: observedAt,
      );
    }
    final kind = switch (wire) {
      'openai_chat_effort' ||
      'codex_responses_effort' => ThinkingControlKind.effort,
      'anthropic_adaptive' => ThinkingControlKind.adaptive,
      'anthropic_budget' => ThinkingControlKind.tokenBudget,
      'toggle_effort' => ThinkingControlKind.toggle,
      'native_toggle_effort' =>
        control.options.values.any((value) => value is String)
            ? ThinkingControlKind.effort
            : ThinkingControlKind.toggle,
      'google_thinking' =>
        control.options.values.any((value) => value is num && value > 0)
            ? ThinkingControlKind.tokenBudget
            : ThinkingControlKind.level,
      'nim_kimi_thinking' => ThinkingControlKind.toggle,
      'nim_qwen_thinking' => ThinkingControlKind.effort,
      _ => ThinkingControlKind.effort,
    };
    final defaultOption = control.defaultOption;
    final options = control.options.entries
        .map((entry) {
          final id = entry.key;
          final rawVal = entry.value;
          return ThinkingControlOption(
            id: id,
            label: _labelForOption(id),
            isOff: _isDisableValue(wire, rawVal),
            isProviderDefault:
                layer.marksProviderDefault && defaultOption == id,
            budgetTokens: _declaredBudgetTokens(wire, rawVal),
          );
        })
        .toList(growable: false);
    return ThinkingControlDescriptor(
      status: ThinkingCapabilityStatus.supported,
      kind: kind,
      options: options,
      defaultOptionId: defaultOption,
      capabilityRevision: revision,
      source: source,
      observedAt: observedAt,
    );
  }

  /// Whether a declared option value is the wire's genuine disable.
  static bool _isDisableValue(String wire, Object? rawVal) {
    final canWireDisable = switch (wire) {
      'openai_chat_effort' ||
      'codex_responses_effort' => rawVal == 'none' || rawVal == 'off',
      'toggle_effort' || 'native_toggle_effort' =>
        rawVal == false || rawVal == 'off' || rawVal == 'none',
      'anthropic_adaptive' =>
        rawVal == false || rawVal == 'off' || rawVal == 'none',
      'anthropic_budget' => rawVal == false,
      'google_thinking' => rawVal == 0 || rawVal == 'off' || rawVal == 'none',
      'nim_kimi_thinking' || 'nim_qwen_thinking' =>
        rawVal == false ||
            (rawVal is String &&
                (rawVal.trim().toLowerCase() == 'off' ||
                    rawVal.trim().toLowerCase() == 'false' ||
                    rawVal.trim().toLowerCase() == 'none')),
      _ => false,
    };
    return canWireDisable &&
        (rawVal == false || rawVal == 0 || rawVal == 'none' || rawVal == 'off');
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
  static const _modelOwnedSources = {
    'profile',
    'config_override',
    ModelsDevThinkingEvidence.sourceId,
    shippedDefaultSource,
  };

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
