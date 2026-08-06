import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:sanad_client/core/di/injection.dart';
import 'package:sanad_client/core/navigation/app_routes.dart';
import 'package:sanad_client/features/conversations/data/repositories/conversation_cache_repository.dart';
import 'package:sanad_client/features/conversations/domain/models/device_conversation_cache_snapshot.dart';
import 'package:sanad_client/features/conversations/domain/models/device_workspace.dart';
import 'package:sanad_client/utils/workspace_picker_helper.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/devices/presentation/bloc/device_cubit.dart';
import 'package:sanad_client/features/devices/presentation/bloc/device_state.dart';
import 'package:sanad_client/utils/app_platform.dart';
import 'package:sanad_client/utils/toast_utils.dart';

import 'package:sanad_client/features/devices/data/device_inventory_source.dart';
import 'package:sanad_client/features/mcp/presentation/screens/mcp_server_management_screen.dart';

import '../widgets/settings_navigation.dart';
import '../widgets/settings_pages.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _cache = getIt<ConversationCacheRepository>();
  SettingsDestination _destination = SettingsDestination.general;
  String? _selectedDeviceId;
  String? _selectedWorkspaceId;
  bool _showAllWorkspaces = false;
  bool _appliedRouteIntent = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_appliedRouteIntent) return;

    final queryParams = GoRouterState.of(context).uri.queryParameters;
    final section = queryParams['section'];
    final queryDeviceId = queryParams['device_id'];
    final queryWorkspaceId = queryParams['workspace_id'];

    final state = context.read<DeviceCubit>().state;
    if (state is DeviceActive || state is DeviceNoActive) {
      _appliedRouteIntent = true;
      final agents = state is DeviceActive ? state.agents : (state as DeviceNoActive).agents;
      final activeDevice = state is DeviceActive ? state.activeAgent : null;
      final targetDevice = agents.where((a) => a.id == queryDeviceId).firstOrNull ?? activeDevice ?? agents.firstOrNull;

      if (targetDevice != null) {
        _selectedDeviceId = targetDevice.id;

        if (section == 'providers') {
          _destination = SettingsDestination.providers;
        } else if (section == 'device' || section == 'overview') {
          _destination = SettingsDestination.overview;
        } else if (section == 'mcp') {
          _destination = SettingsDestination.mcp;
        } else if (section == 'skills') {
          _destination = SettingsDestination.skills;
        } else if (section != null) {
          final matchedDest = SettingsDestination.values.where((d) => d.name == section).firstOrNull;
          if (matchedDest != null) {
            _destination = matchedDest;
          }
        } else {
          _destination = SettingsDestination.overview;
        }
        if (_destination == SettingsDestination.workspace && queryWorkspaceId != null && queryWorkspaceId.isNotEmpty) {
          _selectedWorkspaceId = queryWorkspaceId;
          _showAllWorkspaces = true;
        }
        unawaited(_cache.refreshWorkspaces(targetDevice));
      }
    }
  }

  void _selectDevice(DeviceConfig device) {
    setState(() {
      _selectedDeviceId = device.id;
      _selectedWorkspaceId = null;
      _destination = SettingsDestination.overview;
      _showAllWorkspaces = false;
    });
    unawaited(_cache.refreshWorkspaces(device));
  }

  void _selectPersonal(SettingsDestination destination) {
    setState(() {
      _destination = destination;
      _selectedWorkspaceId = null;
    });
  }

  Future<void> _renameWorkspace(
    DeviceConfig device,
    DeviceWorkspace workspace,
  ) async {
    var value = workspace.name;
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Rename Workspace'),
        content: TextFormField(
          initialValue: workspace.name,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Workspace name'),
          onChanged: (v) => value = v,
          onFieldSubmitted: (v) => Navigator.of(dialogContext).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(value),
            child: const Text('Rename'),
          ),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty) return;
    try {
      await _cache.renameWorkspace(
        device,
        workspaceId: workspace.id,
        displayName: name,
      );
    } catch (error) {
      if (mounted) {
        ToastUtils.showError(
          context,
          _workspaceMutationError(error, 'Could not rename workspace.'),
        );
      }
    }
  }

  Future<void> _changeWorkspacePath(
    DeviceConfig device,
    DeviceWorkspace workspace,
  ) async {
    final path = await WorkspacePickerHelper.pickWorkspacePath(
      context: context,
      device: device,
      confirmButtonText: 'Change Path',
    );
    if (path == null || path.trim().isEmpty) return;
    try {
      await _cache.relocateWorkspace(
        device,
        workspaceId: workspace.id,
        newPath: path,
      );
    } catch (error) {
      if (mounted) {
        ToastUtils.showError(
          context,
          _workspaceMutationError(error, 'Could not change workspace path.'),
        );
      }
    }
  }

  String _workspaceMutationError(Object error, String fallback) {
    return switch (error) {
      StateError() => error.message.toString(),
      FormatException() => error.message,
      _ => fallback,
    };
  }

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<DeviceCubit, DeviceState>(
      builder: (context, state) {
        final devices = switch (state) {
          DeviceActive() => state.agents,
          DeviceNoActive() => state.agents,
          _ => const <DeviceConfig>[],
        }.where((device) => device.id != DeviceInventoryIds.localDevice || device.isLocalReachable).toList();
        final activeDevice = state is DeviceActive ? state.activeAgent : null;
        final selected = devices.where((device) => device.id == _selectedDeviceId).firstOrNull;

        return StreamBuilder<DeviceConversationCacheSnapshot>(
          stream: _cache.snapshotStream,
          initialData: _cache.snapshot,
          builder: (context, cacheSnapshot) {
            final workspaces = selected == null
                ? const <DeviceWorkspace>[]
                : cacheSnapshot.data?.contexts[selected.id]?.workspaces.workspaces ?? const <DeviceWorkspace>[];
            final selectedWorkspace = workspaces.where((workspace) => workspace.id == _selectedWorkspaceId).firstOrNull;

            return LayoutBuilder(
              builder: (context, constraints) {
                final compact = constraints.maxWidth < 820;
                final navigation = SettingsNavigation(
                  devices: devices,
                  activeDeviceId: activeDevice?.id,
                  selectedDevice: selected,
                  selectedDestination: _destination,
                  workspaces: workspaces,
                  selectedWorkspaceId: _selectedWorkspaceId,
                  showAllWorkspaces: _showAllWorkspaces,
                  onSelectPersonal: (dest) {
                    _selectPersonal(dest);
                    if (compact) Navigator.of(context).pop();
                  },
                  onSelectDevice: (device) {
                    _selectDevice(device);
                    if (compact) Navigator.of(context).pop();
                  },
                  onSelectDeviceSection: (destination) {
                    setState(() {
                      _destination = destination;
                      _selectedWorkspaceId = null;
                    });
                    if (compact) Navigator.of(context).pop();
                  },
                  onSelectWorkspace: (workspace) {
                    setState(() {
                      _selectedWorkspaceId = workspace.id;
                      _destination = SettingsDestination.workspace;
                    });
                    if (compact) Navigator.of(context).pop();
                  },
                  onToggleWorkspaces: () => setState(() => _showAllWorkspaces = !_showAllWorkspaces),
                );
                final content = _buildContent(context, selected, activeDevice, selectedWorkspace);

                if (compact) {
                  return Scaffold(
                    appBar: AppBar(
                      title: const Text('Settings'),
                      leading: IconButton(
                        icon: const Icon(Icons.arrow_back_rounded),
                        tooltip: 'Back to conversations',
                        onPressed: () {
                          if (context.canPop()) {
                            context.pop();
                          } else {
                            context.go(AppRoutes.home);
                          }
                        },
                      ),
                      actions: [
                        Builder(
                          builder: (context) {
                            return IconButton(
                              icon: const Icon(Icons.menu_rounded),
                              tooltip: 'Open settings menu',
                              onPressed: () => Scaffold.of(context).openDrawer(),
                            );
                          },
                        ),
                      ],
                    ),
                    drawer: Drawer(child: SafeArea(child: navigation)),
                    body: content,
                  );
                }
                return Scaffold(
                  body: SafeArea(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 300,
                          margin: EdgeInsets.all(AppPlatform.isMacOS ? 8 : 0),
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.surface,
                            border: Border.all(color: Theme.of(context).colorScheme.outline),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: navigation,
                        ),
                        Expanded(child: content),
                      ],
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _buildContent(
    BuildContext context,
    DeviceConfig? selected,
    DeviceConfig? activeDevice,
    DeviceWorkspace? workspace,
  ) {
    if (_destination == SettingsDestination.profile) return const ProfilePage();
    if (_destination == SettingsDestination.general) return const GeneralPage();
    if (selected == null) return const EmptyDevicePage();

    return switch (_destination) {
      SettingsDestination.overview => DeviceOverviewPage(
        key: ValueKey('overview-${selected.id}'),
        device: selected,
        isActive: selected.id == activeDevice?.id,
      ),
      SettingsDestination.providers => ProvidersPage(
        key: ValueKey('providers-${selected.id}'),
        device: selected,
      ),
      SettingsDestination.mcp => McpServerManagementScreen(
        key: ValueKey('mcp-${selected.id}'),
        device: selected,
        embedded: true,
      ),
      SettingsDestination.skills => SkillsPage(
        key: ValueKey('skills-${selected.id}'),
        device: selected,
      ),
      SettingsDestination.workspace when workspace != null => WorkspacePage(
        key: ValueKey('workspace-${selected.id}-${workspace.id}'),
        device: selected,
        workspace: workspace,
        onRename: () => _renameWorkspace(selected, workspace),
        onChangePath: () => _changeWorkspacePath(selected, workspace),
      ),
      _ => const EmptyDevicePage(),
    };
  }
}
