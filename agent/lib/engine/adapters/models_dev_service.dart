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
    'github-copilot': 'github-copilot',
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

    // 4. Stale disk cache fallback
    if (_cache.isEmpty && diskFile.existsSync()) {
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
