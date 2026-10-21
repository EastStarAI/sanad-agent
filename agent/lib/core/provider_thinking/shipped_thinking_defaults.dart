/// Layer 3 of the thinking-capability authority: shipped defaults.
///
/// The records are data generated from `agent/model_capability_defaults.yaml`
/// (same schema as the user `model_capabilities` section, each with a
/// documentation source). This file holds no model names: it only decides,
/// from the record's route class and the active route, whether the record
/// applies, and adapts effort wires to the route's Chat/Responses mode.
library;

import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance.dart';
import 'package:sanad_agent/core/provider_thinking/generated_model_capability_defaults.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_control_models.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_route_policy.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_wire_dialect.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_wire_vocabulary.dart';

class ShippedThinkingDefaults {
  final Map<String, ShippedModelCapabilityDefault> _table;

  const ShippedThinkingDefaults([
    Map<String, ShippedModelCapabilityDefault>? table,
  ]) : _table = table ?? modelCapabilityDefaults;

  static final Map<String, ThinkingControlOverride?> _parsed = {};

  ThinkingControlOverride? _recordFor(String modelId) {
    final key = modelId.trim();
    final entry = _table[key];
    if (entry == null) return null;
    return _parsed.putIfAbsent(
      '${identityHashCode(_table)}:$key',
      () => ThinkingControlOverride.tryParse(entry.thinkingControl),
    );
  }

  /// The default option id the shipped record for the exact [modelId]
  /// declares, regardless of its route class. It is only a default donor for
  /// a winning layer that declares options but no default; it never supplies
  /// options.
  String? declaredDefaultFor(String modelId) {
    final control = _recordFor(modelId);
    if (control == null ||
        control.status != ThinkingCapabilityStatus.supported) {
      return null;
    }
    return control.defaultOption;
  }

  /// The shipped record for the exact [modelId], adapted to [instance], or
  /// `null` when no record exists or the record does not apply to this route
  /// (the next authority layer then answers).
  ThinkingControlOverride? controlFor(
    ProviderInstance instance,
    String modelId,
  ) {
    final entry = _table[modelId.trim()];
    if (entry == null) return null;
    final control = _recordFor(modelId);
    if (control == null) return null;

    final template = ThinkingRoutePolicy.resolveTemplate(instance);
    final apiMode = ThinkingRoutePolicy.apiModeFor(instance, template);
    final dialect = ThinkingRoutePolicy.wireDialectFor(instance);
    final isAggregator =
        !instance.isCustom &&
        ThinkingWireDialectFacts.aggregatorTemplateIds.contains(
          instance.templateId.trim(),
        );
    bool compatible(String wire) => ThinkingRoutePolicy.isWireCompatible(
      wire: wire,
      protocol: instance.protocol,
      apiMode: apiMode,
      templateId: instance.templateId,
      isCustom: instance.isCustom,
    );
    final unsupported = control.status != ThinkingCapabilityStatus.supported;

    switch (entry.routes) {
      case 'nim':
        if (dialect != ThinkingWireDialect.nimChat) return null;
        return unsupported || compatible(control.wire!) ? control : null;
      case 'google':
        final isGoogleRoute =
            !instance.isCustom &&
            template.effectiveThinkingPolicyId == 'google_thinking';
        if (!isGoogleRoute && !isAggregator) return null;
        return unsupported || compatible(control.wire!) ? control : null;
      case 'native':
      case 'first_party':
        // `first_party` withholds the record from partner Chat routes, where
        // the serving route's own evidence (models.dev) answers instead.
        final nativeAllowed = entry.routes == 'first_party'
            ? dialect == ThinkingWireDialect.nativeFirstParty
            : dialect.allowsFirstPartyNativeEnvelope;
        if (nativeAllowed || isAggregator) {
          return unsupported || compatible(control.wire!) ? control : null;
        }
        if (dialect == ThinkingWireDialect.compatibleChat &&
            entry.compatibleChat == 'positive_efforts' &&
            !unsupported) {
          return _positiveEfforts(control);
        }
        return null;
      case 'any':
      default:
        if (unsupported) return control;
        final wire = control.wire!;
        if (compatible(wire)) return control;
        // An OpenAI-family effort fact is the same model fact on Chat and on
        // Responses; only the field that carries it differs.
        const effortWires = {'openai_chat_effort', 'codex_responses_effort'};
        if (effortWires.contains(wire)) {
          for (final other in effortWires) {
            if (other != wire && compatible(other)) {
              return ThinkingControlOverride(
                status: control.status,
                wire: other,
                options: control.options,
                defaultOption: control.defaultOption,
              );
            }
          }
        }
        return null;
    }
  }

  /// The positive effort subset of a native record on a generic compatible
  /// Chat wire: the standard `reasoning_effort` field only, with no Off, no
  /// toggle and no default (the native envelope is not evidenced there).
  static ThinkingControlOverride? _positiveEfforts(
    ThinkingControlOverride control,
  ) {
    final options = <String, dynamic>{
      for (final entry in control.options.entries)
        if (entry.value is String &&
            ThinkingWireVocabulary.effortTierIds.contains(entry.value))
          entry.key: entry.value,
    };
    if (options.isEmpty) return null;
    return ThinkingControlOverride(
      status: ThinkingCapabilityStatus.supported,
      wire: 'openai_chat_effort',
      options: Map.unmodifiable(options),
    );
  }
}
