import 'package:flutter/material.dart';
import 'package:sanad_client/features/provider_setup/data/models/provider_instance_test_result_dto.dart';
import 'package:sanad_client/features/provider_setup/presentation/widgets/provider_discovery_notice.dart';
import 'package:sanad_client/l10n/app_localizations.dart';

/// Renders one connection-test outcome on the instance card (issue 339).
///
/// A pass names what was proven — the verified model count and the generation
/// probe's model and round-trip time. A failure renders the same localized
/// category message every other provider surface uses.
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
      final l10n = AppLocalizations.of(context)!;
      final seconds = result.latencySeconds;
      final summary = seconds == null
          ? l10n.providerTestWorks(result.modelsCount)
          : l10n.providerTestWorksWithProbe(
              result.modelsCount,
              result.model ?? '',
              seconds,
            );
      return Padding(
        key: Key('provider_test_result_$instanceId'),
        padding: const EdgeInsets.only(top: 8),
        child: Text(
          summary,
          style: const TextStyle(
            fontSize: 12,
            color: Colors.green,
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
    );
  }
}
