import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:sanad_client/features/settings/presentation/widgets/settings_widgets.dart';
import 'package:sanad_client/l10n/app_localizations.dart';

import '../../domain/models/client_cli_settings.dart';
import '../bloc/client_cli_cubit.dart';

class ClientCliSettingsCard extends StatelessWidget {
  const ClientCliSettingsCard({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return BlocBuilder<ClientCliCubit, ClientCliSettings>(
      builder: (context, settings) {
        return SettingsCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.clientCli,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          l10n.clientCliDescription,
                          style: TextStyle(
                            color: colorScheme.onSurfaceVariant,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  Switch(
                    key: const Key('client_cli_toggle_switch'),
                    value: settings.enabled,
                    onChanged: (value) {
                      unawaited(context.read<ClientCliCubit>().setEnabled(value));
                    },
                  ),
                ],
              ),
              if (settings.enabled) ...[
                const SizedBox(height: 16),
                const Divider(height: 1),
                const SizedBox(height: 16),
                Text(
                  l10n.clientCliPermissionMode,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<String>(
                    key: const Key('client_cli_permission_mode_selector'),
                    selected: {settings.permissionMode},
                    onSelectionChanged: (selected) {
                      if (selected.isNotEmpty) {
                        unawaited(context.read<ClientCliCubit>().setPermissionMode(selected.first));
                      }
                    },
                    segments: [
                      ButtonSegment<String>(
                        value: ClientCliSettings.defaultMode,
                        label: Text(
                          l10n.clientCliDefaultMode,
                          key: const Key('client_cli_mode_default'),
                        ),
                        icon: const Icon(Icons.shield_outlined),
                      ),
                      ButtonSegment<String>(
                        value: ClientCliSettings.fullAccessMode,
                        label: Text(
                          l10n.clientCliFullAccessMode,
                          key: const Key('client_cli_mode_full_access'),
                        ),
                        icon: const Icon(Icons.bolt_outlined),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  settings.permissionMode == ClientCliSettings.defaultMode
                      ? l10n.clientCliDefaultModeDesc
                      : l10n.clientCliFullAccessModeDesc,
                  style: TextStyle(
                    color: colorScheme.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}
