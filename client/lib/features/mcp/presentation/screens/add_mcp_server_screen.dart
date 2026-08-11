import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:sanad_client/core/navigation/app_routes.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/mcp/data/mcp_runtime_client.dart';
import 'package:sanad_client/features/mcp/domain/models/mcp_runtime_models.dart';
import 'package:sanad_client/features/mcp/domain/models/mcp_server_config.dart';
import 'package:sanad_client/utils/app_platform.dart';
import 'package:sanad_client/utils/toast_utils.dart';

enum _McpServerFormType { remote, stdio }

class AddMcpServerScreen extends StatefulWidget {
  const AddMcpServerScreen({
    super.key,
    this.workspacePath,
    this.scopeLabel,
    this.scope = McpConfigScope.global,
    this.device,
    this.initialConfig,
  });

  final String? workspacePath;
  final String? scopeLabel;
  final McpConfigScope scope;
  final DeviceConfig? device;
  final McpServerConfig? initialConfig;

  @override
  State<AddMcpServerScreen> createState() => _AddMcpServerScreenState();
}

class _AddMcpServerScreenState extends State<AddMcpServerScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _description = TextEditingController();
  final _url = TextEditingController();
  final _command = TextEditingController();
  final _bearer = TextEditingController();
  final _oauthClientId = TextEditingController();
  final _oauthClientSecret = TextEditingController();
  final List<TextEditingController> _args = [];
  final List<_KeyValueRowState> _env = [];
  final List<_KeyValueRowState> _headers = [];

  _McpServerFormType _serverType = _McpServerFormType.remote;
  McpAuthType _authType = McpAuthType.none;
  McpTransportType _transport = McpTransportType.auto;
  McpServerInspection? _inspection;
  Set<String> _disabledTools = {};
  bool _isTesting = false;
  bool _isSaving = false;
  bool _removeBearer = false;
  bool _acceptedRisks = false;
  bool _obscureBearer = true;
  bool _obscureOAuthSecret = true;
  McpOAuthFlow? _oauthFlow;

  bool get _isEditing => widget.initialConfig != null;

  @override
  void initState() {
    super.initState();
    _seed(widget.initialConfig);
  }

  void _seed(McpServerConfig? config) {
    if (config == null) {
      _args.add(TextEditingController());
      _env.add(_KeyValueRowState());
      _headers.add(_KeyValueRowState());
      return;
    }
    _name.text = config.name;
    _description.text = config.description ?? '';
    _url.text = config.serverUrl;
    _command.text = config.command ?? '';
    _serverType = config.transport == McpTransportType.stdio ? _McpServerFormType.stdio : _McpServerFormType.remote;
    _transport = config.transport;
    _authType = config.authType;
    _oauthClientId.text = config.oauthClientId ?? '';
    _disabledTools = config.disabledTools.toSet();
    _acceptedRisks = true;
    _args.addAll(config.args.map((value) => TextEditingController(text: value)));
    if (_args.isEmpty) _args.add(TextEditingController());
    _env.addAll(config.env.entries.map((entry) => _KeyValueRowState(key: entry.key, value: entry.value)));
    _env.addAll(
      config.secretEnvConfigured.map((key) => _KeyValueRowState(key: key, secret: true, configured: true)),
    );
    if (_env.isEmpty) _env.add(_KeyValueRowState());
    _headers.addAll(
      config.headers.entries.map((entry) => _KeyValueRowState(key: entry.key, value: entry.value)),
    );
    _headers.addAll(
      config.secretHeadersConfigured.map((key) => _KeyValueRowState(key: key, secret: true, configured: true)),
    );
    if (_headers.isEmpty) _headers.add(_KeyValueRowState());
  }

  @override
  void dispose() {
    for (final controller in [_name, _description, _url, _command, _bearer, _oauthClientId, _oauthClientSecret]) {
      controller.clear();
      controller.dispose();
    }
    for (final controller in _args) {
      controller.dispose();
    }
    for (final row in [..._env, ..._headers]) {
      row.dispose();
    }
    super.dispose();
  }

  McpServerConfig _draft() {
    final remote = _serverType == _McpServerFormType.remote;
    return McpServerConfig(
      id: widget.initialConfig?.id,
      name: _name.text.trim(),
      description: _trimOrNull(_description.text),
      serverUrl: remote ? _url.text.trim() : '',
      authType: remote ? _authType : McpAuthType.none,
      transport: remote ? _transport : McpTransportType.stdio,
      enabled: widget.initialConfig?.enabled ?? true,
      disabledTools: _disabledTools.toList(growable: false)..sort(),
      command: remote ? null : _trimOrNull(_command.text),
      args: remote
          ? const []
          : _args.map((item) => item.text.trim()).where((item) => item.isNotEmpty).toList(growable: false),
      env: remote ? const {} : _plainValues(_env),
      secretEnvConfigured: widget.initialConfig?.secretEnvConfigured ?? const {},
      headers: remote && _authType == McpAuthType.customHeaders ? _plainValues(_headers) : const {},
      secretHeadersConfigured: widget.initialConfig?.secretHeadersConfigured ?? const {},
      bearerConfigured: widget.initialConfig?.bearerConfigured ?? false,
      oauthConfigured: widget.initialConfig?.oauthConfigured ?? false,
      oauthClientId: remote && _authType == McpAuthType.oauth ? _trimOrNull(_oauthClientId.text) : null,
      oauthAuthUrl: widget.initialConfig?.oauthAuthUrl,
      oauthTokenUrl: widget.initialConfig?.oauthTokenUrl,
    );
  }

  Map<String, dynamic> _secretMutations() {
    final secretEnv = _secretValues(_env);
    final secretHeaders = _secretValues(_headers);
    return {
      if (_authType == McpAuthType.bearer && _bearer.text.isNotEmpty) 'bearer_token': _bearer.text,
      if (_removeBearer) 'remove_bearer': true,
      if (secretEnv.isNotEmpty) 'secret_env': secretEnv,
      if (secretHeaders.isNotEmpty) 'secret_headers': secretHeaders,
      if (_env.any((row) => row.removed && row.configured))
        'remove_secret_env': _env.where((row) => row.removed && row.configured).map((row) => row.key.text).toList(),
      if (_headers.any((row) => row.removed && row.configured))
        'remove_secret_headers': _headers
            .where((row) => row.removed && row.configured)
            .map((row) => row.key.text)
            .toList(),
      if (_authType == McpAuthType.oauth && _oauthClientSecret.text.isNotEmpty)
        'oauth': {'client_secret': _oauthClientSecret.text},
    };
  }

  Future<void> _test() async {
    if (!_validate()) return;
    if (_authType == McpAuthType.oauth && widget.initialConfig?.oauthConfigured != true) {
      await _authorizeOAuth();
      return;
    }
    setState(() {
      _isTesting = true;
      _inspection = null;
    });
    try {
      final result = await context.read<McpRuntimeClient>().inspectServer(
        device: widget.device,
        serverName: _name.text.trim(),
        scope: widget.scope,
        workspaceId: widget.workspacePath,
        draft: _draft(),
        secrets: _secretMutations(),
      );
      if (mounted) setState(() => _inspection = result);
    } catch (error) {
      if (mounted) ToastUtils.showError(context, error.toString());
    } finally {
      if (mounted) setState(() => _isTesting = false);
    }
  }

  Future<void> _authorizeOAuth() async {
    setState(() => _isTesting = true);
    try {
      var flow = await context.read<McpRuntimeClient>().startOAuth(
        device: widget.device,
        draft: _draft(),
        secrets: _secretMutations(),
      );
      if (!mounted) return;
      setState(() => _oauthFlow = flow);
      final authorizationUrl = flow.authorizationUrl;
      if (authorizationUrl != null) {
        final launched = await launchUrl(
          authorizationUrl,
          mode: LaunchMode.externalApplication,
        );
        if (!launched) throw StateError('Could not open the authorization URL.');
      }
      while (mounted && !flow.isTerminal) {
        await Future<void>.delayed(const Duration(seconds: 2));
        flow = await context.read<McpRuntimeClient>().oauthStatus(
          device: widget.device,
          flowId: flow.flowId,
        );
        if (mounted) setState(() => _oauthFlow = flow);
      }
      if (!mounted) return;
      if (flow.status == McpOAuthStatus.approved) {
        await context.read<McpRuntimeClient>().completeOAuth(
          device: widget.device,
          flowId: flow.flowId,
          config: _draft(),
          scope: widget.scope,
          workspaceId: widget.workspacePath,
        );
        final inspection = await context.read<McpRuntimeClient>().inspectServer(
          device: widget.device,
          serverName: _name.text.trim(),
          scope: widget.scope,
          workspaceId: widget.workspacePath,
        );
        if (mounted) setState(() => _inspection = inspection);
      } else if (flow.error != null) {
        ToastUtils.showError(context, flow.error!);
      }
    } catch (error) {
      if (mounted) ToastUtils.showError(context, error.toString());
    } finally {
      if (mounted) setState(() => _isTesting = false);
    }
  }

  Future<void> _cancelOAuth() async {
    final flow = _oauthFlow;
    if (flow == null || flow.isTerminal) return;
    try {
      final cancelled = await context.read<McpRuntimeClient>().cancelOAuth(
        device: widget.device,
        flowId: flow.flowId,
      );
      if (mounted) setState(() => _oauthFlow = cancelled);
    } catch (error) {
      if (mounted) ToastUtils.showError(context, error.toString());
    }
  }

  Future<void> _save() async {
    if (!_validate()) return;
    if (_inspection?.success != true) {
      ToastUtils.showError(context, 'Test the server successfully before saving.');
      return;
    }
    if (!_acceptedRisks) {
      ToastUtils.showError(context, 'Acknowledge the MCP server risks before saving.');
      return;
    }
    setState(() => _isSaving = true);
    try {
      await context.read<McpRuntimeClient>().saveServer(
        device: widget.device,
        scope: widget.scope,
        workspaceId: widget.workspacePath,
        config: _draft(),
        secrets: _secretMutations(),
      );
      _bearer.clear();
      _oauthClientSecret.clear();
      for (final row in [..._env, ..._headers]) {
        if (row.secret) row.value.clear();
      }
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (mounted) ToastUtils.showError(context, error.toString());
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  bool _validate() {
    if (_formKey.currentState?.validate() != true) return false;
    if (_serverType == _McpServerFormType.remote &&
        _authType == McpAuthType.bearer &&
        _bearer.text.isEmpty &&
        widget.initialConfig?.bearerConfigured != true) {
      ToastUtils.showError(context, 'Bearer token is required.');
      return false;
    }
    return true;
  }

  Future<void> _import() async {
    final input = TextEditingController();
    McpConfigPreview? preview;
    McpDraftPreviewEntry? selected;
    String? error;
    var busy = false;
    final result = await showDialog<McpServerConfig>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Import configuration'),
          content: SizedBox(
            width: 620,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Paste an MCP server object or mcpServers document. Nothing is saved until review.'),
                  const SizedBox(height: 12),
                  TextField(
                    controller: input,
                    minLines: 8,
                    maxLines: 14,
                    style: const TextStyle(fontFamily: 'monospace'),
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      hintText: '{\n  "mcpServers": { ... }\n}',
                    ),
                    onChanged: (_) => setDialogState(() {
                      preview = null;
                      selected = null;
                      error = null;
                    }),
                  ),
                  if (preview != null) ...[
                    const SizedBox(height: 12),
                    DropdownButtonFormField<McpDraftPreviewEntry>(
                      initialValue: selected,
                      decoration: const InputDecoration(
                        labelText: 'Draft to review',
                        border: OutlineInputBorder(),
                      ),
                      items: preview!.servers
                          .map((entry) => DropdownMenuItem(value: entry, child: Text(entry.name)))
                          .toList(growable: false),
                      onChanged: (value) => setDialogState(() => selected = value),
                    ),
                    for (final warning in preview!.warnings) Text('Warning: $warning'),
                    for (final field in preview!.unsupportedFields) Text('Unsupported: $field'),
                  ],
                  if (error != null) Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: busy ? null : () => Navigator.pop(context), child: const Text('Cancel')),
            OutlinedButton(
              onPressed: busy
                  ? null
                  : () async {
                      setDialogState(() => busy = true);
                      try {
                        final value = await dialogContext.read<McpRuntimeClient>().previewImport(
                          device: widget.device,
                          input: input.text,
                        );
                        setDialogState(() {
                          preview = value;
                          selected = value.servers.length == 1 ? value.servers.single : null;
                          error = null;
                        });
                      } catch (value) {
                        setDialogState(() => error = value.toString());
                      } finally {
                        setDialogState(() => busy = false);
                      }
                    },
              child: const Text('Preview'),
            ),
            FilledButton(
              onPressed: selected == null ? null : () => Navigator.pop(context, selected!.config),
              child: const Text('Use draft'),
            ),
          ],
        ),
      ),
    );
    input.dispose();
    if (result != null) setState(() => _replaceDraft(result));
  }

  void _replaceDraft(McpServerConfig config) {
    for (final controller in _args) {
      controller.dispose();
    }
    for (final row in [..._env, ..._headers]) {
      row.dispose();
    }
    _args.clear();
    _env.clear();
    _headers.clear();
    _name.text = config.name;
    _description.text = config.description ?? '';
    _url.text = config.serverUrl;
    _command.text = config.command ?? '';
    _serverType = config.transport == McpTransportType.stdio ? _McpServerFormType.stdio : _McpServerFormType.remote;
    _transport = config.transport;
    _authType = config.authType;
    _args.addAll(config.args.map((value) => TextEditingController(text: value)));
    if (_args.isEmpty) _args.add(TextEditingController());
    _env.addAll(config.env.entries.map((entry) => _KeyValueRowState(key: entry.key, value: entry.value)));
    if (_env.isEmpty) _env.add(_KeyValueRowState());
    _headers.addAll(config.headers.entries.map((entry) => _KeyValueRowState(key: entry.key, value: entry.value)));
    if (_headers.isEmpty) _headers.add(_KeyValueRowState());
    _inspection = null;
  }

  Future<void> _pasteArguments() async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim();
    if (text == null || text.isEmpty) return;
    final parsed = RegExp(r'''(?:[^\s"']+|"[^"]*"|'[^']*')+''')
        .allMatches(text)
        .map((match) => match.group(0)!.replaceAll(RegExp(r'''^["']|["']$'''), ''))
        .toList(growable: false);
    setState(() {
      for (final controller in _args) {
        controller.dispose();
      }
      _args
        ..clear()
        ..addAll(parsed.map((value) => TextEditingController(text: value)));
      if (_args.isEmpty) _args.add(TextEditingController());
      _inspection = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: Column(
            children: [
              Padding(
                padding: EdgeInsets.only(
                  left: 16,
                  right: 16,
                  top: AppPlatform.isMacOS ? 44 : 8,
                  bottom: 8,
                ),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back_rounded),
                      tooltip: 'Back',
                      onPressed: () {
                        if (context.canPop()) {
                          context.pop();
                        } else {
                          context.go(AppRoutes.home);
                        }
                      },
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _isEditing ? 'Edit MCP server' : 'Add MCP server',
                      style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const Spacer(),
                    TextButton.icon(
                      onPressed: _import,
                      icon: const Icon(Icons.file_open_outlined, size: 18),
                      label: const Text('Import'),
                    ),
                  ],
                ),
              ),
              Divider(
                height: 1,
                thickness: 1,
                color: theme.colorScheme.outline.withValues(alpha: 0.12),
              ),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    if (constraints.maxWidth >= 900) {
                      return _buildWideLayout(context);
                    }
                    return _buildCompactLayout(context);
                  },
                ),
              ),
              _buildBottomBar(theme),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildWideLayout(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          flex: 6,
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
            children: [
              _buildFormFields(),
            ],
          ),
        ),
        VerticalDivider(
          width: 1,
          thickness: 1,
          color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.15),
        ),
        Expanded(
          flex: 5,
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
            children: [
              _buildInspectionSection(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCompactLayout(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            _buildFormFields(),
            const SizedBox(height: 24),
            _buildInspectionSection(),
          ],
        ),
      ),
    );
  }

  Widget _buildFormFields() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<_McpServerFormType>(
          segments: const [
            ButtonSegment(
              value: _McpServerFormType.remote,
              label: Text('Remote server'),
              icon: Icon(Icons.cloud_outlined),
            ),
            ButtonSegment(
              value: _McpServerFormType.stdio,
              label: Text('Local command'),
              icon: Icon(Icons.terminal),
            ),
          ],
          selected: {_serverType},
          onSelectionChanged: (value) => setState(() {
            _serverType = value.first;
            _inspection = null;
          }),
        ),
        const SizedBox(height: 24),
        Text(
          'Server Details',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 4),
        Text(
          _isEditing ? 'Server identity and metadata.' : 'Enter basic details for this MCP server.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        _field(
          _name,
          'Name',
          hint: 'e.g. Memory Server',
          prefixIcon: const Icon(Icons.badge_outlined),
          enabled: !_isEditing,
          required: true,
        ),
        const SizedBox(height: 12),
        _field(
          _description,
          'Description (optional)',
          hint: 'e.g. MCP server for persistent memory storage',
          prefixIcon: const Icon(Icons.description_outlined),
          maxLines: 2,
        ),
        const SizedBox(height: 24),
        if (_serverType == _McpServerFormType.remote) ..._remoteFields(),
        if (_serverType == _McpServerFormType.stdio) ..._stdioFields(),
      ],
    );
  }

  Widget _buildInspectionSection() {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Inspection & Tools',
              style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            FilledButton.icon(
              onPressed: _isTesting ? null : _test,
              icon: _isTesting
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.wifi_find, size: 18),
              label: Text(
                _isTesting
                    ? 'Working…'
                    : _authType == McpAuthType.oauth && widget.initialConfig?.oauthConfigured != true
                    ? 'Authorize & Test'
                    : 'Test Connection',
              ),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (_oauthFlow != null) ...[
          ListTile(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: BorderSide(color: theme.colorScheme.outline.withValues(alpha: 0.2)),
            ),
            tileColor: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
            leading: const Icon(Icons.key_outlined),
            title: Text('OAuth: ${_oauthFlow!.status.name}'),
            subtitle: _oauthFlow!.error == null ? null : Text(_oauthFlow!.error!),
            trailing: _oauthFlow!.isTerminal
                ? null
                : TextButton(onPressed: _cancelOAuth, child: const Text('Cancel')),
          ),
          const SizedBox(height: 16),
        ],
        if (_inspection != null) ...[
          _reviewCard(_inspection!),
        ] else if (!_isTesting) ...[
          Card(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: theme.colorScheme.outline.withValues(alpha: 0.18)),
            ),
            color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.25),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
              child: Column(
                children: [
                  Icon(
                    Icons.sensors_outlined,
                    size: 36,
                    color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'No inspection results yet',
                    style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Test the server connection to discover available tools and verify communication.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: theme.colorScheme.onSurfaceVariant, fontSize: 12, height: 1.4),
                  ),
                ],
              ),
            ),
          ),
        ],
        const SizedBox(height: 20),
        CheckboxListTile(
          value: _acceptedRisks,
          onChanged: (value) => setState(() => _acceptedRisks = value ?? false),
          controlAffinity: ListTileControlAffinity.leading,
          contentPadding: EdgeInsets.zero,
          title: const Text(
            'I understand this server can access data and perform actions.',
            style: TextStyle(fontSize: 13),
          ),
          subtitle: const Text('Only enable tools and servers you trust.', style: TextStyle(fontSize: 12)),
        ),
      ],
    );
  }

  Widget _buildBottomBar(ThemeData theme) {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          border: Border(top: BorderSide(color: theme.dividerColor)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: _isSaving ? null : () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            const SizedBox(width: 12),
            FilledButton(
              onPressed: _isSaving ? null : _save,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              child: Text(
                _isSaving
                    ? 'Saving…'
                    : _isEditing
                    ? 'Save changes'
                    : 'Add server',
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _remoteFields() => [
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
      _url,
      'Server URL',
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
      initialValue: _transport,
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
      onChanged: (value) => setState(() {
        _transport = value ?? McpTransportType.auto;
        _inspection = null;
      }),
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
      initialValue: _authType,
      decoration: const InputDecoration(
        labelText: 'Authentication',
        border: OutlineInputBorder(),
        prefixIcon: Icon(Icons.security_outlined),
      ),
      items: McpAuthType.values.map((value) => DropdownMenuItem(value: value, child: Text(value.displayName))).toList(),
      onChanged: (value) => setState(() {
        _authType = value ?? McpAuthType.none;
        _inspection = null;
      }),
    ),
    if (_authType == McpAuthType.bearer) ...[
      const SizedBox(height: 12),
      if (widget.initialConfig?.bearerConfigured == true && !_removeBearer)
        _configuredSecret(
          'Bearer token',
          onRemove: () => setState(() => _removeBearer = true),
        ),
      _field(
        _bearer,
        widget.initialConfig?.bearerConfigured == true ? 'Replace bearer token' : 'Bearer token',
        hint: 'Enter token string',
        prefixIcon: const Icon(Icons.vpn_key_outlined),
        obscure: _obscureBearer,
        isObscured: _obscureBearer,
        onToggleObscure: () => setState(() => _obscureBearer = !_obscureBearer),
      ),
    ],
    if (_authType == McpAuthType.oauth) ...[
      const SizedBox(height: 12),
      _field(
        _oauthClientId,
        'OAuth client ID (optional)',
        hint: 'e.g. client_12345',
        prefixIcon: const Icon(Icons.badge_outlined),
      ),
      const SizedBox(height: 12),
      if (widget.initialConfig?.oauthConfigured == true)
        _configuredSecret(
          'OAuth credentials',
          onRemove: () {},
        ),
      _field(
        _oauthClientSecret,
        'Replace OAuth client secret (optional)',
        hint: 'Enter client secret',
        prefixIcon: const Icon(Icons.vpn_key_outlined),
        obscure: _obscureOAuthSecret,
        isObscured: _obscureOAuthSecret,
        onToggleObscure: () => setState(() => _obscureOAuthSecret = !_obscureOAuthSecret),
      ),
    ],
    if (_authType == McpAuthType.customHeaders) ...[
      const SizedBox(height: 24),
      Text('Headers', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
      const SizedBox(height: 8),
      ..._rows(_headers),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: () => setState(() => _headers.add(_KeyValueRowState())),
          icon: const Icon(Icons.add),
          label: const Text('Add header'),
        ),
      ),
    ],
  ];

  List<Widget> _stdioFields() => [
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
      _command,
      'Command',
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
          onPressed: _pasteArguments,
          icon: const Icon(Icons.content_paste, size: 16),
          label: const Text('Paste'),
        ),
      ],
    ),
    const SizedBox(height: 12),
    ..._args.asMap().entries.map(
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
              onPressed: () => setState(() {
                entry.value.dispose();
                _args.removeAt(entry.key);
              }),
              icon: const Icon(Icons.remove_circle_outline),
            ),
          ],
        ),
      ),
    ),
    Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        onPressed: () => setState(() => _args.add(TextEditingController())),
        icon: const Icon(Icons.add),
        label: const Text('Add argument'),
      ),
    ),
    const SizedBox(height: 24),
    Text('Environment variables', style: Theme.of(context).textTheme.titleMedium),
    const SizedBox(height: 4),
    Text('Set environment variables for the subprocess.', style: Theme.of(context).textTheme.bodySmall),
    const SizedBox(height: 12),
    ..._rows(_env),
    Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        onPressed: () => setState(() => _env.add(_KeyValueRowState())),
        icon: const Icon(Icons.add),
        label: const Text('Add variable'),
      ),
    ),
  ];

  List<Widget> _rows(List<_KeyValueRowState> rows) => rows
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
                  onPressed: () => setState(() => row.secret = !row.secret),
                  icon: Icon(row.secret ? Icons.lock_outline : Icons.lock_open_outlined),
                ),
                IconButton(
                  tooltip: 'Remove row',
                  onPressed: () => setState(() => row.removed = true),
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

  Widget _reviewCard(McpServerInspection result) {
    final success = result.success;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  success ? Icons.check_circle : Icons.error_outline,
                  color: success ? Colors.green : Theme.of(context).colorScheme.error,
                ),
                const SizedBox(width: 8),
                Expanded(child: Text(success ? 'Connection succeeded' : result.error ?? 'Connection failed')),
              ],
            ),
            const SizedBox(height: 8),
            Text('Transport: ${result.transport?.displayName ?? 'Unknown'}'),
            Text('Authentication: ${result.authState}'),
            if (result.tools.isNotEmpty) ...[
              const Divider(),
              const Text('Allowed tools', style: TextStyle(fontWeight: FontWeight.w700)),
              for (final tool in result.tools)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: !_disabledTools.contains(tool.name),
                  onChanged: (enabled) => setState(() {
                    enabled ? _disabledTools.remove(tool.name) : _disabledTools.add(tool.name);
                  }),
                  title: Text(tool.name),
                  subtitle: tool.description.isEmpty ? null : Text(tool.description),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _configuredSecret(String label, {required VoidCallback onRemove}) => Container(
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
    onChanged: (_) => _inspection = null,
  );

  Map<String, String> _plainValues(List<_KeyValueRowState> rows) => {
    for (final row in rows)
      if (!row.removed && !row.secret && row.key.text.trim().isNotEmpty) row.key.text.trim(): row.value.text,
  };

  Map<String, String> _secretValues(List<_KeyValueRowState> rows) => {
    for (final row in rows)
      if (!row.removed && row.secret && row.key.text.trim().isNotEmpty && row.value.text.isNotEmpty)
        row.key.text.trim(): row.value.text,
  };

  String? _trimOrNull(String value) => value.trim().isEmpty ? null : value.trim();
}

class _KeyValueRowState {
  _KeyValueRowState({String key = '', String value = '', this.secret = false, this.configured = false})
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
