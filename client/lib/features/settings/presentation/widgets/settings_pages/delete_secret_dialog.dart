import 'package:flutter/material.dart';
import 'package:sanad_client/features/settings/data/secrets_client.dart';
import 'package:sanad_client/features/settings/presentation/bloc/secrets_cubit.dart';
import 'package:sanad_client/l10n/app_localizations.dart';

import 'secrets_failure_text.dart';

/// Confirmation for `secret.delete` (Task 140 C2, K5).
///
/// The dialog names the secret and states that deletion is permanent. The
/// protocol requires `confirm: true`; [SecretsCubit.delete] always sends it, so
/// this dialog is the only place a user can authorize the mutation.
class DeleteSecretDialog extends StatefulWidget {
  const DeleteSecretDialog({super.key, required this.cubit, required this.name});

  final SecretsCubit cubit;
  final String name;

  /// Opens the dialog and reports whether the secret is gone.
  static Future<bool?> show(
    BuildContext context, {
    required SecretsCubit cubit,
    required String name,
  }) => showDialog<bool>(
    context: context,
    builder: (_) => DeleteSecretDialog(cubit: cubit, name: name),
  );

  @override
  State<DeleteSecretDialog> createState() => _DeleteSecretDialogState();
}

class _DeleteSecretDialogState extends State<DeleteSecretDialog> {
  bool _deleting = false;
  String? _failureText;

  Future<void> _confirm() async {
    if (_deleting) return;
    setState(() {
      _deleting = true;
      _failureText = null;
    });

    final outcome = await widget.cubit.delete(widget.name);
    if (!mounted) return;

    // `not_found` means the row is already gone, which is the outcome the user
    // asked for; neither branch may claim a success the Agent did not report.
    if (outcome == SecretsActionOutcome.success || outcome == SecretsActionOutcome.notFound) {
      Navigator.of(context).pop(true);
      return;
    }

    final l10n = AppLocalizations.of(context)!;
    setState(() {
      _deleting = false;
      _failureText =
          secretsFailureText(l10n, widget.cubit.state.failure?.code ?? SecretsErrorCode.unknown) ??
          l10n.secretsDeleteFailed;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colorScheme = Theme.of(context).colorScheme;
    return AlertDialog(
      key: const Key('secret_delete_dialog'),
      title: Text(l10n.deleteSecret),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.deleteSecretConfirm(widget.name)),
          if (_failureText != null) ...[
            const SizedBox(height: 12),
            Text(
              _failureText!,
              key: const Key('secret_delete_error'),
              style: TextStyle(color: colorScheme.error, fontSize: 12),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          key: const Key('secret_delete_cancel_btn'),
          onPressed: _deleting ? null : () => Navigator.of(context).pop(false),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          key: const Key('secret_delete_confirm_btn'),
          style: FilledButton.styleFrom(
            backgroundColor: colorScheme.error,
            foregroundColor: colorScheme.onError,
          ),
          onPressed: _deleting ? null : _confirm,
          child: Text(l10n.secretDeleteConfirmBtn),
        ),
      ],
    );
  }
}
