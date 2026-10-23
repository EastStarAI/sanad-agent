import 'dart:convert';

import '../../../../core/provider_thinking/thinking_wire_vocabulary.dart';
import '../../../../interfaces/platforms/sanad_gateway/capabilities.dart';

/// Pure vendor thinking-control discovery rules for the OpenAI-compatible
/// adapter (Plan 138-10).
///
/// Kimi, native LM Studio and OpenRouter each publish a finite control
/// declaration on their own model item. The rules that validate that evidence
/// and map it onto the owned `openai_chat_effort` wire live here and nowhere
/// else; the adapter keeps the transport and the discovery outcome state.
class OpenAiCompatibleThinkingDiscovery {
  OpenAiCompatibleThinkingDiscovery._();

  /// Verbatim native LM Studio reasoning declaration observed from
  /// `GET /api/v1/models`. Kept as raw endpoint evidence, separate from the
  /// derived declaration below and from any enriched descriptor.
  static const lmStudioReasoningEvidenceKey = 'lm_studio_reasoning';

  /// Documented aggregator gateway effort vocabulary in documented descending
  /// effort order (`https://openrouter.ai/docs/guides/best-practices/reasoning-tokens.md`).
  ///
  /// The wire member is `reasoning.supported_efforts`: a finite list of these
  /// exact values, an explicit `null` documenting every gateway value, or an
  /// omitted member documenting no effort selector at all. Membership is
  /// validated against the shared `ThinkingWireVocabulary`, so discovery and the
  /// typed declaration parser can never drift; this list only fixes the
  /// documented order an explicit `null` (all values) declaration advertises.
  static const _openRouterGatewayEfforts = <String>[
    'max',
    'xhigh',
    'high',
    'medium',
    'low',
    'minimal',
    'none',
  ];

  /// Explicit route-control evidence published for a model whose discovery wire
  /// documents `reasoning` but for which no trustworthy declaration can be
  /// derived.
  ///
  /// The wire's own evidence owns the exact route's control state, so an
  /// unusable declaration resolves that route to `unknown` instead of silently
  /// adopting an unrelated intrinsic ladder. Model-owned image, reasoning-output,
  /// context and other discovery facts stay untouched: only `thinking_control`
  /// is published, and no documented value is copied, adapted or remapped.
  /// Enriches discovered Kimi/Moonshot models with the reasoning declaration
  /// the provider's own `GET /models` item reports.
  ///
  /// Only the registered `kimi` template consumes this schema, and only from
  /// each model's own item: no model-name or URL inference. A declaration is
  /// written only when the evidence is complete and self-consistent:
  /// `supports_reasoning: true`, thinking type `only` (thinking always on, so no
  /// Off option is declared), and a finite positive effort set with an optional
  /// default from `think_efforts` and/or `reasoning.effort`; when both forms are
  /// present they must agree. Anything else leaves discovery untouched so the
  /// existing route policy keeps owning the descriptor. Efforts dispatch on the
  /// Chat `reasoning_effort` field with their exact declared value.
  static List<ModelOption> withKimiReasoning(List<ModelOption> options) {
    return options.map((option) {
      if (option.modelMetadata.containsKey('thinking_control')) return option;
      final declaration = kimiThinkingControlFromDiscovery(
        option.modelMetadata,
      );
      if (declaration == null) return option;
      return option.copyWith(
        supportsReasoning: true,
        modelMetadata: {
          ...option.modelMetadata,
          'thinking_control': declaration,
        },
      );
    }).toList();
  }

