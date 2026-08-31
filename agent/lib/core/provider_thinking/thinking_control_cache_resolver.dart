/// Resolves cached thinking-control metadata for an active provider route.
library;

import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/core/provider_runtime/provider_model_id.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_control_cache_entry.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_control_models.dart';

class ThinkingControlCacheResolver {
  final ProviderInstanceRepository _repository;

  ThinkingControlCacheResolver(this._repository);

  /// Returns the cached `thinking_control` map for [providerInstanceId] +
  /// [modelId], or null when the cache is missing/stale or the model is absent.
  Map<String, dynamic>? resolve({
    required String? providerInstanceId,
    required String? modelId,
    required String? templateId,
    required String protocol,
    int? configRevision,
    int? credentialRevision,
  }) {
    return resolveEntry(
      providerInstanceId: providerInstanceId,
      modelId: modelId,
      templateId: templateId,
      protocol: protocol,
      configRevision: configRevision,
      credentialRevision: credentialRevision,
    )?.descriptor.toMap();
  }

  ThinkingControlCacheEntry? resolveEntry({
    required String? providerInstanceId,
    required String? modelId,
    required String? templateId,
    required String protocol,
    int? configRevision,
    int? credentialRevision,
  }) {
    final instanceId = providerInstanceId?.trim();
    final normalizedModelId = modelId?.trim();
    if (instanceId == null ||
        instanceId.isEmpty ||
        normalizedModelId == null ||
        normalizedModelId.isEmpty) {
      return null;
    }

    final cached = _repository.readModelCache(instanceId, 'models');
    if (cached == null) {
      return null;
    }

    if (configRevision != null &&
        cached['config_revision'] != configRevision) {
      return null;
    }
    if (credentialRevision != null &&
        cached['credential_revision'] != credentialRevision) {
      return null;
    }

    final fetchedAt = _parseFetchedAt(cached['fetched_at']);
    final cacheSource = cached['source']?.toString() ?? 'live';
    final models = cached['models'] as List<dynamic>? ?? const [];
    final resolvedTemplateId = templateId ?? '';
    for (final entry in models) {
      if (entry is! Map) {
        continue;
      }
      final map = Map<String, dynamic>.from(entry);
      final rawValue = map['value']?.toString();
      if (rawValue == null || rawValue.isEmpty) {
        continue;
      }
      final normalizedValue = ProviderModelId.normalize(
        templateId: resolvedTemplateId,
        protocol: protocol,
        rawModelId: rawValue,
      );
      if (normalizedValue != normalizedModelId) {
        continue;
      }
      final thinkingControl = map['thinking_control'];
      if (thinkingControl is Map<String, dynamic>) {
        return ThinkingControlCacheEntry(
          descriptor: ThinkingControlDescriptor.fromMap(thinkingControl),
          fetchedAt: fetchedAt,
          cacheSource: cacheSource,
        );
      }
      if (thinkingControl is Map) {
        return ThinkingControlCacheEntry(
          descriptor: ThinkingControlDescriptor.fromMap(
            thinkingControl.map((key, value) => MapEntry(key.toString(), value)),
          ),
          fetchedAt: fetchedAt,
          cacheSource: cacheSource,
        );
      }
      return null;
    }

    return null;
  }

  DateTime? _parseFetchedAt(Object? raw) {
    if (raw == null) {
      return null;
    }
    final parsed = DateTime.tryParse(raw.toString());
    if (parsed == null) {
      return null;
    }
    return parsed.isUtc ? parsed : parsed.toUtc();
  }
}
