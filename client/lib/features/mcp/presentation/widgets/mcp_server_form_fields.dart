import 'package:flutter/material.dart';

import 'package:sanad_client/features/mcp/domain/models/mcp_server_config.dart';
import 'package:sanad_client/l10n/app_localizations.dart';

/// Which kind of MCP server the draft form describes.
enum McpServerFormType { remote, stdio }

/// Renders the typed draft fields of an MCP server form.
///
/// `AddMcpServerScreen` owns every controller, list, and flag of the draft;
/// this widget only renders them and reports intent through typed callbacks.
class McpServerFormFields extends StatelessWidget {
  const McpServerFormFields({
    super.key,
    required this.name,
    required this.description,
    required this.url,
    required this.command,
    required this.bearer,
    required this.oauthClientId,
    required this.oauthClientSecret,
    required this.args,
    required this.env,
    required this.headers,
    required this.serverType,
    required this.authType,
    required this.transport,
    required this.isEditing,
    required this.bearerConfigured,
    required this.oauthConfigured,
    required this.removeBearer,
    required this.obscureBearer,
    required this.obscureOAuthSecret,
    required this.onServerTypeChanged,
    required this.onTransportChanged,
    required this.onAuthTypeChanged,
    required this.onRemoveBearer,
    required this.onToggleObscureBearer,
    required this.onToggleObscureOAuthSecret,
    required this.onPasteArguments,
    required this.onAddArgument,
    required this.onRemoveArgument,
    required this.onAddEnvRow,
    required this.onAddHeaderRow,
    required this.onRowSecretToggled,
    required this.onRowRemoved,
    required this.onFieldChanged,
  });

