import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import '../../core/constants.dart';
import '../../core/sanad_home/sanad_home_bootstrap.dart';
import '../../core/models/model_metadata.dart';

class ModelsDevService {
  final _logger = Logger('ModelsDevService');
  static const String modelsDevUrl = 'https://models.dev/api.json';
  static const int cacheTtlSeconds = 3600; // 1 hour

  Map<String, dynamic> _cache = {};
  DateTime? _lastFetchTime;
  final http.Client? client;
  final String? cacheFilePathOverride;

  ModelsDevService({this.client, this.cacheFilePathOverride});

  String get _cacheFilePath =>
      cacheFilePathOverride ?? p.join(getSanadHome(), 'models_dev_cache.json');

  static const Map<String, String> providerToModelsDev = {
    'openrouter': 'openrouter',
    'novita': 'novita-ai',
    'anthropic': 'anthropic',
    'openai': 'openai',
    'openai-codex': 'openai',
    'zai': 'zai',
    'zai-coding': 'zai-coding-plan',
    'zai-coding-plan': 'zai-coding-plan',
    'kimi': 'kimi-for-coding',
    'kimi-coding': 'kimi-for-coding',
    'moonshot': 'kimi-for-coding',
    'stepfun': 'stepfun',
    'kimi-coding-cn': 'kimi-for-coding',
    'minimax': 'minimax',
    'minimax-oauth': 'minimax',
    'minimax-cn': 'minimax-cn',
    'deepseek': 'deepseek',
    'alibaba': 'alibaba',
    'qwen-oauth': 'alibaba',
    'copilot': 'github-copilot',
    'opencode-zen': 'opencode',
    'opencode-go': 'opencode-go',
    'kilocode': 'kilo',
    'fireworks': 'fireworks-ai',
    'huggingface': 'huggingface',
    'gemini': 'google',
    'google': 'google',
    'xai': 'xai',
    'xai-oauth': 'xai',
    'xiaomi': 'xiaomi',
    'nvidia': 'nvidia',
    'groq': 'groq',
    'mistral': 'mistral',
    'togetherai': 'togetherai',
    'perplexity': 'perplexity',
    'cohere': 'cohere',
    'ollama-cloud': 'ollama-cloud',
  };

  /// Main interface to list models for a provider that are suitable for agentic use.
  /// Filters for tool_call = true and excludes known noise.
  Future<List<String>> listAgenticModels(String provider) async {
    final mdevProvider =
        providerToModelsDev[provider.toLowerCase()] ?? provider.toLowerCase();
    final data = await _fetchRegistry();
    final providerData = data[mdevProvider];
    if (providerData is! Map) return [];

    final models = providerData['models'];
    if (models is! Map) return [];

    final List<String> result = [];
    final noiseRegexp = RegExp(
      r'-tts\b|embedding|live-|-(preview|exp)-\d{2,4}[-_]|-image\b|-image-preview\b|-customtools\b',
      caseSensitive: false,
    );

    for (final entry in models.entries) {
      final mid = entry.key;
      final mdata = entry.value;
      if (mdata is! Map) continue;

      final isToolCall = mdata['tool_call'] == true;
      if (!isToolCall) continue;

      if (noiseRegexp.hasMatch(mid)) continue;

      result.add(mid);
    }
    return result;
  }

  /// Grounded exact aliases for models known under alternative identifiers or relay names.
  /// Strictly same-generation aliases only; no cross-generation fallbacks.
  static const Map<String, List<String>> groundedModelAliases = {
    'claude-haiku-4.5': [
      'claude-haiku-4-5',
      'claude-haiku-4-5-20251001',
    ],
    'claude-haiku-4-5': [
      'claude-haiku-4.5',
      'claude-haiku-4-5-20251001',
    ],
    'claude-haiku-4-5-20251001': [
      'claude-haiku-4.5',
      'claude-haiku-4-5',
    ],
  };

  /// Explicitly hydrates or refreshes the catalog cache from disk or network.
  Future<void> ensureLoaded({bool forceRefresh = false}) async {
    await _fetchRegistry(forceRefresh: forceRefresh);
  }

  /// Exact image-input evidence for the selected model.
  /// Resolves canonical known models across vendors/providers.
  Future<bool> supportsImageInput(String model) async {
    await _fetchRegistry();
    return supportsImageInputSync(model) ?? false;
  }

