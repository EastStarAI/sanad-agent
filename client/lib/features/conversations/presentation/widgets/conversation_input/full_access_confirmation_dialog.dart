import 'package:flutter/material.dart';

/// One-time confirmation dialog presented before enabling Full Access on a workspace.
///
/// Under Plan 83 (Task 83h / Gate H1), this dialog clearly explains the risks of
/// running privileged operations without per-action approval prompts.
class FullAccessConfirmationDialog extends StatelessWidget {
  const FullAccessConfirmationDialog({super.key});

  /// Displays the dialog and returns true if confirmed ('Turn On'), false otherwise.
  static Future<bool> show(BuildContext context) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) => const FullAccessConfirmationDialog(),
    );
    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return AlertDialog(
      title: Text(
        'Turn on Full Access?',
        style: theme.textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w600,
        ),
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Full Access lets Sanad act in this workspace without asking before each operation. It may:',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurface,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 16),
              _buildRiskItem(
                context,
                icon: Icons.folder_open_outlined,
                title: 'Access files and folders',
                description:
                    'Read, create, modify, upload, or delete files available to your user account.',
              ),
              const SizedBox(height: 12),
              _buildRiskItem(
                context,
                icon: Icons.terminal_outlined,
                title: 'Run terminal commands',
                description:
                    'Execute commands, install software, and change system or development settings.',
              ),
              const SizedBox(height: 12),
              _buildRiskItem(
                context,
                icon: Icons.public_outlined,
                title: 'Use the internet and connected tools',
                description:
                    'Access websites, send data, and use enabled tools and plugins.',
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colorScheme.errorContainer.withValues(alpha: 0.25),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: colorScheme.error.withValues(alpha: 0.3),
                  ),
                ),
                child: Text(
                  'Commands run with your operating-system account and may access sensitive files or credentials available to that account. Malicious instructions or prompt injection could cause data loss or exposure.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.error,
                    height: 1.4,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    'You can turn Full Access off at any time.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 4),
                  InkWell(
                    onTap: () {
                      // Informational link placeholder; does not impede confirmation
                    },
                    borderRadius: BorderRadius.circular(4),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
                      child: Text(
                        'Learn more',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.primary,
                          decoration: TextDecoration.underline,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const Key('cancel_full_access_button'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('confirm_turn_on_full_access'),
          style: FilledButton.styleFrom(
            backgroundColor: colorScheme.primary,
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Turn On'),
        ),
      ],
    );
  }

  Widget _buildRiskItem(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String description,
  }) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: colorScheme.primary),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                description,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
