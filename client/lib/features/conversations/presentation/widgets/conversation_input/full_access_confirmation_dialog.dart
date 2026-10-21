import 'package:flutter/material.dart';
import 'package:sanad_client/l10n/app_localizations.dart';

/// Confirmation shown once, before a workspace moves from Default to Full
/// Access. Turning Full Access off never shows it, and no banner persists
/// after it is accepted. It changes neither execution mode nor discovery.
class FullAccessConfirmationDialog extends StatelessWidget {
  const FullAccessConfirmationDialog({super.key});

  /// Returns true only when the user chooses Turn On.
  static Future<bool> show(BuildContext context) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (_) => const FullAccessConfirmationDialog(),
    );
    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final bodyStyle = theme.textTheme.bodyMedium?.copyWith(height: 1.4);

    return AlertDialog(
      key: const Key('full_access_confirmation_dialog'),
      title: Text(l10n.fullAccessDialogTitle),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.fullAccessDialogIntro, style: bodyStyle),
              const SizedBox(height: 16),
              _RiskItem(
                icon: Icons.folder_open_outlined,
                title: l10n.fullAccessDialogFilesTitle,
                body: l10n.fullAccessDialogFilesBody,
              ),
              _RiskItem(
                icon: Icons.terminal_outlined,
                title: l10n.fullAccessDialogTerminalTitle,
                body: l10n.fullAccessDialogTerminalBody,
              ),
              _RiskItem(
                icon: Icons.public_outlined,
                title: l10n.fullAccessDialogNetworkTitle,
                body: l10n.fullAccessDialogNetworkBody,
              ),
              const SizedBox(height: 4),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colorScheme.errorContainer.withValues(alpha: 0.25),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: colorScheme.error.withValues(alpha: 0.3),
                  ),
                ),
                child: Text(l10n.fullAccessDialogWarning, style: bodyStyle),
              ),
              const SizedBox(height: 12),
              Text(
                l10n.fullAccessDialogReversible,
                style: bodyStyle?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const Key('full_access_cancel_button'),
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          key: const Key('full_access_confirm_button'),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(l10n.fullAccessDialogConfirm),
        ),
      ],
    );
  }
}

class _RiskItem extends StatelessWidget {
  const _RiskItem({required this.icon, required this.title, required this.body});

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: theme.colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  body,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
