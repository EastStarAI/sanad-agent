import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:http/http.dart' as http;

import '../../core/config.dart';
import '../../core/models/message.dart';
import '../../core/models/agent_response.dart';
import '../../core/models/llm_provider_state.dart';
import '../../core/models/tool_call.dart';
import '../../capabilities/models/tool_schema.dart';
import 'llm_adapter.dart';
import '../../core/provider_thinking/aggregator_thinking_wire_codec.dart';
import '../../core/provider_thinking/deepseek_thinking_wire_codec.dart';
import '../../core/provider_thinking/google_thinking_wire_codec.dart';
import '../../core/provider_thinking/native_thinking_directive.dart';
import '../../core/provider_thinking/toggle_effort_thinking_wire_codec.dart';
import '../../core/provider_thinking/thinking_route_policy.dart';
import '../../core/provider_thinking/thinking_wire_vocabulary.dart';
import '../../core/provider_thinking/zai_thinking_wire_codec.dart';
import '../../core/models/model_metadata.dart';
import '../../core/di.dart';
import '../../core/provider_runtime/provider_instance.dart';
import '../../core/provider_runtime/provider_protocol_constants.dart';
import '../../core/provider_runtime/provider_instance_repository.dart';
import '../../core/provider_runtime/provider_endpoint_resolver.dart';
import '../../core/provider_runtime/provider_model_id.dart';
import '../../core/provider_runtime/route_capability_resolver.dart';
import '../../interfaces/platforms/sanad_gateway/capabilities.dart';
import 'provider_profile.dart';
import 'models_dev_service.dart';
import 'llm_http_exception.dart';
import 'opencode_session_affinity.dart';
import 'llm_request_options.dart';
import 'provider_request_transport.dart';
import 'tagged_reasoning_parser.dart';
import 'tool_result_wire_codec.dart';
import '../llm_request_dumper.dart';

class BaseOpenAIAdapter implements LLMAdapter {
  final _logger = Logger('BaseOpenAIAdapter');
  final Config config;
  final ProviderProfile profile;
  final http.Client? client;
  final http.Client Function()? requestClientFactory;
  final ModelsDevService? modelsDevService;
  final ModelContextLimitLookup? modelContextLimitLookup;
  final String? baseUrlOverride;
  final String? apiKeyOverride;
  final String? defaultModelOverride;
  final String? providerInstanceId;
  String _availableModelsSource = 'fallback';
  Object? _lastModelsException;

  BaseOpenAIAdapter(
    this.config,
    this.profile, {
    this.client,
    this.requestClientFactory,
    this.modelsDevService,
    this.modelContextLimitLookup,
    this.baseUrlOverride,
    this.apiKeyOverride,
    this.defaultModelOverride,
    this.providerInstanceId,
  });

  String get _baseUrl => ProviderEndpointResolver.normalizeBaseUrl(
    baseUrlOverride ?? config.baseUrlFor(profile),
  );
  String get _apiKey => apiKeyOverride ?? config.apiKeyFor(profile);
  Map<String, String> get _modelDiscoveryHeaders => {
    if (_apiKey.isNotEmpty) 'Authorization': 'Bearer $_apiKey',
    ...profile.defaultHeaders,
  };

  // Public accessors for subclasses (Strategy Pattern)
  String get baseUrl => _baseUrl;
  String get apiKey => _apiKey;
  String get availableModelsSource => _availableModelsSource;
  Object? get lastModelsException => _lastModelsException;
  void setLastModelsException(Object? exception) =>
      _lastModelsException = exception;
  void setAvailableModelsSource(String source) =>
      _availableModelsSource = source;
  List<ModelOption> fallbackModelOptions() => _fallbackModelOptions();
  String resolveModel(String? override) => _resolveModel(override);
  String providerForModel(String model) => _providerForModel(model);
  Map<String, dynamic>? tryDecodeToolArguments(String args) =>
      _tryDecodeToolArguments(args);
  String roleToString(MessageRole role) => _roleToString(role);

