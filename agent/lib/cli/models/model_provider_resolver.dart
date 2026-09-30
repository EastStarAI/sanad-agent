import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';

/// Resolved provider and model identities ready for gateway transmission.
class ResolvedModelProvider {
  final String providerId;
  final String providerName;
  final String modelName;

  const ResolvedModelProvider({
    required this.providerId,
    required this.providerName,
    required this.modelName,
  });

  @override
  String toString() => '$providerName ($providerId) : $modelName';
}

/// Result of model and provider resolution.
class ModelProviderResolutionResult {
  final ResolvedModelProvider? resolved;
  final String? errorMessage;
  final String? hintMessage;

  bool get isSuccess => resolved != null;

  const ModelProviderResolutionResult.success(this.resolved)
    : errorMessage = null,
      hintMessage = null;

  const ModelProviderResolutionResult.failure({
    required this.errorMessage,
    this.hintMessage,
  }) : resolved = null;
}

/// Centralized resolver for AI providers and models across all CLI entry points.
///
/// Follows DRY and ensures predictable provider routing:
/// 1. Accepts human-friendly names (e.g. 'ChatGPT', 'OpenCode Go', 'openai-codex') or UUIDs.
/// 2. If no provider specified, defaults to current active session provider or default configured provider.
/// 3. Validates that the requested model belongs to the target provider.
/// 4. If model belongs to a different provider, fails cleanly with an actionable hint instead of guessing.
class ModelProviderResolver {
  final ProviderInstanceRepository? _repositoryOverride;
  final String? _sanadHomeOverride;
  final bool allowFallback;

  const ModelProviderResolver({
    ProviderInstanceRepository? repositoryOverride,
    String? sanadHomeOverride,
    this.allowFallback = false,
  }) : _repositoryOverride = repositoryOverride,
       _sanadHomeOverride = sanadHomeOverride;

