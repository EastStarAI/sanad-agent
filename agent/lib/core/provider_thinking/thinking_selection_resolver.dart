/// Validates thinking selections against the active route descriptor.
library;

import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/core/provider_runtime/provider_model_id.dart';
import 'package:sanad_agent/core/provider_thinking/native_thinking_directive.dart';
import 'package:sanad_agent/core/provider_thinking/provider_thinking_policy.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_capability_assembler.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_control_cache_resolver.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_control_models.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_policy_context.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_control_stale_evidence.dart';
import 'package:sanad_agent/core/provider_thinking/ollama_thinking_probe.dart';
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

/// Ordered positive effort ladder used to clamp a requested level.
const _effortLadder = ['minimal', 'low', 'medium', 'high', 'xhigh', 'max'];

/// Clamps [requested] to the nearest *lower* level the route supports.
///
/// Never escalates and never falls to an Off/none option. Returns `null` when
/// [requested] is not a ladder level or no lower supported level exists.
String? clampThinkingSelection({
  required String requested,
  required Iterable<String> optionIds,
}) {
  final requestedIndex = _effortLadder.indexOf(requested.trim().toLowerCase());
  if (requestedIndex < 0) return null;
  final supported = optionIds.toSet();
  for (var index = requestedIndex - 1; index >= 0; index--) {
    final candidate = _effortLadder[index];
    if (supported.contains(candidate)) return candidate;
  }
  return null;
}

class ThinkingSelectionResolver {
  final ProviderInstanceRepository _instances;
  final ThinkingControlCacheResolver _cacheResolver;
  final ThinkingCapabilityAssembler _assembler;
  final ProviderThinkingRegistry _registry;

  /// [config] is accepted for call-site compatibility; the settings layer is
  /// read through [assembler], which owns the layered authority.
  ThinkingSelectionResolver({
    required ProviderInstanceRepository instances,
    required ThinkingControlCacheResolver cacheResolver,
    required ThinkingCapabilityAssembler assembler,
    required ProviderThinkingRegistry registry,
    Config? config,
  }) : _instances = instances,
       _cacheResolver = cacheResolver,
       _assembler = assembler,
       _registry = registry;

