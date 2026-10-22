import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:dotenv/dotenv.dart';
import 'package:yaml/yaml.dart';
import '../engine/adapters/provider_profile.dart';
import '../engine/adapters/provider_registry.dart';
import 'constants.dart';
import 'provider_thinking/thinking_control_models.dart';
import 'provider_thinking/thinking_wire_vocabulary.dart';

class Config {
  static const String _defaultGatewayUrl = 'https://api.sanad.eaststarai.com';
  static const String _defaultLlmBaseUrl = 'https://api.openai.com/v1';
  static const int _defaultLocalGatewayPort = 58085;
  static const String _defaultPortalUrl = 'https://portal.sanad.eaststarai.com';

  DotEnv _env;
  final Map<String, String> _environment;
  late ModelAwareRuntimePolicy _modelAwarePolicy;

  /// Paths of the env files actually loaded, in load order. Tracked so that
  /// [_ensureFreshEnv] can re-stat them and reload when any changes on disk.
  List<String> _envPaths = const [];

  /// Cached on-disk signature of the loaded env files: the maximum modified
  /// timestamp and the sum of sizes across all loaded files. When either
  /// differs from a fresh stat, the env is reloaded.
  DateTime? _envMtime;
  int _envSize = 0;

  Config({
    Map<String, String>? environment,
    ModelAwareRuntimePolicy? modelAwarePolicy,
  }) : _environment = environment ?? Platform.environment,
       _env = DotEnv() {
    _loadEnvFiles();
    _modelAwarePolicy =
        modelAwarePolicy ??
        ModelAwareRuntimePolicy.load(File('${getSanadHome()}/config.yaml'));
  }

  /// Loads (or reloads) the env files from the path resolved by [getEnvPath]
  /// and records the on-disk signature used by [_ensureFreshEnv].
  void _loadEnvFiles() {
    _env = DotEnv();
    final paths = <String>[];

    final envPath = getEnvPath();
    if (File(envPath).existsSync()) {
      paths.add(envPath);
    }

    if (paths.isNotEmpty) {
      _env.load(paths);
    }
    _envPaths = List<String>.unmodifiable(paths);
    _refreshEnvSignature();
  }

  /// Recomputes the on-disk signature of [_envPaths] and stores it.
  void _refreshEnvSignature() {
    DateTime? maxMtime;
    var totalSize = 0;
    for (final path in _envPaths) {
      try {
        final stat = File(path).statSync();
        totalSize += stat.size;
        final modified = stat.modified;
        if (maxMtime == null || modified.isAfter(maxMtime)) {
          maxMtime = modified;
        }
      } catch (_) {
        // File vanished or unreadable: force a reload on next check by
        // nulling the signature.
        _envMtime = null;
        _envSize = -1;
        return;
      }
    }
    _envMtime = maxMtime;
    _envSize = totalSize;
  }

  /// Cheap hot-path check that reloads the env files from disk only when their
  /// combined (max mtime, total size) signature has changed since the last
  /// load. Called by the main getters so that edits to `.env` are picked up
  /// without a restart and without a manual [reload] call.
  void _ensureFreshEnv() {
    DateTime? maxMtime;
    var totalSize = 0;
    for (final path in _envPaths) {
      try {
        final stat = File(path).statSync();
        totalSize += stat.size;
        final modified = stat.modified;
        if (maxMtime == null || modified.isAfter(maxMtime)) {
          maxMtime = modified;
        }
      } catch (_) {
        // A previously-loaded file is now gone/unreadable; reload to reflect.
        _loadEnvFiles();
        return;
      }
    }
    if (maxMtime != _envMtime || totalSize != _envSize) {
      _loadEnvFiles();
    }
  }

  /// Forces a reload of the env files from disk. Intended for tests and the
  /// `sanad setup` wizard; normal callers should rely on [_ensureFreshEnv].
  void reload() {
    _loadEnvFiles();
  }

  /// Resolves the API key for a specific [profile] (by its `envApiKeyName`),
  /// falling back to the generic `LLM_API_KEY`. Unlike [llmApiKey], this does
  /// NOT depend on the active provider — it reads the key for the given
  /// profile, enabling per-message routing to a non-active provider.
  String apiKeyFor(ProviderProfile profile) {
    _ensureFreshEnv();
    if (profile.envApiKeyName != null) {
      final specKey = _readString(profile.envApiKeyName!);
      if (specKey.trim().isNotEmpty) {
        return specKey;
      }
    }
    return _readString('LLM_API_KEY');
  }

  /// Resolves the base URL for a specific [profile], falling back to the
  /// generic `LLM_BASE_URL` and then the profile's default. Unlike
  /// [llmBaseUrl], this does NOT depend on the active provider.
  String baseUrlFor(ProviderProfile profile) {
    _ensureFreshEnv();
    if (profile.envBaseUrlName != null) {
      final specBaseUrl = _readString(profile.envBaseUrlName!);
      if (specBaseUrl.trim().isNotEmpty) {
        return specBaseUrl;
      }
    }
    final envBaseUrl = _readString('LLM_BASE_URL');
    if (envBaseUrl.trim().isNotEmpty) {
      return envBaseUrl;
    }
    if (profile.defaultBaseUrl != null) {
      return profile.defaultBaseUrl!;
    }
    return _defaultLlmBaseUrl;
  }

  String get activeProvider {
    _ensureFreshEnv();
    return _readString('ACTIVE_PROVIDER').trim().toLowerCase();
  }

