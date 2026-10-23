import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:sanad_client/core/presentation/widgets/app_progress_indicator.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:sanad_client/core/presentation/bloc/appearance/appearance_cubit.dart';
import 'package:sanad_client/core/presentation/bloc/appearance/appearance_state.dart';
import 'package:sanad_client/l10n/app_localizations.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:sanad_client/core/navigation/app_routes.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/mcp/data/mcp_runtime_client.dart';
import 'package:sanad_client/features/mcp/domain/models/mcp_runtime_models.dart';
import 'package:sanad_client/features/mcp/domain/models/mcp_server_config.dart';
import 'package:sanad_client/features/mcp/presentation/widgets/mcp_inspection_review.dart';
import 'package:sanad_client/features/mcp/presentation/widgets/mcp_server_form_fields.dart';
import 'package:sanad_client/features/settings/presentation/widgets/settings_widgets.dart';
import 'package:sanad_client/utils/app_platform.dart';
import 'package:sanad_client/utils/toast_utils.dart';

class AddMcpServerScreen extends StatefulWidget {
  const AddMcpServerScreen({
    super.key,
    this.workspaceId,
    this.scopeLabel,
    this.scope = McpConfigScope.global,
    this.device,
    this.initialConfig,
  });

  final String? workspaceId;
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
  final List<McpKeyValueRowState> _env = [];
  final List<McpKeyValueRowState> _headers = [];

