import 'package:flutter/material.dart';
import 'package:sanad_client/features/conversations/domain/models/turn_replay_result.dart';

class TurnReplayConfirmationDialog extends StatelessWidget {
  final TurnReplayAction action;
  final TurnReplaySafety safety;
  final bool confirmsUnsafe;
  final bool confirmsSteerDrop;

  const TurnReplayConfirmationDialog({
    required this.action,
    required this.safety,
    required this.confirmsUnsafe,
    required this.confirmsSteerDrop,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final warnings = <String>[
      if (confirmsUnsafe)
        safety == TurnReplaySafety.unknown
            ? 'Sanad cannot verify whether this turn’s tools are safe to repeat. Continuing may repeat changes to files or external systems.'
            : 'This turn used tools that may change files or external systems. Continuing can repeat those side effects.',
      if (confirmsSteerDrop)
        'This turn includes steering messages. Continuing will not send those follow-up directions again.',
    ];
    return AlertDialog(
      title: Text(action == TurnReplayAction.edit ? 'Edit and rerun this turn?' : 'Retry this turn?'),
      content: Text(warnings.join('\n\n')),
      actions: [
        TextButton(
          key: const Key('turn_replay_cancel_button'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('turn_replay_confirm_button'),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Continue'),
        ),
      ],
    );
  }
}