  String get scheduleTimezone {
    _ensureFreshEnv();
    final tz = _readString('SCHEDULE_TIMEZONE').trim();
    return tz.isEmpty ? 'local' : tz;
  }

  String get version => loadAgentVersion();

  String get llmApiKey {
    _ensureFreshEnv();
    final provider = resolveProviderName();
    final profile = ProviderRegistry.findByNameOrAlias(provider);
    if (profile != null && profile.envApiKeyName != null) {
      final specKey = _readString(profile.envApiKeyName!);
      if (specKey.trim().isNotEmpty) {
        return specKey;
      }
    }
    return _readString('LLM_API_KEY');
  }

  String get llmBaseUrl {
    _ensureFreshEnv();
    final provider = resolveProviderName();
    final profile = ProviderRegistry.findByNameOrAlias(provider);
    if (profile != null && profile.envBaseUrlName != null) {
      final specBaseUrl = _readString(profile.envBaseUrlName!);
      if (specBaseUrl.trim().isNotEmpty) {
        return specBaseUrl;
      }
    }
    final envBaseUrl = _readString('LLM_BASE_URL');
    if (envBaseUrl.trim().isNotEmpty) {
      return envBaseUrl;
    }
    if (profile != null && profile.defaultBaseUrl != null) {
      return profile.defaultBaseUrl!;
    }
    return _defaultLlmBaseUrl;
  }

  String get llmModel {
    _ensureFreshEnv();
    final provider = resolveProviderName();
    final profile = ProviderRegistry.findByNameOrAlias(provider);
    if (profile != null && profile.envModelName != null) {
      final specModel = _readString(profile.envModelName!);
      if (specModel.trim().isNotEmpty) {
        return specModel;
      }
    }
    final genericModel = _readString('LLM_MODEL');
    if (genericModel.trim().isNotEmpty) {
      return genericModel;
    }
    if (profile != null && profile.fallbackModels.isNotEmpty) {
      return profile.fallbackModels.first;
    }
    return 'gpt-3.5-turbo';
  }

  String resolveProviderName() {
    _ensureFreshEnv();
    final prov = activeProvider;
    if (prov.isNotEmpty) {
      return prov;
    }
    // Auto-detect based on LLM_BASE_URL
    final rawBaseUrl = _readString('LLM_BASE_URL').toLowerCase();
    final rawModel = _readString(
      'LLM_MODEL',
      defaultValue: 'gpt-3.5-turbo',
    ).toLowerCase();
    if (rawBaseUrl.contains('chatgpt.com') ||
        rawBaseUrl.contains('openai-codex')) {
      return 'openai-codex';
    } else if (rawBaseUrl.contains('x.com') ||
        rawBaseUrl.contains('grok-subscription') ||
        rawBaseUrl.contains('xai-oauth')) {
      return 'xai-oauth';
    } else if (rawBaseUrl.contains('anthropic') ||
        rawModel.startsWith('claude')) {
      return 'anthropic';
    } else if (rawBaseUrl.contains('openrouter')) {
      return 'openrouter';
    } else if (rawBaseUrl.contains('googleapis.com') ||
        rawModel.startsWith('gemini')) {
      return 'gemini';
    } else if (rawBaseUrl.contains('deepseek')) {
      return 'deepseek';
    } else if (rawBaseUrl.contains('x.ai') || rawBaseUrl.contains('grok')) {
      return 'xai';
    } else if (rawBaseUrl.contains('11434') || rawBaseUrl.contains('ollama')) {
      return 'ollama';
    } else if (rawBaseUrl.contains('nvidia')) {
      return 'nvidia';
    }
    return 'openai';
  }

  String get webSearchProvider {
    _ensureFreshEnv();
    return _readString(
      'WEB_SEARCH_PROVIDER',
      defaultValue: 'ddg',
    ).trim().toLowerCase();
  }

  String get serperApiKey {
    _ensureFreshEnv();
    return _readString('SERPER_API_KEY', defaultValue: '').trim();
  }

  String get gatewayUrl =>
      _readString('GATEWAY_URL', defaultValue: _defaultGatewayUrl);

  /// Plan 23: ``sanad-portal`` is the only public auth surface for the
  /// open-source CLI/daemon. All authentication (start / status / refresh /
  /// logout) goes through this URL. The CLI must not call backend auth paths.
  String get portalUrl =>
      _readString('PORTAL_URL', defaultValue: _defaultPortalUrl);

  int? contextModelLimit(String modelId) =>
      _modelAwarePolicy.contextModelLimits[_normalizeModelId(modelId)];

  /// Bound for one compaction provider pass to return its whole response.
  Duration get compactionPassTimeout =>
      _modelAwarePolicy.compaction.passTimeout;

  CompactionPolicy compactionPolicyForModel(String modelId) =>
      _modelAwarePolicy.compaction.forModel(_normalizeModelId(modelId));

  ModelAwareRuntimePolicy get modelAwarePolicy => _modelAwarePolicy;

  ModelAwareRuntimePolicy reloadModelAwarePolicy() {
    final candidate = ModelAwareRuntimePolicy.load(
      File('${getSanadHome()}/config.yaml'),
    );
    _modelAwarePolicy = candidate;
    return _modelAwarePolicy;
  }

  static String _normalizeModelId(String modelId) =>
      modelId.trim().toLowerCase();

  bool get enableGateway {
    _ensureFreshEnv();
    return _readBool('ENABLE_GATEWAY', defaultValue: true);
  }