  McpServerFormType _serverType = McpServerFormType.remote;
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
      _env.add(McpKeyValueRowState());
      _headers.add(McpKeyValueRowState());
      return;
    }
    _name.text = config.name;
    _description.text = config.description ?? '';
    _url.text = config.serverUrl;
    _command.text = config.command ?? '';
    _serverType = config.transport == McpTransportType.stdio ? McpServerFormType.stdio : McpServerFormType.remote;
    _transport = config.transport;
    _authType = config.authType;
    _oauthClientId.text = config.oauthClientId ?? '';
    _disabledTools = config.disabledTools.toSet();
    _acceptedRisks = true;
    _args.addAll(config.args.map((value) => TextEditingController(text: value)));
    if (_args.isEmpty) _args.add(TextEditingController());
    _env.addAll(config.env.entries.map((entry) => McpKeyValueRowState(key: entry.key, value: entry.value)));
    _env.addAll(
      config.secretEnvConfigured.map((key) => McpKeyValueRowState(key: key, secret: true, configured: true)),
    );
    if (_env.isEmpty) _env.add(McpKeyValueRowState());
    _headers.addAll(
      config.headers.entries.map((entry) => McpKeyValueRowState(key: entry.key, value: entry.value)),
    );
    _headers.addAll(
      config.secretHeadersConfigured.map((key) => McpKeyValueRowState(key: key, secret: true, configured: true)),
    );
    if (_headers.isEmpty) _headers.add(McpKeyValueRowState());
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
    final remote = _serverType == McpServerFormType.remote;
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
        workspaceId: widget.workspaceId,
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
        if (!launched) throw StateError(AppLocalizations.of(context)!.mcpCouldNotOpenAuthUrl);
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
          workspaceId: widget.workspaceId,
        );
        final inspection = await context.read<McpRuntimeClient>().inspectServer(
          device: widget.device,
          serverName: _name.text.trim(),
          scope: widget.scope,
          workspaceId: widget.workspaceId,
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
      ToastUtils.showError(context, AppLocalizations.of(context)!.mcpTestSuccessNote);
      return;
    }
    if (!_acceptedRisks) {
      ToastUtils.showError(context, AppLocalizations.of(context)!.mcpRiskAckSave);
      return;
    }
    setState(() => _isSaving = true);
    try {
      await context.read<McpRuntimeClient>().saveServer(
        device: widget.device,
        scope: widget.scope,
        workspaceId: widget.workspaceId,
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
    if (_serverType == McpServerFormType.remote &&
        _authType == McpAuthType.bearer &&
        _bearer.text.isEmpty &&
        widget.initialConfig?.bearerConfigured != true) {
      ToastUtils.showError(context, AppLocalizations.of(context)!.mcpBearerTokenRequired);
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
          title: Text(AppLocalizations.of(context)!.mcpImportConfig),
          content: SizedBox(
            width: 620,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(AppLocalizations.of(context)!.mcpPasteHint),
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
                      decoration: InputDecoration(
                        labelText: AppLocalizations.of(context)!.mcpDraftToReview,
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
              child: Text(AppLocalizations.of(context)!.mcpPreview),
            ),
            FilledButton(
              onPressed: selected == null ? null : () => Navigator.pop(context, selected!.config),
              child: Text(AppLocalizations.of(context)!.mcpUseDraft),
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
    _serverType = config.transport == McpTransportType.stdio ? McpServerFormType.stdio : McpServerFormType.remote;
    _transport = config.transport;
    _authType = config.authType;
    _args.addAll(config.args.map((value) => TextEditingController(text: value)));
    if (_args.isEmpty) _args.add(TextEditingController());
    _env.addAll(config.env.entries.map((entry) => McpKeyValueRowState(key: entry.key, value: entry.value)));
    if (_env.isEmpty) _env.add(McpKeyValueRowState());
    _headers.addAll(config.headers.entries.map((entry) => McpKeyValueRowState(key: entry.key, value: entry.value)));
    if (_headers.isEmpty) _headers.add(McpKeyValueRowState());
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
      backgroundColor: Colors.transparent,
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
                      tooltip: AppLocalizations.of(context)!.mcpBack,
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
                      _isEditing ? AppLocalizations.of(context)!.mcpEditServer : AppLocalizations.of(context)!.mcpAddServer,
                      style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const Spacer(),
                    TextButton.icon(
                      onPressed: _import,
                      icon: const Icon(Icons.file_open_outlined, size: 18),
                      label: Text(AppLocalizations.of(context)!.mcpImport),
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
              SettingsCard(child: _buildFormFields()),
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
              SettingsCard(child: _buildInspectionSection()),
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
            SettingsCard(child: _buildFormFields()),
            const SizedBox(height: 24),
            SettingsCard(child: _buildInspectionSection()),
          ],
        ),
      ),
    );
  }

  Widget _buildFormFields() {
    return McpServerFormFields(
      name: _name,
      description: _description,
      url: _url,
      command: _command,
      bearer: _bearer,
      oauthClientId: _oauthClientId,
      oauthClientSecret: _oauthClientSecret,
      args: _args,
      env: _env,
      headers: _headers,
      serverType: _serverType,
      authType: _authType,
      transport: _transport,
      isEditing: _isEditing,
      bearerConfigured: widget.initialConfig?.bearerConfigured == true,
      oauthConfigured: widget.initialConfig?.oauthConfigured == true,
      removeBearer: _removeBearer,
      obscureBearer: _obscureBearer,
      obscureOAuthSecret: _obscureOAuthSecret,
      onServerTypeChanged: (value) => setState(() {
        _serverType = value;
        _inspection = null;
      }),
      onTransportChanged: (value) => setState(() {
        _transport = value;
        _inspection = null;
      }),
      onAuthTypeChanged: (value) => setState(() {
        _authType = value;
        _inspection = null;
      }),
      onRemoveBearer: () => setState(() => _removeBearer = true),
      onToggleObscureBearer: () => setState(() => _obscureBearer = !_obscureBearer),
      onToggleObscureOAuthSecret: () => setState(() => _obscureOAuthSecret = !_obscureOAuthSecret),
      onPasteArguments: _pasteArguments,
      onAddArgument: () => setState(() => _args.add(TextEditingController())),
      onRemoveArgument: (index) => setState(() {
        _args[index].dispose();
        _args.removeAt(index);
      }),
      onAddEnvRow: () => setState(() => _env.add(McpKeyValueRowState())),
      onAddHeaderRow: () => setState(() => _headers.add(McpKeyValueRowState())),
      onRowSecretToggled: (row) => setState(() => row.secret = !row.secret),
      onRowRemoved: (row) => setState(() => row.removed = true),
      onFieldChanged: () => _inspection = null,
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
              AppLocalizations.of(context)!.mcpInspectionTools,
              style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            FilledButton.icon(
              key: const Key('mcp_form_test_btn'),
              onPressed: _isTesting ? null : _test,
              icon: _isTesting
                  ? const SizedBox.square(
                      dimension: 16,
                      child: AppProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.wifi_find, size: 18),
              label: Text(
                _isTesting
                    ? AppLocalizations.of(context)!.mcpWorking
                    : _authType == McpAuthType.oauth && widget.initialConfig?.oauthConfigured != true
                    ? AppLocalizations.of(context)!.mcpAuthAndTest
                    : AppLocalizations.of(context)!.mcpTestConnection,
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
            title: Text(AppLocalizations.of(context)!.mcpOAuthStatus(_oauthFlow!.status.name)),
            subtitle: _oauthFlow!.error == null ? null : Text(_oauthFlow!.error!),
            trailing: _oauthFlow!.isTerminal ? null : TextButton(onPressed: _cancelOAuth, child: const Text('Cancel')),
          ),
          const SizedBox(height: 16),
        ],
        if (_inspection != null) ...[
          McpInspectionReview(
            result: _inspection!,
            disabledTools: _disabledTools,
            onToolToggled: (toolName, enabled) => setState(() {
              enabled ? _disabledTools.remove(toolName) : _disabledTools.add(toolName);
            }),
          ),
        ] else if (!_isTesting) ...[
          const McpInspectionPlaceholder(),
        ],
        const SizedBox(height: 20),
        CheckboxListTile(
          key: const Key('mcp_form_accept_risks_checkbox'),
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
    final appearance = context.watch<AppearanceCubit?>()?.state;
    final isCustomBg = appearance != null && appearance.backgroundOption != AppBackgroundOption.defaultTheme;
    final barColor = isCustomBg
        ? (theme.cardTheme.color ?? theme.colorScheme.surface).withValues(alpha: 0.60)
        : theme.colorScheme.surface;

    final bar = Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
      decoration: BoxDecoration(
        color: barColor,
        border: Border(
          top: BorderSide(
            color: isCustomBg ? theme.colorScheme.outline.withValues(alpha: 0.25) : theme.dividerColor,
          ),
        ),
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
              key: const Key('mcp_form_save_btn'),
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
      );

    final barWidget = SafeArea(
      top: false,
      child: bar,
    );

    if (isCustomBg) {
      return ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: barWidget,
        ),
      );
    }
    return barWidget;
  }

  Map<String, String> _plainValues(List<McpKeyValueRowState> rows) => {
    for (final row in rows)
      if (!row.removed && !row.secret && row.key.text.trim().isNotEmpty) row.key.text.trim(): row.value.text,
  };

  Map<String, String> _secretValues(List<McpKeyValueRowState> rows) => {
    for (final row in rows)
      if (!row.removed && row.secret && row.key.text.trim().isNotEmpty && row.value.text.isNotEmpty)
        row.key.text.trim(): row.value.text,
  };

  String? _trimOrNull(String value) => value.trim().isEmpty ? null : value.trim();
}