  ThinkingSelectionResolution resolve({
    required String providerInstanceId,
    required String modelId,
    required String? selectionId,
  }) {
    final stored = _instances.findById(providerInstanceId);
    if (stored == null) {
      throw ThinkingSelectionException(
        code: ThinkingSelectionErrorCode.instanceNotFound,
        message: 'Provider instance not found for thinking validation.',
      );
    }
    // Task 120: validate against the wire this model is actually dispatched on.
    final instance = _assembler.routeInstance(stored, modelId);

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
        message:
            'Thinking controls are unsupported for the active model route.',
      );
    }
    if (descriptor.status == ThinkingCapabilityStatus.unknown) {
      // No authority layer reports a set: the selection passes through
      // unchanged (never clamped or rejected) and the turn is admitted with
      // the provider default, sending no thinking field.
      return ThinkingSelectionResolution(
        selectionId: trimmed,
        descriptor: descriptor,
        directive: const UseProviderDefault(),
      );
    }

    var resolvedSelectionId =
        migrateLegacyThinkingSelectionId(
          selectionId: trimmed,
          descriptor: descriptor,
        ) ??
        trimmed;

    if (!descriptor.containsOptionId(resolvedSelectionId)) {
      final clamped = clampThinkingSelection(
        requested: resolvedSelectionId,
        optionIds: descriptor.options.map((option) => option.id),
      );
      if (clamped == null) {
        throw ThinkingSelectionException(
          code: ThinkingSelectionErrorCode.optionUnavailable,
          message:
              'The selected thinking option is unavailable for this route.',
        );
      }
      resolvedSelectionId = clamped;
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
    final layer = _assembler.resolveLayer(instance: instance, model: model);
    if (layer is ThinkingControlRecordLayer) {
      return _buildResolutionFromControlOverride(
        control: layer.control,
        descriptor: descriptor,
        instance: instance,
        selectionId: selectionId,
      );
    }

    if (layer is ThinkingModelsDevLayer) {
      final effectiveSelection = selectionId?.trim();
      if (effectiveSelection == null || effectiveSelection.isEmpty) {
        return ThinkingSelectionResolution(
          selectionId: null,
          descriptor: descriptor,
          directive: const UseProviderDefault(),
        );
      }
      final directive = layer.evidence.directiveFor(
        layer.wire,
        effectiveSelection,
      );
      if (directive == null) {
        throw ThinkingSelectionException(
          code: ThinkingSelectionErrorCode.optionUnavailable,
          message:
              'The selected thinking option is unavailable for this route.',
        );
      }
      return ThinkingSelectionResolution(
        selectionId: effectiveSelection,
        descriptor: descriptor,
        directive: directive,
      );
    }

    final template = ThinkingRoutePolicy.resolveTemplate(instance);
    final policyId = ThinkingRoutePolicy.policyIdFor(
      instance,
      modelId: model.value,
    );
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

  ThinkingSelectionResolution _buildResolutionFromControlOverride({
    required ThinkingControlOverride control,
    required ThinkingControlDescriptor descriptor,
    required ProviderInstance instance,
    required String? selectionId,
  }) {
    // Provider-default omission contract: an omitted, cleared or whitespace-only
    // selection is `UseProviderDefault` for configuration and endpoint
    // declarations alike. A documented default stays truthful descriptor
    // metadata (`defaultOptionId`) and is dispatched only when it is actually
    // selected; it never turns omission into an explicit request field.
    final effectiveSelection = selectionId?.trim();
    if (effectiveSelection == null || effectiveSelection.isEmpty) {
      return ThinkingSelectionResolution(
        selectionId: null,
        descriptor: descriptor,
        directive: const UseProviderDefault(),
      );
    }

    if (control.status != ThinkingCapabilityStatus.supported ||
        !control.options.containsKey(effectiveSelection)) {
      throw ThinkingSelectionException(
        code: ThinkingSelectionErrorCode.optionUnavailable,
        message: 'The selected thinking option is unavailable for this route.',
      );
    }

    final wire = control.wire;
    final template = ThinkingRoutePolicy.resolveTemplate(instance);
    final apiMode = ThinkingRoutePolicy.apiModeFor(instance, template);
    if (wire == null ||
        !ThinkingRoutePolicy.isWireCompatible(
          wire: wire,
          protocol: instance.protocol,
          apiMode: apiMode,
          templateId: instance.templateId,
          isCustom: instance.isCustom,
        )) {
      throw ThinkingSelectionException(
        code: ThinkingSelectionErrorCode.capabilityUnsupported,
        message:
            'Wire policy $wire is incompatible with ${instance.protocol} route (apiMode: $apiMode).',
      );
    }

    final optionVal = control.options[effectiveSelection];
    final NativeThinkingDirective directive = switch (wire) {
      'openai_chat_effort' => OpenAiEffortDirective(optionVal.toString()),
      'codex_responses_effort' => ResponsesReasoningDirective(
        effort: optionVal.toString(),
      ),
      'anthropic_adaptive' => switch (optionVal) {
        'none' ||
        'off' ||
        false => const ThinkingToggleDirective(enabled: false),
        _ => AnthropicAdaptiveDirective(optionVal.toString()),
      },
      'anthropic_budget' => switch (optionVal) {
        false => const ThinkingToggleDirective(enabled: false),
        num n when n >= 1024 => AnthropicBudgetDirective(n.toInt()),
        _ => throw ThinkingSelectionException(
          code: ThinkingSelectionErrorCode.optionUnavailable,
          message: 'Anthropic budget must be an integer >= 1024.',
        ),
      },
      'nim_kimi_thinking' => switch (optionVal) {
        bool b => ChatTemplateBooleanDirective(key: 'thinking', value: b),
        'true' ||
        'on' => ChatTemplateBooleanDirective(key: 'thinking', value: true),
        'false' ||
        'off' => ChatTemplateBooleanDirective(key: 'thinking', value: false),
        _ => throw ThinkingSelectionException(
          code: ThinkingSelectionErrorCode.optionUnavailable,
          message:
              'NIM template-kwargs toggle value must be boolean or on/off.',
        ),
      },
      'nim_qwen_thinking' => switch (optionVal) {
        bool b => ChatTemplateBooleanDirective(
          key: 'enable_thinking',
          value: b,
        ),
        'true' || 'on' => ChatTemplateBooleanDirective(
          key: 'enable_thinking',
          value: true,
        ),
        'false' || 'off' => ChatTemplateBooleanDirective(
          key: 'enable_thinking',
          value: false,
        ),
        'low' ||
        'medium' ||
        'xhigh' => OpenAiEffortDirective(optionVal.toString()),
        _ => throw ThinkingSelectionException(
          code: ThinkingSelectionErrorCode.optionUnavailable,
          message:
              'Self-hosted NIM Qwen value must be boolean/on/off or one of '
              'low, medium, xhigh.',
        ),
      },
      'native_toggle_effort' => switch (optionVal) {
        false => const ThinkingToggleDirective(enabled: false),
        true => const ThinkingToggleDirective(enabled: true),
        String effort => NativeThinkingEffortDirective(effort),
        _ => throw ThinkingSelectionException(
          code: ThinkingSelectionErrorCode.optionUnavailable,
          message: 'Native toggle/effort value must be boolean or an effort.',
        ),
      },
      'toggle_effort' => switch (optionVal) {
        bool b => ThinkingToggleDirective(enabled: b),
        'true' || 'on' => const ThinkingToggleDirective(enabled: true),
        'false' || 'off' => const ThinkingToggleDirective(enabled: false),
        _ => throw ThinkingSelectionException(
          code: ThinkingSelectionErrorCode.optionUnavailable,
          message: 'Toggle option value must be boolean or on/off.',
        ),
      },
      'google_thinking' => switch (optionVal) {
        0 || 'none' || 'off' => const GoogleBudgetDirective(0),
        num n => GoogleBudgetDirective(n.toInt()),
        _ => GoogleLevelDirective(optionVal.toString()),
      },
      _ => throw ThinkingSelectionException(
        code: ThinkingSelectionErrorCode.capabilityUnsupported,
        message: 'Unsupported wire policy: $wire',
      ),
    };

    return ThinkingSelectionResolution(
      selectionId: selectionId ?? effectiveSelection,
      descriptor: descriptor,
      directive: directive,
    );
  }

  ModelOption _modelForRoute({
    required ProviderInstance instance,
    required String modelId,
  }) {
    final cached = _instances.readModelCache(instance.id, 'models');
    if (cached != null &&
        cached['config_revision'] == instance.configRevision &&
        cached['credential_revision'] == instance.credentialRevision) {
      final models = cached['models'] as List<dynamic>? ?? const [];
      final target = ProviderModelId.normalize(
        templateId: instance.templateId,
        protocol: instance.protocol,
        rawModelId: modelId,
      );
      for (final entry in models) {
        if (entry is Map) {
          try {
            final map = Map<String, dynamic>.from(entry);
            if (!map.containsKey('value') && map.containsKey('id')) {
              map['value'] = map['id'];
            }
            final option = ModelOption.fromJson(map);
            final opt = ProviderModelId.normalize(
              templateId: instance.templateId,
              protocol: instance.protocol,
              rawModelId: option.value,
            );
            if (opt.isNotEmpty && opt == target) {
              if (option.thinkingControl == null) {
                final cachedTc = _cacheResolver.resolve(
                  providerInstanceId: instance.id,
                  modelId: modelId,
                  templateId: instance.templateId,
                  protocol: instance.protocol,
                  configRevision: instance.configRevision,
                  credentialRevision: instance.credentialRevision,
                );
                if (cachedTc != null) {
                  return option.copyWith(
                    thinkingControl: ThinkingControlDescriptor.fromMap(
                      cachedTc,
                    ),
                  );
                }
              }
              return option;
            }
          } catch (_) {}
        }
      }
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
    // Explicit failure/invalidation evidence stays authoritative for the route:
    // a transient probe failure or stale cache keeps thinking unresolved until
    // a live probe succeeds again, even though the assembler can still rebuild a
    // supported descriptor from persisted model metadata.
    if (ThinkingControlStaleEvidence.isInvalidated(cached)) {
      return ThinkingControlStaleEvidence.freshUnknown(
        capabilityRevision: fresh.capabilityRevision,
      );
    }
    if (cached.capabilityRevision != fresh.capabilityRevision) {
      return fresh;
    }
    if (!ThinkingControlStaleEvidence.isStale(cached)) {
      return cached;
    }
    // Expired live evidence normally fails closed to unknown. The single
    // exception is expired evidence whose descriptor was produced from a
    // validated native declaration for the exact model route and whose fresh
    // rebuild under the same revision still resolves supported: those facts are
    // model-owned, not clock-owned, and stay authoritative until an
    // authoritative refresh, invalidation, or revision change.
    if (_retainsValidatedNativeFacts(
      model: model,
      cached: cached,
      fresh: fresh,
    )) {
      return cached;
    }
    return ThinkingControlStaleEvidence.freshUnknown(
      capabilityRevision: fresh.capabilityRevision,
    );
  }

  /// Whether expired `live` evidence may retain its validated native
  /// declaration instead of degrading to unknown.
  ///
  /// Narrowness is deliberate:
  /// * explicit failure/invalidation markers (`live_probe_failed`,
  ///   `cache_stale`, `stale_live_evidence`) are never `live`, so they can
  ///   never be retained;
  /// * malformed, unknown, or unsupported evidence on either side fails
  ///   closed;
  /// * the caller has already proven the cached and freshly rebuilt
  ///   descriptors share the route/config/credential revision.
  static bool _retainsValidatedNativeFacts({
    required ModelOption model,
    required ThinkingControlDescriptor cached,
    required ThinkingControlDescriptor fresh,
  }) {
    if (cached.source != 'live' || fresh.source != 'live') {
      return false;
    }
    if (cached.status != ThinkingCapabilityStatus.supported ||
        fresh.status != ThinkingCapabilityStatus.supported) {
      return false;
    }
    return _hasValidatedNativeDeclaration(model.modelMetadata);
  }

  /// A validated native declaration is model-owned evidence discovered from the
  /// adapter probe itself, so it remains true independently of wall-clock age.
  static bool _hasValidatedNativeDeclaration(Map<String, Object?> metadata) {
    return OllamaThinkingProbe.hasThinkingCapability(metadata) == true &&
        OllamaThinkingProbe.parseThinkingDeclaration(metadata) != null;
  }
}