  bool get computerUse {
    _ensureFreshEnv();
    return _readBool('COMPUTER_USE', defaultValue: false);
  }

  /// Plan 30 §8.1: when true, the runtime may automatically switch a session
  /// to a qualified provider instance when the current one fails
  /// (rate limit / billing / quota). Defaults to true; individual instances
  /// still opt out via `allow_auto_failover=false`.
  bool get providerAutoFailover {
    _ensureFreshEnv();
    return _readBool('PROVIDER_AUTO_FAILOVER', defaultValue: true);
  }

  /// Whether [key] is supplied by the daemon process environment. Persisted
  /// file mutations cannot override such values and must be presented as
  /// externally managed to protocol clients.
  bool isProcessManaged(String key) =>
      _environment[key]?.trim().isNotEmpty ?? false;

  bool get enableLocalGateway =>
      _readBool('ENABLE_LOCAL_GATEWAY', defaultValue: true);

  int get localGatewayPort =>
      _readInt('LOCAL_GATEWAY_PORT', defaultValue: _defaultLocalGatewayPort);

  String get logLevel => _readString('LOG_LEVEL', defaultValue: 'INFO');

  bool get dumpRequests => _readBool('DUMP_REQUESTS', defaultValue: false);

  bool get dumpRequestsStdout =>
      _readBool('DUMP_REQUESTS_STDOUT', defaultValue: false);

  bool get logColor => _readBool('LOG_COLOR', defaultValue: true);

  int get logMaxLength => _readInt('LOG_MAX_LENGTH', defaultValue: 500);

  String get localGatewayHost =>
      _readString('LOCAL_GATEWAY_HOST', defaultValue: '127.0.0.1').trim();

  String get localGatewayUrl {
    final host = localGatewayHost;
    final authority = host.contains(':') ? '[$host]' : host;
    return 'http://$authority:$localGatewayPort';
  }

  bool get hasConfiguredLlmBaseUrl =>
      _readString('LLM_BASE_URL').trim().isNotEmpty;

  bool get usesLikelyLocalLlm {
    final uri = Uri.tryParse(llmBaseUrl);
    final host = uri?.host.toLowerCase() ?? '';
    return host == '127.0.0.1' ||
        host == 'localhost' ||
        host == '0.0.0.0' ||
        llmBaseUrl.contains('11434') ||
        llmBaseUrl.toLowerCase().contains('ollama');
  }

  bool get isValid {
    if (llmModel.trim().isEmpty) {
      return false;
    }

    if (llmApiKey.trim().isNotEmpty) {
      return true;
    }

    if (usesLikelyLocalLlm) {
      return true;
    }

    if (hasConfiguredLlmBaseUrl && llmBaseUrl != _defaultLlmBaseUrl) {
      return true;
    }

    return false;
  }

  String _readString(String key, {String defaultValue = ''}) {
    final processValue = _environment[key];
    if (processValue != null && processValue.trim().isNotEmpty) {
      return processValue;
    }

    final value = _env[key];
    if (value != null && value.trim().isNotEmpty) {
      return value;
    }

    return defaultValue;
  }

  String getEnvVar(String key, {String defaultValue = ''}) {
    return _readString(key, defaultValue: defaultValue);
  }

  int _readInt(String key, {required int defaultValue}) {
    final rawValue = _readString(key);
    return int.tryParse(rawValue) ?? defaultValue;
  }

  bool _readBool(String key, {required bool defaultValue}) {
    final rawValue = _readString(key, defaultValue: defaultValue.toString());
    return rawValue.toLowerCase() == 'true';
  }
}

class CompactionPolicy {
  final double threshold;
  final double targetRatio;

  const CompactionPolicy({required this.threshold, required this.targetRatio});
}

class ModelAwareCompactionPolicy extends CompactionPolicy {
  /// Default bound for one compaction provider pass (summary, repair, chunk
  /// or reduce) to return its complete response (Task 118). Non-streamed
  /// passes cannot report progress, so the normal-turn `connectTimeout`
  /// (90 s) cut slow models whose ~50k-input recovery passes took 60-71 s.
  /// A near-window main pass is several times larger, so the default leaves
  /// room for a full-window pass at that observed throughput while staying
  /// bounded. `config.yaml` `compaction.passTimeoutSeconds` overrides it.
  static const defaultPassTimeout = Duration(seconds: 600);

  final Map<String, CompactionPolicy> models;

  /// Bound for one compaction provider pass to return its whole response.
  final Duration passTimeout;

  const ModelAwareCompactionPolicy({
    required super.threshold,
    required super.targetRatio,
    required this.models,
    this.passTimeout = defaultPassTimeout,
  });

  CompactionPolicy forModel(String normalizedModelId) {
    final override = models[normalizedModelId];
    return override ??
        CompactionPolicy(threshold: threshold, targetRatio: targetRatio);
  }
}

/// Complete post-compaction request target (Task 118 Stage3A).
///
/// The target covers the whole next request (system/runtime instructions,
/// tools, summary, retained tail, media and replay) and is a ratio of the
/// full resolved window `W`, never of the internal usable input budget.
abstract final class CompactionTargetPolicy {
  /// Planning reservation for the summary while the retained tail is chosen,
  /// before the summary exists: the summary instruction asks for about two
  /// pages. A previous summary's measured size replaces it when one exists.
  /// It never enters a reported measurement: the target outcome is decided on
  /// the measured request after the summary is generated.
  static const int summaryReservationTokens = 2048;

