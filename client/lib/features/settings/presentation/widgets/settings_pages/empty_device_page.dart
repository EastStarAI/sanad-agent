import 'package:flutter/material.dart';
import 'package:sanad_client/l10n/app_localizations.dart';

class EmptyDevicePage extends StatelessWidget {
  const EmptyDevicePage({super.key});

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.devices_other_outlined, size: 52),
        const SizedBox(height: 12),
        Text(AppLocalizations.of(context)!.selectADevice, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 6),
        Text(AppLocalizations.of(context)!.deviceSettingsPlaceholder),
      ],
    ),
  );
}
