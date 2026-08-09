import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'package:sanad_client/core/di/injection.dart';
import 'package:sanad_client/core/navigation/app_routes.dart';
import 'package:sanad_client/features/mcp/data/mcp_runtime_client.dart';
import 'package:sanad_client/features/mcp/domain/models/mcp_runtime_models.dart';
import 'package:sanad_client/features/mcp/domain/models/mcp_server_config.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/devices/presentation/bloc/device_cubit.dart';
import 'package:sanad_client/features/devices/presentation/bloc/device_state.dart';
import 'package:sanad_client/infrastructure/local_tools/workspace_tool_runtime_context.dart';
import 'package:sanad_client/utils/toast_utils.dart';

enum _McpConfigSource { global, workspace, effective }

enum _McpTransportFilter { all, stdio, remote }

class McpServerManagementScreen extends StatefulWidget {
  const McpServerManagementScreen({
    super.key,
    this.device,
    this.workspaceId,
    this.workspaceName,
    this.embedded = false,
  });

  final DeviceConfig? device;
  final String? workspaceId;
  final String? workspaceName;
  final bool embedded;

  @override
  State<McpServerManagementScreen> createState() => _McpServerManagementScreenState();
}

class _McpServerManagementScreenState extends State<McpServerManagementScreen> {
  final WorkspaceToolRuntimeContext _workspaceRuntimeContext = getIt<WorkspaceToolRuntimeContext>();

  final Map<String, bool> _activeConnections = {};
  final Map<String, List<McpRuntimeTool>> _serverTools = {};
  final Map<String, String> _connectionErrors = {};
  final Map<String, bool> _isConnecting = {};
  final Set<String> _expandedServerIds = {};
  final Map<String, _McpConfigSource> _effectiveOrigins = {};

  _McpConfigSource _source = _McpConfigSource.global;
  _McpTransportFilter _transportFilter = _McpTransportFilter.all;

  bool _isLoading = true;
  bool _isRefreshingConnections = false;
  bool _refreshConnectionsQueued = false;
  int _connectionRefreshCycle = 0;

  String? _workspacePath;
  String? _workspaceName;
  List<McpServerConfig> _globalServers = const [];
  List<McpServerConfig> _workspaceServers = const [];
  List<McpServerConfig> _effectiveServers = const [];
  McpRuntimeSnapshot? _snapshot;

  @override
  void initState() {
    super.initState();
    unawaited(_loadData());
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);