  /// The complete-request target for a resolved window `W`.
  static int targetRequestTokens({
    required int windowTokens,
    required double ratio,
  }) => windowTokens <= 0 ? 0 : (windowTokens * ratio).floor();
}

/// Limits of the bounded recovery summarizer that runs when the ordinary
/// provider-backed compaction request overflows (Task 117, 0P-F2).
class CompactionRecoveryPolicy {
  static const defaults = CompactionRecoveryPolicy(
    passBudgetSafetyRatio: 0.80,
    maxChunks: 16,
    minPassBudgetTokens: 512,
    fallbackOutputReservationTokens: 16_384,
  );

  /// Fraction of the effective input budget one recovery pass may use. Kept
  /// below 1 because the estimate is not an exact tokenizer: since Task 118b
  /// non-ASCII text is priced by its encoding, so the margin now covers
  /// tokenizer variance on code, JSON and tool output rather than Arabic and
  /// CJK undercounting.
  final double passBudgetSafetyRatio;

  /// Maximum number of source chunks one recovery may summarize. A source
  /// that needs more fails before any recovery provider call.
  final int maxChunks;

  /// Smallest usable per-pass source budget after the stable system prompt,
  /// tool schemas, and instruction are reserved.
  final int minPassBudgetTokens;

  /// Output reservation assumed for the pre-send fit check of the full
  /// summary pass when no route capability (settings, provider metadata,
  /// models.dev) declares the model's maximum output (Task 118b). It is the
  /// default completion reservation a provider applied when the request set
  /// no output limit (live: 16384). Planning only: compaction never sends an
  /// output cap of its own.
  final int fallbackOutputReservationTokens;

  const CompactionRecoveryPolicy({
    required this.passBudgetSafetyRatio,
    required this.maxChunks,
    required this.minPassBudgetTokens,
    this.fallbackOutputReservationTokens = 16_384,
  });
}

class ThinkingControlOverride {
  final ThinkingCapabilityStatus status;
  final String? wire;
  final Map<String, dynamic> options;
  final String? defaultOption;

  const ThinkingControlOverride({
    required this.status,
    this.wire,
    this.options = const {},
    this.defaultOption,
  });

  String get fingerprint {
    if (status != ThinkingCapabilityStatus.supported) {
      return status.name;
    }
    final sortedKeys = options.keys.toList()..sort();
    final canonicalOptions = <String, dynamic>{
      for (final k in sortedKeys) k: options[k],
    };
    final canonicalPayload = jsonEncode({
      'status': status.name,
      'wire': wire,
      'default_option': defaultOption,
      'options': canonicalOptions,
    });
    return sha256.convert(utf8.encode(canonicalPayload)).toString();
  }

  static ThinkingControlOverride? tryParse(Object? raw) {
    if (raw == null) return null;
    if (raw is ThinkingControlOverride) return raw;
    if (raw is! Map) return null;
    try {
      final map = Map<String, dynamic>.from(
        raw.map((key, value) => MapEntry(key.toString(), value)),
      );
      return parse(map);
    } catch (_) {
      return null;
    }
  }

