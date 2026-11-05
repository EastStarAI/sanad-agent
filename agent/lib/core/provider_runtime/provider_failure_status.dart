import 'package:sanad_agent/core/provider_runtime/provider_discovery_error.dart';
import 'package:sanad_agent/core/provider_runtime/provider_protocol_constants.dart';

/// Status a connection failure proves, or `null` when it proves nothing about
/// the configuration and must leave the lifecycle untouched.
///
/// This is the single owner of the cause → lifecycle mapping (issue 339). Both
/// write paths use it: `ProviderInstanceService` after a verification, and the
/// legacy read-repair when it restores a definitive cause onto a `ready` row.
///
/// `needs_auth` is reserved for a rejected credential (`401`, or `403` when
/// discovery itself was refused) and `error` for a definitive endpoint failure.
/// Transport failures, timeouts, rate limits, outages, unusable lists, and every
/// warning-grade copy (a probe `403`, a model rejecting the check request)
/// attach their cause without naming a status.
String? statusForDiscoveryFailure(ProviderDiscoveryError failure) {
  if (!failure.isDefinitive) return null;
  switch (failure.kind) {
    case ProviderFailureCategory.invalidCredential:
    case ProviderFailureCategory.forbidden:
      return InstanceStatus.needsAuth;
    case ProviderFailureCategory.endpointNotFound:
    case ProviderFailureCategory.http:
      return InstanceStatus.error;
    default:
      return null;
  }
}