  final TextEditingController name;
  final TextEditingController description;
  final TextEditingController url;
  final TextEditingController command;
  final TextEditingController bearer;
  final TextEditingController oauthClientId;
  final TextEditingController oauthClientSecret;
  final List<TextEditingController> args;
  final List<McpKeyValueRowState> env;
  final List<McpKeyValueRowState> headers;
  final McpServerFormType serverType;
  final McpAuthType authType;
  final McpTransportType transport;
  final bool isEditing;
  final bool bearerConfigured;
  final bool oauthConfigured;
  final bool removeBearer;
  final bool obscureBearer;
  final bool obscureOAuthSecret;
  final ValueChanged<McpServerFormType> onServerTypeChanged;
  final ValueChanged<McpTransportType> onTransportChanged;
  final ValueChanged<McpAuthType> onAuthTypeChanged;
  final VoidCallback onRemoveBearer;
  final VoidCallback onToggleObscureBearer;
  final VoidCallback onToggleObscureOAuthSecret;
  final VoidCallback onPasteArguments;
  final VoidCallback onAddArgument;
  final ValueChanged<int> onRemoveArgument;
  final VoidCallback onAddEnvRow;
  final VoidCallback onAddHeaderRow;
  final ValueChanged<McpKeyValueRowState> onRowSecretToggled;
  final ValueChanged<McpKeyValueRowState> onRowRemoved;
  final VoidCallback onFieldChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<McpServerFormType>(
          key: Key('mcp_form_segment_btn'),
          segments: [
            ButtonSegment(
              value: McpServerFormType.remote,
              label: Text(AppLocalizations.of(context)!.mcpRemoteServer),
              icon: Icon(Icons.cloud_outlined),
            ),
            ButtonSegment(
              value: McpServerFormType.stdio,
              label: Text(AppLocalizations.of(context)!.mcpLocalCommand),
              icon: Icon(Icons.terminal),
            ),
          ],
          selected: {serverType},
          onSelectionChanged: (value) => onServerTypeChanged(value.first),
        ),
        const SizedBox(height: 24),
        Text(
          AppLocalizations.of(context)!.mcpServerDetails,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 4),
        Text(
          isEditing ? AppLocalizations.of(context)!.mcpServerIdentity : AppLocalizations.of(context)!.mcpServerIdentityHint,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        _field(
          name,
          AppLocalizations.of(context)!.mcpServerName,
          key: const Key('mcp_form_name_input'),
          hint: 'e.g. Memory Server',
          prefixIcon: const Icon(Icons.badge_outlined),
          enabled: !isEditing,
          required: true,
        ),
        const SizedBox(height: 12),
        _field(
          description,
          AppLocalizations.of(context)!.mcpServerDescription,
          key: const Key('mcp_form_description_input'),
          hint: 'e.g. MCP server for persistent memory storage',
          prefixIcon: const Icon(Icons.description_outlined),
          maxLines: 2,
        ),
        const SizedBox(height: 24),
        if (serverType == McpServerFormType.remote) ..._remoteFields(context),
        if (serverType == McpServerFormType.stdio) ..._stdioFields(context),
      ],
    );
  }

  List<Widget> _remoteFields(BuildContext context) => [
    Text(
      'Connection',
      style: Theme.of(context).textTheme.titleMedium,
    ),
    const SizedBox(height: 4),
    Text(
      'Configure how Sanad connects to this remote MCP server.',
      style: Theme.of(context).textTheme.bodySmall,
    ),
    const SizedBox(height: 12),
    _field(
      url,
      'Server URL',
      key: const Key('mcp_form_url_input'),
      hint: 'https://example.com/mcp',
      prefixIcon: const Icon(Icons.link),
      required: true,
      validator: (value) {
        final uri = Uri.tryParse(value?.trim() ?? '');
        return uri != null && (uri.scheme == 'http' || uri.scheme == 'https') ? null : 'Enter an HTTP or HTTPS URL';
      },
    ),
    const SizedBox(height: 12),
    DropdownButtonFormField<McpTransportType>(
      initialValue: transport,
      decoration: const InputDecoration(
        labelText: 'Transport',
        border: OutlineInputBorder(),
        prefixIcon: Icon(Icons.swap_calls_outlined),
      ),
      items: const [
        McpTransportType.auto,
        McpTransportType.streamableHttp,
        McpTransportType.sse,
      ].map((value) => DropdownMenuItem(value: value, child: Text(value.displayName))).toList(growable: false),
      onChanged: (value) => onTransportChanged(value ?? McpTransportType.auto),
    ),
    const SizedBox(height: 24),
    Text(
      'Credentials',
      style: Theme.of(context).textTheme.titleMedium,
    ),
    const SizedBox(height: 4),
    Text(
      'Select and configure credentials for this server.',
      style: Theme.of(context).textTheme.bodySmall,
    ),
    const SizedBox(height: 12),
    DropdownButtonFormField<McpAuthType>(
      initialValue: authType,
      decoration: const InputDecoration(
        labelText: 'Authentication',
        border: OutlineInputBorder(),
        prefixIcon: Icon(Icons.security_outlined),
      ),
      items: McpAuthType.values.map((value) => DropdownMenuItem(value: value, child: Text(value.displayName))).toList(),
      onChanged: (value) => onAuthTypeChanged(value ?? McpAuthType.none),
    ),
    if (authType == McpAuthType.bearer) ...[
      const SizedBox(height: 12),
      if (bearerConfigured && !removeBearer)
        _configuredSecret(
          context,
          'Bearer token',
          onRemove: onRemoveBearer,
        ),
      _field(
        bearer,
        bearerConfigured ? 'Replace bearer token' : 'Bearer token',
        hint: 'Enter token string',
        prefixIcon: const Icon(Icons.vpn_key_outlined),
        obscure: obscureBearer,
        isObscured: obscureBearer,
        onToggleObscure: onToggleObscureBearer,
      ),
    ],
    if (authType == McpAuthType.oauth) ...[
      const SizedBox(height: 12),
      _field(
        oauthClientId,
        'OAuth client ID (optional)',
        hint: 'e.g. client_12345',
        prefixIcon: const Icon(Icons.badge_outlined),
      ),
      const SizedBox(height: 12),
      if (oauthConfigured)
        _configuredSecret(
          context,
          'OAuth credentials',
          onRemove: () {},
        ),
      _field(
        oauthClientSecret,
        'Replace OAuth client secret (optional)',
        hint: 'Enter client secret',
        prefixIcon: const Icon(Icons.vpn_key_outlined),
        obscure: obscureOAuthSecret,
        isObscured: obscureOAuthSecret,
        onToggleObscure: onToggleObscureOAuthSecret,
      ),
    ],
    if (authType == McpAuthType.customHeaders) ...[
      const SizedBox(height: 24),
      Text('Headers', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
      const SizedBox(height: 8),
      ..._rows(headers),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: onAddHeaderRow,
          icon: const Icon(Icons.add),
          label: const Text('Add header'),
        ),
      ),
    ],
  ];

  List<Widget> _stdioFields(BuildContext context) => [
    Text(
      'Local Command',
      style: Theme.of(context).textTheme.titleMedium,
    ),
    const SizedBox(height: 4),
    Text(
      'Specify the executable command to run locally.',
      style: Theme.of(context).textTheme.bodySmall,
    ),
    const SizedBox(height: 12),
    _field(
      command,
      'Command',
      key: const Key('mcp_form_command_input'),
      hint: 'e.g. npx, uvx, python, or node',
      prefixIcon: const Icon(Icons.terminal_outlined),
      required: true,
    ),
    const SizedBox(height: 24),
    Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Arguments', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              Text('Command line arguments passed to the process.', style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
        TextButton.icon(
          onPressed: onPasteArguments,
          icon: const Icon(Icons.content_paste, size: 16),
          label: const Text('Paste'),
        ),
      ],
    ),
    const SizedBox(height: 12),
    ...args.asMap().entries.map(
      (entry) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          children: [
            Expanded(
              child: _field(
                entry.value,
                'Argument ${entry.key + 1}',
                hint: 'e.g. -y or @modelcontextprotocol/server',
                prefixIcon: const Icon(Icons.code_outlined),
                isDense: true,
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              tooltip: 'Remove argument',
              onPressed: () => onRemoveArgument(entry.key),
              icon: const Icon(Icons.remove_circle_outline),
            ),
          ],
        ),
      ),
    ),
    Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        onPressed: onAddArgument,
        icon: const Icon(Icons.add),
        label: const Text('Add argument'),
      ),
    ),
    const SizedBox(height: 24),
    Text('Environment variables', style: Theme.of(context).textTheme.titleMedium),
    const SizedBox(height: 4),
    Text('Set environment variables for the subprocess.', style: Theme.of(context).textTheme.bodySmall),
    const SizedBox(height: 12),
    ..._rows(env),
    Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        onPressed: onAddEnvRow,
        icon: const Icon(Icons.add),
        label: const Text('Add variable'),
      ),
    ),
  ];

  List<Widget> _rows(List<McpKeyValueRowState> rows) => rows
      .where((row) => !row.removed)
      .map(
        (row) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final fields = [
                Expanded(
                  child: _field(
                    row.key,
                    'Key',
                    hint: 'KEY_NAME',
                    prefixIcon: const Icon(Icons.label_outline, size: 18),
                    isDense: true,
                    required: row.value.text.isNotEmpty || row.configured,
                  ),
                ),
                const SizedBox(width: 8, height: 8),
                Expanded(
                  child: _field(
                    row.value,
                    row.configured ? 'Configured — enter replacement' : 'Value',
                    hint: 'value',
                    prefixIcon: Icon(row.secret ? Icons.lock_outline : Icons.text_fields_outlined, size: 18),
                    isDense: true,
                    obscure: row.secret,
                  ),
                ),
                const SizedBox(width: 4),
                IconButton(
                  tooltip: row.secret ? 'Secret value' : 'Visible value',
                  onPressed: () => onRowSecretToggled(row),
                  icon: Icon(row.secret ? Icons.lock_outline : Icons.lock_open_outlined),
                ),
                IconButton(
                  tooltip: 'Remove row',
                  onPressed: () => onRowRemoved(row),
                  icon: const Icon(Icons.delete_outline),
                ),
              ];
              return constraints.maxWidth < 560
                  ? Column(
                      children: [
                        Row(children: [fields[0]]),
                        const SizedBox(height: 8),
                        Row(children: fields.sublist(2)),
                      ],
                    )
                  : Row(children: fields);
            },
          ),
        ),
      )
      .toList(growable: false);

  Widget _configuredSecret(BuildContext context, String label, {required VoidCallback onRemove}) => Container(
    margin: const EdgeInsets.only(bottom: 12),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.25)),
      color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.25),
    ),
    child: ListTile(
      dense: true,
      leading: const Icon(Icons.check_circle_outline, color: Colors.green, size: 20),
      title: Text('$label configured', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
      trailing: TextButton(onPressed: onRemove, child: const Text('Remove')),
    ),
  );

  Widget _field(
    TextEditingController controller,
    String label, {
    Key? key,
    String? hint,
    bool required = false,
    bool obscure = false,
    bool? isObscured,
    VoidCallback? onToggleObscure,
    bool enabled = true,
    bool isDense = false,
    int maxLines = 1,
    Widget? prefixIcon,
    Widget? suffixIcon,
    String? Function(String?)? validator,
  }) => TextFormField(
    key: key,
    controller: controller,
    enabled: enabled,
    obscureText: obscure,
    maxLines: obscure ? 1 : maxLines,
    decoration: InputDecoration(
      labelText: label,
      hintText: hint,
      isDense: isDense,
      border: const OutlineInputBorder(),
      prefixIcon: prefixIcon,
      suffixIcon: onToggleObscure != null
          ? IconButton(
              onPressed: onToggleObscure,
              icon: Icon(
                (isObscured ?? true) ? Icons.visibility_outlined : Icons.visibility_off_outlined,
              ),
            )
          : suffixIcon,
    ),
    validator: validator ?? (required ? (value) => value?.trim().isEmpty == true ? '$label is required' : null : null),
    onChanged: (_) => onFieldChanged(),
  );
}

/// Mutable row state for one key/value pair of an MCP server draft.
class McpKeyValueRowState {
  McpKeyValueRowState({String key = '', String value = '', this.secret = false, this.configured = false})
    : key = TextEditingController(text: key),
      value = TextEditingController(text: value);

  final TextEditingController key;
  final TextEditingController value;
  bool secret;
  bool configured;
  bool removed = false;

  void dispose() {
    value.clear();
    key.dispose();
    value.dispose();
  }
}
