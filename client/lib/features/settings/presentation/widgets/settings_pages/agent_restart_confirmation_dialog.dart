import 'package:flutter/material.dart';

enum AgentRestartMode { safe, force }

class AgentRestartConfirmationDialog extends StatelessWidget {
  const AgentRestartConfirmationDialog({
    super.key,
    required this.deviceName,
  });

  final String deviceName;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 600;
    return AlertDialog(
      constraints: const BoxConstraints(maxWidth: 560),
      insetPadding: EdgeInsets.symmetric(
        horizontal: compact ? 16 : 40,
        vertical: 24,
      ),
      title: const Text('Restart agent'),
      content: Text(
        'Restart $deviceName? Restart waits for a safe checkpoint. Force restart '
        'may interrupt active work. The connection will drop until the agent '
        'comes back online.',
      ),
      buttonPadding: EdgeInsets.zero,
      actionsOverflowDirection: VerticalDirection.down,
      actions: [
        TextButton(
          key: const Key('dialog_cancel_restart_button'),
          style: TextButton.styleFrom(
            minimumSize: const Size(0, 48),
            padding: const EdgeInsets.symmetric(horizontal: 12),
          ),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('dialog_force_restart_button'),
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
            foregroundColor: Theme.of(context).colorScheme.onError,
            minimumSize: const Size(0, 48),
            padding: const EdgeInsets.symmetric(horizontal: 16),
          ),
          onPressed: () => Navigator.of(context).pop(AgentRestartMode.force),
          child: const Text('Force restart'),
        ),
        FilledButton(
          key: const Key('dialog_confirm_restart_button'),
          style: FilledButton.styleFrom(
            minimumSize: const Size(0, 48),
            padding: const EdgeInsets.symmetric(horizontal: 16),
          ),
          onPressed: () => Navigator.of(context).pop(AgentRestartMode.safe),
          child: const Text('Restart'),
        ),
      ],
    );
  }
}