  /// Resolves the provider and model according to explicit user flags and system defaults.
  ModelProviderResolutionResult resolve({
    String? requestedModel,
    String? requestedProvider,
    String? activeSessionProviderId,
    String? activeSessionModel,
  }) {
    final stateHome = _sanadHomeOverride ?? getSanadStateHome();
    final dbFile = File(p.join(stateHome, 'state.db'));

    AgentStateDatabase? db;
    try {
      final ProviderInstanceRepository repo;
      if (_repositoryOverride != null) {
        repo = _repositoryOverride;
      } else if (dbFile.existsSync()) {
        db = AgentStateDatabase.atPath(stateHome);
        repo = ProviderInstanceRepository(db);
      } else {
        // Fallback gracefully for mock test environments or ephemeral runs without state.db
        final effModel = requestedModel?.trim().isNotEmpty == true
            ? requestedModel!.trim()
            : (activeSessionModel?.trim().isNotEmpty == true
                  ? activeSessionModel!.trim()
                  : 'default');
        final effProv = requestedProvider?.trim().isNotEmpty == true
            ? requestedProvider!.trim()
            : (activeSessionProviderId?.trim().isNotEmpty == true
                  ? activeSessionProviderId!.trim()
                  : 'default');
        return ModelProviderResolutionResult.success(
          ResolvedModelProvider(
            providerId: effProv,
            providerName: effProv,
            modelName: effModel,
          ),
        );
      }

      final instances = repo.findAll();
      if (instances.isEmpty) {
        if (allowFallback) {
          final fallbackProvider = requestedProvider?.trim().isNotEmpty == true
              ? requestedProvider!.trim()
              : 'default';
          final fallbackModel = requestedModel?.trim().isNotEmpty == true
              ? requestedModel!.trim()
              : 'default';
          return ModelProviderResolutionResult.success(
            ResolvedModelProvider(
              providerId: fallbackProvider,
              providerName: fallbackProvider,
              modelName: fallbackModel,
            ),
          );
        }
        return const ModelProviderResolutionResult.failure(
          errorMessage: 'No AI providers configured.',
          hintMessage: 'Run "sanad setup" to add and configure an AI provider.',
        );
      }

      // 1. Resolve Target Provider
      ProviderInstance? targetProvider;
      if (requestedProvider != null && requestedProvider.trim().isNotEmpty) {
        final query = requestedProvider.trim().toLowerCase();
        for (final inst in instances) {
          if (inst.displayName.toLowerCase() == query ||
              inst.templateId.toLowerCase() == query ||
              inst.id.toLowerCase() == query) {
            targetProvider = inst;
            break;
          }
        }
        if (targetProvider == null) {
          if (allowFallback) {
            final effName = requestedProvider.trim();
            return ModelProviderResolutionResult.success(
              ResolvedModelProvider(
                providerId: effName,
                providerName: effName,
                modelName: requestedModel?.trim().isNotEmpty == true
                    ? requestedModel!.trim()
                    : 'default',
              ),
            );
          }
          final availableNames = instances
              .map((i) => '"${i.displayName}"')
              .join(', ');
          return ModelProviderResolutionResult.failure(
            errorMessage: 'Provider "$requestedProvider" not found.',
            hintMessage: 'Configured providers: [$availableNames]',
          );
        }
      } else {
        // Fallback to active session provider or system default
        if (activeSessionProviderId != null) {
          for (final inst in instances) {
            if (inst.id == activeSessionProviderId) {
              targetProvider = inst;
              break;
            }
          }
        }
        targetProvider ??= instances.firstWhere(
          (i) => i.isDefault,
          orElse: () => instances.first,
        );
      }

      // 2. Resolve Target Model
      final trimmedModel = requestedModel?.trim();
      if (trimmedModel == null || trimmedModel.isEmpty) {
        final effectiveModel =
            (activeSessionModel != null &&
                activeSessionModel.trim().isNotEmpty &&
                _isModelAvailable(
                  targetProvider,
                  activeSessionModel.trim(),
                  repo,
                ))
            ? activeSessionModel.trim()
            : (targetProvider.defaultModel ??
                  _getFirstAvailableModel(targetProvider, repo) ??
                  'default');

        return ModelProviderResolutionResult.success(
          ResolvedModelProvider(
            providerId: targetProvider.id,
            providerName: targetProvider.displayName,
            modelName: effectiveModel,
          ),
        );
      }

      // 3. Verify Model Availability on Target Provider
      if (_isModelAvailable(targetProvider, trimmedModel, repo)) {
        return ModelProviderResolutionResult.success(
          ResolvedModelProvider(
            providerId: targetProvider.id,
            providerName: targetProvider.displayName,
            modelName: trimmedModel,
          ),
        );
      }

      // 4. Model not in target provider: Search where it exists to guide the user
      final providersWithModel = <ProviderInstance>[];
      for (final inst in instances) {
        if (inst.id != targetProvider.id &&
            _isModelAvailable(inst, trimmedModel, repo)) {
          providersWithModel.add(inst);
        }
      }

      if (allowFallback) {
        return ModelProviderResolutionResult.success(
          ResolvedModelProvider(
            providerId: targetProvider.id,
            providerName: targetProvider.displayName,
            modelName: trimmedModel,
          ),
        );
      }

      if (providersWithModel.isNotEmpty) {
        final matchingNames = providersWithModel
            .map((p) => '"${p.displayName}"')
            .join(', ');
        final recommendedProvider = providersWithModel.first.displayName;
        return ModelProviderResolutionResult.failure(
          errorMessage:
              'Model "$trimmedModel" is not available under provider "${targetProvider.displayName}".',
          hintMessage:
              'Model "$trimmedModel" is available under: [$matchingNames].\n'
              'To use it, specify:\n'
              '  --provider "$recommendedProvider" --model "$trimmedModel"',
        );
      }

      return ModelProviderResolutionResult.failure(
        errorMessage:
            'Model "$trimmedModel" was not found in any configured provider.',
        hintMessage: 'Run "sanad models" to view all available models.',
      );
    } catch (e) {
      return ModelProviderResolutionResult.failure(
        errorMessage: 'Failed to resolve model and provider: $e',
      );
    } finally {
      db?.dispose();
    }
  }

  /// Checks if [modelName] is available in [instance], either as default or in model cache.
  bool _isModelAvailable(
    ProviderInstance instance,
    String modelName,
    ProviderInstanceRepository repo,
  ) {
    if (instance.defaultModel != null &&
        instance.defaultModel!.toLowerCase() == modelName.toLowerCase()) {
      return true;
    }

    final cache =
        repo.readModelCache(instance.id, 'models') ??
        repo.readModelCache(instance.id, 'all') ??
        repo.readModelCache(instance.id, 'default');

    if (cache != null && cache['models'] is List) {
      for (final m in cache['models'] as List) {
        if (m is Map) {
          final val = m['value'] ?? m['id'] ?? m['name'] ?? '';
          if (val.toString().toLowerCase() == modelName.toLowerCase()) {
            return true;
          }
        } else if (m.toString().toLowerCase() == modelName.toLowerCase()) {
          return true;
        }
      }
    }

    return false;
  }

  String? _getFirstAvailableModel(
    ProviderInstance instance,
    ProviderInstanceRepository repo,
  ) {
    if (instance.defaultModel != null && instance.defaultModel!.isNotEmpty) {
      return instance.defaultModel;
    }

    final cache =
        repo.readModelCache(instance.id, 'models') ??
        repo.readModelCache(instance.id, 'all') ??
        repo.readModelCache(instance.id, 'default');

    if (cache != null && cache['models'] is List) {
      final list = cache['models'] as List;
      if (list.isNotEmpty) {
        final first = list.first;
        if (first is Map) {
          return (first['value'] ?? first['id'] ?? first['name'])?.toString();
        }
        return first.toString();
      }
    }
    return null;
  }
}
