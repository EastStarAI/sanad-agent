/// Daemon-side service that resolves a [ProviderUsageResult] for a given
/// instance (Task 55 Gate B).
///
/// This service is the single bridge between the protocol layer and the usage
/// adapters. It:
///   • Resolves the instance by UUID (never by template id alone).
///   • Reads the instance's stored credential through [SecretStore].
///   • Builds a [ProviderUsageContext] with the resolved credential + base URL.
///   • Delegates to the matching [ProviderUsageAdapter] when one is registered
///     for the instance's template; otherwise returns `unsupported`.
///   • Maps adapter exceptions to typed result statuses
///     (auth_required / unavailable / failed) without leaking credential or
///     response-body details.
///
/// The service does NOT touch instance readiness, model execution, or the rate
/// limiter. Usage failures are fully contained (Task 55 §3.1, §3.4).
library;

import 'dart:convert';
import 'dart:math';

import 'package:logging/logging.dart';

import '../provider_runtime/provider_instance_repository.dart';
import '../provider_runtime/secret_store.dart';
import 'provider_usage_adapter.dart';
import 'provider_usage_models.dart';

/// Injectable factory for producing a fresh HTTP client per usage fetch. The
/// production wiring installs [defaultProductionHttpClient] (Task 55 Gate A).
/// Tests inject a fake factory.
typedef UsageHttpClientFactoryFn = ProviderUsageHttpClient Function();

class ProviderUsageService {
  ProviderUsageService({
    required ProviderInstanceRepository instanceRepository,
    required SecretStore secretStore,
    required ProviderUsageRegistry registry,
    required UsageHttpClientFactoryFn httpClientFactory,
  }) : _instanceRepository = instanceRepository,
       _secretStore = secretStore,
       _registry = registry,
       _httpClientFactory = httpClientFactory;

  final ProviderInstanceRepository _instanceRepository;
  final SecretStore _secretStore;
  final ProviderUsageRegistry _registry;
  final UsageHttpClientFactoryFn _httpClientFactory;
  final _log = Logger('ProviderUsageService');
  final Map<String, ProviderUsageResetResult> _idempotency = {};
  final Map<String, Future<ProviderUsageResetResult>> _inFlightResets = {};
  final Map<String, _ResetConfirmation> _confirmations = {};
  static const _maxIdempotencyEntries = 128;
  static const _confirmationLifetime = Duration(minutes: 2);

  /// Returns the typed result for a `provider.usage.get` command.
  ///
  /// [requestId] and [instanceId] are always echoed back on the result.
  Future<ProviderUsageResult> getUsage({
    required String instanceId,
    String? requestId,
  }) async {
    final instance = _instanceRepository.findById(instanceId);
    if (instance == null) {
      return ProviderUsageResult.failed(
        instanceId,
        'Provider instance not found.',
      )..requestId = requestId;
    }

    final adapter = _registry.adapterFor(instance.templateId);
    if (adapter == null) {
      // No usage adapter registered for this template → the UI shows no
      // `Usage & limits` section. This is NOT an error (Task 55 §3.4).
      return ProviderUsageResult.unsupported(instanceId)..requestId = requestId;
    }

    final credential = _secretStore.read(instanceId);
    final baseUrl = instance.effectiveBaseUrl ?? '';

    final context = ProviderUsageContext(
      instanceId: instanceId,
      templateId: instance.templateId,
      baseUrl: baseUrl,
      credential: credential,
      accountId: _extractAccountId(credential),
      httpClientFactory: _httpClientFactory,
    );

    if (!adapter.canFetch(context)) {
      return ProviderUsageResult.authRequired(
        instanceId,
        'Account sign-in is required to view usage limits.',
      )..requestId = requestId;
    }

    try {
      final snapshot = await adapter.fetch(context);
      return ProviderUsageResult.available(snapshot)..requestId = requestId;
    } on ProviderUsageAuthException catch (e) {
      return ProviderUsageResult.authRequired(instanceId, e.message)
        ..requestId = requestId;
    } on ProviderUsageUnavailableException catch (e) {
      return ProviderUsageResult.unavailable(instanceId, e.message)
        ..requestId = requestId;
    } on ProviderUsageException catch (e) {
      return ProviderUsageResult.failed(instanceId, e.message)
        ..requestId = requestId;
    } catch (e) {
      _log.warning(
        'Unexpected usage fetch failure for instance $instanceId: $e',
      );
      return ProviderUsageResult.failed(
        instanceId,
        'Usage information could not be loaded.',
      )..requestId = requestId;
    }
  }

