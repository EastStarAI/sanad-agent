import 'package:sanad_agent/core/provider_runtime/provider_discovery_error.dart';
import 'package:sanad_agent/core/provider_runtime/provider_failure_status.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/core/provider_runtime/provider_protocol_constants.dart';

/// Discovery state of one provider instance as every client and CLI surface
/// receives it (issue 339).
///
/// The projection is additive and nullable: a consumer that does not know these
/// keys simply ignores them, and an instance that never ran discovery projects
/// `null` for both entries instead of an empty object.
class ProviderDiscoveryProjection {
  const ProviderDiscoveryProjection({
    this.error,
    this.source,
    this.verified = false,
    this.status,
  });

  /// Sanitized cause of the last failed discovery, or `null` when the current
  /// revisions discovered cleanly (or never discovered).
  final ProviderDiscoveryError? error;

  /// `live`, `fallback`, `cache_stale`, or `failed`; `null` without a row.
  final String? source;

  /// Whether the cached model list is a verified live answer for the instance's
  /// current config and credential revisions.
  final bool verified;

  /// Status the legacy read-repair just proved, or `null` when this read did not
  /// change the lifecycle. See [statusOf].
  final String? status;

  /// Effective lifecycle status for [instance] on this read.
  ///
  /// A legacy row that still only carried raw text is re-derived and repaired in
  /// [ProviderDiscoveryProjection.of]; when the restored cause is definitive and
  /// the row still claimed `ready`, the same reconciliation a fresh verification
  /// runs has already demoted it. Projecting the stored status would then put a
  /// `READY` badge beside a rejected credential for one read (issue 339 review
  /// 3), so every surface reads the status from here.
  String statusOf(ProviderInstance instance) => status ?? instance.status;

  /// Builds the projection for [instance] from its stored cache row.
  ///
  /// A row whose revisions no longer match the instance describes an older
  /// configuration, so its error is not projected: the instance was demoted for
  /// a different reason and a stale `401` would be misleading. The same guard
  /// keeps the repair from re-demoting a row the owner has already moved on
  /// from.
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
    final restored = ProviderDiscoveryError.restoreDetailed(
      detailJson: row['last_error_detail'],
      legacyText: row['last_error'],
    );
    final error = restored.error;
    String? repairedStatus;
    if (restored.legacy && error != null) {
      // Read-repair (issue 339 review 2): rows written by an older daemon keep
      // only the sanitized summary and its structured form, so a raw body, a
      // local port, or an embedded URL never survives in the database.
      repository.recordVerificationCause(
        instanceId: instance.id,
        cacheKey: 'models',
        lastError: error.summary,
        lastErrorDetail: error.toJson(),
      );
      repairedStatus = _demoteIfDefinitive(
        repository,
        instance,
        error,
        revisionsMatch: revisionsMatch,
      );
    }
    return ProviderDiscoveryProjection(
      error: revisionsMatch ? error : null,
      source: source,
      verified: revisionsMatch && source == 'live',
      status: repairedStatus,
    );
  }

  /// Read-repair half of the migration: a definitive cause restored onto a row
  /// that still claimed `ready` names the status the mutation paths would have
  /// written, and persists it once (issue 339 review 3).
  ///
  /// Only a legacy row reaches this — the repair above rewrites the structured
  /// detail in the same call, so every later read takes the non-legacy path and
  /// cannot re-demote an instance the owner has since fixed. The status write
  /// reuses [statusForDiscoveryFailure], the same mapping
  /// `ProviderInstanceService.reconcileStatus` applies, and never calls back
  /// into the projection, so there is no loop.
  static String? _demoteIfDefinitive(
    ProviderInstanceRepository repository,
    ProviderInstance instance,
    ProviderDiscoveryError error, {
    required bool revisionsMatch,
  }) {
    if (!revisionsMatch) return null;
    if (instance.status != InstanceStatus.ready) return null;
    final target = statusForDiscoveryFailure(error);
    if (target == null || target == instance.status) return null;
    repository.update(
      instance.copyWith(status: target, updatedAt: DateTime.now()),
    );
    return target;
  }

  /// Extra keys to merge into a projected instance or model-cache entry.
  ///
  /// `status` travels with the cause so a repaired row cannot contradict it on
  /// the read that performed the repair.
  Map<String, dynamic> toMap(ProviderInstance instance) => {
    'status': statusOf(instance),
    'discovery_error': error?.toMap(),
    'model_cache': source == null
        ? null
        : {'source': source, 'verified': verified},
  };
}
