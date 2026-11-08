import 'package:flutter/material.dart';
import 'package:sanad_client/features/settings/data/device_settings_client.dart';
import 'package:sanad_client/l10n/app_localizations.dart';

import 'settings_widgets.dart';

/// Dictation section of the device settings page.
///
/// It renders the daemon's own projection (`dictation` in the settings
/// snapshot), so enabled state, selected model, readiness, size and the busy
/// flag always match what the composer mic reports. The section owns no runtime
/// state and never reads `config.yaml` itself.
class DictationSettingsCard extends StatelessWidget {
  const DictationSettingsCard({
    super.key,
    required this.dictation,
    required this.enabled,
    required this.onToggle,
  });

  final DictationSettingsSetting dictation;

  /// False while saving or when the owner's `config.yaml` names `stt.enabled`.
  final bool enabled;
  final ValueChanged<bool> onToggle;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final model = dictation.selectedModel;
    final reason = dictation.reason;
    final modelLabel = model == null
        ? null
        : model.labelCode == 'path_override'
        ? l10n.dictationPathOverrideModel
        : (model.label ?? model.id);

    return SettingsCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.deviceSettingsDictationTitle,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          SwitchListTile(
            key: const Key('device_settings_dictation_enabled'),
            contentPadding: EdgeInsets.zero,
            title: Text(l10n.deviceSettingsDictationEnabled),
            subtitle: Text(
              dictation.managedExternally
                  ? l10n.deviceSettingsDictationManagedExternally
                  : l10n.deviceSettingsDictationEnabledHint,
            ),
            value: dictation.enabled,
            onChanged: enabled ? onToggle : null,
          ),
          const Divider(height: 1),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.deviceSettingsDictationModel,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      modelLabel ?? l10n.deviceSettingsDictationNoModel,
                      key: const Key('device_settings_dictation_model'),
                      style: theme.textTheme.bodyMedium,
                    ),
                    if (model?.totalBytes != null && model!.totalBytes! > 0)
                      Text(
                        _formatBytes(l10n, model.totalBytes!),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              _StatusChip(
                key: const Key('device_settings_dictation_status'),
                ready: dictation.ready && reason == null,
                label: dictation.busy
                    ? l10n.deviceSettingsDictationBusy
                    : dictation.ready && reason == null
                    ? l10n.deviceSettingsDictationReady
                    : l10n.deviceSettingsDictationNotReady,
              ),
            ],
          ),
          if (reason != null) ...[
            const SizedBox(height: 8),
            Text(
              _reasonLabel(l10n, reason),
              key: const Key('device_settings_dictation_reason'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.error,
              ),
            ),
          ],
        ],
      ),
    );
  }

  static String _formatBytes(AppLocalizations l10n, int bytes) {
    const mb = 1024 * 1024;
    final value = bytes / mb;
    return value >= 1024
        ? l10n.dictationModelSizeGb((value / 1024).toStringAsFixed(1))
        : l10n.dictationModelSizeMb(value.toStringAsFixed(0));
  }

  static String _reasonLabel(AppLocalizations l10n, String reason) {
    // The daemon reports machine codes only. An unknown code is localized to a
    // neutral sentence rather than rendered verbatim, so a parser or config
    // message can never reach the settings page.
    return switch (reason) {
      'native_runtime_preparing' => l10n.dictationRuntimePreparing,
      'native_runtime_missing' => l10n.dictationRuntimeMissing,
      'unsupported_platform' => l10n.dictationUnsupportedPlatform,
      'dictation_disabled' => l10n.dictationDisabled,
      'model_not_installed' => l10n.dictationModelRequired,
      'config_invalid' => l10n.dictationUnavailable,
      _ => l10n.dictationUnavailable,
    };
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({super.key, required this.ready, required this.label});

  final bool ready;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final color = ready ? colorScheme.primary : colorScheme.error;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