  /// Validates one Kimi `/models` item and returns the owned
  /// `openai_chat_effort` declaration, or `null` when the evidence is absent,
  /// malformed, inconsistent, or not an always-on (`only`) effort contract.
  static Map<String, Object?>? kimiThinkingControlFromDiscovery(
    Map<String, Object?> item,
  ) {
    if (item['supports_reasoning'] != true) return null;

    final topType = item['supports_thinking_type'];
    final reasoning = item['reasoning'];
    if (item.containsKey('reasoning') && reasoning is! Map) return null;
    final nestedType = reasoning is Map ? reasoning['type'] : null;
    if (topType == null && nestedType == null) return null;
    if (topType != null && topType is! String) return null;
    if (nestedType != null && nestedType is! String) return null;
    if (topType != null && nestedType != null && topType != nestedType) {
      return null;
    }
    final thinkingType = ((topType ?? nestedType) as String).trim();
    if (thinkingType != 'only') return null;

    ({List<String> efforts, String? defaultEffort})? parse(
      Object? rawEfforts,
      Object? rawDefault,
    ) {
      if (rawEfforts is! List || rawEfforts.isEmpty) return null;
      final efforts = <String>[];
      for (final entry in rawEfforts) {
        if (entry is! String) return null;
        final value = entry.trim();
        // `only` cannot disable thinking, so a disabling effort is malformed.
        if (value == 'none' ||
            !ThinkingWireVocabulary.isAdmittedEffort(value) ||
            efforts.contains(value)) {
          return null;
        }
        efforts.add(value);
      }
      if (rawDefault != null) {
        if (rawDefault is! String || !efforts.contains(rawDefault.trim())) {
          return null;
        }
      }
      return (efforts: efforts, defaultEffort: (rawDefault as String?)?.trim());
    }

    ({List<String> efforts, String? defaultEffort})? fromThinkEfforts;
    if (item.containsKey('think_efforts')) {
      final raw = item['think_efforts'];
      if (raw is! Map || raw['support'] != true) return null;
      fromThinkEfforts = parse(raw['valid_efforts'], raw['default_effort']);
      if (fromThinkEfforts == null) return null;
    }
    ({List<String> efforts, String? defaultEffort})? fromReasoning;
    if (reasoning is Map && reasoning.containsKey('effort')) {
      final raw = reasoning['effort'];
      if (raw is! Map) return null;
      fromReasoning = parse(raw['valid'], raw['default']);
      if (fromReasoning == null) return null;
    }
    final declared = fromThinkEfforts ?? fromReasoning;
    if (declared == null) return null;
    if (fromThinkEfforts != null && fromReasoning != null) {
      final a = {...fromThinkEfforts.efforts};
      final b = {...fromReasoning.efforts};
      if (a.length != b.length ||
          !a.containsAll(b) ||
          fromThinkEfforts.defaultEffort != fromReasoning.defaultEffort) {
        return null;
      }
    }
    return {
      'status': 'supported',
      'wire': 'openai_chat_effort',
      'options': {for (final effort in declared.efforts) effort: effort},
      'default_option': ?declared.defaultEffort,
    };
  }

  static const _openRouterUnresolvedControl = <String, Object?>{
    'status': 'unknown',
  };

  /// Documented native LM Studio public reasoning values for
  /// `capabilities.reasoning.allowed_options` / `capabilities.reasoning.default`
  /// (`https://lmstudio.ai/docs/developer/rest/list`).
  static const _lmStudioNativeReasoningValues = <String>{
    'off',
    'on',
    'low',
    'medium',
    'high',
  };

  /// Native values with a documented OpenAI-compatible Chat `reasoning_effort`
  /// equivalent. Every advertised option keeps its exact native value, so
  /// `low`/`medium`/`high` reach the wire unchanged.
  static const _lmStudioChatEffortValues = <String>['low', 'medium', 'high'];

  /// Enriches discovered LM Studio models with the finite reasoning declaration
  /// served by the native `GET /api/v1/models` endpoint.
  ///
  /// Model identity is matched exactly: a native `key` or one of its
  /// `loaded_instances[].id` identifiers must equal the discovered
  /// compatibility id, and exactly one native entry may claim it. Absent,
  /// failing, malformed or ambiguous evidence leaves the compatibility
  /// discovery result untouched; no support is fabricated, no protocol is
  /// switched and no unrelated metadata is reset.
  ///
  /// [fetchNativeModels] and [onWarning] keep the transport and the logger with
  /// the adapter: this owner only validates and maps the evidence it is given.
  static Future<List<ModelOption>> withLmStudioNativeReasoning(
    List<ModelOption> options, {
    required Future<List<Map<String, Object?>>?> Function() fetchNativeModels,
    required void Function(String message) onWarning,
  }) async {
    if (options.isEmpty) return options;
    try {
      final nativeModels = await fetchNativeModels();
      if (nativeModels == null || nativeModels.isEmpty) return options;

      // Count distinct native entries, not aliases within the same entry.
      final candidatesById = <String, Set<Map<String, Object?>>>{};
      for (final model in nativeModels) {
        final key = model['key'];
        if (key is! String || key.isEmpty) continue;
        candidatesById
            .putIfAbsent(key, () => Set<Map<String, Object?>>.identity())
            .add(model);

        final instances = model['loaded_instances'];
        if (instances is! List) continue;
        for (final instance in instances) {
          if (instance is! Map) continue;
          final instanceId = instance['id'];
          if (instanceId is! String || instanceId.isEmpty) continue;
          candidatesById
              .putIfAbsent(
                instanceId,
                () => Set<Map<String, Object?>>.identity(),
              )
              .add(model);
        }
      }

      return options.map((option) {
        // Native enrichment cannot replace the compatibility endpoint's own
        // declaration (including a malformed one owned by that authority).
        if (option.modelMetadata.containsKey('thinking_control')) return option;
        final candidates = candidatesById[option.value];
        if (candidates == null || candidates.length != 1) return option;

        final capabilities = candidates.single['capabilities'];
        final reasoning = capabilities is Map
            ? capabilities['reasoning']
            : null;
        final declaration = _parseNativeReasoningDeclaration(reasoning);
        if (declaration == null) return option;

        final declaredControl = _declaredThinkingControlFromNative(declaration);
        return option.copyWith(
          modelMetadata: {
            ...option.modelMetadata,
            lmStudioReasoningEvidenceKey: reasoning,
            'thinking_control': ?declaredControl,
          },
        );
      }).toList();
    } catch (e) {
      onWarning('Failed to enrich LM Studio native reasoning metadata: $e');
      return options;
    }
  }

