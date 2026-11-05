import 'package:sanad_agent/core/provider_runtime/provider_discovery_error.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';

/// Discovery state of one provider instance as every client and CLI surface
/// receives it (issue 339).
///
/// The projection is additive and nullable: a consumer that does not know these
/// keys simply ignores them, and an instance that never ran discovery projects
/// `null` for both entries instead of an empty object.
class ProviderDiscoveryProjection {
  const ProviderDiscoveryProjection({this.error, this.source, this.verified = false});

  /// Sanitized cause of the last failed discovery, or `null` when the current
  /// revisions discovered cleanly (or never discovered).
  final ProviderDiscoveryError? error;

  /// `live`, `fallback`, `cache_stale`, or `failed`; `null` without a row.
  final String? source;

  /// Whether the cached model list is a verified live answer for the instance's
  /// current config and credential revisions.
  final bool verified;

  /// Builds the projection for [instance] from its stored cache row.
  ///
  /// A row whose revisions no longer match the instance describes an older
  /// configuration, so its error is not projected: the instance was demoted for
  /// a different reason and a stale `401` would be misleading.
  factory ProviderDiscoveryProjection.of(
    ProviderInstanceRepository repository,
    ProviderInstance instance,
  ) {
    final row = repository.readModelCache(instance.id, 'models');
    if (row == null) return const ProviderDiscoveryProjection();
    final revisionsMatch =
        row['config_revision'] == instance.configRevision &&
        row['credential_revision'] == instance.credentialRevision;
    final source = row['source']?.toString();
    return ProviderDiscoveryProjection(
      error: revisionsMatch
          ? ProviderDiscoveryError.tryRestore(
              detailJson: row['last_error_detail'],
              legacyText: row['last_error'],
            )
          : null,
      source: source,
      verified: revisionsMatch && source == 'live',
    );
  }

  /// Extra keys to merge into a projected instance or model-cache entry.
  Map<String, dynamic> toMap() => {
    'discovery_error': error?.toMap(),
    'model_cache': source == null
        ? null
        : {'source': source, 'verified': verified},
  };
}
