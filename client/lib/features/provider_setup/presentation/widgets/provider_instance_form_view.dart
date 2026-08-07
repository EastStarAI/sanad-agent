import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:sanad_client/features/provider_setup/data/models/provider_instance_dto.dart';
import 'package:sanad_client/features/provider_setup/data/models/provider_template_dto.dart';
import 'package:sanad_client/features/provider_setup/presentation/bloc/provider_setup_cubit.dart';
import 'package:sanad_client/features/provider_setup/presentation/bloc/provider_setup_state.dart';
import 'package:sanad_client/features/provider_setup/presentation/widgets/provider_setup_step_scaffold.dart';

const _supportedProviderProtocols = [
  'openai_compatible',
  'anthropic_compatible',
];

String _protocolDisplayName(String protocol) => switch (protocol) {
  'openai_compatible' => 'OpenAI API Compatible',
  'anthropic_compatible' => 'Anthropic API Compatible',
  _ => protocol,
};

class ProviderInstanceFormView extends StatefulWidget {
  const ProviderInstanceFormView({
    super.key,
    this.globalAutoFailoverEnabled = true,
  });

  final bool globalAutoFailoverEnabled;

  @override
  State<ProviderInstanceFormView> createState() => _ProviderInstanceFormViewState();
}

class _ProviderInstanceFormViewState extends State<ProviderInstanceFormView> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _displayNameController;
  late final TextEditingController _baseUrlController;
  late final TextEditingController _newKeyController;
  late String _authMethod;
  late String _protocol;
  String _credentialAction = 'keep';
  late bool _allowAutoFailover;
  bool _showCredentialActions = false;
  bool _obscureKey = true;

  @override
  void initState() {
    super.initState();
    final cubit = context.read<ProviderSetupCubit>();
    final state = cubit.state;
    final instance = state.selectedInstance;
    final template = state.selectedTemplate;
    _displayNameController = TextEditingController(
      text: cubit.draftDisplayName ?? instance?.displayName ?? _suggestUniqueDisplayName(state, template, instance?.id),
    );
    _baseUrlController = TextEditingController(
      text: cubit.draftBaseUrl ?? instance?.baseUrl ?? template?.defaultBaseUrl ?? '',
    );
    _newKeyController = TextEditingController(text: cubit.draftApiKey);
    _authMethod = instance?.authMethod ?? template?.effectiveAuthMethods.firstOrNull ?? 'api_key';
    _protocol = cubit.draftProtocol ?? instance?.protocol ?? template?.protocol ?? 'openai_compatible';
    _allowAutoFailover = cubit.draftAllowAutoFailover ?? instance?.allowAutoFailover ?? true;
  }

  @override
  void dispose() {
    _displayNameController.dispose();
    _baseUrlController.dispose();
    _newKeyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<ProviderSetupCubit, ProviderSetupState>(
      builder: (context, state) {
        final template = state.selectedTemplate;
        final selected = state.selectedInstance;
        final isEdit = selected != null && state.provisionalInstanceId != selected.id;
        final isCustom = template?.name == 'custom';
        final saving = state.operation == ProviderSetupOperation.savingDetails;

        return Form(
          key: _formKey,
          child: ProviderSetupStepScaffold(
            body: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  isEdit ? 'Edit Provider Instance' : 'Add ${template?.displayName ?? 'Provider'}',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 20),
                TextFormField(
                  key: const Key('provider_display_name_field'),
                  controller: _displayNameController,
                  decoration: const InputDecoration(
                    labelText: 'Display Name',
                    hintText: 'e.g. Work OpenAI Account',
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return 'Please enter a display name';
                    }
                    final normalized = value.trim().toLowerCase();
                    final duplicate = state.instances.any(
                      (instance) =>
                          instance.id != selected?.id && instance.displayName.trim().toLowerCase() == normalized,
                    );
                    return duplicate ? 'This display name is already in use' : null;
                  },
                ),
                const SizedBox(height: 24),
                Text(
                  'Connection',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  isEdit
                      ? 'Connection settings are fixed after setup.'
                      : 'Confirm how Sanad connects to this provider.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                if (isEdit)
                  _ReadOnlyConnectionValue(
                    label: 'Base URL',
                    value: selected.baseUrl ?? 'Provider default',
                  )
                else
                  TextFormField(
                    key: const Key('provider_base_url_field'),
                    controller: _baseUrlController,
                    decoration: const InputDecoration(
                      labelText: 'Base URL',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.link),
                    ),
                    validator: (value) =>
                        isCustom && (value == null || value.trim().isEmpty) ? 'Please enter a base URL' : null,
                  ),
                const SizedBox(height: 12),
                if (!isEdit && isCustom)
                  DropdownButtonFormField<String>(
                    key: const Key('provider_protocol_field'),
                    initialValue: _protocol,
                    decoration: const InputDecoration(
                      labelText: 'Protocol',
                      border: OutlineInputBorder(),
                    ),
                    items: _supportedProviderProtocols
                        .map(
                          (protocol) => DropdownMenuItem(
                            value: protocol,
                            child: Text(_protocolDisplayName(protocol)),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value != null) setState(() => _protocol = value);
                    },
                  )
                else
                  _ReadOnlyConnectionValue(
                    label: 'Protocol',
                    value: _protocolDisplayName(
                      selected?.protocol ?? _protocol,
                    ),
                  ),
                if (!isEdit && _authMethod == 'api_key') ...[
                  const SizedBox(height: 20),
                  TextFormField(
                    key: const Key('provider_api_key_field'),
                    controller: _newKeyController,
                    obscureText: _obscureKey,
                    decoration: InputDecoration(
                      labelText: template?.isApiKeyOptional == true ? 'API Key (optional)' : 'API Key',
                      border: const OutlineInputBorder(),
                      prefixIcon: const Icon(Icons.vpn_key_outlined),
                      suffixIcon: IconButton(
                        onPressed: () => setState(() => _obscureKey = !_obscureKey),
                        icon: Icon(
                          _obscureKey ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                        ),
                      ),
                    ),
                    validator: (value) {
                      if (template?.isApiKeyOptional != true && (value == null || value.trim().isEmpty)) {
                        return 'Please enter an API key';
                      }
                      return null;
                    },
                  ),
                ],
                if (isEdit) ...[
                  const SizedBox(height: 24),
                  _buildCredentialSection(state),
                  const SizedBox(height: 24),
                  Text(
                    'Default Model',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  _ReadOnlyConnectionValue(
                    label: 'Current model',
                    value: selected.defaultModel ?? 'Not selected',
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      key: const Key('change_provider_model_button'),
                      onPressed: saving ? null : () => _changeModel(selected),
                      icon: const Icon(Icons.swap_horiz),
                      label: const Text('Change Model'),
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                Text(
                  'Reliability',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                SwitchListTile.adaptive(
                  key: const Key('provider_auto_failover_switch'),
                  contentPadding: EdgeInsets.zero,
                  value: _allowAutoFailover,
                  activeThumbColor: Theme.of(context).colorScheme.error,
                  activeTrackColor: Theme.of(context).colorScheme.error.withValues(alpha: 0.35),
                  title: const Text('Allow automatic failover'),
                  subtitle: widget.globalAutoFailoverEnabled
                      ? null
                      : const Text(
                          'Global auto failover is off. This preference is preserved.',
                        ),
                  onChanged: widget.globalAutoFailoverEnabled
                      ? (value) => setState(
                          () => _allowAutoFailover = value,
                        )
                      : null,
                ),
                Padding(
                  key: const Key('provider_auto_failover_warning'),
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.warning_amber_rounded,
                        size: 20,
                        color: Theme.of(context).colorScheme.error,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'When enabled, Sanad may automatically use this provider if another provider fails.',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (isEdit) ...[
                  const SizedBox(height: 24),
                  Text(
                    'Danger Zone',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      key: const Key('delete_provider_from_edit_button'),
                      onPressed: saving ? null : () => _deleteSelected(selected),
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('Delete Provider'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                ],
                if (state.error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    state.error!,
                    key: const Key('provider_form_error'),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
            footer: Row(
              children: [
                TextButton(
                  onPressed: saving ? null : () => _cancel(context),
                  child: const Text('Cancel'),
                ),
                const Spacer(),
                FilledButton(
                  key: const Key('provider_form_submit'),
                  onPressed: saving ? null : _submit,
                  child: Text(
                    saving ? 'Saving...' : (isEdit ? 'Save changes' : 'Continue'),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildCredentialSection(ProviderSetupState state) {
    final instance = state.selectedInstance!;
    final credential = instance.credential;
    final isApiKey = instance.authMethod == 'api_key';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Credential', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        if (isApiKey)
          _ReadOnlyConnectionValue(
            label: 'Stored API Key',
            value: credential?.maskedSecret ?? (credential?.hasSecret == true ? 'Stored securely' : 'Not set'),
          )
        else ...[
          _ReadOnlyConnectionValue(
            label: 'Connected Account',
            value: credential?.accountLabel ?? (credential?.hasSecret == true ? 'Connected' : 'Disconnected'),
          ),
          if (credential?.accountName != null && credential!.accountName != credential.accountLabel) ...[
            const SizedBox(height: 8),
            _ReadOnlyConnectionValue(
              label: 'Account Name',
              value: credential.accountName!,
            ),
          ],
        ],
        const SizedBox(height: 8),
        if (isApiKey && !_showCredentialActions)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => setState(() => _showCredentialActions = true),
              icon: const Icon(Icons.key),
              label: Text(
                credential?.hasSecret == true ? 'Replace or remove key' : 'Add API Key',
              ),
            ),
          ),
        if (isApiKey && _showCredentialActions) ...[
          DropdownButtonFormField<String>(
            initialValue: _credentialAction,
            decoration: const InputDecoration(
              labelText: 'Credential Action',
              border: OutlineInputBorder(),
            ),
            items: [
              DropdownMenuItem(
                value: 'keep',
                child: Text(
                  credential?.hasSecret == true ? 'Keep existing' : 'Keep as-is (no key stored)',
                ),
              ),
              const DropdownMenuItem(
                value: 'replace',
                child: Text('Replace with new key'),
              ),
              if (credential?.hasSecret == true)
                const DropdownMenuItem(
                  value: 'remove',
                  child: Text('Remove credential'),
                ),
            ],
            onChanged: (value) {
              if (value != null) setState(() => _credentialAction = value);
            },
          ),
          if (_credentialAction == 'replace') ...[
            const SizedBox(height: 12),
            TextFormField(
              controller: _newKeyController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'New API Key',
                border: OutlineInputBorder(),
              ),
              validator: (value) => _credentialAction == 'replace' && (value == null || value.trim().isEmpty)
                  ? 'Please enter a new API key'
                  : null,
            ),
          ],
        ],
        if (!isApiKey)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => _reconnect(instance),
              icon: const Icon(Icons.login),
              label: const Text('Reconnect account'),
            ),
          ),
      ],
    );
  }

  Future<void> _cancel(BuildContext context) async {
    final cubit = context.read<ProviderSetupCubit>();
    if (cubit.state.provisionalInstanceId == null) {
      final instance = cubit.state.selectedInstance;
      if (instance != null && _hasUnsavedEdits(instance) && !await _confirmDiscardChanges()) {
        return;
      }
      instance == null ? cubit.backToPicker() : cubit.backToInstances();
      return;
    }
    final discard = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Discard provider setup?'),
        content: const Text(
          'This removes the incomplete provider created by this setup attempt.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Keep setup'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (discard == true && context.mounted) {
      await cubit.discardProvisionalSetup();
    }
  }

  bool _hasUnsavedEdits(ProviderInstanceDto instance) {
    return _displayNameController.text.trim() != instance.displayName ||
        _allowAutoFailover != instance.allowAutoFailover ||
        _credentialAction != 'keep' ||
        _newKeyController.text.trim().isNotEmpty;
  }

  Future<bool> _confirmDiscardChanges() async {
    final discard = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Discard changes?'),
        content: const Text('Your unsaved provider changes will be lost.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Keep editing'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Discard changes'),
          ),
        ],
      ),
    );
    return discard == true;
  }

  Future<void> _changeModel(ProviderInstanceDto instance) async {
    if (_hasUnsavedEdits(instance) && !await _confirmDiscardChanges()) return;
    if (!mounted) return;
    await context.read<ProviderSetupCubit>().changeSelectedInstanceModel();
  }

  Future<void> _reconnect(ProviderInstanceDto instance) async {
    if (_hasUnsavedEdits(instance) && !await _confirmDiscardChanges()) return;
    if (!mounted) return;
    await context.read<ProviderSetupCubit>().reconnectInstance(instance);
  }

  Future<void> _deleteSelected(ProviderInstanceDto instance) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete Provider?'),
        content: Text(
          instance.isDefault
              ? 'This is the default provider. Deleting it may stop model requests until another ready provider is made default.'
              : 'Delete “${instance.displayName}” and its stored credentials?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await context.read<ProviderSetupCubit>().removeInstance(instance.id);
    }
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    if (_credentialAction == 'remove') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Remove API key?'),
          content: const Text(
            'The provider will stop working until a new credential is added.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Remove'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    final cubit = context.read<ProviderSetupCubit>();
    final baseUrl = _baseUrlController.text.trim();
    final apiKey = _newKeyController.text.trim();
    cubit.rememberDraft(
      displayName: _displayNameController.text.trim(),
      protocol: _protocol,
      baseUrl: baseUrl.isEmpty ? null : baseUrl,
      apiKey: apiKey.isEmpty ? null : apiKey,
      allowAutoFailover: _allowAutoFailover,
    );
    unawaited(
      cubit.createOrUpdateInstance(
        displayName: _displayNameController.text.trim(),
        authMethod: _authMethod,
        protocol: _protocol,
        baseUrl: baseUrl.isEmpty ? null : baseUrl,
        allowAutoFailover: _allowAutoFailover,
        credentialAction: _credentialAction,
        newApiKey: apiKey.isEmpty ? null : apiKey,
      ),
    );
  }

  String _suggestUniqueDisplayName(
    ProviderSetupState state,
    ProviderTemplateDto? template,
    String? currentInstanceId,
  ) {
    final base = (template?.displayName ?? template?.name ?? 'Provider').trim();
    final names = state.instances
        .where((instance) => instance.id != currentInstanceId)
        .map((instance) => instance.displayName.trim().toLowerCase())
        .toSet();
    if (!names.contains(base.toLowerCase())) return base;
    var suffix = 2;
    while (names.contains('$base $suffix'.toLowerCase())) {
      suffix++;
    }
    return '$base $suffix';
  }
}

class _ReadOnlyConnectionValue extends StatelessWidget {
  const _ReadOnlyConnectionValue({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        border: Border.all(
          color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.55),
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelSmall),
          const SizedBox(height: 2),
          SelectableText(value),
        ],
      ),
    );
  }
}