  static ThinkingControlOverride parse(
    Map<String, dynamic> tcMap, {
    String context = 'thinking_control',
  }) {
    ModelAwareRuntimePolicy._rejectUnknown(tcMap, const {
      'status',
      'wire',
      'options',
      'default_option',
      'default_option_id',
    }, context);

    final rawStatus = tcMap['status'];
    if (rawStatus is! String) {
      throw FormatException('$context.status is required and must be a string');
    }
    final status = ThinkingCapabilityStatus.tryParse(rawStatus.trim());
    if (status == null) {
      throw FormatException(
        'Invalid thinking_control status: $rawStatus (expected supported, unsupported, or unknown)',
      );
    }

    if (status != ThinkingCapabilityStatus.supported) {
      if (tcMap.containsKey('wire')) {
        throw FormatException(
          'thinking_control with status "${status.name}" cannot declare wire',
        );
      }
      if (tcMap.containsKey('options')) {
        final opts = tcMap['options'];
        if (opts is Map && opts.isNotEmpty) {
          throw FormatException(
            'thinking_control with status "${status.name}" cannot declare options',
          );
        }
      }
      return ThinkingControlOverride(status: status);
    }

    final wire = tcMap['wire'];
    if (wire is! String || wire.trim().isEmpty) {
      throw FormatException(
        '$context.wire is required when status is supported',
      );
    }
    const knownWires = {
      'openai_chat_effort',
      'codex_responses_effort',
      'anthropic_adaptive',
      'anthropic_budget',
      'toggle_effort',
      'google_thinking',
      'nim_kimi_thinking',
      'nim_qwen_thinking',
      'native_toggle_effort',
    };
    if (!knownWires.contains(wire.trim())) {
      throw FormatException('Unknown wire policy: $wire');
    }

    final rawOptions = tcMap['options'];
    if (rawOptions is! Map || rawOptions.isEmpty) {
      throw FormatException(
        '$context.options must be a non-empty map when status is supported',
      );
    }
    final options = <String, dynamic>{};
    for (final optEntry in rawOptions.entries) {
      if (optEntry.key is! String) {
        throw FormatException('thinking_control option keys must be strings');
      }
      final optKey = (optEntry.key as String).trim();
      if (optKey.isEmpty) {
        throw FormatException('thinking_control option key cannot be empty');
      }
      final optVal = optEntry.value;
      if (wire == 'anthropic_budget') {
        final optKeyLower = optKey.toLowerCase();
        // The documented Messages disable is `thinking: {type: disabled}`,
        // declared as an exact Boolean `false` on an off/none key. A numeric
        // value can never disable thinking.
        if ((optKeyLower == 'off' || optKeyLower == 'none') && optVal == false) {
          options[optKey] = false;
          continue;
        }
        if (optKeyLower == 'off' || optKeyLower == 'none') {
          throw FormatException(
            'anthropic_budget wire does not support disabling thinking (off/none option prohibited).',
          );
        }
        if (optVal is! num ||
            optVal.toInt() < 1024 ||
            optVal != optVal.toInt()) {
          throw FormatException(
            'anthropic_budget option "$optKey" value must be an integer of at least 1024',
          );
        }
        options[optKey] = optVal.toInt();
      } else if (wire == 'native_toggle_effort') {
        // A native Chat envelope: `thinking: {type: enabled|disabled}` for the
        // Boolean toggle, plus `reasoning_effort` with thinking enabled for an
        // effort. Off/on carry exact Booleans; an effort id carries its own
        // canonical effort value (never a Boolean and never a remap).
        final optKeyLower = optKey.toLowerCase();
        if (optVal is bool) {
          if ((optKeyLower == 'off' || optKeyLower == 'none') && optVal) {
            throw FormatException(
              'Option "$optKey" cannot map to active toggle value "$optVal". Off/none must disable thinking.',
            );
          }
          if (optKeyLower == 'on' && !optVal) {
            throw FormatException(
              'Option "$optKey" cannot map to disabled toggle value "$optVal".',
            );
          }
          if (ThinkingWireVocabulary.isAdmittedEffortTier(optKeyLower)) {
            throw FormatException(
              'Option "$optKey" cannot map to Boolean "$optVal": a canonical '
              'effort id must carry its own canonical effort value.',
            );
          }
          options[optKey] = optVal;
          continue;
        }
        if (optVal is! String ||
            !ThinkingWireVocabulary.effortTierIds.contains(
              optVal.trim().toLowerCase(),
            )) {
          throw FormatException(
            'native_toggle_effort option "$optKey" value "$optVal" must be a boolean or a positive effort (allowed: ${ThinkingWireVocabulary.effortTierIds.join(', ')})',
          );
        }
        final trimmedVal = optVal.trim().toLowerCase();
        if (optKeyLower == 'off' || optKeyLower == 'none' || optKeyLower == 'on') {
          throw FormatException(
            'Option "$optKey" cannot map to effort "$optVal"; toggle ids carry Booleans.',
          );
        }
        if (!ThinkingWireVocabulary.canonicalEffortMatches(
          optionId: optKey,
          value: trimmedVal,
        )) {
          throw FormatException(
            'Option "$optKey" cannot map to effort "$optVal": a canonical '
            'effort id must carry its own canonical value.',
          );
        }
        options[optKey] = trimmedVal;
      } else if (wire == 'toggle_effort') {
        final optKeyLower = optKey.toLowerCase();
        final bool isEnabled;
        if (optVal is bool) {
          isEnabled = optVal;
        } else if (optVal is String) {
          final strLower = optVal.trim().toLowerCase();
          if (strLower == 'true' || strLower == 'on') {
            isEnabled = true;
          } else if (strLower == 'false' || strLower == 'off') {
            isEnabled = false;
          } else {
            throw FormatException(
              'toggle_effort option "$optKey" value "$optVal" must be a boolean or on/off',
            );
          }
        } else {
          throw FormatException(
            'toggle_effort option "$optKey" value must be a boolean or on/off',
          );
        }
        if ((optKeyLower == 'off' || optKeyLower == 'none') && isEnabled) {
          throw FormatException(
            'Option "$optKey" cannot map to active toggle value "$optVal". Off/none must disable thinking.',
          );
        }
        if (optKeyLower == 'on' && !isEnabled) {
          throw FormatException(
            'Option "$optKey" cannot map to disabled toggle value "$optVal".',
          );
        }
        if (ThinkingWireVocabulary.isAdmittedEffortTier(optKeyLower)) {
          throw FormatException(
            'Option "$optKey" cannot map to Boolean "$optVal": a canonical '
            'effort id must carry its own canonical effort value, not a '
            'Boolean toggle.',
          );
        }
        options[optKey] = isEnabled;
      } else if (wire == 'nim_kimi_thinking' || wire == 'nim_qwen_thinking') {
        // NVIDIA NIM documents thinking as a finite chat_template_kwargs
        // Boolean; the self-hosted Qwen container documents the Boolean disable
        // plus an effort ladder. Boolean fields stay genuine validated Booleans
        // and a key named after a disable or an effort tier must not lie.
        final optKeyLower = optKey.toLowerCase();
        final bool? toggleValue;
        if (optVal is bool) {
          toggleValue = optVal;
        } else if (optVal is String) {
          final strLower = optVal.trim().toLowerCase();
          if (strLower == 'true' || strLower == 'on') {
            toggleValue = true;
          } else if (strLower == 'false' || strLower == 'off') {
            toggleValue = false;
          } else {
            toggleValue = null;
          }
        } else {
          toggleValue = null;
        }

        if (toggleValue == null) {
          // Effort values are only admissible on the Qwen wire, and only as an
          // exact canonical value on a key named after that same value.
          final isEffortValue =
              wire == 'nim_qwen_thinking' &&
              optVal is String &&
              ThinkingWireVocabulary.nimQwenEffortIds.contains(
                optVal.trim().toLowerCase(),
              );
          if (!isEffortValue) {
            throw FormatException(
              '$wire option "$optKey" value "$optVal" must be a boolean/on/off'
              '${wire == 'nim_qwen_thinking' ? ' or one of ${ThinkingWireVocabulary.nimQwenEffortIds.join(', ')}' : ''}',
            );
          }
          if (optKeyLower != optVal.trim().toLowerCase()) {
            throw FormatException(
              'Option "$optKey" cannot map to effort "$optVal": the option id '
              'must name the canonical effort value it sends.',
            );
          }
          if (optKeyLower == 'off' ||
              optKeyLower == 'none' ||
              optKeyLower == 'on') {
            throw FormatException(
              'Option "$optKey" cannot map to active effort "$optVal".',
            );
          }
          options[optKey] = optVal.trim().toLowerCase();
          continue;
        }

        if ((optKeyLower == 'off' || optKeyLower == 'none') && toggleValue) {
          throw FormatException(
            'Option "$optKey" cannot map to active toggle value "$optVal". '
            'Off/none must disable thinking.',
          );
        }
        if (optKeyLower == 'on' && !toggleValue) {
          throw FormatException(
            'Option "$optKey" cannot map to disabled toggle value "$optVal".',
          );
        }
        // A canonical effort-tier id must not lie in either direction: it may
        // neither hide a disable (false) nor advertise an effort while
        // dispatching an unspecified enabled/default Boolean (true).
        if (ThinkingWireVocabulary.isAdmittedEffortTier(optKeyLower)) {
          throw FormatException(
            'Option "$optKey" cannot map to Boolean "$optVal": a canonical '
            'effort id must carry its own canonical effort value, not a '
            'Boolean toggle.',
          );
        }
        options[optKey] = toggleValue;
      } else if (wire == 'openai_chat_effort' ||
          wire == 'codex_responses_effort') {
        // The documented effort vocabulary is centralized so declarations and
        // the typed serializers admit exactly the same finite values; canonical
        // `minimal` and `max` are part of it.
        const allowedEfforts = ThinkingWireVocabulary.effortIds;
        if (optVal is! String ||
            !allowedEfforts.contains(optVal.trim().toLowerCase())) {
          throw FormatException(
            '$wire option "$optKey" value "$optVal" is not a valid effort (allowed: ${allowedEfforts.join(', ')})',
          );
        }
        final trimmedVal = optVal.trim().toLowerCase();
        final optKeyLower = optKey.toLowerCase();
        if ((optKeyLower == 'off' || optKeyLower == 'none') &&
            trimmedVal != 'none') {
          throw FormatException(
            'Option "$optKey" cannot map to active effort "$optVal". Off/none must disable thinking.',
          );
        }
        if (trimmedVal == 'none' &&
            optKeyLower != 'off' &&
            optKeyLower != 'none') {
          throw FormatException(
            'Option "$optKey" cannot map to disabling effort "$optVal" unless named off/none.',
          );
        }
        // Shared no-remap invariant: any canonical effort id must carry its own
        // canonical value, not just `low`.
        if (!ThinkingWireVocabulary.canonicalEffortMatches(
          optionId: optKey,
          value: trimmedVal,
        )) {
          throw FormatException(
            'Option "$optKey" cannot map to effort "$optVal": a canonical '
            'effort id must carry its own canonical value.',
          );
        }
        options[optKey] = trimmedVal;
      } else if (wire == 'anthropic_adaptive') {
        final optKeyLower = optKey.toLowerCase();
        final String trimmedVal;
        if (optVal is bool) {
          if (optVal == false) {
            trimmedVal = 'off';
          } else {
            throw FormatException(
              'anthropic_adaptive option "$optKey" cannot be boolean true; specify effort tier (low, medium, high, max)',
            );
          }
        } else if (optVal is String) {
          trimmedVal = optVal.trim().toLowerCase();
        } else {
          throw FormatException(
            'anthropic_adaptive option "$optKey" value must be an effort string or false',
          );
        }
        const allowedAdaptive = {'none', 'off', 'low', 'medium', 'high', 'max'};
        if (!allowedAdaptive.contains(trimmedVal)) {
          throw FormatException(
            'anthropic_adaptive option "$optKey" value "$optVal" is not a valid effort (allowed: ${allowedAdaptive.join(', ')})',
          );
        }
        final isDisable = trimmedVal == 'none' || trimmedVal == 'off';
        if ((optKeyLower == 'off' || optKeyLower == 'none') && !isDisable) {
          throw FormatException(
            'Option "$optKey" cannot map to active effort "$optVal". Off/none must disable thinking.',
          );
        }
        if (isDisable && optKeyLower != 'off' && optKeyLower != 'none') {
          throw FormatException(
            'Option "$optKey" cannot map to disabling value "$optVal" unless named off/none.',
          );
        }
        if (!ThinkingWireVocabulary.canonicalEffortMatches(
          optionId: optKey,
          value: trimmedVal,
        )) {
          throw FormatException(
            'Option "$optKey" cannot map to effort "$optVal": a canonical '
            'effort id must carry its own canonical value.',
          );
        }
        options[optKey] = trimmedVal;
      } else if (wire == 'google_thinking') {
        final optKeyLower = optKey.toLowerCase();
        if (optVal is num) {
          final b = optVal.toInt();
          if (b < 0 || optVal != b) {
            throw FormatException(
              'google_thinking option "$optKey" budget must be a non-negative integer',
            );
          }
          if ((optKeyLower == 'off' || optKeyLower == 'none') && b != 0) {
            throw FormatException(
              'Option "$optKey" cannot map to active budget "$optVal". Off/none must disable thinking.',
            );
          }
          if (b == 0 && optKeyLower != 'off' && optKeyLower != 'none') {
            throw FormatException(
              'Option "$optKey" cannot map to 0 budget unless named off/none.',
            );
          }
          options[optKey] = b;
        } else if (optVal is String) {
          final trimmedVal = optVal.trim().toLowerCase();
          const allowedGoogleLevels = {
            ...ThinkingWireVocabulary.googleLevelIds,
            'none',
            'off',
          };
          if (!allowedGoogleLevels.contains(trimmedVal)) {
            throw FormatException(
              'google_thinking option "$optKey" value "$optVal" is not a valid level (allowed: ${allowedGoogleLevels.join(', ')})',
            );
          }
          final isDisable = trimmedVal == 'none' || trimmedVal == 'off';
          if ((optKeyLower == 'off' || optKeyLower == 'none') && !isDisable) {
            throw FormatException(
              'Option "$optKey" cannot map to active level "$optVal". Off/none must disable thinking.',
            );
          }
          if (isDisable && optKeyLower != 'off' && optKeyLower != 'none') {
            throw FormatException(
              'Option "$optKey" cannot map to disabling level "$optVal" unless named off/none.',
            );
          }
          // Shared no-remap invariant for the documented level ids.
          if (!ThinkingWireVocabulary.canonicalLevelMatches(
            optionId: optKey,
            value: trimmedVal,
          )) {
            throw FormatException(
              'Option "$optKey" cannot map to level "$optVal": a canonical '
              'level id must carry its own canonical value.',
            );
          }
          options[optKey] = trimmedVal;
        } else {
          throw FormatException(
            'google_thinking option "$optKey" value must be an integer budget or level string',
          );
        }
      }
    }

    final defaultOption =
        (tcMap['default_option'] ?? tcMap['default_option_id'])
            ?.toString()
            .trim();
    if (defaultOption != null && defaultOption.isNotEmpty) {
      if (!options.containsKey(defaultOption)) {
        throw FormatException(
          'default_option "$defaultOption" must be one of declared options: ${options.keys.toList()}',
        );
      }
    }

    return ThinkingControlOverride(
      status: status,
      wire: wire.trim(),
      options: Map.unmodifiable(options),
      defaultOption: (defaultOption != null && defaultOption.isNotEmpty)
          ? defaultOption
          : null,
    );
  }
}