    try {
      final workspace = _workspaceRuntimeContext.activeWorkspace;
      _workspacePath =
          widget.workspaceId ?? (workspace?.path.trim().isNotEmpty == true ? workspace!.path.trim() : null);
      _workspaceName = widget.workspaceName ?? workspace?.name;
      _applySnapshot(
        await context.read<McpRuntimeClient>().listServers(
          device: _targetDevice,
          workspaceId: _workspacePath,
        ),
      );

      await _reconnectVisibleServers();
    } catch (error) {
      if (mounted) ToastUtils.showError(context, error.toString());
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _rebuildEffectiveOrigins() {
    _effectiveOrigins.clear();
    final effectiveSection = _snapshot?.effective;
    if (effectiveSection == null) {
      return;
    }

    for (final server in effectiveSection.servers) {
      switch (server.source) {
        case 'workspace':
          _effectiveOrigins[server.name] = _McpConfigSource.workspace;
          break;
        case 'global':
          _effectiveOrigins[server.name] = _McpConfigSource.global;
          break;
      }
    }
  }

  void _applySnapshot(McpRuntimeSnapshot snapshot) {
    _snapshot = snapshot;
    _workspacePath = snapshot.workspaceId ?? _workspacePath;
    _globalServers = snapshot.global.servers.map((entry) => entry.config).toList(growable: false);
    _workspaceServers = snapshot.workspace.servers.map((entry) => entry.config).toList(growable: false);
    _effectiveServers = snapshot.effective.servers.map((entry) => entry.config).toList(growable: false);
    _rebuildEffectiveOrigins();
  }

  List<McpServerConfig> get _currentServers {
    final base = switch (_source) {
      _McpConfigSource.global => _globalServers,
      _McpConfigSource.workspace => _workspaceServers,
      _McpConfigSource.effective => _effectiveServers,
    };

    return base.where(_matchesTransportFilter).toList(growable: false);
  }

  bool _matchesTransportFilter(McpServerConfig server) {
    return switch (_transportFilter) {
      _McpTransportFilter.all => true,
      _McpTransportFilter.stdio => server.detectedTransport == McpTransportType.stdio,
      _McpTransportFilter.remote =>
        server.detectedTransport == McpTransportType.sse || server.detectedTransport == McpTransportType.streamableHttp,
    };
  }

  Future<void> _reconnectVisibleServers() async {
    _refreshConnectionsQueued = true;
    if (_isRefreshingConnections) {
      return;
    }

    _isRefreshingConnections = true;
    try {
      while (_refreshConnectionsQueued) {
        _refreshConnectionsQueued = false;
        final cycle = ++_connectionRefreshCycle;
        final visibleEnabledServers = _currentServers.where((server) => server.enabled).toList(growable: false);

        if (mounted) {
          setState(() {
            _activeConnections.clear();
            _serverTools.clear();
            _connectionErrors.clear();
            _isConnecting
              ..clear()
              ..addEntries(visibleEnabledServers.map((server) => MapEntry(server.id, true)));
          });
        }

        await Future.wait(
          visibleEnabledServers.map((server) => _connectToServer(server, cycle)),
        );
      }
    } finally {
      _isRefreshingConnections = false;
    }
  }

  Future<void> _connectToServer(McpServerConfig config, int cycle) async {
    if (!config.enabled) {
      return;
    }
    if (cycle != _connectionRefreshCycle) {
      return;
    }

    try {
      final result = await context.read<McpRuntimeClient>().inspectServer(
        device: _targetDevice,
        serverName: config.name,
        scope: _currentScope,
        workspaceId: _workspacePath,
      );

      if (mounted && cycle == _connectionRefreshCycle) {
        setState(() {
          if (result.success) {
            _activeConnections[config.id] = true;
            _serverTools[config.id] = result.tools;
          } else {
            _activeConnections.remove(config.id);
            _serverTools.remove(config.id);
            _connectionErrors[config.id] = result.error ?? 'Unknown connection error';
          }
          _isConnecting[config.id] = false;
        });
      }
    } catch (e) {
      if (mounted && cycle == _connectionRefreshCycle) {
        setState(() {
          _connectionErrors[config.id] = e.toString();
          _isConnecting[config.id] = false;
        });
      }
    }
  }

  Future<void> _disconnectServer(String serverId) async {
    if (mounted) {
      setState(() {
        _activeConnections.remove(serverId);
        _serverTools.remove(serverId);
        _connectionErrors.remove(serverId);
        _isConnecting.remove(serverId);
      });
    }
  }

  Future<void> _persistServer(McpServerConfig server) async {
    final snapshot = await context.read<McpRuntimeClient>().saveServer(
      device: _targetDevice,
      scope: _currentScope,
      workspaceId: _editableWorkspacePath,
      config: server,
    );
    if (!mounted) {
      return;
    }
    setState(() => _applySnapshot(snapshot));
  }

  Future<void> _toggleServerEnabled(McpServerConfig server, bool enabled) async {
    if (!_canEditCurrentSource) {
      return;
    }
    await _persistServer(server.copyWith(enabled: enabled));
    if (!enabled) {
      await _disconnectServer(server.id);
    }
    await _loadData();
  }

  Future<void> _toggleToolEnabled(McpServerConfig server, String toolName, bool enabled) async {
    if (!_canEditCurrentSource) {
      return;
    }

    final disabledTools = List<String>.from(server.disabledTools);
    if (enabled) {
      disabledTools.remove(toolName);
    } else if (!disabledTools.contains(toolName)) {
      disabledTools.add(toolName);
    }

    await _persistServer(server.copyWith(disabledTools: disabledTools));
    await _loadData();
  }

  Future<void> _deleteServer(McpServerConfig server) async {
    if (!_canEditCurrentSource) {
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Server'),
        content: Text('Delete `${server.name}` from this source?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) {
      return;
    }

    final snapshot = await context.read<McpRuntimeClient>().deleteServer(
      device: _targetDevice,
      scope: _currentScope,
      workspaceId: _editableWorkspacePath,
      serverName: server.name,
    );
    await _disconnectServer(server.id);
    if (mounted) {
      setState(() => _applySnapshot(snapshot));
    }
  }

  Future<void> _openEditServer(McpServerConfig server) async {
    final source = _source == _McpConfigSource.effective
        ? _effectiveOrigins[server.name] ?? _McpConfigSource.global
        : _source;
    final result = await context.push(
      AppRoutes.addMcpServer,
      extra: {..._extraForSource(source), 'initialConfig': server},
    );
    if (result != null) await _loadData();
  }

  Future<void> _exportServer(McpServerConfig server) async {
    try {
      final result = await context.read<McpRuntimeClient>().exportServers(
        device: _targetDevice,
        serverNames: [server.name],
        scope: _currentScope,
        workspaceId: _workspacePath,
      );
      await Clipboard.setData(ClipboardData(text: result.json));
      if (mounted) {
        ToastUtils.showSuccess(
          context,
          'Copied redacted JSON. Credentials were excluded.',
        );
      }
    } catch (error) {
      if (mounted) ToastUtils.showError(context, error.toString());
    }
  }

  Future<void> _editAdvancedJson(McpServerConfig server) async {
    final source = _source == _McpConfigSource.effective
        ? _effectiveOrigins[server.name] ?? _McpConfigSource.global
        : _source;
    final scope = source == _McpConfigSource.workspace ? McpConfigScope.workspace : McpConfigScope.global;
    final workspaceId = source == _McpConfigSource.workspace ? _workspacePath : null;
    try {
      final document = await context.read<McpRuntimeClient>().readAdvanced(
        device: _targetDevice,
        serverName: server.name,
        scope: scope,
        workspaceId: workspaceId,
      );
      if (!mounted) return;
      final controller = TextEditingController(text: document.json);
      McpConfigPreview? preview;
      String? error;
      var busy = false;
      final saved = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: Text('Advanced JSON · ${server.name}'),
            content: SizedBox(
              width: 680,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Credentials are excluded. Preview is required before Save.'),
                    const SizedBox(height: 12),
                    TextField(
                      controller: controller,
                      minLines: 12,
                      maxLines: 20,
                      style: const TextStyle(fontFamily: 'monospace'),
                      onChanged: (_) => setDialogState(() {
                        preview = null;
                        error = null;
                      }),
                    ),
                    if (preview != null) ...[
                      const SizedBox(height: 12),
                      Text('${preview!.diff.length} fields changed'),
                      for (final item in preview!.diff) Text('• ${item.field}'),
                    ],
                    if (error != null) ...[
                      const SizedBox(height: 12),
                      Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(onPressed: busy ? null : () => Navigator.pop(context, false), child: const Text('Cancel')),
              OutlinedButton(
                onPressed: busy
                    ? null
                    : () async {
                        setDialogState(() => busy = true);
                        try {
                          final value = await dialogContext.read<McpRuntimeClient>().previewAdvanced(
                            device: _targetDevice,
                            serverName: server.name,
                            scope: scope,
                            workspaceId: workspaceId,
                            input: controller.text,
                          );
                          setDialogState(() {
                            preview = value;
                            error = null;
                          });
                        } catch (value) {
                          setDialogState(() => error = value.toString());
                        } finally {
                          setDialogState(() => busy = false);
                        }
                      },
                child: const Text('Preview changes'),
              ),
              FilledButton(
                onPressed: busy || preview == null
                    ? null
                    : () async {
                        setDialogState(() => busy = true);
                        try {
                          await dialogContext.read<McpRuntimeClient>().saveAdvanced(
                            device: _targetDevice,
                            serverName: server.name,
                            scope: scope,
                            workspaceId: workspaceId,
                            input: controller.text,
                            baseRevision: document.baseRevision,
                            previewRevision: preview!.revision,
                          );
                          if (context.mounted) Navigator.pop(context, true);
                        } catch (value) {
                          setDialogState(() => error = value.toString());
                        } finally {
                          if (context.mounted) setDialogState(() => busy = false);
                        }
                      },
                child: const Text('Save'),
              ),
            ],
          ),
        ),
      );
      await Future<void>.delayed(kThemeAnimationDuration);
      controller.dispose();
      if (saved == true) await _loadData();
    } catch (error) {
      if (mounted) ToastUtils.showError(context, error.toString());
    }
  }

