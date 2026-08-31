import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import 'package:sanad_agent/core/provider_runtime/copilot_model_catalog.dart';
import 'package:sanad_agent/core/provider_runtime/env_file_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_credential_resolver.dart';
import 'package:sanad_agent/core/provider_runtime/provider_protocol_constants.dart';
import 'package:sanad_agent/engine/adapters/codex_models_service.dart';
import 'package:sanad_agent/engine/adapters/provider_profile.dart';
import 'package:sanad_agent/engine/adapters/provider_registry.dart';

/// Fetches live model lists from a provider when possible, falling back to the
/// registry's `fallbackModels` when the network call fails or the provider
/// does not support model fetching.
class ModelOptionsService {
  final _logger = Logger('ModelOptionsService');

  final EnvFileService _env;
  final ProviderCredentialResolver _resolver;
  final http.Client Function() _clientFactory;
  final CodexModelsService _codexModelsService;

  ModelOptionsService(
    this._env,
    this._resolver, {
    http.Client Function()? clientFactory,
    CodexModelsService? codexModelsService,
  }) : _clientFactory = clientFactory ?? http.Client.new,
       _codexModelsService = codexModelsService ?? CodexModelsService();

  /// Returns the model options for [providerId]. When [fetchLive] is true and
  /// the provider supports it, a live `/models` (or `/api/tags` for Ollama)
  /// request is attempted first.
  Future<ModelOptionsResult> optionsFor(
    String providerId, {
    bool fetchLive = true,
  }) async {
    final profile =
        ProviderRegistry.findByNameOrAlias(providerId) ??
        ProviderProfile(
          name: providerId,
          displayName: providerId,
          fallbackModels: const [],
        );
    final fallback = profile.fallbackModels;
    final selected = _selectedModelFor(profile);
    final resolution = _resolver.resolve(providerId);

    if (!fetchLive || !profile.supportsModelFetch) {
      return ModelOptionsResult(
        providerId: profile.name,
        models: fallback,
        selectedModel: selected,
        authenticated: resolution.isReady,
        authType: profile.authType,
        keyEnv: profile.envApiKeyName,
        warning: resolution.isReady ? null : resolution.reason,
        source: 'fallback',
      );
    }

    final liveModels = await _fetchLiveModels(profile, resolution.credential);
    if (liveModels.isNotEmpty) {
      final sortedModels = profile.name == 'openai-codex'
          ? liveModels
          : _sortLiveModelsByFallback(liveModels, fallback);

      return ModelOptionsResult(
        providerId: profile.name,
        models: sortedModels,
        selectedModel: selected,
        authenticated: resolution.isReady,
        authType: profile.authType,
        keyEnv: profile.envApiKeyName,
        warning: resolution.isReady ? null : resolution.reason,
        source: 'live',
      );
    }
    return ModelOptionsResult(
      providerId: profile.name,
      models: fallback,
      selectedModel: selected,
      authenticated: resolution.isReady,
      authType: profile.authType,
      keyEnv: profile.envApiKeyName,
      warning: resolution.isReady
          ? 'Live model list unavailable; using fallback presets.'
          : resolution.reason,
      source: 'fallback',
    );
  }

  /// Returns options for every provider in a single payload (used by
  /// `model.options`).
  Future<List<Map<String, dynamic>>> allOptions({
    bool fetchLive = false,
  }) async {
    final results = <Map<String, dynamic>>[];
    for (final profile in ProviderRegistry.profiles) {
      final result = await optionsFor(profile.name, fetchLive: fetchLive);
      results.add(result.toMap());
    }
    return results;
  }

  String? _selectedModelFor(ProviderProfile profile) {
    if (profile.envModelName != null) {
      final v = _env.get(profile.envModelName!);
      if (v.trim().isNotEmpty) return v;
    }
    final active = _env.get('ACTIVE_PROVIDER').trim().toLowerCase();
    if (active.isEmpty || active == profile.name) {
      final generic = _env.get('LLM_MODEL');
      if (generic.trim().isNotEmpty) return generic;
    }
    return null;
  }