class ModelCapabilityOverride {
  final bool? supportsImageInput;
  final ThinkingControlOverride? thinkingControl;

  const ModelCapabilityOverride({
    this.supportsImageInput,
    this.thinkingControl,
  });

  String get fingerprint {
    final canonicalPayload = jsonEncode({
      'supports_image_input': supportsImageInput,
      'thinking_control': thinkingControl?.fingerprint,
    });
    return sha256.convert(utf8.encode(canonicalPayload)).toString();
  }
}

class ModelAwareRuntimePolicy {
  static const defaults = ModelAwareRuntimePolicy(
    contextModelLimits: {},
    compaction: ModelAwareCompactionPolicy(
      threshold: 0.90,
      targetRatio: 0.10,
      models: {},
    ),
    modelCapabilities: {},
  );

  final Map<String, int> contextModelLimits;
  final ModelAwareCompactionPolicy compaction;
  final Map<String, ModelCapabilityOverride> modelCapabilities;

  const ModelAwareRuntimePolicy({
    required this.contextModelLimits,
    required this.compaction,
    this.modelCapabilities = const {},
  });

  ModelCapabilityOverride? capabilityOverrideFor(String modelId) {
    return modelCapabilities[modelId];
  }

  /// The compaction pass timeout the runtime of [sanadHome] uses
  /// (`config.yaml` `compaction.passTimeoutSeconds`). A client of that
  /// runtime, such as `sanad session compact`, bounds its wait for a
  /// compaction result with it. An unreadable or invalid file yields the
  /// default, because the client must still wait for the real outcome.
  static Duration compactionPassTimeoutForHome(String sanadHome) {
    try {
      return ModelAwareRuntimePolicy.load(
        File('$sanadHome/config.yaml'),
      ).compaction.passTimeout;
    } on FormatException {
      return ModelAwareCompactionPolicy.defaultPassTimeout;
    } on FileSystemException {
      return ModelAwareCompactionPolicy.defaultPassTimeout;
    }
  }

