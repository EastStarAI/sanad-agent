import 'dart:io';
import 'package:dotenv/dotenv.dart';
import '../engine/adapters/provider_profile.dart';
import '../engine/adapters/provider_registry.dart';
import 'constants.dart';

class Config {
  static const String _defaultGatewayUrl = 'https://api.sanad.eaststarai.com';
  static const String _defaultLlmBaseUrl = 'https://api.openai.com/v1';
  static const int _defaultLocalGatewayPort = 58085;
  static const String _defaultPortalUrl = 'https://portal.sanad.eaststarai.com';

  DotEnv _env;
  final Map<String, String> _environment;

  /// Paths of the env files actually loaded, in load order. Tracked so that
  /// [_ensureFreshEnv] can re-stat them and reload when any changes on disk.
  List<String> _envPaths = const [];

  /// Cached on-disk signature of the loaded env files: the maximum modified
  /// timestamp and the sum of sizes across all loaded files. When either
  /// differs from a fresh stat, the env is reloaded.
  DateTime? _envMtime;
  int _envSize = 0;

  Config({Map<String, String>? environment})
    : _environment = environment ?? Platform.environment,
      _env = DotEnv() {
    _loadEnvFiles();
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

  /// Fallback context limit if the adapter cannot determine it from the model name.
  int get contextLimit => _readInt('CONTEXT_LIMIT', defaultValue: 4000);

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