  /// Synchronous image-input check against existing memory cache without I/O.
  /// Returns `null` if the registry cache has not been loaded yet or model capability is unknown.
  bool? supportsImageInputSync(String model) {
    _ensureDiskCacheLoadedSync();
    if (_cache.isEmpty) return null;

    // 1. If model is explicitly namespaced (e.g. "anthropic/claude-3-5-sonnet" or "openai/gpt-4o"), inspect only that namespace.
    if (model.contains('/')) {
      final slashIndex = model.indexOf('/');
      final vendorPrefix = model.substring(0, slashIndex).trim();
      final modelSuffix = model.substring(slashIndex + 1).trim();
      if (vendorPrefix.isNotEmpty && modelSuffix.isNotEmpty) {
        final vendorKey = providerToModelsDev[vendorPrefix.toLowerCase()] ??
            vendorPrefix.toLowerCase();
        final vendorData = _cache[vendorKey];
        if (vendorData is Map) {
          final res = _lookupInVendor(vendorData, modelSuffix);
          if (res.hasValue) return res.value;
        }
      }
      return null;
    }

    // 2. Bare model ID: resolve purely from model identity across all vendor namespaces.
    // Provider instance, template, and endpoint must NOT select or hint intrinsic metadata.
    final candidateResults = <bool>{};
    for (final vendorEntry in _cache.entries) {
      final vendorData = vendorEntry.value;
      if (vendorData is! Map) continue;
      final res = _lookupInVendor(vendorData, model);
      if (res.isConflict) {
        // Contradictory grounded model claims in a vendor: another publisher cannot erase ambiguity!
        return null;
      }
      if (res.hasValue) {
        candidateResults.add(res.value);
      }
      // Missing facts do not veto unambiguous known facts from other vendors.
    }

    // Return consensus if unambiguous; if conflicting (both true and false) or empty, return null (unknown).
    if (candidateResults.length == 1) {
      return candidateResults.first;
    }
    return null;
  }

  _VendorLookupResult _lookupInVendor(Map vendorData, String model) {
    final models = vendorData['models'];
    if (models is! Map) return _VendorLookupResult.missing;

    // 1. If exact selected ID is present, it is authoritative.
    if (models.containsKey(model)) {
      final support = _extractImageSupport(models[model]);
      if (support != null) {
        return _VendorLookupResult.from(support);
      }
      return _VendorLookupResult.missing;
    }

    // 2. When exact selected ID is missing, check grounded aliases.
    final aliases = groundedModelAliases[model];
    if (aliases == null || aliases.isEmpty) return _VendorLookupResult.missing;

    final aliasResults = <bool>{};
    for (final alias in aliases) {
      if (alias != model && models.containsKey(alias)) {
        final support = _extractImageSupport(models[alias]);
        if (support != null) {
          aliasResults.add(support);
        }
      }
    }

    // Contradictory SAME-vendor alias candidates must indicate conflict.
    if (aliasResults.length > 1) {
      return _VendorLookupResult.conflict;
    }
    if (aliasResults.length == 1) {
      return _VendorLookupResult.from(aliasResults.first);
    }
    return _VendorLookupResult.missing;
  }

  static bool? _extractImageSupport(dynamic modelEntry) {
    if (modelEntry is! Map) return null;
    final modalities = modelEntry['modalities'];
    if (modalities is! Map) return null;
    final input = modalities['input'];
    if (input is List && input.every((v) => v is String)) {
      return input.contains('image');
    }
    return null;
  }

  void _ensureDiskCacheLoadedSync() {
    if (_cache.isNotEmpty) return;
    try {
      final diskFile = File(_cacheFilePath);
      if (diskFile.existsSync()) {
        final content = cacheFilePathOverride == null
            ? utf8.decode(
                SanadHomeBootstrap.identity().readSecretBytes(
                  'models_dev_cache.json',
                ),
              )
            : diskFile.readAsStringSync();
        final decoded = jsonDecode(content);
        if (decoded is Map<String, dynamic>) {
          _cache = decoded;
          final stat = diskFile.statSync();
          final ageSeconds = DateTime.now().difference(stat.modified).inSeconds;
          _lastFetchTime = DateTime.now().subtract(
            Duration(seconds: ageSeconds >= 0 ? ageSeconds : 0),
          );
        }
      }
    } catch (_) {}
  }

  /// Check if a model supports reasoning.
  Future<bool> supportsReasoning(String provider, String model) async {
    final mdata = await _getModelData(provider, model);
    if (mdata != null) {
      return mdata['reasoning'] == true;
    }
    // Fallback based on model name
    final lowerModel = model.toLowerCase();
    return lowerModel.contains('o1') ||
        lowerModel.contains('o3') ||
        lowerModel.contains('reasoning') ||
        lowerModel.contains('deepseek-r');
  }

  /// Get context limit for a model.
  Future<int?> getContextLimit(String provider, String model) async {
    final mdata = await _getModelData(provider, model);
    if (mdata != null) {
      final limit = mdata['limit'];
      if (limit is Map) {
        final ctx = limit['context'];
        if (ctx is num && ctx > 0) {
          return ctx.toInt();
        }
      }
    }
    // Fallback to static metadata
    return ModelMetadata.getLimitForModel(model);
  }