  /// Strictly validates a native LM Studio `capabilities.reasoning` object.
  ///
  /// Returns `null` for absent, malformed, empty or non-finite declarations,
  /// including a value outside the documented native vocabulary or a default
  /// that is not one of the declared values. No default is ever inferred.
  static ({Set<String> allowed, String defaultOption})?
  _parseNativeReasoningDeclaration(Object? raw) {
    if (raw is! Map) return null;

    final allowedRaw = raw['allowed_options'];
    if (allowedRaw is! List || allowedRaw.isEmpty) return null;
    final allowed = <String>{};
    for (final entry in allowedRaw) {
      if (entry is! String) return null;
      final value = entry.trim();
      if (!_lmStudioNativeReasoningValues.contains(value)) return null;
      allowed.add(value);
    }

    final defaultRaw = raw['default'];
    if (defaultRaw is! String) return null;
    final defaultOption = defaultRaw.trim();
    if (!allowed.contains(defaultOption)) return null;

    return (allowed: allowed, defaultOption: defaultOption);
  }

  /// Maps a validated native declaration onto the documented compatibility Chat
  /// wire, or `null` when no declared value has an evidenced wire equivalent.
  ///
  /// Native-only values (`on`/`off`) are never mapped to another value, and an
  /// unmappable native default stays unrepresentable so a real provider default
  /// remains plain omission instead of an invented selectable level.
  static Map<String, Object?>? _declaredThinkingControlFromNative(
    ({Set<String> allowed, String defaultOption}) declaration,
  ) {
    final options = <String, dynamic>{
      for (final value in _lmStudioChatEffortValues)
        if (declaration.allowed.contains(value)) value: value,
    };
    if (options.isEmpty) return null;

    return {
      'status': 'supported',
      'wire': 'openai_chat_effort',
      'options': options,
      if (options.containsKey(declaration.defaultOption))
        'default_option': declaration.defaultOption,
    };
  }