  @override
  Future<List<ModelOption>> getAvailableModels() async {
    _lastModelsException = null;
    final List<Uri> candidates;
    try {
      candidates = _modelsEndpointCandidates();
    } catch (error) {
      _lastModelsException = error;
      _availableModelsSource = 'fallback';
      return _fallbackModelOptions();
    }
    for (final url in candidates) {
      try {
        final response = await _get(url, headers: _modelDiscoveryHeaders);
        if (response.statusCode != 200) {
          _lastModelsException = LlmHttpException.fromResponse(
            response,
            operation: 'getAvailableModels',
          );
          continue;
        }

        final data = jsonDecode(response.body);
        final modelsList = data['data'] as List?;
        if (modelsList == null) {
          _lastModelsException = StateError(
            'Response data is not a list of models',
          );
          continue;
        }

        final List<ModelOption> options = [];
        final agenticModels = modelsDevService != null
            ? await modelsDevService!.listAgenticModels(profile.name)
            : <String>[];

        for (var item in modelsList) {
          final id = item['id'] as String;
          final normalizedId = _normalizeModelId(id);

          if (!_isAgenticModel(normalizedId, agenticModels)) {
            continue;
          }

          final label = _formatModelLabel(normalizedId);
          final supportsReasoning = await _modelSupportsReasoning(normalizedId);

          int? contextLimit;
          if (item is Map) {
            final possibleKeys = [
              'context_window',
              'context_length',
              'context_size',
              'max_context_length',
              'max_position_embeddings',
              'max_model_len',
              'max_input_tokens',
              'max_sequence_length',
              'max_seq_len',
              'n_ctx_train',
              'n_ctx',
              'ctx_size',
            ];
            for (final key in possibleKeys) {
              final val = item[key];
              if (val is num && val > 0) {
                contextLimit = val.toInt();
                break;
              }
            }
          }
          contextLimit ??= await _modelContextLimit(normalizedId);

          options.add(
            ModelOption(
              value: normalizedId,
              label: label,
              provider: profile.name,
              contextWindow: contextLimit,
              supportsReasoning: supportsReasoning,
              modelMetadata: item is Map
                  ? Map<String, Object?>.from(
                      item.map((key, value) => MapEntry(key.toString(), value)),
                    )
                  : const {},
            ),
          );
        }
        if (options.isNotEmpty) {
          var resolvedOptions = options;
          if (profile.name == 'lm-studio') {
            resolvedOptions = await _withLmStudioNativeReasoning(options);
          }
          if (profile.name == 'openrouter') {
            resolvedOptions = _withOpenRouterReasoning(resolvedOptions);
          }
          _availableModelsSource = 'live';
          _lastModelsException = null;
          if (profile.fallbackModels.isNotEmpty) {
            resolvedOptions.sort((a, b) {
              var aId = a.value;
              var bId = b.value;

              if (aId.startsWith('~')) aId = aId.substring(1);
              if (bId.startsWith('~')) bId = bId.substring(1);

              final aIndex = profile.fallbackModels.indexOf(aId);
              final bIndex = profile.fallbackModels.indexOf(bId);

              if (aIndex != -1 && bIndex != -1) {
                return aIndex.compareTo(bIndex);
              } else if (aIndex != -1) {
                return -1;
              } else if (bIndex != -1) {
                return 1;
              }
              return 0;
            });
          }
          return resolvedOptions;
        }
      } catch (e) {
        _logger.warning('Failed to fetch standard models from $url: $e');
        _lastModelsException = e;
      }
    }

    // Fallback: return at least the current configured model
    _availableModelsSource = 'fallback';
    return _fallbackModelOptions();
  }

  String _normalizeModelId(String rawModelId) {
    return ProviderModelId.normalize(
      templateId: profile.name,
      protocol: profile.effectiveProtocol,
      rawModelId: rawModelId,
    );
  }

  String _fallbackModelId() {
    final configured = defaultModelOverride ?? config.llmModel;
    return _normalizeModelId(configured);
  }

  List<ModelOption> _fallbackModelOptions() {
    final merged = <String>[];
    final selected = _fallbackModelId();
    if (selected.isNotEmpty) {
      merged.add(selected);
    }
    for (final model in profile.fallbackModels) {
      final normalized = _normalizeModelId(model);
      if (normalized.isNotEmpty && !merged.contains(normalized)) {
        merged.add(normalized);
      }
    }
    if (merged.isEmpty) {
      merged.add(selected);
    }

    return merged
        .map((modelId) {
          final lowered = modelId.toLowerCase();
          return ModelOption(
            value: modelId,
            label: _formatModelLabel(modelId),
            provider: profile.name,
            contextWindow: ModelMetadata.getLimitForModel(modelId),
            supportsReasoning:
                lowered.contains('o1') ||
                lowered.contains('o3') ||
                lowered.contains('reasoning'),
          );
        })
        .toList(growable: false);
  }

  List<Uri> _modelsEndpointCandidates() {
    return ProviderEndpointResolver.resolveOpenAiModelsEndpointCandidates(
      _baseUrl,
    );
  }

  String _formatModelLabel(String name) {
    String capitalize(String s) =>
        s.isEmpty ? '' : '${s[0].toUpperCase()}${s.substring(1)}';

    var cleanName = name.contains('/') ? name.split('/').last : name;
    if (cleanName.startsWith('~')) {
      cleanName = cleanName.substring(1);
    }

    return cleanName
        .split('-')
        .map((part) {
          if (part.startsWith('gpt')) {
            return 'GPT${part.substring(3)}';
          }
          return capitalize(part);
        })
        .join(' ');
  }

  bool _isAgenticModel(String modelId, List<String> agenticModels) {
    if (profile.isCustom || profile.effectiveAuthFlow == 'custom_endpoint') {
      return true;
    }

    final lowercaseId = modelId.toLowerCase();

    if (agenticModels.isNotEmpty) {
      if (agenticModels.any((m) => m.toLowerCase() == lowercaseId)) {
        return true;
      }
    }

    // Strip namespaces (like openai/, google/, anthropic/) and tildes (~anthropic/)
    var cleanId = lowercaseId.contains('/')
        ? lowercaseId.split('/').last
        : lowercaseId;
    if (cleanId.startsWith('~')) {
      cleanId = cleanId.substring(1);
    }

    // Heuristics fallback
    final matchesKnown =
        cleanId.startsWith('gpt-') ||
        cleanId.startsWith('o1-') ||
        cleanId.startsWith('o3-') ||
        cleanId.startsWith('claude-') ||
        cleanId.contains('deepseek') ||
        cleanId.startsWith('gemma-') ||
        cleanId.startsWith('gemma') ||
        profile.name == 'nvidia' ||
        cleanId.contains('nvidia') ||
        cleanId.contains('nemotron');

    if (matchesKnown) return true;

    return ModelMetadata.getLimitForModel(cleanId) != null;
  }