  Future<Map<String, dynamic>?> _getModelData(
    String provider,
    String model,
  ) async {
    final mdevProvider =
        providerToModelsDev[provider.toLowerCase()] ?? provider.toLowerCase();
    final data = await _fetchRegistry();
    final providerData = data[mdevProvider];
    if (providerData is! Map) return null;

    final models = providerData['models'];
    if (models is! Map) return null;

    // Exact match
    var mdata = models[model];
    if (mdata is Map) return Map<String, dynamic>.from(mdata);

    // Case-insensitive match
    final lowerModel = model.toLowerCase();
    for (final entry in models.entries) {
      if (entry.key.toLowerCase() == lowerModel) {
        if (entry.value is Map) {
          return Map<String, dynamic>.from(entry.value);
        }
      }
    }

    // Suffix match (e.g., :cloud, -cloud)
    for (final suffix in [':cloud', '-cloud']) {
      final keyWithSuffix = model + suffix;
      final mdataSuffix = models[keyWithSuffix];
      if (mdataSuffix is Map) {
        return Map<String, dynamic>.from(mdataSuffix);
      }

      final lowerKeyWithSuffix = lowerModel + suffix;
      for (final entry in models.entries) {
        if (entry.key.toLowerCase() == lowerKeyWithSuffix) {
          if (entry.value is Map) {
            return Map<String, dynamic>.from(entry.value);
          }
        }
      }
    }

    return null;
  }

  Future<Map<String, dynamic>> _fetchRegistry({
    bool forceRefresh = false,
  }) async {
    // 1. Memory cache check
    if (!forceRefresh &&
        _cache.isNotEmpty &&
        _lastFetchTime != null &&
        DateTime.now().difference(_lastFetchTime!).inSeconds <
            cacheTtlSeconds) {
      return _cache;
    }

    // 2. Disk cache check
    final diskFile = File(_cacheFilePath);
    if (!forceRefresh && diskFile.existsSync()) {
      try {
        final stat = diskFile.statSync();
        final ageSeconds = DateTime.now().difference(stat.modified).inSeconds;
        if (ageSeconds >= 0 && ageSeconds < cacheTtlSeconds) {
          final content = cacheFilePathOverride == null
              ? utf8.decode(
                  SanadHomeBootstrap.identity().readSecretBytes(
                    'models_dev_cache.json',
                  ),
                )
              : diskFile.readAsStringSync();
          final decoded = jsonDecode(content);
          if (decoded is Map<String, dynamic>) {
            _cache = decoded;
            _lastFetchTime = DateTime.now().subtract(
              Duration(seconds: ageSeconds),
            );
            _logger.fine('Loaded models.dev from fresh disk cache');
            return _cache;
          }
        }
      } catch (e) {
        _logger.warning('Failed to load disk cache: $e');
      }
    }

    // 3. Network fetch
    try {
      final httpClient = client ?? http.Client();
      final response = await httpClient
          .get(Uri.parse(modelsDevUrl))
          .timeout(const Duration(seconds: 15));
      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);
        if (decoded is Map<String, dynamic>) {
          _cache = decoded;
          _lastFetchTime = DateTime.now();
          // Write to disk cache atomically
          try {
            if (cacheFilePathOverride == null) {
              await SanadHomeBootstrap.identity().writeConfigText(
                'models_dev_cache.json',
                response.body,
              );
            } else {
              diskFile.parent.createSync(recursive: true);
              diskFile.writeAsStringSync(response.body, flush: true);
            }
          } catch (e) {
            _logger.warning('Failed to write disk cache: $e');
          }
          _logger.info('Fetched models.dev registry successfully');
          return _cache;
        }
      }
    } catch (e) {
      _logger.warning('Failed to fetch models.dev registry from network: $e');
    }

    // 4. Stale/updated disk cache fallback
    if ((_cache.isEmpty || forceRefresh) && diskFile.existsSync()) {
      try {
        final content = cacheFilePathOverride == null
            ? utf8.decode(
                SanadHomeBootstrap.identity().readSecretBytes(
                  'models_dev_cache.json',
                ),
              )
            : diskFile.readAsStringSync();
        final decoded = jsonDecode(content);
        if (decoded is Map<String, dynamic>) {
          _cache = decoded;
          // Set last fetch time to expire soon (5 mins) to retry network
          _lastFetchTime = DateTime.now().subtract(
            const Duration(seconds: cacheTtlSeconds - 300),
          );
          _logger.info('Loaded models.dev from stale disk cache');
          return _cache;
        }
      } catch (e) {
        _logger.warning('Failed to load stale disk cache: $e');
      }
    }

    return _cache;
  }
}

sealed class _VendorLookupResult {
  const _VendorLookupResult();
  static const missing = _VendorMissingResult();
  static const conflict = _VendorConflictResult();
  static const supported = _VendorValueResult(true);
  static const unsupported = _VendorValueResult(false);

  static _VendorLookupResult from(bool val) =>
      val ? supported : unsupported;

  bool get isConflict => this is _VendorConflictResult;
  bool get hasValue => this is _VendorValueResult;
  bool get value => (this as _VendorValueResult).supported;
}

class _VendorMissingResult extends _VendorLookupResult {
  const _VendorMissingResult();
}

class _VendorConflictResult extends _VendorLookupResult {
  const _VendorConflictResult();
}

class _VendorValueResult extends _VendorLookupResult {
  final bool supported;
  const _VendorValueResult(this.supported);
}
