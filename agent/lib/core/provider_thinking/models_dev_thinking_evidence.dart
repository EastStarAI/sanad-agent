/// models.dev thinking evidence: the third capability-authority layer.
///
/// Capability authority is layered: settings override, then provider-reported
/// `/models` metadata, then the serving vendor's models.dev entry, then
/// `unknown`. This file owns only the models.dev layer: it validates one exact
/// vendor entry's `reasoning` / `reasoning_options`, maps it onto a
/// [ThinkingControlDescriptor] for the active route wire, and turns a selected
/// option id into the typed directive that wire carries. It never consults a
/// model-name table and never infers a control from a model id.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../provider_runtime/provider_instance.dart';
import 'native_thinking_directive.dart';
import 'thinking_control_models.dart';
import 'thinking_route_policy.dart';
import 'thinking_wire_vocabulary.dart';

/// Looks up the serving vendor's exact models.dev entry for a route, from the
/// already-hydrated catalog cache (no I/O on the admission path).
typedef ModelsDevEntryLookup =
    Map<String, dynamic>? Function(String templateId, String modelId);

/// The request wire family that will carry a models.dev-derived selection.
enum ModelsDevThinkingWire {
  /// OpenAI-compatible Chat `reasoning_effort` (+ `thinking.type` toggle).
  chat,

  /// Responses `reasoning.effort`.
  responses,

  /// Anthropic Messages adaptive effort / disable.
  messages,

  /// Gemini-compatible Chat `thinking_level` / zero budget.
  google;

  /// The wire the active route actually speaks, or `null` when the route's
  /// thinking transport is not one models.dev evidence can drive (for example
  /// native Ollama, which owns its own live probe).
  static ModelsDevThinkingWire? forRoute(ProviderInstance instance) {
    final template = ThinkingRoutePolicy.resolveTemplate(instance);
    final apiMode = ThinkingRoutePolicy.apiModeFor(instance, template);
    bool compatible(String wire) => ThinkingRoutePolicy.isWireCompatible(
      wire: wire,
      protocol: instance.protocol,
      apiMode: apiMode,
      templateId: instance.templateId,
      isCustom: instance.isCustom,
    );
    if (!instance.isCustom &&
        template.effectiveThinkingPolicyId == 'google_thinking' &&
        compatible('google_thinking')) {
      return ModelsDevThinkingWire.google;
    }
    if (compatible('openai_chat_effort')) return ModelsDevThinkingWire.chat;
    if (compatible('codex_responses_effort')) {
      return ModelsDevThinkingWire.responses;
    }
    if (compatible('anthropic_adaptive')) return ModelsDevThinkingWire.messages;
    return null;
  }
}

/// Validated `reasoning` / `reasoning_options` facts of one models.dev entry.
class ModelsDevThinkingEvidence {
  /// `false` only when the entry positively reports `reasoning: false`.
  final bool reasons;

  /// Declared effort values, in declared order.
  final List<String> efforts;

  /// Declared default effort, when the entry names one of [efforts].
  final String? defaultEffort;

  /// Whether a thinking on/off toggle is declared.
  final bool toggle;

  /// Whether thinking is declared always-on (`only`), so it cannot be disabled.
  final bool alwaysOn;

  /// Canonical fingerprint of the raw evidence.
  final String fingerprint;

  const ModelsDevThinkingEvidence._({
    required this.reasons,
    required this.efforts,
    required this.defaultEffort,
    required this.toggle,
    required this.alwaysOn,
    required this.fingerprint,
  });

  /// Strictly parses one entry. Returns `null` when the entry reports no
  /// thinking-control evidence, or when the evidence is malformed or
  /// self-contradictory (fail closed to `unknown`).
  static ModelsDevThinkingEvidence? tryParse(Map<String, dynamic>? entry) {
    if (entry == null) return null;
    final reasoning = entry['reasoning'];
    final rawOptions = entry['reasoning_options'];
    final fingerprint = sha256
        .convert(
          utf8.encode(
            jsonEncode({'reasoning': reasoning, 'options': rawOptions}),
          ),
        )
        .toString()
        .substring(0, 16);

    if (reasoning == false) {
      if (rawOptions is List && rawOptions.isNotEmpty) return null;
      return ModelsDevThinkingEvidence._(
        reasons: false,
        efforts: const [],
        defaultEffort: null,
        toggle: false,
        alwaysOn: false,
        fingerprint: fingerprint,
      );
    }
    if (reasoning != true) return null;
    // Reasoning output alone is not request-time control evidence.
    if (rawOptions is! List || rawOptions.isEmpty) return null;

    List<String>? efforts;
    String? defaultEffort;
    var toggle = false;
    var alwaysOn = false;
    for (final raw in rawOptions) {
      if (raw is! Map) return null;
      final type = raw['type'];
      switch (type) {
        case 'effort':
          if (efforts != null) return null;
          final values = raw['values'];
          if (values is! List || values.isEmpty) return null;
          final parsed = <String>[];
          for (final value in values) {
            if (value is! String) return null;
            final trimmed = value.trim();
            if (!ThinkingWireVocabulary.isAdmittedEffort(trimmed) ||
                parsed.contains(trimmed)) {
              return null;
            }
            parsed.add(trimmed);
          }
          final rawDefault = raw['default'];
          if (rawDefault != null) {
            if (rawDefault is! String || !parsed.contains(rawDefault.trim())) {
              return null;
            }
            defaultEffort = rawDefault.trim();
          }
          efforts = parsed;
        case 'toggle':
          if (toggle) return null;
          toggle = true;
        case 'only':
          if (alwaysOn) return null;
          alwaysOn = true;
        case 'budget_tokens':
          // A token-budget range (`min`/`max`) names no finite option; no
          // budget tier is invented from it, and it does not void the
          // entry's other declared controls.
          break;
        default:
          return null;
      }
    }
    if (toggle && alwaysOn) return null;
    final effortList = efforts ?? const <String>[];
    if (alwaysOn && effortList.contains(ThinkingWireVocabulary.disableEffort)) {
      return null;
    }
    return ModelsDevThinkingEvidence._(
      reasons: true,
      efforts: List.unmodifiable(effortList),
      defaultEffort: defaultEffort,
      toggle: toggle,
      alwaysOn: alwaysOn,
      fingerprint: fingerprint,
    );
  }