  factory ModelAwareRuntimePolicy.load(File file) {
    if (!file.existsSync() || file.readAsStringSync().trim().isEmpty) {
      return defaults;
    }
    dynamic decoded;
    try {
      decoded = loadYaml(file.readAsStringSync());
    } catch (error) {
      throw FormatException('Invalid Sanad config.yaml: ${error.runtimeType}');
    }
    if (decoded is! YamlMap) {
      throw const FormatException(
        'Invalid Sanad config.yaml: root must be a map',
      );
    }
    final root = _stringMap(decoded, 'root');
    final context = _optionalMap(root['context'], 'context');
    _rejectUnknown(context, const {'modelLimits'}, 'context');
    final rawLimits = _optionalMap(
      context['modelLimits'],
      'context.modelLimits',
    );
    final limits = <String, int>{};
    for (final entry in rawLimits.entries) {
      final value = entry.value;
      if (value is! num || value.toInt() <= 0 || value != value.toInt()) {
        throw FormatException(
          'context.modelLimits.${entry.key} must be a positive integer',
        );
      }
      limits[Config._normalizeModelId(entry.key)] = value.toInt();
    }

    final rawCompaction = _optionalMap(root['compaction'], 'compaction');
    _rejectUnknown(rawCompaction, const {
      'threshold',
      'targetRatio',
      'models',
      'passTimeoutSeconds',
    }, 'compaction');
    final threshold = _ratio(
      rawCompaction['threshold'],
      0.90,
      'compaction.threshold',
    );
    final targetRatio = _ratio(
      rawCompaction['targetRatio'],
      0.10,
      'compaction.targetRatio',
    );
    final rawModels = _optionalMap(
      rawCompaction['models'],
      'compaction.models',
    );
    final models = <String, CompactionPolicy>{};
    for (final entry in rawModels.entries) {
      final model = _optionalMap(entry.value, 'compaction.models.${entry.key}');
      _rejectUnknown(model, const {
        'threshold',
        'targetRatio',
      }, 'compaction.models.${entry.key}');
      models[Config._normalizeModelId(entry.key)] = CompactionPolicy(
        threshold: _ratio(
          model['threshold'],
          threshold,
          'compaction.models.${entry.key}.threshold',
        ),
        targetRatio: _ratio(
          model['targetRatio'],
          targetRatio,
          'compaction.models.${entry.key}.targetRatio',
        ),
      );
    }

    final rawCapabilities = _optionalMap(
      root['model_capabilities'],
      'model_capabilities',
    );
    final capabilities = <String, ModelCapabilityOverride>{};
    for (final entry in rawCapabilities.entries) {
      final modelId = entry.key;
      if (modelId.contains('*')) {
        throw FormatException(
          'Wildcard model keys are prohibited in model_capabilities: $modelId',
        );
      }
      final rawConfig = _optionalMap(
        entry.value,
        'model_capabilities.$modelId',
      );

      // Detect and actionably reject retired nested provider schema
      final hasNestedProviderShape = rawConfig.values.any(
        (v) =>
            v is Map &&
            (v.containsKey('supports_image_input') ||
                v.containsKey('thinking_control')),
      );
      if (hasNestedProviderShape) {
        throw FormatException(
          'Nested provider-instance format in model_capabilities is no longer supported. '
          'model_capabilities must be keyed directly by exact model identity '
          '(e.g. model_capabilities."$modelId": {supports_image_input: ...}).',
        );
      }

      _rejectUnknown(rawConfig, const {
        'supports_image_input',
        'thinking_control',
      }, 'model_capabilities.$modelId');

      bool? supportsImageInput;
      if (rawConfig.containsKey('supports_image_input')) {
        final val = rawConfig['supports_image_input'];
        if (val != null && val is! bool) {
          throw FormatException(
            'model_capabilities.$modelId.supports_image_input must be a boolean',
          );
        }
        supportsImageInput = val as bool?;
      }

      ThinkingControlOverride? thinkingControl;
      if (rawConfig.containsKey('thinking_control')) {
        final rawTc = rawConfig['thinking_control'];
        if (rawTc != null) {
          final tcMap = _optionalMap(
            rawTc,
            'model_capabilities.$modelId.thinking_control',
          );
          thinkingControl = ThinkingControlOverride.parse(
            tcMap,
            context: 'model_capabilities.$modelId.thinking_control',
          );
        }
      }

      capabilities[modelId] = ModelCapabilityOverride(
        supportsImageInput: supportsImageInput,
        thinkingControl: thinkingControl,
      );
    }

    return ModelAwareRuntimePolicy(
      contextModelLimits: Map.unmodifiable(limits),
      compaction: ModelAwareCompactionPolicy(
        threshold: threshold,
        targetRatio: targetRatio,
        models: Map.unmodifiable(models),
        passTimeout: _positiveSeconds(
          rawCompaction['passTimeoutSeconds'],
          ModelAwareCompactionPolicy.defaultPassTimeout,
          'compaction.passTimeoutSeconds',
        ),
      ),
      modelCapabilities: Map.unmodifiable(capabilities),
    );
  }