  Future<List<String>> _fetchLiveModels(
    ProviderProfile profile,
    String? credential,
  ) async {
    final baseUrl = _resolveBaseUrl(profile);
    if (baseUrl.isEmpty) return const [];

    final client = _clientFactory();
    try {
      if (profile.name == 'openai-codex') {
        final models = await _codexModelsService.fetch(
          client: client,
          baseUrl: baseUrl,
          accessToken: credential ?? '',
          provider: profile.name,
        );
        _logger.info(
          'Codex model discovery succeeded (${models.length} models)',
        );
        return models.map((model) => model.value).toList(growable: false);
      }

      if (profile.name == kGithubCopilotTemplateId) {
        final headers = <String, String>{
          ...GithubCopilotProtocol.staticRequestHeaders,
          if (credential != null && credential.isNotEmpty)
            'Authorization': 'Bearer $credential',
        };
        final resp = await client
            .get(Uri.parse('$baseUrl/models'), headers: headers)
            .timeout(const Duration(seconds: 5));
        if (resp.statusCode != 200) return const [];
        final decoded = jsonDecode(resp.body);
        return CopilotModelCatalog.parseList(
          decoded,
        ).map((model) => model.id).toList(growable: false);
      }

      if (profile.apiMode == 'ollama') {
        final resp = await client
            .get(Uri.parse('$baseUrl/api/tags'))
            .timeout(const Duration(seconds: 4));
        if (resp.statusCode == 200) {
          final decoded = jsonDecode(resp.body) as Map<String, dynamic>;
          final modelsList = decoded['models'] as List?;
          if (modelsList != null) {
            return modelsList.map((m) => (m as Map)['name'] as String).toList();
          }
        }
        return const [];
      }

      final headers = <String, String>{};
      if (credential != null && credential.isNotEmpty) {
        headers['Authorization'] = 'Bearer $credential';
      }
      if (profile.authType == 'anthropic_messages' ||
          profile.apiMode == 'anthropic_messages') {
        headers['x-api-key'] = credential ?? '';
        headers['anthropic-version'] = '2023-06-01';
      }
      final resp = await client
          .get(Uri.parse('$baseUrl/models'), headers: headers)
          .timeout(const Duration(seconds: 5));
      if (resp.statusCode == 200) {
        final decoded = jsonDecode(resp.body) as Map<String, dynamic>;
        final data = decoded['data'] as List?;
        if (data != null) {
          final fetched = data.map((m) => (m as Map)['id'] as String).toList();
          fetched.sort();
          return fetched;
        }
      }
      return const [];
    } catch (e) {
      if (profile.name == 'openai-codex') {
        _logger.warning('Codex model discovery failed: $e');
      } else {
        _logger.fine('Live model fetch failed for ${profile.name}: $e');
      }
      return const [];
    } finally {
      client.close();
    }
  }

  List<String> _sortLiveModelsByFallback(
    List<String> liveModels,
    List<String> fallback,
  ) {
    final liveSet = liveModels.toSet();
    return [
      for (final model in fallback)
        if (liveSet.contains(model)) model,
      for (final model in liveModels)
        if (!fallback.contains(model)) model,
    ];
  }

  String _resolveBaseUrl(ProviderProfile profile) {
    if (profile.envBaseUrlName != null) {
      final v = _env.get(profile.envBaseUrlName!);
      if (v.trim().isNotEmpty) return v;
    }
    final generic = _env.get('LLM_BASE_URL');
    if (generic.trim().isNotEmpty) return generic;
    return profile.defaultBaseUrl ?? '';
  }
}

class ModelOptionsResult {
  final String providerId;
  final List<String> models;
  final String? selectedModel;
  final bool authenticated;
  final String authType;
  final String? keyEnv;
  final String? warning;
  final String source;

  ModelOptionsResult({
    required this.providerId,
    required this.models,
    required this.selectedModel,
    required this.authenticated,
    required this.authType,
    required this.keyEnv,
    required this.warning,
    required this.source,
  });

  Map<String, dynamic> toMap() => {
    'provider_id': providerId,
    'models': models,
    if (selectedModel != null) 'selected_model': selectedModel,
    'authenticated': authenticated,
    'auth_type': authType,
    if (keyEnv != null) 'key_env': keyEnv,
    if (warning != null) 'warning': warning,
    'source': source,
  };
}