  /// Enriches discovered aggregator models with the finite thinking declaration
  /// documented on each `GET /models` item.
  ///
  /// The discovery wire itself owns this schema: only the registered aggregator
  /// provider identity consumes it, never a generic/local/custom Chat endpoint
  /// and never a URL substring guess. Each option is read from its own exact
  /// model item, so no cross-model, cross-case or cross-namespace inference is
  /// possible; two items claiming one exact identity declare a control only when
  /// their raw evidence agrees, and conflicting claims publish unresolved route
  /// evidence instead of either claim.
  ///
  /// Raw endpoint evidence stays the verbatim item member (`reasoning`) while
  /// the validated declaration is written separately to `thinking_control`. A
  /// declaration already owned by the compatibility discovery wire is left
  /// untouched: aggregator enrichment never replaces or competes with it.
  ///
  /// A model item that documents `reasoning` owns its route's control state:
  /// when that documentation yields no trustworthy declaration — no effort
  /// selector, malformed values or flags, a default inconsistent with the
  /// documented set, a mixed or conflicting duplicate claim for one exact
  /// identity — the option receives explicit `unknown` route-control evidence
  /// rather than falling back to an unrelated intrinsic ladder. An identity whose
  /// rows are all names-only publishes nothing, so existing authority and
  /// intrinsic model knowledge stay intact, and every documented canonical effort
  /// value is declared truthfully with its own exact value.
  static List<ModelOption> withOpenRouterReasoning(List<ModelOption> options) {
    if (options.isEmpty) return options;

    final evidenceSignatures = <String, Set<String>>{};
    for (final option in options) {
      evidenceSignatures
          .putIfAbsent(option.value, () => <String>{})
          .add(
            jsonEncode([
              option.modelMetadata.containsKey('reasoning'),
              option.modelMetadata['reasoning'],
            ]),
          );
    }

    return options.map((option) {
      if (option.modelMetadata.containsKey('thinking_control')) return option;
      final signatures = evidenceSignatures[option.value];
      final ambiguous = signatures == null || signatures.length != 1;
      if (!option.modelMetadata.containsKey('reasoning') && !ambiguous) {
        return option;
      }
      final declaration = ambiguous
          ? _openRouterUnresolvedControl
          : _openRouterThinkingControl(option.modelMetadata['reasoning']) ??
                _openRouterUnresolvedControl;
      return option.copyWith(
        modelMetadata: {
          ...option.modelMetadata,
          'thinking_control': declaration,
        },
      );
    }).toList();
  }

  /// Strictly validates one discovered aggregator `reasoning` declaration.
  ///
  /// Returns the validated `openai_chat_effort` declaration, or `null` when the
  /// presented documentation yields no trustworthy declaration. Every documented
  /// canonical effort is admissible, so no documented set is reduced, clamped or
  /// aliased; no default, budget choice, bound or effort value is ever invented.
  static Map<String, Object?>? _openRouterThinkingControl(Object? raw) {
    if (raw is! Map) return null;

    final efforts = _openRouterDocumentedEfforts(raw);
    if (efforts == null) return null;

    final mandatoryRaw = raw['mandatory'];
    if (raw.containsKey('mandatory') && mandatoryRaw is! bool) return null;
    final defaultEnabled = raw['default_enabled'];
    if (raw.containsKey('default_enabled') && defaultEnabled is! bool) {
      return null;
    }

    final defaultEffortRaw = raw['default_effort'];
    if (raw.containsKey('default_effort')) {
      if (defaultEffortRaw is! String || !efforts.contains(defaultEffortRaw)) {
        return null;
      }
    }

    // A documented mandatory model has no Off option and rejects
    // `effort: "none"`, so the disable value is never advertised for it.
    final admissible = mandatoryRaw == true
        ? efforts.where((effort) => effort != 'none').toList(growable: false)
        : efforts;
    if (admissible.isEmpty) return null;

    String? defaultOption;
    if (defaultEffortRaw is String) {
      if (defaultEffortRaw != 'none' &&
          defaultEnabled != false &&
          admissible.contains(defaultEffortRaw)) {
        defaultOption = defaultEffortRaw;
      }
    }

    return {
      'status': 'supported',
      'wire': 'openai_chat_effort',
      'options': {for (final effort in admissible) effort: effort},
      'default_option': ?defaultOption,
    };
  }

  /// The documented finite effort set for one aggregator model item, or `null`
  /// when the member is omitted, malformed, duplicated or outside the documented
  /// gateway vocabulary.
  ///
  /// An explicit `null` documents every gateway value; an omitted member
  /// documents no effort selector at all. Admissibility comes from the shared
  /// `ThinkingWireVocabulary` the typed declaration parser validates against, so
  /// every documented canonical value (`max`, `xhigh`, `high`, `medium`, `low`,
  /// `minimal`, `none`) is declarable here and none is rejected or remapped.
  static List<String>? _openRouterDocumentedEfforts(Map<dynamic, dynamic> raw) {
    if (!raw.containsKey('supported_efforts')) return null;

    final rawEfforts = raw['supported_efforts'];
    if (rawEfforts == null) return List<String>.of(_openRouterGatewayEfforts);
    if (rawEfforts is! List || rawEfforts.isEmpty) return null;

    final efforts = <String>[];
    for (final entry in rawEfforts) {
      if (entry is! String) return null;
      if (!ThinkingWireVocabulary.isAdmittedEffort(entry)) return null;
      if (efforts.contains(entry)) return null;
      efforts.add(entry);
    }
    return efforts;
  }
}