  static Map<String, dynamic> _stringMap(dynamic value, String path) {
    if (value is! Map) {
      throw FormatException('$path must be a map');
    }
    final result = <String, dynamic>{};
    for (final entry in value.entries) {
      if (entry.key is! String) {
        throw FormatException('$path keys must be strings');
      }
      result[entry.key as String] = entry.value;
    }
    return result;
  }

  static Map<String, dynamic> _optionalMap(dynamic value, String path) =>
      value == null ? <String, dynamic>{} : _stringMap(value, path);

  static void _rejectUnknown(
    Map<String, dynamic> map,
    Set<String> known,
    String path,
  ) {
    final unknown = map.keys.where((key) => !known.contains(key)).toList();
    if (unknown.isNotEmpty) {
      throw FormatException('Unknown $path key: ${unknown.first}');
    }
  }

  static Duration _positiveSeconds(
    dynamic value,
    Duration fallback,
    String path,
  ) {
    if (value == null) return fallback;
    if (value is! num || value <= 0 || value != value.toInt()) {
      throw FormatException('$path must be a positive integer');
    }
    return Duration(seconds: value.toInt());
  }

  static double _ratio(dynamic value, double fallback, String path) {
    if (value == null) return fallback;
    if (value is! num || value <= 0 || value >= 1) {
      throw FormatException('$path must be between 0 and 1');
    }
    return value.toDouble();
  }
}
