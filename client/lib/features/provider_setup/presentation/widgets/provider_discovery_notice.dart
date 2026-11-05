import 'package:flutter/material.dart';
import 'package:sanad_client/features/provider_setup/data/models/provider_discovery_error_dto.dart';
import 'package:sanad_client/l10n/app_localizations.dart';

/// Visible, actionable cause of a failed provider connection, plus the
/// "unverified fallback list" label (issue 339).
///
/// The daemon classifies and sanitizes the failure; this widget only chooses the
/// localized sentence for that category, so a rejected credential is never
/// rendered as an opaque status name and no provider response body reaches the
/// screen.
class ProviderDiscoveryNotice extends StatelessWidget {
  final ProviderDiscoveryErrorDto? error;
  final ProviderModelCacheDto? modelCache;
  final String instanceId;

  /// Prefix for this notice's stable widget keys.
  ///
  /// One card can show two notices for the same instance — the persisted cause
  /// from the daemon projection and the transient connection-test failure — so
  /// each rendering site owns a distinct prefix and a key lookup stays unique
  /// (issue 339 review 3).
  final String keyPrefix;

  const ProviderDiscoveryNotice({
    super.key,
    required this.error,
    required this.instanceId,
    this.modelCache,
    this.keyPrefix = 'provider_discovery',
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final discovery = error;
    final showFallback = modelCache?.isUnverifiedFallback ?? false;
    if (discovery == null && !showFallback) {
      return const SizedBox.shrink();
    }

    // A definitive cause is an error; a non-definitive one explains a failed
    // check over a still-usable saved list, so it keeps a warning style and
    // never contradicts a READY badge (issue 339 review 2).
    final isWarning = discovery != null && !discovery.definitive;
    final color = isWarning
        ? theme.colorScheme.tertiary
        : discovery == null
        ? theme.colorScheme.onSurfaceVariant
        : theme.colorScheme.error;

    return Container(
      key: Key('${keyPrefix}_notice_$instanceId'),
      width: double.infinity,
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (discovery != null)
            Text(
              isWarning
                  ? l10n.providerLastCheckFailed(
                      messageForFailure(l10n, discovery),
                    )
                  : messageForFailure(l10n, discovery),
              key: Key('${keyPrefix}_message_$instanceId'),
              style: TextStyle(fontSize: 12, color: color, height: 1.35),
            ),
          if (discovery?.endpoint != null) ...[
            const SizedBox(height: 4),
            SelectableText(
              l10n.providerDiscoveryEndpoint(discovery!.endpoint!),
              key: Key('${keyPrefix}_endpoint_$instanceId'),
              style: TextStyle(
                fontSize: 11,
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.3,
              ),
            ),
          ],
          if (showFallback) ...[
            if (discovery != null) const SizedBox(height: 4),
            Text(
              l10n.providerModelCacheUnverified,
              key: Key('${keyPrefix}_fallback_$instanceId'),
              style: TextStyle(
                fontSize: 11,
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.3,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Localized sentence for one classified failure.
  ///
  /// Shared with the connection-test notice so Test, setup verification, and
  /// the instance list describe the same category with the same words.
  static String messageForFailure(
    AppLocalizations l10n,
    ProviderDiscoveryErrorDto failure,
  ) {
    switch (failure.kind) {
      case 'invalid_credential':
        return l10n.providerDiscoveryInvalidCredential;
      case 'forbidden':
        return l10n.providerDiscoveryForbidden;
      case 'endpoint_not_found':
        return l10n.providerDiscoveryEndpointNotFound;
      case 'rate_limited':
        return l10n.providerDiscoveryRateLimited;
      case 'timeout':
        return l10n.providerDiscoveryTimeout;
      case 'network':
        return l10n.providerDiscoveryNetwork;
      case 'server_error':
        return l10n.providerDiscoveryServerError;
      case 'no_models':
        return l10n.providerDiscoveryNoModels;
      case 'http':
        final status = failure.statusCode;
        return status == null
            ? l10n.providerDiscoveryUnknown
            : l10n.providerDiscoveryHttp(status);
      default:
        // Never echo the daemon's English summary: every category has a
        // localized sentence and `unknown` is the catch-all (issue 339
        // review 2).
        return l10n.providerDiscoveryUnknown;
    }
  }
}
