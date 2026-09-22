import 'dart:async';
import 'package:logging/logging.dart';

import 'package:sanad_agent/core/provider_runtime/provider_instance.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/core/agent_runtime_service.dart';
import 'package:sanad_agent/engine/adapters/base_anthropic_adapter.dart';
import 'package:sanad_agent/engine/adapters/base_openai_adapter.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/capabilities.dart';

/// Bounded concurrency queue helper to limit parallel tasks.
class ConcurrencyLimiter {
  final int maxConcurrency;
  int _activeCount = 0;
  final List<Completer<void>> _queue = [];

  ConcurrencyLimiter(this.maxConcurrency);

  Future<T> run<T>(Future<T> Function() task) async {
    while (_activeCount >= maxConcurrency) {
      final completer = Completer<void>();
      _queue.add(completer);
      await completer.future;
    }
    _activeCount++;
    try {
      return await task();
    } finally {
      _activeCount--;
      if (_queue.isNotEmpty) {
        final next = _queue.removeAt(0);
        next.complete();
      }
    }
  }
}

/// Service that manages the cached list of models for each provider instance,
/// implementing a Stale-While-Revalidate (SWR) cache flow (Plan 29 §10.3).
class ProviderModelCacheService {
  final _logger = Logger('ProviderModelCacheService');
  final ProviderInstanceRepository _repo;
  final AgentRuntimeService _runtime;
  final ConcurrencyLimiter _limiter;
  final Duration _cooldown;

  // Active refreshes map for coalescing
  final Map<String, Future<List<ModelOption>>> _activeRefreshes = {};

  // Broadcast stream for successful cache update events
  final _eventController = StreamController<String>.broadcast();

  ProviderModelCacheService(
    this._repo,
    this._runtime, {
    int maxConcurrency = 3,
    Duration cooldown = const Duration(minutes: 5),
  }) : _limiter = ConcurrencyLimiter(maxConcurrency),
       _cooldown = cooldown;

  /// Emits the instanceId when its model cache is successfully refreshed.
  Stream<String> get onRefreshed => _eventController.stream;

  /// Returns the cached model list if it exists and its revisions match the current instance.
  List<ModelOption>? snapshot(String instanceId) {
    final instance = _repo.findById(instanceId);
    if (instance == null) return null;

    final cached = _repo.readModelCache(instanceId, 'models');
    if (cached == null) return null;

    // Reject cache if config_revision or credential_revision doesn't match
    if (cached['config_revision'] != instance.configRevision ||
        cached['credential_revision'] != instance.credentialRevision) {
      _logger.fine(
        'Snapshot rejected due to revision mismatch for instance $instanceId',
      );
      return null;
    }

    final modelsList = cached['models'] as List<dynamic>?;
    if (modelsList == null) return null;

    return modelsList
        .map(
          (m) => ModelOption(
            value: m['value'] as String,
            label: m['label'] as String,
            provider: m['provider'] as String?,
            contextWindow: m['context_window'] as int?,
            supportsReasoning: m['supports_reasoning'] as bool? ?? false,
          ),
        )
        .toList();
  }

  /// Refreshes the models list from the live provider endpoint.
  /// Coalesces concurrent calls for the same instance and applies cooldown checks.
  Future<List<ModelOption>> refresh(String instanceId, {bool manual = false}) {
    final instance = _repo.findById(instanceId);
    if (instance == null) {
      return Future.error(StateError('Instance not found: $instanceId'));
    }

    // Check cooldown unless manual refresh is requested
    if (!manual) {
      final cached = _repo.readModelCache(instanceId, 'models');
      if (cached != null &&
          cached['config_revision'] == instance.configRevision &&
          cached['credential_revision'] == instance.credentialRevision) {
        final fetchedAtStr = cached['fetched_at'] as String?;
        if (fetchedAtStr != null) {
          final fetchedAt = DateTime.parse(fetchedAtStr);
          if (DateTime.now().difference(fetchedAt) < _cooldown) {
            _logger.fine(
              'Refresh skipped: cooldown active for instance $instanceId',
            );
            final modelsList = cached['models'] as List<dynamic>;
            return Future.value(
              modelsList
                  .map(
                    (m) => ModelOption(
                      value: m['value'] as String,
                      label: m['label'] as String,
                      provider: m['provider'] as String?,
                      contextWindow: m['context_window'] as int?,
                      supportsReasoning:
                          m['supports_reasoning'] as bool? ?? false,
                    ),
                  )
                  .toList(),
            );
          }
        }
      }
    }

    // Coalesce concurrent refreshes for the same instance
    var active = _activeRefreshes[instanceId];
    if (active != null) {
      _logger.fine('Coalescing refresh for instance $instanceId');
      return active;
    }

    active = _runTrackedRefresh(instance);
    _activeRefreshes[instanceId] = active;
    return active;
  }

