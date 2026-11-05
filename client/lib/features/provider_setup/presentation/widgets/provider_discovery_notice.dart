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

  const ProviderDiscoveryNotice({
    super.key,
    required this.error,
    required this.instanceId,
    this.modelCache,
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

    final color = discovery != null
        ? theme.colorScheme.error
        : theme.colorScheme.onSurfaceVariant;

    return Container(
      key: Key('provider_discovery_notice_$instanceId'),
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
              messageForFailure(l10n, discovery),
              key: Key('provider_discovery_message_$instanceId'),
              style: TextStyle(fontSize: 12, color: color, height: 1.35),
            ),
          if (discovery?.endpoint != null) ...[
            const SizedBox(height: 4),
            SelectableText(
              l10n.providerDiscoveryEndpoint(discovery!.endpoint!),
              key: Key('provider_discovery_endpoint_$instanceId'),
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
              key: Key('provider_discovery_fallback_$instanceId'),
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
        return failure.message?.isNotEmpty == true
            ? failure.message!
            : l10n.providerDiscoveryUnknown;
    }
  }
}