  /// Performs a fresh preflight and consumes at most one reset credit.
  ///
  /// Concurrent retries with the same instance-scoped idempotency key share
  /// one operation. Each caller still receives its own request correlation id.
  Future<ProviderUsageResetResult> resetUsage({
    required String instanceId,
    required String idempotencyKey,
    String? requestId,
    String? confirmationToken,
  }) async {
    final cacheKey = '$instanceId:$idempotencyKey';
    final cached = _idempotency[cacheKey];
    if (cached != null) return _withRequestId(cached, requestId);

    final operation = _inFlightResets.putIfAbsent(
      cacheKey,
      () => _performResetUsage(
        instanceId: instanceId,
        idempotencyKey: idempotencyKey,
        confirmationToken: confirmationToken,
      ),
    );
    try {
      return _withRequestId(await operation, requestId);
    } finally {
      if (identical(_inFlightResets[cacheKey], operation)) {
        _inFlightResets.remove(cacheKey);
      }
    }
  }

  Future<ProviderUsageResetResult> _performResetUsage({
    required String instanceId,
    required String idempotencyKey,
    String? confirmationToken,
  }) async {
    const requestId = null;
    if (idempotencyKey.trim().isEmpty) {
      return ProviderUsageResetResult(
        status: ProviderUsageResetStatus.failed,
        providerInstanceId: instanceId,
        requestId: requestId,
        message: 'A reset request identity is required.',
      );
    }
    final cacheKey = '$instanceId:$idempotencyKey';
    final instance = _instanceRepository.findById(instanceId);
    final adapter = instance == null
        ? null
        : _registry.adapterFor(instance.templateId);
    if (instance == null || adapter is! ProviderUsageResetAdapter) {
      return ProviderUsageResetResult(
        status: ProviderUsageResetStatus.unsupported,
        providerInstanceId: instanceId,
        requestId: requestId,
        message: 'Usage resets are not supported for this account.',
      );
    }

    final preflight = await getUsage(instanceId: instanceId);
    final snapshot = preflight.snapshot;
    if (!preflight.isAvailable || snapshot == null) {
      final status = preflight.status == ProviderUsageResultStatus.authRequired
          ? ProviderUsageResetStatus.authRequired
          : ProviderUsageResetStatus.failed;
      return ProviderUsageResetResult(
        status: status,
        providerInstanceId: instanceId,
        requestId: requestId,
        message: preflight.message ?? 'Current usage could not be verified.',
      );
    }
    if (snapshot.availableResets <= 0) {
      return ProviderUsageResetResult(
        status: ProviderUsageResetStatus.noCredit,
        providerInstanceId: instanceId,
        requestId: requestId,
        message: 'No reset credits are available for this account.',
        availableResets: 0,
        snapshot: snapshot,
      );
    }

    final fingerprint = _snapshotFingerprint(snapshot);
    final exhausted = snapshot.windows.any((window) => window.isExhausted);
    if (!exhausted) {
      final confirmation = confirmationToken == null
          ? null
          : _confirmations.remove(confirmationToken);
      final valid =
          confirmation != null &&
          confirmation.instanceId == instanceId &&
          confirmation.fingerprint == fingerprint &&
          DateTime.now().toUtc().isBefore(confirmation.expiresAt);
      if (!valid) {
        final token = _newConfirmationToken();
        _confirmations[token] = _ResetConfirmation(
          instanceId,
          fingerprint,
          DateTime.now().toUtc().add(_confirmationLifetime),
        );
        return ProviderUsageResetResult(
          status: ProviderUsageResetStatus.confirmationRequired,
          providerInstanceId: instanceId,
          requestId: requestId,
          message:
              'Your limits are not exhausted. Resetting now may waste this credit.',
          availableResets: snapshot.availableResets,
          snapshot: snapshot,
          confirmationToken: token,
        );
      }
    }

    final credential = _secretStore.read(instanceId);
    final context = ProviderUsageContext(
      instanceId: instanceId,
      templateId: instance.templateId,
      baseUrl: instance.effectiveBaseUrl ?? '',
      credential: credential,
      accountId: _extractAccountId(credential),
      httpClientFactory: _httpClientFactory,
    );
    try {
      final mutation = await adapter.reset(
        context,
        idempotencyKey: idempotencyKey,
      );
      ProviderUsageSnapshot? refreshed;
      var refreshFailed = false;
      if (mutation.status == ProviderUsageResetStatus.reset ||
          mutation.status == ProviderUsageResetStatus.nothingToReset ||
          mutation.status == ProviderUsageResetStatus.alreadyRedeemed) {
        final refresh = await getUsage(instanceId: instanceId);
        refreshed = refresh.snapshot;
        refreshFailed = refreshed == null;
      }
      final result = ProviderUsageResetResult(
        status: mutation.status,
        providerInstanceId: instanceId,
        message: _resetMessage(mutation.status, refreshFailed: refreshFailed),
        availableResets: refreshed?.availableResets ?? mutation.availableResets,
        snapshot: refreshed,
        refreshFailed: refreshFailed,
      );
      _remember(cacheKey, result);
      return _withRequestId(result, requestId);
    } on ProviderUsageAuthException {
      return ProviderUsageResetResult(
        status: ProviderUsageResetStatus.authRequired,
        providerInstanceId: instanceId,
        requestId: requestId,
        message: 'ChatGPT account sign-in is required to reset limits.',
      );
    } catch (_) {
      return ProviderUsageResetResult(
        status: ProviderUsageResetStatus.failed,
        providerInstanceId: instanceId,
        requestId: requestId,
        message: 'Reset could not be completed. Please try again.',
      );
    }
  }