  Future<List<ModelOption>> _runTrackedRefresh(
    ProviderInstance instance,
  ) async {
    try {
      return await _limiter.run(() => _doLiveRefresh(instance));
    } finally {
      _activeRefreshes.remove(instance.id);
    }
  }

  Future<List<ModelOption>> _doLiveRefresh(ProviderInstance instance) async {
    final instanceId = instance.id;
    final configRev = instance.configRevision;
    final credRev = instance.credentialRevision;

    try {
      // Model list fetches do not require a user-selected model; use a
      // placeholder so the adapter can be resolved for the instance.
      final signature = _runtime.resolveSignature(
        providerId: instanceId,
        modelId: instance.defaultModel ?? '_model_list_fetch_',
      );
      final adapter = _runtime.adapterFor(signature);

      final liveModels = await adapter.getAvailableModels();
      final source = switch (adapter) {
        BaseOpenAIAdapter adapter => adapter.availableModelsSource,
        BaseAnthropicAdapter adapter => adapter.availableModelsSource,
        _ => 'live',
      };

      if (liveModels.isEmpty) {
        throw StateError('Empty model list returned from provider');
      }

      String? lastError;
      if (source == 'fallback') {
        if (adapter is BaseOpenAIAdapter) {
          lastError = adapter.lastModelsException?.toString();
        } else if (adapter is BaseAnthropicAdapter) {
          lastError = adapter.lastModelsException?.toString();
        }
        lastError ??=
            'Failed to fetch standard models (fell back to local presets).';
      }

      // Atomic update
      _repo.upsertModelCache(
        instanceId: instanceId,
        cacheKey: 'models',
        models: liveModels.map((m) => m.toJson()).toList(),
        fetchedAt: DateTime.now(),
        source: source,
        configRevision: configRev,
        credentialRevision: credRev,
        lastError: lastError,
      );

      _logger.info(
        'Live model cache refresh succeeded for instance $instanceId',
      );
      _eventController.add(instanceId);
      return liveModels;
    } catch (e) {
      _logger.warning('Failed to refresh models for instance $instanceId: $e');

      // Keep previous success in DB but update last_error metadata
      final cached = _repo.readModelCache(instanceId, 'models');
      final cachedModels = cached?['models'] as List<dynamic>?;
      if (cached != null && cachedModels != null && cachedModels.isNotEmpty) {
        _repo.upsertModelCache(
          instanceId: instanceId,
          cacheKey: 'models',
          models: cachedModels,
          fetchedAt: cached['fetched_at'] != null
              ? DateTime.parse(cached['fetched_at'] as String)
              : DateTime.now(),
          source: 'cache_stale',
          configRevision: cached['config_revision'] as int? ?? configRev,
          credentialRevision: cached['credential_revision'] as int? ?? credRev,
          lastError: e.toString(),
        );

        return cachedModels
            .map(
              (m) => ModelOption(
                value: m['value'] as String,
                label: m['label'] as String,
                provider: m['provider'] as String?,
                contextWindow: m['context_window'] as int?,
                supportsReasoning: m['supports_reasoning'] as bool? ?? false,
              ),
            )
            .toList();
      }

      _repo.upsertModelCache(
        instanceId: instanceId,
        cacheKey: 'models',
        models: const [],
        fetchedAt: DateTime.now(),
        source: 'failed',
        configRevision: configRev,
        credentialRevision: credRev,
        lastError: e.toString(),
      );
      rethrow;
    }
  }

  void dispose() {
    _eventController.close();
  }
}