  Future<void> _openAddServer() async {
    if (_source == _McpConfigSource.effective) {
      if (_workspacePath == null) {
        final result = await context.push(
          AppRoutes.addMcpServer,
          extra: {'scopeLabel': 'Device', 'scope': McpConfigScope.global},
        );
        if (result != null) {
          await _loadData();
        }
        return;
      }

      final choice = await showModalBottomSheet<_McpConfigSource>(
        context: context,
        builder: (context) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.public),
                title: const Text('Add to Device'),
                onTap: () => Navigator.pop(context, _McpConfigSource.global),
              ),
              ListTile(
                leading: const Icon(Icons.workspaces_outline),
                title: Text('Add to ${_workspaceName ?? 'Workspace'}'),
                onTap: () => Navigator.pop(context, _McpConfigSource.workspace),
              ),
            ],
          ),
        ),
      );

      if (choice == null) {
        return;
      }

      final result = await context.push(
        AppRoutes.addMcpServer,
        extra: _extraForSource(choice),
      );
      if (result != null) {
        await _loadData();
      }
      return;
    }

    final result = await context.push(
      AppRoutes.addMcpServer,
      extra: _extraForSource(_source),
    );
    if (result != null) {
      await _loadData();
    }
  }

  Map<String, dynamic> _extraForSource(_McpConfigSource source) {
    return switch (source) {
      _McpConfigSource.global => {
        'device': _targetDevice,
        'scopeLabel': 'Device',
        'scope': McpConfigScope.global,
      },
      _McpConfigSource.workspace => {
        'device': _targetDevice,
        'scopeLabel': _workspaceName ?? 'Workspace',
        'workspacePath': _workspacePath,
        'scope': McpConfigScope.workspace,
      },
      _McpConfigSource.effective => {
        'device': _targetDevice,
        'scopeLabel': 'Device',
        'scope': McpConfigScope.global,
      },
    };
  }

  bool get _canEditCurrentSource {
    if (_source == _McpConfigSource.effective) {
      return false;
    }
    if (_source == _McpConfigSource.workspace && (_workspacePath == null || _workspacePath!.isEmpty)) {
      return false;
    }
    return true;
  }

  String? get _editableWorkspacePath {
    return _source == _McpConfigSource.workspace ? _workspacePath : null;
  }

  McpConfigScope get _currentScope {
    return switch (_source) {
      _McpConfigSource.global => McpConfigScope.global,
      _McpConfigSource.workspace => McpConfigScope.workspace,
      _McpConfigSource.effective => McpConfigScope.effective,
    };
  }

  DeviceConfig get _targetDevice {
    final explicit = widget.device;
    if (explicit != null) return explicit;
    final state = context.read<DeviceCubit>().state;
    if (state is DeviceActive) return state.activeAgent;
    throw StateError('Select a device before managing MCP servers.');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final body = Stack(
      children: [
        Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_workspacePath != null)
                    SegmentedButton<_McpConfigSource>(
                      segments: [
                        const ButtonSegment(
                          value: _McpConfigSource.global,
                          label: Text('Device'),
                          icon: Icon(Icons.computer_outlined),
                        ),
                        ButtonSegment(
                          value: _McpConfigSource.workspace,
                          label: Text(_workspaceName ?? 'Workspace'),
                          icon: const Icon(Icons.workspaces_outline),
                          enabled: _workspacePath != null,
                        ),
                        const ButtonSegment(
                          value: _McpConfigSource.effective,
                          label: Text('Effective'),
                          icon: Icon(Icons.merge_type),
                        ),
                      ],
                      selected: {_source},
                      onSelectionChanged: (selection) async {
                        setState(() => _source = selection.first);
                        await _reconnectVisibleServers();
                      },
                    ),
                  if (_source == _McpConfigSource.effective && _overriddenDeviceServers.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(
                      'Workspace definitions override same-name device servers. Overridden device servers: ${_overriddenDeviceServers.join(', ')}.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  SegmentedButton<_McpTransportFilter>(
                    segments: const [
                      ButtonSegment(value: _McpTransportFilter.all, label: Text('All')),
                      ButtonSegment(value: _McpTransportFilter.stdio, label: Text('Stdio')),
                      ButtonSegment(value: _McpTransportFilter.remote, label: Text('Remote')),
                    ],
                    selected: {_transportFilter},
                    onSelectionChanged: (selection) async {
                      setState(() => _transportFilter = selection.first);
                      await _reconnectVisibleServers();
                    },
                  ),
                ],
              ),
            ),
            Expanded(child: _buildServerPane(context)),
          ],
        ),
        if (_isLoading)
          Positioned.fill(
            child: IgnorePointer(
              child: Container(
                color: theme.colorScheme.surface.withValues(alpha: 0.72),
                alignment: Alignment.center,
                child: const CircularProgressIndicator(),
              ),
            ),
          ),
      ],
    );
    if (widget.embedded) return body;
    return Scaffold(
      appBar: AppBar(
        title: const Text('MCP'),
        actions: [
          IconButton(
            onPressed: _openAddServer,
            icon: const Icon(Icons.add),
            tooltip: 'Add MCP Server',
          ),
        ],
      ),
      body: body,
    );
  }

  Widget _buildServerPane(BuildContext context) {
    if (_source == _McpConfigSource.workspace && _workspacePath == null) {
      return _buildEmptyMessage(
        context,
        'Select a workspace to manage local MCP servers.',
      );
    }

    final servers = _currentServers;
    if (servers.isEmpty) {
      return _buildEmptyMessage(
        context,
        'No MCP servers found for this source and filter.',
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: servers.length,
      separatorBuilder: (_, _) => const SizedBox(height: 12),
      itemBuilder: (context, index) => _buildServerCard(context, servers[index]),
    );
  }

  Widget _buildServerCard(BuildContext context, McpServerConfig server) {
    final isConnected = _activeConnections.containsKey(server.id);
    final isConnecting = _isConnecting[server.id] == true;
    final error = _connectionErrors[server.id];
    final tools = _serverTools[server.id] ?? const <McpRuntimeTool>[];
    final isExpanded = _expandedServerIds.contains(server.id);

    final statusText = !server.enabled
        ? 'Disabled'
        : isConnecting
        ? 'Connecting...'
        : error ?? (isConnected ? '${tools.length} tools' : 'Disconnected');

    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: '${server.name}, ${server.enabled ? 'Enabled' : 'Disabled'}, ${tools.length} tools',
      child: Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.12)),
        ),
        child: Column(
          children: [
            Semantics(
              button: true,
              container: true,
              explicitChildNodes: true,
              label: '${isExpanded ? 'Collapse' : 'Expand'} ${server.name} details',

              child: InkWell(
                excludeFromSemantics: true,
                onTap: () {
                  setState(() {
                    if (isExpanded) {
                      _expandedServerIds.remove(server.id);
                    } else {
                      _expandedServerIds.add(server.id);
                    }
                  });
                },
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      _StatusDot(
                        color: !server.enabled
                            ? Theme.of(context).colorScheme.outline
                            : error != null
                            ? Theme.of(context).colorScheme.error
                            : isConnected
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              server.name,
                              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: 4),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                _MetaChip(label: server.enabled ? 'Enabled' : 'Disabled'),
                                _MetaChip(label: _transportLabel(server)),
                                _MetaChip(label: server.authType.displayName),
                                _MetaChip(label: '${tools.length} tools'),
                                if (_source == _McpConfigSource.effective) _MetaChip(label: _originLabel(server)),
                                if (server.disabledTools.isNotEmpty)
                                  _MetaChip(label: '${server.disabledTools.length} disabled'),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text(
                              statusText,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: error != null
                                    ? Theme.of(context).colorScheme.error
                                    : Theme.of(context).colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Semantics(
                        excludeSemantics: true,
                        label: '${server.enabled ? 'Disable' : 'Enable'} ${server.name}',
                        toggled: server.enabled,

                        child: Switch(
                          value: server.enabled,
                          onChanged: _canEditCurrentSource ? (value) => _toggleServerEnabled(server, value) : null,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (isExpanded)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Divider(color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.12)),
                    if (tools.isEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          server.enabled ? 'Connect to discover tools.' : 'Server is disabled.',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ...tools.map(
                      (tool) => Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(tool.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                                  const SizedBox(height: 4),
                                  Text(
                                    tool.description,
                                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 12),
                            Column(
                              children: [
                                Semantics(
                                  excludeSemantics: true,
                                  label: '${server.isToolDisabled(tool.name) ? 'Enable' : 'Disable'} tool ${tool.name}',
                                  toggled: !server.isToolDisabled(tool.name),
                                  child: Switch(
                                    value: !server.isToolDisabled(tool.name),
                                    onChanged: _canEditCurrentSource
                                        ? (value) => _toggleToolEnabled(server, tool.name, value)
                                        : null,
                                  ),
                                ),
                                Text(
                                  server.isToolDisabled(tool.name) ? 'Disabled' : 'Enabled',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Wrap(
                      alignment: WrapAlignment.end,
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        OutlinedButton.icon(
                          onPressed: () => _connectToServer(server, _connectionRefreshCycle),
                          icon: const Icon(Icons.wifi_find),
                          label: const Text('Test'),
                        ),
                        if (_source != _McpConfigSource.effective || _effectiveOrigins.containsKey(server.name))
                          OutlinedButton.icon(
                            onPressed: () => _openEditServer(server),
                            icon: const Icon(Icons.edit_outlined),
                            label: const Text('Edit'),
                          ),
                        PopupMenuButton<String>(
                          tooltip: 'Advanced actions',
                          onSelected: (value) {
                            if (value == 'export') unawaited(_exportServer(server));
                            if (value == 'json') unawaited(_editAdvancedJson(server));
                          },
                          itemBuilder: (context) => const [
                            PopupMenuItem(value: 'export', child: Text('Export JSON')),
                            PopupMenuItem(value: 'json', child: Text('Edit JSON')),
                          ],
                        ),
                        if (_canEditCurrentSource)
                          TextButton.icon(
                            onPressed: () => _deleteServer(server),
                            icon: const Icon(Icons.delete_outline),
                            label: const Text('Remove'),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyMessage(BuildContext context, String message) {
    return Center(
      child: Text(
        message,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        textAlign: TextAlign.center,
      ),
    );
  }

  String _originLabel(McpServerConfig server) {
    return switch (_effectiveOrigins[server.name]) {
      _McpConfigSource.workspace => 'Workspace',
      _McpConfigSource.global => 'Device',
      _ => 'Unknown',
    };
  }

  Set<String> get _overriddenDeviceServers {
    final workspaceNames = _workspaceServers.map((server) => server.name.trim().toLowerCase()).toSet();
    return _globalServers
        .where((server) => workspaceNames.contains(server.name.trim().toLowerCase()))
        .map((server) => server.name)
        .toSet();
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
      ),
    );
  }
}

class _MetaChip extends StatelessWidget {
  const _MetaChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

String _transportLabel(McpServerConfig server) {
  return switch (server.transport) {
    McpTransportType.auto => 'Auto-detect',
    McpTransportType.stdio => 'STDIO',
    McpTransportType.sse => 'SSE',
    McpTransportType.streamableHttp => 'HTTP',
  };
}