  Future<bool> _modelSupportsReasoning(String modelId) async {
    if (modelsDevService != null) {
      final registryMatch = await modelsDevService!.supportsReasoning(
        profile.name,
        modelId,
      );
      if (registryMatch) return true;
    }
    final lowercaseId = modelId.toLowerCase();
    return lowercaseId.contains('o1') ||
        lowercaseId.contains('o3') ||
        lowercaseId.contains('o4') ||
        lowercaseId.contains('gpt-5') ||
        lowercaseId.contains('gpt-6') ||
        lowercaseId.contains('reasoning') ||
        lowercaseId.contains('deepseek-r');
  }

  Future<int?> _modelContextLimit(String modelId) async {
    if (modelsDevService != null) {
      return modelsDevService!.getContextLimit(profile.name, modelId);
    }
    return ModelMetadata.getLimitForModel(modelId);
  }

  @override
  Future<int> getContextLimit([String? modelOverride]) async {
    final resolvedModel = _resolveModel(modelOverride);
    final configuredLimit = config.contextModelLimit(resolvedModel);
    if (configuredLimit != null) return configuredLimit;

    final catalogLimit = modelContextLimitLookup?.call(resolvedModel);
    if (catalogLimit != null) return catalogLimit;

    // 1. LM Studio local probe (reference-style)
    if (profile.name == 'lm-studio') {
      try {
        final cleanBase = _lmStudioNativeBase;
        final url = Uri.parse('$cleanBase/api/v1/models');
        final response = await _get(url, timeout: const Duration(seconds: 2));
        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          final models = data['models'] as List?;
          if (models != null) {
            for (var model in models) {
              if (model is Map) {
                final key = model['key'] ?? model['id'];
                if (key == resolvedModel) {
                  final loadedInstances = model['loaded_instances'] as List?;
                  if (loadedInstances != null && loadedInstances.isNotEmpty) {
                    final config = loadedInstances.first['config'];
                    if (config is Map) {
                      final ctxLen = config['context_length'];
                      if (ctxLen is num && ctxLen > 0) {
                        return ctxLen.toInt();
                      }
                    }
                  }
                }
              }
            }
          }
        }
      } catch (e) {
        _logger.warning('Failed to probe LM Studio context limit: $e');
      }
    }

    // 2. llama.cpp local probe (reference-style)
    if (profile.name == 'llama-cpp') {
      try {
        final cleanBase = baseUrl.replaceAll('/v1', '').replaceAll('/v1/', '');
        final urls = [
          Uri.parse('$baseUrl/props'),
          Uri.parse('$cleanBase/v1/props'),
          Uri.parse('$cleanBase/props'),
        ];
        for (final url in urls) {
          try {
            final response = await _get(
              url,
              timeout: const Duration(seconds: 2),
            );
            if (response.statusCode == 200) {
              final data = jsonDecode(response.body);
              final nCtx = data['default_generation_settings']?['n_ctx'];
              if (nCtx is num && nCtx > 0) {
                return nCtx.toInt();
              }
            }
          } catch (_) {}
        }
      } catch (e) {
        _logger.warning('Failed to probe llama.cpp context limit: $e');
      }
    }

    if (modelsDevService != null) {
      final limit = await modelsDevService!.getContextLimit(
        profile.name,
        resolvedModel,
      );
      if (limit != null) return limit;
    }

    final metadataLimit = ModelMetadata.getLimitForModel(resolvedModel);
    if (metadataLimit != null) return metadataLimit;