  void _remember(String key, ProviderUsageResetResult result) {
    if (_idempotency.length >= _maxIdempotencyEntries) {
      _idempotency.remove(_idempotency.keys.first);
    }
    _idempotency[key] = result;
  }

  ProviderUsageResetResult _withRequestId(
    ProviderUsageResetResult value,
    String? requestId,
  ) => ProviderUsageResetResult(
    status: value.status,
    providerInstanceId: value.providerInstanceId,
    requestId: requestId,
    message: value.message,
    availableResets: value.availableResets,
    snapshot: value.snapshot,
    confirmationToken: value.confirmationToken,
    refreshFailed: value.refreshFailed,
  );

  String _snapshotFingerprint(ProviderUsageSnapshot snapshot) => jsonEncode({
    'fetched_at': snapshot.fetchedAt.toUtc().toIso8601String(),
    'resets': snapshot.availableResets,
    'reset_credits': snapshot.resetCredits.map((c) => c.toMap()).toList(),
    'windows': snapshot.windows.map((w) => w.toMap()).toList(),
  });

  String _newConfirmationToken() {
    final random = Random.secure();
    return base64Url.encode(List<int>.generate(24, (_) => random.nextInt(256)));
  }

  String _resetMessage(String status, {required bool refreshFailed}) {
    if (status == ProviderUsageResetStatus.reset) {
      return refreshFailed
          ? 'Limits were reset, but refreshed usage could not be loaded.'
          : 'Usage limits were reset successfully.';
    }
    if (status == ProviderUsageResetStatus.nothingToReset) {
      return 'Nothing needed resetting. Your credit was not spent.';
    }
    if (status == ProviderUsageResetStatus.noCredit) {
      return 'No reset credit is available.';
    }
    if (status == ProviderUsageResetStatus.alreadyRedeemed) {
      return 'This reset was already processed; no additional credit was spent.';
    }
    return 'Reset could not be completed.';
  }

  /// Returns whether the instance's template has a usage adapter registered.
  /// Used by the `provider.usage.support` capability query so the client can
  /// decide whether to show the `Usage & limits` disclosure without issuing a
  /// full fetch (Task 55 §3.5).
  bool supportsUsage(String instanceId) {
    final instance = _instanceRepository.findById(instanceId);
    if (instance == null) return false;
    return _registry.supportsTemplate(instance.templateId);
  }

  /// Extracts the `ChatGPT-Account-Id` from the credential's OAuth metadata
  /// when available. Currently the Sanad [SecretRecord] does not carry a
  /// dedicated account-id field, so this returns null. When the OAuth flow
  /// starts persisting an account id (e.g. from the id-token or a separate
  /// field), this is the single place to surface it (Task 55 §3.3).
  String? _extractAccountId(/* SecretRecord? */ dynamic credential) {
    // Intentionally null in v1: the ChatGPT-Account-Id header is optional and
    // the current SecretRecord shape does not carry it. Leaving this as a
    // single extraction point keeps future additions localised.
    return null;
  }
}

class _ResetConfirmation {
  final String instanceId;
  final String fingerprint;
  final DateTime expiresAt;
  const _ResetConfirmation(this.instanceId, this.fingerprint, this.expiresAt);
}
