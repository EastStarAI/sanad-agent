import 'package:flutter/material.dart';
import 'package:sanad_client/features/settings/data/secrets_client.dart';
import 'package:sanad_client/features/settings/presentation/bloc/secrets_cubit.dart';
import 'package:sanad_client/l10n/app_localizations.dart';

import 'secrets_failure_text.dart';

/// The Add / Replace dialog for one stored secret (Task 140 C2, K3, K4).
///
/// The submitted value lives only in [_valueController]: it is not a widget
/// field, it is cleared before the request is awaited (on submit and on
/// cancel), and it is handed straight to [SecretsCubit.set]. Replace mode opens
/// with an empty value field, so no surface can pre-fill, preview, or reveal
/// the stored value; the name is read-only because replacing never renames.
class SecretEditorDialog extends StatefulWidget {
  const SecretEditorDialog({super.key, required this.cubit, this.secret});

  final SecretsCubit cubit;

  /// `null` adds a new secret; a value opens this same form in Replace mode.
  final StoredSecret? secret;

  /// Opens the dialog and reports whether the Agent accepted the mutation.
  static Future<bool?> show(
    BuildContext context, {
    required SecretsCubit cubit,
    StoredSecret? secret,
  }) => showDialog<bool>(
    context: context,
    builder: (_) => SecretEditorDialog(cubit: cubit, secret: secret),
  );

  @override
  State<SecretEditorDialog> createState() => _SecretEditorDialogState();
}

class _SecretEditorDialogState extends State<SecretEditorDialog> {
  final _nameController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _valueController = TextEditingController();

  bool _showValue = false;
  bool _saving = false;
  String? _nameError;
  String? _valueError;
  String? _failureText;

  bool get _isReplace => widget.secret != null;

  @override
  void initState() {
    super.initState();
    final secret = widget.secret;
    if (secret == null) return;
    _nameController.text = secret.name;
    _descriptionController.text = secret.description ?? '';
    // The value field starts empty in every mode: there is nothing to read.
  }

  @override
  void dispose() {
    _valueController.clear();
    _valueController.dispose();
    _nameController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    final l10n = AppLocalizations.of(context)!;
    final name = _isReplace ? widget.secret!.name : _nameController.text.trim();
    final description = _descriptionController.text.trim();
    final value = _valueController.text;

    final nameError = _isReplace || SecretsClient.isValidNameFormat(name) ? null : l10n.secretInvalidName;
    final valueError = value.isEmpty
        ? l10n.secretValueRequired
        : value.length > SecretsClient.maxValueLength
        ? l10n.secretValueTooLong(SecretsClient.maxValueLength)
        : null;

    if (nameError != null || valueError != null) {
      setState(() {
        _nameError = nameError;
        _valueError = valueError;
        _failureText = null;
      });
      return;
    }

    setState(() {
      _nameError = null;
      _valueError = null;
      _failureText = null;
      _saving = true;
    });
    // The value does not outlive the request that carries it.
    _valueController.clear();

    final outcome = await widget.cubit.set(
      name: name,
      value: value,
      description: description.isEmpty ? null : description,
    );
    if (!mounted) return;

    if (outcome == SecretsActionOutcome.success) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _saving = false;
      _failureText = _failureMessage(l10n);
    });
  }

  void _cancel() {
    _valueController.clear();
    Navigator.of(context).pop(false);
  }

  String _failureMessage(AppLocalizations l10n) {
    final code = widget.cubit.state.failure?.code ?? SecretsErrorCode.unknown;
    return secretsFailureText(l10n, code) ?? l10n.secretsSaveFailed;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return AlertDialog(
      key: const Key('secret_editor_dialog'),
      title: Text(_isReplace ? l10n.replaceSecret : l10n.addSecret),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                key: const Key('secret_name_input'),
                controller: _nameController,
                autofocus: !_isReplace,
                readOnly: _isReplace,
                autocorrect: false,
                enableSuggestions: false,
                textDirection: TextDirection.ltr,
                decoration: InputDecoration(
                  labelText: l10n.secretName,
                  errorText: _nameError,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('secret_description_input'),
                controller: _descriptionController,
                maxLength: SecretsClient.maxDescriptionLength,
                decoration: InputDecoration(
                  labelText: _isReplace ? l10n.secretDescription : l10n.secretDescriptionOptional,
                ),
              ),
              const SizedBox(height: 4),
              TextField(
                key: const Key('secret_value_input'),
                controller: _valueController,
                obscureText: !_showValue,
                enableSuggestions: false,
                autocorrect: false,
                enableIMEPersonalizedLearning: false,
                keyboardType: TextInputType.visiblePassword,
                textDirection: TextDirection.ltr,
                onSubmitted: (_) => _save(),
                decoration: InputDecoration(
                  labelText: l10n.secretValue,
                  hintText: l10n.secretValueHint,
                  errorText: _valueError,
                  suffixIcon: IconButton(
                    key: const Key('secret_value_toggle'),
                    tooltip: _showValue ? l10n.secretValueHide : l10n.secretValueShow,
                    icon: Icon(
                      _showValue ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                      size: 18,
                    ),
                    onPressed: () => setState(() => _showValue = !_showValue),
                  ),
                ),
              ),
              if (_isReplace) ...[
                const SizedBox(height: 8),
                Text(
                  l10n.replaceSecretNote,
                  key: const Key('secret_replace_note'),
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
              ],
              if (_failureText != null) ...[
                const SizedBox(height: 12),
                Text(
                  _failureText!,
                  key: const Key('secret_editor_error'),
                  style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const Key('secret_cancel_btn'),
          onPressed: _saving ? null : _cancel,
          child: Text(l10n.cancel),
        ),
        FilledButton(
          key: const Key('secret_save_btn'),
          onPressed: _saving ? null : _save,
          child: Text(l10n.saveSecret),
        ),
      ],
    );
  }
}