    return ModelMetadata.unknownContextLimit;
  }

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

  /// Native LM Studio REST base URL. The native API is served from the server
  /// root while the OpenAI-compatible API lives under `/v1`.
  String get _lmStudioNativeBase =>
      _baseUrl.replaceAll('/v1', '').replaceAll('/v1/', '');

  /// Enriches discovered LM Studio models with the finite reasoning declaration
  /// served by the native `GET /api/v1/models` endpoint.
  ///
  /// Model identity is matched exactly: a native `key` or one of its
  /// `loaded_instances[].id` identifiers must equal the discovered
  /// compatibility id, and exactly one native entry may claim it. Absent,
  /// failing, malformed or ambiguous evidence leaves the compatibility
  /// discovery result untouched; no support is fabricated, no protocol is
  /// switched and no unrelated metadata is reset.
  Future<List<ModelOption>> _withLmStudioNativeReasoning(
    List<ModelOption> options,
  ) async {
    if (options.isEmpty) return options;
    try {
      final nativeModels = await _fetchLmStudioNativeModels();
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
      _logger.warning(
        'Failed to enrich LM Studio native reasoning metadata: $e',
      );
      return options;
    }
  }

  Future<List<Map<String, Object?>>?> _fetchLmStudioNativeModels() async {
    final response = await _get(
      Uri.parse('$_lmStudioNativeBase/api/v1/models'),
      headers: _modelDiscoveryHeaders,
      timeout: const Duration(seconds: 2),
    );
    if (response.statusCode != 200) return null;
    final data = jsonDecode(response.body);
    if (data is! Map) return null;
    final models = data['models'];
    if (models is! List) return null;

    final parsed = <Map<String, Object?>>[];
    for (final model in models) {
      final modelMap = _asStringMap(model);
      if (modelMap != null) parsed.add(modelMap);
    }
    return parsed;
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
  List<ModelOption> _withOpenRouterReasoning(List<ModelOption> options) {
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

  String _resolveModel(String? override) {
    if (override == null || override.isEmpty) {
      return _fallbackModelId();
    }
    return _normalizeModelId(override);
  }

  @override
  Future<AgentResponse> generateResponse(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async {
    final url = Uri.parse('$_baseUrl/chat/completions');
    final resolvedModel = _resolveModel(modelOverride);
    final body = await _buildRequestBody(
      history,
      tools: tools,
      resolvedModel: resolvedModel,
      options: options,
    );
    final headers = _requestHeaders(options);
    if (LLMRequestDumper.isEnabled) {
      await LLMRequestDumper.recordActualRequest(
        url: url,
        headers: headers,
        body: body,
      );
    }

    final transport = ProviderRequestTransport(
      options: options,
      adapterSharedClient: client,
      requestClientFactory:
          requestClientFactory ?? options.requestClientFactory,
    );
    late http.Response response;
    try {
      response = await transport.post(
        url,
        headers: headers,
        body: jsonEncode(body),
        operation: 'generateResponse',
      );
    } finally {
      await transport.dispose();
    }

    _logger.info('LLM Response status: ${response.statusCode}');
    if (LLMRequestDumper.isEnabled) {
      await LLMRequestDumper.dumpResponse(response.body);
    }

    if (response.statusCode != 200) {
      throw LlmHttpException.fromResponse(
        response,
        operation: 'generateResponse',
      );
    }

    final data = _asStringMap(jsonDecode(response.body));
    final choices = data?['choices'];
    if (choices is! List || choices.isEmpty) {
      throw const FormatException('Chat completion response has no choices.');
    }
    final choiceEnvelope = _asStringMap(choices.first);
    final choice = _asStringMap(choiceEnvelope?['message']);
    if (choiceEnvelope == null || choice == null) {
      throw const FormatException('Chat completion choice has no message.');
    }

    final structuredReasoning = _extractStructuredReasoning(choice);
    final tagged = splitTaggedReasoning(choice['content']?.toString() ?? '');
    final reasoning = structuredReasoning.visibleText ?? tagged.reasoning;
    final content = tagged.content;
    final toolCalls = _parseToolCalls(choice['tool_calls']);
    final usage = _asStringMap(data?['usage']);
    final finishReason = _normalizeFinishReason(
      choiceEnvelope['finish_reason'],
      hasToolCalls: toolCalls.isNotEmpty,
    );
    final providerState = _providerStateForReasoning(
      details: structuredReasoning.details,
      reasoningContent: structuredReasoning.providerContent,
      options: options,
    );

    return AgentResponse(
      message: Message(
        role: MessageRole.assistant,
        content: content,
        toolCalls: toolCalls.isEmpty ? null : toolCalls,
        reasoning: reasoning,
        providerState: providerState,
      ),
      isToolCall: toolCalls.isNotEmpty,
      usage: usage,
      model: resolvedModel,
      provider: _providerForModel(resolvedModel),
      finishReason: finishReason,
    );
  }

  @override
  Stream<AgentResponse> generateStream(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async* {
    final url = Uri.parse('$_baseUrl/chat/completions');
    final resolvedModel = _resolveModel(modelOverride);
    final transport = ProviderRequestTransport(
      options: options,
      adapterSharedClient: client,
      requestClientFactory:
          requestClientFactory ?? options.requestClientFactory,
    );
    final request = http.Request('POST', url);
    request.headers.addAll(_requestHeaders(options));
    final body = await _buildRequestBody(
      history,
      tools: tools,
      resolvedModel: resolvedModel,
      options: options,
      stream: true,
    );

    if (LLMRequestDumper.isEnabled) {
      await LLMRequestDumper.recordActualRequest(
        url: url,
        headers: request.headers,
        body: body,
      );
    }

    request.body = jsonEncode(body);
    late http.StreamedResponse response;
    try {
      response = await transport.send(request, operation: 'generateStream');
    } catch (_) {
      await transport.dispose();
      rethrow;
    }

    try {
      _logger.info(
        'LLM Stream Response started (status: ${response.statusCode})',
      );

      if (response.statusCode != 200) {
        final errBody = await response.stream.bytesToString();
        if (LLMRequestDumper.isEnabled) {
          await LLMRequestDumper.dumpResponse({
            'status_code': response.statusCode,
            'error': errBody,
          });
        }
        throw LlmHttpException.fromStreamedResponse(
          response,
          errBody,
          operation: 'generateStream',
        );
      }

      final partialToolCalls = <int, _PartialToolCall>{};
      final completedToolCalls = <ToolCall>[];
      final reasoningDetails = <dynamic>[];
      final tagFallback = TaggedReasoningStreamParser();
      var emittedProviderState = false;
      final contentBuffer = StringBuffer();
      final reasoningBuffer = StringBuffer();
      final providerReasoningContentBuffer = StringBuffer();
      var hasProviderReasoningContent = false;
      Map<String, dynamic>? finalUsage;
      LLMFinishReason streamFinishReason = LLMFinishReason.unknown;

      try {
        await for (final line in transport.decodeSseLines(
          response.stream,
          operation: 'generateStream',
        )) {
          transport.throwIfCancelled(operation: 'generateStream');
          if (line.trim().isEmpty) continue;

          if (line.startsWith('data:')) {
            final dataStr = line.substring(5).trim();
            if (dataStr == '[DONE]') break;

            final data = _asStringMap(jsonDecode(dataStr));
            if (data == null) continue;
            // Some providers (NVIDIA NIM, Vertex AI) return HTTP 200 but embed a
            // provider-side error in the SSE payload. Surface it as an
            // LlmHttpException so the runtime classifier can handle it
            // identically to a non-2xx HTTP failure.
            final errorObj = data['error'];
            if (errorObj is Map<String, dynamic>) {
              final code = errorObj['code'];
              final statusCode = code is int
                  ? code
                  : int.tryParse(code?.toString() ?? '') ?? response.statusCode;
              final structuredError = {
                'error': {
                  if (errorObj['type'] != null) 'type': errorObj['type'],
                  if (errorObj['code'] != null) 'code': errorObj['code'],
                  if (errorObj['message'] != null)
                    'message': errorObj['message'],
                },
              };
              throw LlmHttpException(
                statusCode: statusCode,
                body: jsonEncode(structuredError),
                headers: response.headers,
                operation: 'generateStream',
              );
            }

            final usage = _asStringMap(data['usage']);
            if (usage != null) finalUsage = usage;

            if (data['choices'] == null || (data['choices'] as List).isEmpty) {
              if (usage != null) {
                yield AgentResponse(
                  message: Message(role: MessageRole.assistant, content: ''),
                  isToolCall: false,
                  usage: usage,
                  model: resolvedModel,
                  provider: _providerForModel(resolvedModel),
                  finishReason: LLMFinishReason.unknown,
                );
              }
              continue;
            }

            final choice = _asStringMap((data['choices'] as List).first);
            final delta = _asStringMap(choice?['delta']);
            if (delta == null) continue;

            final structuredReasoning = _extractStructuredReasoning(delta);
            reasoningDetails.addAll(structuredReasoning.details);
            final providerReasoningContent =
                structuredReasoning.providerContent;
            if (providerReasoningContent is String) {
              hasProviderReasoningContent = true;
              providerReasoningContentBuffer.write(providerReasoningContent);
            }
            final contentChunk = delta['content']?.toString();
            final taggedChunk = contentChunk == null
                ? const TaggedReasoningText()
                : tagFallback.add(contentChunk);
            if (taggedChunk.content != null) {
              contentBuffer.write(taggedChunk.content);
            }
            if (taggedChunk.reasoning != null) {
              reasoningBuffer.write(taggedChunk.reasoning);
            } else if (structuredReasoning.visibleText != null) {
              reasoningBuffer.write(structuredReasoning.visibleText);
            }

            if (delta['tool_calls'] != null) {
              final List<dynamic> tcList = delta['tool_calls'];
              for (var i = 0; i < tcList.length; i++) {
                final tc = _asStringMap(tcList[i]);
                if (tc == null) {
                  throw const FormatException(
                    'Malformed streamed chat completion tool call.',
                  );
                }
                final index = (tc['index'] as num?)?.toInt() ?? i;
                final function = _asStringMap(tc['function']);
                final partial = partialToolCalls.putIfAbsent(
                  index,
                  () => _PartialToolCall(),
                );
                partial.append(
                  id: tc['id']?.toString(),
                  name: function?['name']?.toString(),
                  argumentsChunk: function?['arguments']?.toString(),
                );
              }
            }

            final finishReason = _normalizeFinishReason(
              choice?['finish_reason'],
              hasToolCalls: false,
            );
            if (finishReason != LLMFinishReason.unknown) {
              streamFinishReason = finishReason;
            }
            final providerState = finishReason == LLMFinishReason.unknown
                ? null
                : _providerStateForReasoning(
                    details: reasoningDetails,
                    reasoningContent: hasProviderReasoningContent
                        ? providerReasoningContentBuffer.toString()
                        : null,
                    options: options,
                  );
            if (providerState != null) emittedProviderState = true;

            if (taggedChunk.content != null ||
                taggedChunk.reasoning != null ||
                structuredReasoning.visibleText != null ||
                usage != null ||
                finishReason != LLMFinishReason.unknown) {
              yield AgentResponse(
                message: Message(
                  role: MessageRole.assistant,
                  content: taggedChunk.content,
                  reasoning:
                      structuredReasoning.visibleText ?? taggedChunk.reasoning,
                  providerState: providerState,
                ),
                isToolCall: false,
                usage: usage,
                model: resolvedModel,
                provider: _providerForModel(resolvedModel),
                finishReason: finishReason,
              );
            }
          }
        }

        final pendingTagged = tagFallback.finish();
        if (pendingTagged.content != null || pendingTagged.reasoning != null) {
          if (pendingTagged.content != null) {
            contentBuffer.write(pendingTagged.content);
          }
          if (pendingTagged.reasoning != null) {
            reasoningBuffer.write(pendingTagged.reasoning);
          }
          yield AgentResponse(
            message: Message(
              role: MessageRole.assistant,
              content: pendingTagged.content,
              reasoning: pendingTagged.reasoning,
            ),
            model: resolvedModel,
            provider: _providerForModel(resolvedModel),
          );
        }

        for (final entry in partialToolCalls.entries) {
          final partial = entry.value;
          final decodedArguments = _tryDecodeToolArguments(
            partial.argumentsBuffer.toString(),
          );
          if (decodedArguments == null) {
            throw FormatException(
              'Malformed arguments for streamed tool ${partial.name ?? '<unknown>'}.',
            );
          }
          completedToolCalls.add(
            ToolCall(
              id: partial.id ?? '',
              name: partial.name ?? '',
              arguments: decodedArguments,
            ),
          );
        }

        if (completedToolCalls.isNotEmpty) {
          final providerState = _providerStateForReasoning(
            details: reasoningDetails,
            reasoningContent: hasProviderReasoningContent
                ? providerReasoningContentBuffer.toString()
                : null,
            options: options,
          );
          if (providerState != null) emittedProviderState = true;
          yield AgentResponse(
            message: Message(
              role: MessageRole.assistant,
              content: '',
              toolCalls: completedToolCalls,
              providerState: providerState,
            ),
            isToolCall: true,
            usage: null,
            model: resolvedModel,
            provider: _providerForModel(resolvedModel),
            finishReason: LLMFinishReason.toolCalls,
          );
        }

        if (!emittedProviderState &&
            (reasoningDetails.isNotEmpty || hasProviderReasoningContent)) {
          yield AgentResponse(
            message: Message(
              role: MessageRole.assistant,
              providerState: _providerStateForReasoning(
                details: reasoningDetails,
                reasoningContent: hasProviderReasoningContent
                    ? providerReasoningContentBuffer.toString()
                    : null,
                options: options,
              ),
            ),
            model: resolvedModel,
            provider: _providerForModel(resolvedModel),
          );
        }

        if (LLMRequestDumper.isEnabled) {
          final effectiveFinishReason = completedToolCalls.isNotEmpty
              ? LLMFinishReason.toolCalls
              : streamFinishReason;
          await LLMRequestDumper.dumpResponse({
            'status_code': response.statusCode,
            'message': {
              'role': 'assistant',
              'content': contentBuffer.toString(),
              if (reasoningBuffer.isNotEmpty)
                'reasoning': reasoningBuffer.toString(),
              if (completedToolCalls.isNotEmpty)
                'tool_calls': completedToolCalls
                    .map((tc) => tc.toJson())
                    .toList(),
            },
            'finish_reason': effectiveFinishReason.name,
            'usage': ?finalUsage,
          });
        }
      } catch (e) {
        if (LLMRequestDumper.isEnabled) {
          await LLMRequestDumper.dumpResponse({
            'status_code': response.statusCode,
            if (contentBuffer.isNotEmpty ||
                reasoningBuffer.isNotEmpty ||
                partialToolCalls.isNotEmpty ||
                completedToolCalls.isNotEmpty)
              'partial_message': {
                'role': 'assistant',
                if (contentBuffer.isNotEmpty)
                  'content': contentBuffer.toString(),
                if (reasoningBuffer.isNotEmpty)
                  'reasoning': reasoningBuffer.toString(),
                if (completedToolCalls.isNotEmpty)
                  'tool_calls': completedToolCalls
                      .map((tc) => tc.toJson())
                      .toList(),
                if (partialToolCalls.isNotEmpty)
                  'partial_tool_calls': partialToolCalls.values
                      .map(
                        (p) => {
                          if (p.id != null) 'id': p.id,
                          if (p.name != null) 'name': p.name,
                          'arguments': p.argumentsBuffer.toString(),
                        },
                      )
                      .toList(),
              },
            'error': e.toString(),
          });
        }
        rethrow;
      }
    } finally {
      await transport.dispose();
    }
  }

  static const _providerStateNamespace = 'openai_chat_completions';

  Future<Map<String, dynamic>> _buildRequestBody(
    List<Message> history, {
    required String resolvedModel,
    required LLMRequestOptions options,
    List<ToolSchema>? tools,
    bool stream = false,
  }) async {
    final hasImages = ToolResultWireCodec.hasImages(history);
    bool supportsImages = false;
    if (hasImages) {
      final instanceId = options.providerInstanceId ?? providerInstanceId;
      final overrideSnapshot =
          options.routeCapabilityProfile?.rawOverride ??
          options.routeCapabilitySnapshot;
      final profileSnapshot =
          options.routeCapabilityProfile ??
          (overrideSnapshot != null
              ? RouteCapabilityProfile(
                  providerInstanceId: instanceId ?? profile.name,
                  modelId: resolvedModel,
                  imageSupport: overrideSnapshot.supportsImageInput == true
                      ? RouteImageSupport.supported
                      : (overrideSnapshot.supportsImageInput == false
                            ? RouteImageSupport.unsupported
                            : RouteImageSupport.unknown),
                  evidenceSource: 'snapshot',
                  rawOverride: overrideSnapshot,
                )
              : RouteCapabilityResolver(
                  instances: getIt.isRegistered<ProviderInstanceRepository>()
                      ? getIt<ProviderInstanceRepository>()
                      : null,
                  config: config,
                  modelsDevService: modelsDevService,
                ).resolveSync(
                  providerInstanceId: instanceId ?? profile.name,
                  modelId: resolvedModel,
                  baseUrl: _baseUrl,
                ));

      if (profileSnapshot.imageSupport == RouteImageSupport.unsupported) {
        throw LocalImageCapabilityException(
          modelId: resolvedModel,
          imageSupport: RouteImageSupport.unsupported,
        );
      } else if (profileSnapshot.imageSupport == RouteImageSupport.unknown) {
        throw LocalImageCapabilityException(
          modelId: resolvedModel,
          imageSupport: RouteImageSupport.unknown,
        );
      }
      supportsImages = true;
    }
    final verifiedAttachments =
        await ToolResultWireCodec.loadVerifiedUserAttachments(
          history,
          attachmentStore: options.attachmentStore,
        );
    final body = <String, dynamic>{
      'model': resolvedModel,
      'messages': ToolResultWireCodec.chatMessages(
        history,
        messageToWire: (message) => _messageToWire(
          message,
          options,
          verifiedAttachments: verifiedAttachments,
        ),
        supportsImageInput: supportsImages,
      ),
      if (stream) 'stream': true,
      if (stream) 'stream_options': const {'include_usage': true},
      if (options.maxOutputTokens != null)
        'max_completion_tokens': options.maxOutputTokens,
    };

    final directive = options.thinkingDirective;
    if (directive != null && directive is! UseProviderDefault) {
      final routeInstance = _toRouteInstance(
        overrideInstanceId: options.providerInstanceId,
      );
      final effectivePolicyId = ThinkingRoutePolicy.policyIdFor(
        routeInstance,
        modelId: resolvedModel,
      );

      if (effectivePolicyId == 'aggregator_upstream') {
        AggregatorThinkingWireCodec.applyReasoning(body, directive);
      } else if (directive is GoogleBudgetDirective ||
          directive is GoogleLevelDirective ||
          effectivePolicyId == 'google_thinking') {
        GoogleThinkingWireCodec.applyThinkingConfig(body, directive);
      } else if (effectivePolicyId == 'deepseek_thinking') {
        DeepSeekThinkingWireCodec.applyChatCompletions(body, directive);
      } else if (effectivePolicyId == 'zai_thinking') {
        ZaiThinkingWireCodec.applyChatCompletions(body, directive);
      } else {
        ToggleEffortThinkingWireCodec.applyChatCompletions(body, directive);
      }
    }

    if (tools != null && tools.isNotEmpty) {
      body['tools'] = tools
          .map(
            (tool) => {
              'type': 'function',
              'function': {
                'name': tool.name,
                'description': tool.description,
                'parameters': tool.parameters,
              },
            },
          )
          .toList(growable: false);
    }
    return body;
  }

  ProviderInstance _toRouteInstance({String? overrideInstanceId}) {
    final effectiveId = overrideInstanceId ?? providerInstanceId;
    if (effectiveId != null &&
        getIt.isRegistered<ProviderInstanceRepository>()) {
      final found = getIt<ProviderInstanceRepository>().findById(effectiveId);
      if (found != null) return found;
    }
    return ProviderInstance(
      id: effectiveId ?? profile.name,
      templateId: profile.name,
      displayName: profile.displayName,
      protocol: profile.protocol ?? ProviderProtocol.openaiCompatible,
      authMethod: profile.authMethods.isNotEmpty
          ? profile.authMethods.first
          : ProviderAuthMethod.apiKey,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
  }

  Map<String, dynamic> _messageToWire(
    Message message,
    LLMRequestOptions options, {
    Map<String, String>? verifiedAttachments,
  }) {
    dynamic content = message.role == MessageRole.tool
        ? textOnlyToolResultContent(message)
        : message.content ?? '';
    if (message.role == MessageRole.user && message.attachments.isNotEmpty) {
      final parts = <Map<String, dynamic>>[];
      if (message.content != null && message.content!.isNotEmpty) {
        parts.add({'type': 'text', 'text': message.content!});
      }
      for (final att in message.attachments) {
        final b64 =
            verifiedAttachments?[att.id] ??
            ToolResultWireCodec.userAttachmentBase64(
              att,
              preloadedBase64: verifiedAttachments,
            );
        if (b64 != null) {
          parts.add({
            'type': 'image_url',
            'image_url': {'url': 'data:${att.mimeType};base64,$b64'},
          });
        }
      }
      if (parts.isNotEmpty) {
        content = parts;
      }
    }
    final data = <String, dynamic>{
      'role': _roleToString(message.role),
      'content': content,
    };
    if (message.toolCalls != null) {
      data['tool_calls'] = message.toolCalls!
          .map(
            (toolCall) => {
              'id': toolCall.id,
              'type': 'function',
              'function': {
                'name': toolCall.name,
                'arguments': jsonEncode(toolCall.arguments),
              },
            },
          )
          .toList(growable: false);
    }
    if (message.toolCallId != null) {
      data['tool_call_id'] = message.toolCallId;
    }

    final state = message.providerState;
    if (state?.namespace == _providerStateNamespace &&
        state?.issuer == _stateIssuer(options)) {
      final reasoningDetails = state!.data['reasoning_details'];
      if (reasoningDetails is List) {
        data['reasoning_details'] = reasoningDetails;
      }
      if (state.data.containsKey('reasoning_content')) {
        data['reasoning_content'] = state.data['reasoning_content'];
      }
    }
    return data;
  }

  Map<String, String> _requestHeaders(LLMRequestOptions options) =>
      withOpenCodeSessionAffinity(
        headers: {
          'Content-Type': 'application/json',
          if (_apiKey.isNotEmpty) 'Authorization': 'Bearer $_apiKey',
          ...profile.defaultHeaders,
        },
        providerName: profile.name,
        baseUrl: _baseUrl,
        sessionId: options.sessionId,
      );

  String _stateIssuer(LLMRequestOptions options) {
    final instance = options.providerInstanceId ?? profile.name;
    final endpoint = _baseUrl.replaceFirst(RegExp(r'/+$'), '');
    return '$instance|${profile.effectiveProtocol}|$endpoint';
  }

  LLMProviderState? _providerStateForReasoning({
    required List<dynamic> details,
    required dynamic reasoningContent,
    required LLMRequestOptions options,
  }) {
    final data = <String, dynamic>{
      if (details.isNotEmpty) 'reasoning_details': details,
      'reasoning_content': ?reasoningContent,
    };
    if (data.isEmpty) return null;
    return LLMProviderState(
      namespace: _providerStateNamespace,
      issuer: _stateIssuer(options),
      data: data,
    );
  }

  _StructuredReasoning _extractStructuredReasoning(
    Map<String, dynamic> payload,
  ) {
    final details = <dynamic>[];
    final visible = <String>[];

    void collectVisible(dynamic value) {
      if (value is String) {
        if (value.trim().isNotEmpty) visible.add(value);
        return;
      }
      if (value is List) {
        for (final item in value) {
          collectVisible(item);
        }
        return;
      }
      final map = _asStringMap(value);
      if (map == null) return;
      for (final key in const ['text', 'content', 'summary']) {
        if (map.containsKey(key)) collectVisible(map[key]);
      }
    }

    final rawDetails = payload['reasoning_details'];
    if (rawDetails is List) {
      details.addAll(rawDetails);
    } else if (rawDetails != null) {
      details.add(rawDetails);
    }

    final reasoningContent = payload['reasoning_content'];
    final reasoning = payload['reasoning'];
    if (reasoningContent != null) {
      collectVisible(reasoningContent);
    } else if (reasoning != null) {
      collectVisible(reasoning);
    } else if (rawDetails != null) {
      collectVisible(rawDetails);
    }

    return _StructuredReasoning(
      visibleText: visible.isEmpty ? null : visible.join(),
      details: details,
      providerContent: reasoningContent,
    );
  }

  List<ToolCall> _parseToolCalls(dynamic rawToolCalls) {
    if (rawToolCalls is! List) return const [];
    return rawToolCalls
        .map((rawToolCall) {
          final toolCall = _asStringMap(rawToolCall);
          final function = _asStringMap(toolCall?['function']);
          if (toolCall == null || function == null) {
            throw const FormatException('Malformed chat completion tool call.');
          }
          final rawArguments = function['arguments']?.toString() ?? '';
          final arguments = _tryDecodeToolArguments(rawArguments);
          if (arguments == null) {
            throw FormatException(
              'Malformed arguments for tool ${function['name'] ?? '<unknown>'}.',
            );
          }
          return ToolCall(
            id: toolCall['id']?.toString() ?? '',
            name: function['name']?.toString() ?? '',
            arguments: arguments,
          );
        })
        .toList(growable: false);
  }

  LLMFinishReason _normalizeFinishReason(
    dynamic rawFinishReason, {
    required bool hasToolCalls,
  }) {
    switch (rawFinishReason?.toString()) {
      case 'stop':
        return LLMFinishReason.stop;
      case 'tool_calls':
      case 'function_call':
        return LLMFinishReason.toolCalls;
      case 'length':
      case 'max_tokens':
        return LLMFinishReason.length;
      case 'incomplete':
        return LLMFinishReason.incomplete;
      case 'content_filter':
      case 'error':
        return LLMFinishReason.failed;
      case 'cancelled':
      case 'canceled':
        return LLMFinishReason.cancelled;
      default:
        return hasToolCalls
            ? LLMFinishReason.toolCalls
            : LLMFinishReason.unknown;
    }
  }

  Future<T> _withTimeout<T>(Future<T> future, Duration? timeout) =>
      timeout == null ? future : future.timeout(timeout);

  Future<http.Response> _get(
    Uri url, {
    Map<String, String>? headers,
    Duration? timeout,
  }) async {
    final httpClient = client ?? http.Client();
    try {
      return await _withTimeout(httpClient.get(url, headers: headers), timeout);
    } finally {
      if (client == null) httpClient.close();
    }
  }

  Map<String, dynamic>? _asStringMap(dynamic value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) {
      return value.map((key, item) => MapEntry(key.toString(), item));
    }
    return null;
  }

  String _roleToString(MessageRole role) {
    switch (role) {
      case MessageRole.system:
        return 'system';
      case MessageRole.user:
        return 'user';
      case MessageRole.assistant:
        return 'assistant';
      case MessageRole.tool:
        return 'tool';
    }
  }

  String _providerForModel(String modelName) {
    final normalized = modelName.startsWith('openai/')
        ? modelName.substring('openai/'.length)
        : modelName;

    if (normalized.contains('/')) {
      return normalized.split('/').first;
    }
    return profile.name;
  }

  Map<String, dynamic>? _tryDecodeToolArguments(String rawArguments) {
    if (rawArguments.trim().isEmpty) {
      return {};
    }

    try {
      final decoded = jsonDecode(rawArguments);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      if (decoded is Map) {
        return decoded.map((key, value) => MapEntry(key.toString(), value));
      }
    } catch (_) {
      return null;
    }
    return null;
  }
}

class _PartialToolCall {
  String? id;
  String? name;
  final StringBuffer argumentsBuffer = StringBuffer();

  void append({String? id, String? name, String? argumentsChunk}) {
    if (id != null && id.isNotEmpty) {
      this.id = id;
    }
    if (name != null && name.isNotEmpty) {
      this.name = name;
    }
    if (argumentsChunk != null && argumentsChunk.isNotEmpty) {
      argumentsBuffer.write(argumentsChunk);
    }
  }
}

class _StructuredReasoning {
  final String? visibleText;
  final List<dynamic> details;
  final dynamic providerContent;

  const _StructuredReasoning({
    this.visibleText,
    this.details = const [],
    this.providerContent,
  });
}
