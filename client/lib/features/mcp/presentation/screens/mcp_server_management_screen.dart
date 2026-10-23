import 'dart:async';
import 'package:flutter/material.dart';
import 'package:sanad_client/core/presentation/widgets/app_progress_indicator.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:sanad_client/l10n/app_localizations.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'package:sanad_client/core/di/injection.dart';
import 'package:sanad_client/core/navigation/app_routes.dart';
import 'package:sanad_client/features/mcp/data/mcp_runtime_client.dart';
import 'package:sanad_client/features/mcp/domain/models/mcp_runtime_models.dart';
import 'package:sanad_client/features/mcp/domain/models/mcp_server_config.dart';
import 'package:sanad_client/features/mcp/presentation/widgets/mcp_advanced_json_dialog.dart';
import 'package:sanad_client/features/mcp/presentation/widgets/mcp_server_card.dart';
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
  bool _mutating = false;
  int _connectionRefreshCycle = 0;

  String? _workspaceId;
  String? _workspaceName;
  List<McpServerConfig> _globalServers = const [];
  List<McpServerConfig> _workspaceServers = const [];
  List<McpServerConfig> _effectiveServers = const [];
  McpRuntimeSnapshot? _snapshot;

  @override
  void initState() {
    super.initState();
    if (widget.workspaceId != null) {
      _source = _McpConfigSource.workspace;
    }
    unawaited(_loadData());
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);

    if (!_deviceOnline) {
      if (mounted) setState(() => _isLoading = false);
      return;
    }

    try {
      final workspace = _workspaceRuntimeContext.activeWorkspace;
      _workspaceId = widget.workspaceId ?? (workspace?.id.trim().isNotEmpty == true ? workspace!.id.trim() : null);
      _workspaceName = widget.workspaceName ?? workspace?.name;
      _applySnapshot(
        await context.read<McpRuntimeClient>().listServers(
          device: _targetDevice,
          workspaceId: _workspaceId,
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
    _workspaceId = snapshot.workspaceId ?? _workspaceId;
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
        workspaceId: _workspaceId,
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
    if (!_canEditCurrentSource || _mutating || !_deviceOnline) {
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(AppLocalizations.of(context)!.mcpDeleteServer),
        content: Text(AppLocalizations.of(context)!.mcpDeleteConfirm(server.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(AppLocalizations.of(context)!.mcpCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(AppLocalizations.of(context)!.mcpDelete),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) {
      return;
    }

    setState(() => _mutating = true);
    try {
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
    } catch (error) {
      await _loadData();
      if (mounted) {
        ToastUtils.showError(context, error.toString());
      }
    } finally {
      if (mounted) setState(() => _mutating = false);
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
        workspaceId: _workspaceId,
      );
      await Clipboard.setData(ClipboardData(text: result.json));
      if (mounted) {
        ToastUtils.showSuccess(
          context,
          AppLocalizations.of(context)!.mcpCopiedRedacted,
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
    final workspaceId = source == _McpConfigSource.workspace ? _workspaceId : null;
    try {
      final document = await context.read<McpRuntimeClient>().readAdvanced(
        device: _targetDevice,
        serverName: server.name,
        scope: scope,
        workspaceId: workspaceId,
      );
      if (!mounted) return;
      final saved = await showMcpAdvancedJsonDialog(
        context: context,
        device: _targetDevice,
        server: server,
        scope: scope,
        workspaceId: workspaceId,
        document: document,
      );
      if (saved == true) await _loadData();
    } catch (error) {
      if (mounted) ToastUtils.showError(context, error.toString());
    }
  }

  Future<void> _openAddServer() async {
    if (!_deviceOnline || _mutating) {
      return;
    }
    if (_source == _McpConfigSource.effective) {
      if (_workspaceId == null) {
        final result = await context.push(
          AppRoutes.addMcpServer,
          extra: _extraForSource(_McpConfigSource.global),
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
                title: Text(AppLocalizations.of(context)!.mcpAddToDevice),
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
        'workspaceId': _workspaceId,
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
    if (_source == _McpConfigSource.workspace && (_workspaceId == null || _workspaceId!.isEmpty)) {
      return false;
    }
    return true;
  }

  String? get _editableWorkspacePath {
    return _source == _McpConfigSource.workspace ? _workspaceId : null;
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
    throw StateError(AppLocalizations.of(context)!.mcpSelectDeviceFirst);
  }

  bool get _deviceOnline {
    try {
      return _targetDevice.isOnline;
    } catch (_) {
      return false;
    }
  }

  bool get _canMutate => _deviceOnline && !_mutating && _canEditCurrentSource;

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
                  if (widget.embedded)
                    Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton.icon(
                        key: const ValueKey('add-mcp-server'),
                        onPressed: _deviceOnline && !_mutating ? _openAddServer : null,
                        icon: const Icon(Icons.add),
                        label: Text(AppLocalizations.of(context)!.mcpAddToList),
                      ),
                    ),
                  if (widget.embedded && _workspaceId != null) const SizedBox(height: 12),
                  if (_workspaceId != null)
                    SegmentedButton<_McpConfigSource>(
                      key: const Key('mcp_scope_segment_btn'),
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
                          enabled: _workspaceId != null,
                        ),
                        ButtonSegment(
                          value: _McpConfigSource.effective,
                          label: Text(AppLocalizations.of(context)!.mcpEffective),
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
                child: const AppProgressIndicator(),
              ),
            ),
          ),
      ],
    );
    if (widget.embedded) return body;
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: const Text('MCP'),
        actions: [
          IconButton(
            onPressed: _deviceOnline && !_mutating ? _openAddServer : null,
            icon: const Icon(Icons.add),
            tooltip: AppLocalizations.of(context)!.mcpAddServerTitle,
          ),
        ],
      ),
      body: body,
    );
  }

  Widget _buildServerPane(BuildContext context) {
    if (!_deviceOnline) {
      return _buildEmptyMessage(
        context,
        AppLocalizations.of(context)!.mcpDeviceOffline,
      );
    }
    if (_source == _McpConfigSource.workspace && _workspaceId == null) {
      return _buildEmptyMessage(
        context,
        AppLocalizations.of(context)!.mcpSelectWorkspaceFirst,
      );
    }

    final servers = _currentServers;
    if (servers.isEmpty) {
      return _buildEmptyMessage(
        context,
        AppLocalizations.of(context)!.mcpNoServers,
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
    final isExpanded = _expandedServerIds.contains(server.id);
    return McpServerCard(
      server: server,
      isConnected: _activeConnections.containsKey(server.id),
      isConnecting: _isConnecting[server.id] == true,
      error: _connectionErrors[server.id],
      tools: _serverTools[server.id] ?? const <McpRuntimeTool>[],
      isExpanded: isExpanded,
      originLabel: _source == _McpConfigSource.effective ? _originLabel(server) : null,
      showEdit: _source != _McpConfigSource.effective || _effectiveOrigins.containsKey(server.name),
      canEditCurrentSource: _canEditCurrentSource,
      canTestOrEdit: _deviceOnline && !_mutating,
      canMutate: _canMutate,
      onToggleExpanded: () => setState(() {
        if (isExpanded) {
          _expandedServerIds.remove(server.id);
        } else {
          _expandedServerIds.add(server.id);
        }
      }),
      onToggleEnabled: (value) => _toggleServerEnabled(server, value),
      onToggleTool: (toolName, value) => _toggleToolEnabled(server, toolName, value),
      onTest: () => _connectToServer(server, _connectionRefreshCycle),
      onEdit: () => _openEditServer(server),
      onExport: () => unawaited(_exportServer(server)),
      onEditJson: () => unawaited(_editAdvancedJson(server)),
      onDelete: () => _deleteServer(server),
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
