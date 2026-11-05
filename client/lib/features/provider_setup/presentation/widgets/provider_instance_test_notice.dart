import 'package:flutter/material.dart';
import 'package:sanad_client/features/provider_setup/data/models/provider_instance_test_result_dto.dart';
import 'package:sanad_client/features/provider_setup/presentation/widgets/provider_discovery_notice.dart';
import 'package:sanad_client/l10n/app_localizations.dart';

/// Renders one connection-test outcome on the instance card (issue 339).
///
/// Four distinct shapes, because they mean different things:
/// - the probe ran and answered: what was proven, with the round-trip time;
/// - the credential listed models but no model is selected yet: a partial
///   success that asks for a model;
/// - the probe could not prove the selected model: a warning that never implies
///   a rejected credential;
/// - a definitive failure: the same localized category message every other
///   provider surface uses.
class ProviderInstanceTestNotice extends StatelessWidget {
  final String instanceId;
  final ProviderInstanceTestResultDto result;

  const ProviderInstanceTestNotice({
    super.key,
    required this.instanceId,
    required this.result,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (result.success) {
      return Padding(
        key: Key('provider_test_result_$instanceId'),
        padding: const EdgeInsets.only(top: 8),
        child: Text(
          _successSummary(AppLocalizations.of(context)!),
          style: TextStyle(
            fontSize: 12,
            color: result.probeWarned
                ? theme.colorScheme.onSurfaceVariant
                : Colors.green,
            height: 1.35,
          ),
        ),
      );
    }

    final failure = result.failure;
    if (failure == null) {
      return Padding(
        key: Key('provider_test_result_$instanceId'),
        padding: const EdgeInsets.only(top: 8),
        child: Text(
          AppLocalizations.of(context)!.providerDiscoveryUnknown,
          style: TextStyle(fontSize: 12, color: theme.colorScheme.error),
        ),
      );
    }
    return ProviderDiscoveryNotice(
      instanceId: instanceId,
      error: failure,
      // The persisted cause keeps `provider_discovery_*`; the Test failure
      // owns its own prefix so both notices can coexist in one card without a
      // duplicate key (issue 339 review 3).
      keyPrefix: 'provider_test_failure',
    );
  }

  String _successSummary(AppLocalizations l10n) {
    if (result.probePassed) {
      final seconds = result.latencySeconds;
      return seconds == null
          ? l10n.providerTestWorks(result.modelsCount)
          : l10n.providerTestWorksWithProbe(
              result.modelsCount,
              result.model ?? '',
              seconds,
            );
    }
    if (result.probeWarned) {
      final warning = result.warning;
      if (warning == null) {
        return l10n.providerProbeUnknownWarning(result.modelsCount);
      }
      switch (warning.kind) {
        case 'model_rejected':
          return l10n.providerProbeModelRejected(
            result.modelsCount,
            warning.model ?? result.model ?? '',
          );
        case 'forbidden':
          // A probe 403 means "may list, may not run": a warning, never a
          // rejected credential (issue 339 review 2).
          return l10n.providerProbeForbidden(
            result.modelsCount,
            warning.model ?? result.model ?? '',
          );
        case 'timeout':
          return l10n.providerProbeTimedOut(result.modelsCount);
        case 'network':
          return l10n.providerProbeNetworkFailed(result.modelsCount);
        case 'rate_limited':
          return l10n.providerProbeRateLimited(result.modelsCount);
        default:
          return l10n.providerProbeUnknownWarning(result.modelsCount);
      }
    }
    // `skipped`: the key listed models but no model is selected to probe.
    return l10n.providerKeyAcceptedNoModel(result.modelsCount);
  }
}
