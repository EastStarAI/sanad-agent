import 'package:sanad_agent/core/provider_usage/provider_usage_models.dart';
import 'package:sanad_agent/core/provider_usage/provider_usage_service.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';

/// Maps the Task 55 provider-account-usage commands onto
/// [ProviderUsageService] and builds their response envelopes.
///
/// This mapping lives beside [ProviderCommandHandler] rather than inside it so
/// the handler stays inside its size ratchet. Behaviour is unchanged: the same
/// payload fields are read, the same service calls are made, and the same
/// envelope types are emitted.
class ProviderUsageCommandMapper {
  const ProviderUsageCommandMapper({
    required ProviderUsageService? usageService,
    required this.buildEnvelope,
  }) : _usageService = usageService;

  final ProviderUsageService? _usageService;

  /// Emits one canonical event envelope; the handler passes its bridge method.
  final Map<String, dynamic> Function(CanonicalEvent event) buildEnvelope;

  /// `provider.usage.get` → `provider.usage.result`.
  ///
  /// Delegates to [ProviderUsageService] when registered; otherwise returns
  /// `unsupported` for every instance so the client hides the section cleanly
  /// without an error (Task 55 §3.4).
  Future<Map<String, dynamic>> buildGet(CanonicalEvent event) async {
    final requestId = event.payload['request_id'] as String?;
    final instanceId = event.payload['provider_instance_id'] as String? ?? '';

    final result =
        _usageService != null
              ? await _usageService.getUsage(
                  instanceId: instanceId,
                  requestId: requestId,
                )
              : ProviderUsageResult.unsupported(instanceId)
          ..requestId = requestId;

    return buildEnvelope(
      CanonicalEvent(
        type: CanonicalEventTypes.providerUsageResult,
        payload: result.toMap(),
      ),
    );
  }

  /// `provider.usage.reset` → `provider.usage.reset_result`.
  ///
  /// `credit_id` is optional: it targets the credit whose row the user pressed,
  /// and its absence keeps the original consume request.
  Future<Map<String, dynamic>> buildReset(CanonicalEvent event) async {
    final requestId = event.payload['request_id'] as String?;
    final instanceId = event.payload['provider_instance_id'] as String? ?? '';
    final idempotencyKey = event.payload['idempotency_key'] as String? ?? '';
    final confirmationToken = event.payload['confirmation_token'] as String?;
    final creditId = event.payload['credit_id'] as String?;
    final result = _usageService == null
        ? ProviderUsageResetResult(
            status: ProviderUsageResetStatus.unsupported,
            providerInstanceId: instanceId,
            requestId: requestId,
            message: 'Usage resets are not supported for this account.',
          )
        : await _usageService.resetUsage(
            instanceId: instanceId,
            idempotencyKey: idempotencyKey,
            requestId: requestId,
            confirmationToken: confirmationToken,
            creditId: creditId,
          );
    return buildEnvelope(
      CanonicalEvent(
        type: CanonicalEventTypes.providerUsageResetResult,
        payload: result.toMap(),
      ),
    );
  }

  /// `provider.usage.support` → `provider.usage.support_result`.
  ///
  /// Returns a per-instance map of `supported` flags so the client can decide
  /// which instances warrant a `Usage & limits` disclosure without issuing a
  /// full fetch for each one (Task 55 §3.5).
  Future<Map<String, dynamic>> buildSupport(CanonicalEvent event) async {
    final requestId = event.payload['request_id'] as String?;

    final instanceIds =
        (event.payload['provider_instance_ids'] as List?)
            ?.map((e) => e.toString())
            .toList() ??
        const <String>[];

    final support = <String, bool>{};
    if (_usageService != null) {
      for (final id in instanceIds) {
        support[id] = _usageService.supportsUsage(id);
      }
    }

    return buildEnvelope(
      CanonicalEvent(
        type: CanonicalEventTypes.providerUsageSupportResult,
        payload: {'request_id': requestId, 'support': support},
      ),
    );
  }
}