  /// The `canonical_model_id` (`<vendor>/<model-id>`) a provider entry built
  /// from a lab `base_model` exposes, or `null` when absent or malformed.
  static ({String vendor, String modelId})? canonicalModelId(
    Map<String, dynamic>? entry,
  ) {
    final raw = entry?['canonical_model_id'];
    if (raw is! String) return null;
    final value = raw.trim();
    final slash = value.indexOf('/');
    if (slash <= 0 || slash == value.length - 1) return null;
    return (
      vendor: value.substring(0, slash),
      modelId: value.substring(slash + 1),
    );
  }

  /// Option ids this evidence offers on [wire], in display/declared order, or
  /// `null` when the wire cannot carry a declared value (fail closed).
  List<String>? optionIdsFor(ModelsDevThinkingWire wire) {
    final ids = <String>[];
    for (final effort in efforts) {
      if (wire == ModelsDevThinkingWire.google &&
          !ThinkingWireVocabulary.isAdmittedGoogleLevel(effort)) {
        return null;
      }
      ids.add(effort);
    }
    if (toggle) {
      final hasDisable = ids.contains(ThinkingWireVocabulary.disableEffort);
      if (efforts.isEmpty) {
        // A bare toggle needs a genuine enable as well as a disable.
        if (wire != ModelsDevThinkingWire.chat) return null;
        ids.addAll(const ['on', 'off']);
      } else if (!hasDisable && wire != ModelsDevThinkingWire.responses) {
        // Declared order is weakest-first (Clients reverse it for display), so
        // the disable leads, matching the existing Off-first descriptors.
        ids.insert(0, 'off');
      }
    }
    return ids;
  }

  /// Builds the route descriptor for [wire].
  ThinkingControlDescriptor descriptorFor({
    required ModelsDevThinkingWire wire,
    required String capabilityRevision,
  }) {
    if (!reasons || (alwaysOn && efforts.isEmpty && !toggle)) {
      // Positive report: no reasoning, or always-on with no selectable value.
      return ThinkingControlDescriptor.unsupported(
        capabilityRevision: capabilityRevision,
        source: sourceId,
      );
    }
    final ids = optionIdsFor(wire);
    if (ids == null || ids.isEmpty) {
      return ThinkingControlDescriptor.unknown(
        capabilityRevision: capabilityRevision,
        source: sourceId,
      );
    }
    final kind = efforts.isEmpty
        ? ThinkingControlKind.toggle
        : wire == ModelsDevThinkingWire.google
        ? ThinkingControlKind.level
        : ThinkingControlKind.effort;
    return ThinkingControlDescriptor(
      status: ThinkingCapabilityStatus.supported,
      kind: kind,
      options: [
        for (final id in ids)
          ThinkingControlOption(
            id: id,
            label: _label(id),
            isOff: id == 'off' || id == ThinkingWireVocabulary.disableEffort,
            isProviderDefault: id == defaultEffort,
          ),
      ],
      defaultOptionId: defaultEffort,
      capabilityRevision: capabilityRevision,
      source: sourceId,
    );
  }

  /// Typed directive for one selected option id on [wire], or `null` when the
  /// id is not an option this evidence offers there.
  NativeThinkingDirective? directiveFor(
    ModelsDevThinkingWire wire,
    String selectionId,
  ) {
    final ids = optionIdsFor(wire);
    if (ids == null || !ids.contains(selectionId)) return null;
    if (selectionId == 'on') return const ThinkingToggleDirective(enabled: true);
    if (selectionId == 'off') {
      return wire == ModelsDevThinkingWire.google
          ? const GoogleBudgetDirective(0)
          : const ThinkingToggleDirective(enabled: false);
    }
    return switch (wire) {
      ModelsDevThinkingWire.chat => OpenAiEffortDirective(selectionId),
      ModelsDevThinkingWire.responses => ResponsesReasoningDirective(
        effort: selectionId,
      ),
      ModelsDevThinkingWire.messages =>
        selectionId == ThinkingWireVocabulary.disableEffort
            ? const ThinkingToggleDirective(enabled: false)
            : AnthropicAdaptiveDirective(selectionId),
      ModelsDevThinkingWire.google => GoogleLevelDirective(selectionId),
    };
  }

  static const sourceId = 'models_dev';

  static String _label(String id) => switch (id) {
    'none' => 'None',
    'minimal' => 'Minimal',
    'low' => 'Low',
    'medium' => 'Medium',
    'high' => 'High',
    'xhigh' => 'Extra High',
    'max' => 'Max',
    'on' => 'On',
    'off' => 'Off',
    _ => id,
  };
}
