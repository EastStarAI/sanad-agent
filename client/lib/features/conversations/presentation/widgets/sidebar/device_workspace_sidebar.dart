import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../../../../core/navigation/app_routes.dart';
import '../../../../../utils/app_platform.dart';
import '../../../../auth/presentation/widgets/user_profile_tile.dart';
import '../../../../devices/domain/models/device_config.dart';
import '../../../../devices/presentation/bloc/device_cubit.dart';
import '../../../../devices/presentation/bloc/device_state.dart';
import '../../../data/repositories/conversation_cache_repository.dart';
import '../../../domain/models/conversation_resource_state.dart';
import '../../../domain/models/device_workspace.dart';
import '../../../domain/models/session.dart';
import '../../../domain/models/sidebar_conversation_group.dart';
import '../../../../../utils/toast_utils.dart';
import '../../../../../utils/workspace_picker_helper.dart';
import '../../bloc/session_cubit.dart';
import '../../bloc/session_sidebar_cubit.dart';
import '../../bloc/session_sidebar_state.dart';
import 'sidebar_composition.dart';
import 'sidebar_device_header_bar.dart';
import 'sidebar_sections.dart';
import 'sidebar_workspace_group_tile.dart';

/// Redesigned device workspace sidebar (Plan 32c).
///
/// Replaces the flat `Devices -> Sessions` tree with:
/// ```
/// [ Selected device v ] [ Settings ]
/// Workspaces               +
///   workspace-a            +
///     Conversation A
///     ...
/// Conversations
///   Unscoped conversation
/// ```
///
/// Gate C0 fixes the composition and ownership contract. All session/workspace
/// data flows from [ConversationCacheRepository] via [SessionSidebarCubit];
/// the device list comes from [DeviceCubit]. The shell is a layout container
/// that wires intents to cubit/repository calls — it owns no cache.
class DeviceWorkspaceSidebar extends StatelessWidget {
  final bool isDrawerMode;
  final VoidCallback? onClose;
  final bool showChrome;
  final double? width;

  @visibleForTesting
  static Future<String?> Function()? debugPickDirectoryPath;

  const DeviceWorkspaceSidebar({
    super.key,
    this.isDrawerMode = false,
    this.onClose,
    this.showChrome = true,
    this.width,
  });

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final sidebarWidth =
        (width ??
                (isDrawerMode
                    ? mediaQuery.size.width * SidebarBreakpoints.drawerWidthFactor
                    : SidebarBreakpoints.desktopWidth))
            .clamp(
              SidebarBreakpoints.minWidth,
              isDrawerMode ? mediaQuery.size.width : SidebarBreakpoints.maxWidth,
            );
    final isMacOS = AppPlatform.isMacOS;
    final theme = Theme.of(context);

    Widget buildDeviceHeader() {
      return BlocSelector<
        DeviceCubit,
        DeviceState,
        ({List<DeviceConfig> devices, DeviceConfig? active, bool isLoading})
      >(
        selector: _deviceSelectorWithLoading,
        builder: (context, data) {
          return SidebarDeviceHeaderBar(
            devices: data.devices,
            activeDevice: data.active,
            onDeviceSelected: (device) => context.read<DeviceCubit>().setActiveAgent(device.id),
            onSettingsTapped: () => context.push(AppRoutes.settings),
            isDrawerMode: isDrawerMode,
            isLoadingFromBackend: data.isLoading,
          );
        },
      );
    }

    return Semantics(
      container: true,
      label: 'Conversation sidebar',
      child: FocusTraversalGroup(
        child: Container(
          width: sidebarWidth,
          margin: EdgeInsets.zero,
          decoration: BoxDecoration(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: theme.colorScheme.outline.withValues(alpha: 0.20),
            ),
          ),
          child: SafeArea(
            top: !isMacOS,
            child: Column(
              children: [
                if (!isDrawerMode)
                  SizedBox(height: isMacOS ? SidebarBreakpoints.macOSTrafficLightsHeight : 32)
                else if (isMacOS)
                  const SizedBox(
                    key: Key('macos_drawer_traffic_lights_spacer'),
                    height: SidebarBreakpoints.macOSTrafficLightsHeight + SidebarBreakpoints.macOSDrawerTopGap,
                  ),

                buildDeviceHeader(),
                Expanded(
                  child: BlocSelector<DeviceCubit, DeviceState, ({DeviceConfig? active, List<DeviceConfig> devices})>(
                    selector: _deviceSelector,
                    builder: (context, deviceState) {
                      return BlocSelector<
                        SessionSidebarCubit,
                        SessionSidebarState,
                        ({String? activeDeviceId, bool showInitialLoading, bool hasSnapshot})
                      >(
                        selector: (state) => (
                          activeDeviceId: state.activeDeviceId,
                          showInitialLoading: state.showInitialLoading,
                          hasSnapshot: state.snapshot != null,
                        ),
                        builder: (context, sidebar) {
                          final snapshotDevice = sidebar.activeDeviceId == null
                              ? null
                              : deviceState.devices.where((device) => device.id == sidebar.activeDeviceId).firstOrNull;
                          final activeDevice = snapshotDevice ?? deviceState.active;
                          if (activeDevice == null) {
                            return _emptyState(context, 'No device selected');
                          }
                          if (sidebar.activeDeviceId != null && sidebar.activeDeviceId != activeDevice.id) {
                            return const SizedBox.shrink();
                          }
                          if (sidebar.showInitialLoading && !sidebar.hasSnapshot) {
                            return const Center(child: CircularProgressIndicator(strokeWidth: 2));
                          }
                          return _SidebarBody(
                            device: activeDevice,
                            isDrawerMode: isDrawerMode,
                            onClose: onClose,
                          );
                        },
                      );
                    },
                  ),
                ),
                if (showChrome) const UserProfileTile(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static ({List<DeviceConfig> devices, DeviceConfig? active}) _deviceSelector(DeviceState state) {
    return switch (state) {
      DeviceActive(:final activeAgent, :final agents) => (devices: agents, active: activeAgent),
      DeviceNoActive(:final agents) => (devices: agents, active: null),
      _ => (devices: const <DeviceConfig>[], active: null),
    };
  }

  static ({List<DeviceConfig> devices, DeviceConfig? active, bool isLoading}) _deviceSelectorWithLoading(
    DeviceState state,
  ) {
    return switch (state) {
      DeviceActive(:final activeAgent, :final agents) => (devices: agents, active: activeAgent, isLoading: false),
      DeviceNoActive(:final agents, :final isLoadingFromBackend) => (
        devices: agents,
        active: null,
        isLoading: isLoadingFromBackend,
      ),
      _ => (devices: const <DeviceConfig>[], active: null, isLoading: false),
    };
  }

  Widget _emptyState(BuildContext context, String message) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          message,
          style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 14),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

class _SidebarBody extends StatelessWidget {
  final DeviceConfig device;
  final bool isDrawerMode;
  final VoidCallback? onClose;

  const _SidebarBody({
    required this.device,
    required this.isDrawerMode,
    this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final sidebarCubit = context.read<SessionSidebarCubit>();
    final sessionCubit = context.read<SessionCubit>();
    final cacheRepository = context.read<ConversationCacheRepository>();
    void selectSession(SessionRef ref) {
      final sessions = cacheRepository.sessionsForDevice(device.id);
      Session? found;
      for (final session in sessions) {
        if (session.id == ref.id) {
          found = session;
          break;
        }
      }
      final target = found ?? _fallbackSession(ref.id);
      unawaited(sessionCubit.selectSession(target));
      context.go(AppRoutes.sessionLocation(device.id, ref.id));
      if (isDrawerMode && onClose != null) onClose!();
    }

    Future<void> createWorkspace() async {
      final selected = await WorkspacePickerHelper.promptCreateWorkspace(
        context: context,
        device: device,
        debugLocalPath: DeviceWorkspaceSidebar.debugPickDirectoryPath,
      );
      if (selected == null) return;
      final workspace = await cacheRepository.createWorkspace(
        device,
        path: selected.path,
        name: selected.name,
        description: selected.description,
      );
      if (workspace != null && context.mounted) {
        unawaited(sidebarCubit.loadWorkspaceConversationsIfNeeded(device, workspace.id));
      } else if (context.mounted) {
        ToastUtils.showError(context, 'Could not create workspace');
      }
    }

    Future<void> newConversationIn(String? workspaceId) async {
      await sessionCubit.startNewChat(device, workspaceId: workspaceId);
      if (!context.mounted) return;
      final targetWorkspaceId = cacheRepository.newConversationDraft(device.id).workspaceId;
      context.go(
        AppRoutes.newConversationLocation(
          device.id,
          workspaceId: targetWorkspaceId,
        ),
      );
      if (isDrawerMode && onClose != null) onClose!();
    }

    Future<void> toggleExpansion(String workspaceId) async {
      final wasExpanded = sidebarCubit.state.isWorkspaceExpanded(workspaceId);
      sidebarCubit.toggleWorkspaceExpansion(device.id, workspaceId);
      if (!wasExpanded) {
        await sidebarCubit.loadWorkspaceConversationsIfNeeded(device, workspaceId);
      }
    }

    return CustomScrollView(
      key: const Key('device_workspace_sidebar_scroll'),
      slivers: [
        SliverToBoxAdapter(
          child: _SidebarStatusBanner(
            device: device,
            isDrawerMode: isDrawerMode,
            onRetry: () => sidebarCubit.refreshDevice(device),
          ),
        ),
        SliverToBoxAdapter(child: SizedBox(height: 8)),
        SliverToBoxAdapter(
          child: _NewSessionButton(
            device: device,
            isDrawerMode: isDrawerMode,
            onTap: () => newConversationIn(null),
          ),
        ),
        SliverToBoxAdapter(
          child: BlocSelector<SessionSidebarCubit, SessionSidebarState, _WorkspaceShellSlice>(
            selector: (state) => _WorkspaceShellSlice(
              workspaces: state.snapshot?.workspaces ?? const <DeviceWorkspace>[],
              groups: state.workspaceGroups,
              workspacesState: state.workspacesState,
              contentRevision: _workspaceGroupsRevision(state.workspaceGroups),
              expansion: state.snapshot?.workspaceExpansion ?? const <String, bool>{},
            ),
            builder: (context, section) {
              return SidebarWorkspacesSection(
                workspaces: section.workspaces,
                workspaceTiles: [
                  for (final workspace in section.workspaces)
                    if (_groupByWorkspaceId(section.groups, workspace.id) case final group?)
                      SidebarWorkspaceGroupTile(
                        key: ValueKey('workspace-group:${workspace.id}'),
                        device: device,
                        group: group,
                        isExpanded: section.expansion[workspace.id] ?? true,
                        isDrawerMode: isDrawerMode,
                        onToggleExpansion: () => toggleExpansion(workspace.id),
                        onNewConversation: () => newConversationIn(workspace.id),
                        onLoadMore: () => sidebarCubit.loadMore(device, workspaceId: workspace.id),
                        onRetry: () => sidebarCubit.refreshWorkspaceConversations(device, workspace.id),
                        onSessionSelected: selectSession,
                        isWorkspaceAvailable: workspace.isAvailable,
                        onOpenWorkspaceSettings: () => context.push(
                          AppRoutes.workspaceSettingsLocation(
                            device.id,
                            workspace.id,
                          ),
                        ),
                      ),
                ],
                workspacesState: section.workspacesState,
                isDrawerMode: isDrawerMode,
                onCreateWorkspace: createWorkspace,
                onRetryWorkspaces: () => sidebarCubit.refreshWorkspaces(device),
              );
            },
          ),
        ),
        SliverToBoxAdapter(
          child: BlocSelector<SessionSidebarCubit, SessionSidebarState, ({SidebarConversationGroup? group})>(
            selector: (state) => (group: state.unscopedGroup),
            builder: (context, section) {
              return SidebarUnscopedConversationsSection(
                device: device,
                group: section.group,
                isDrawerMode: isDrawerMode,
                onLoadMore: () => sidebarCubit.loadMore(device, workspaceId: null),
                onRetry: () => sidebarCubit.refreshUnscopedConversations(device),
                onNewConversation: () => newConversationIn(null),
                onSessionSelected: selectSession,
              );
            },
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 8)),
      ],
    );
  }

  Session _fallbackSession(String id) => Session(
    id: id,
    title: 'Loading…',
    deviceId: device.id,
    createdAt: DateTime.now(),
    updatedAt: DateTime.now(),
  );
}

class _WorkspaceShellSlice extends Equatable {
  final List<DeviceWorkspace> workspaces;
  final List<SidebarConversationGroup> groups;
  final ConversationResourceState workspacesState;
  final String contentRevision;
  final Map<String, bool> expansion;

  const _WorkspaceShellSlice({
    required this.workspaces,
    required this.groups,
    required this.workspacesState,
    required this.contentRevision,
    this.expansion = const <String, bool>{},
  });

  @override
  List<Object?> get props => [workspaces, workspacesState, contentRevision, expansion];
}

SidebarConversationGroup? _groupByWorkspaceId(
  List<SidebarConversationGroup> groups,
  String workspaceId,
) {
  for (final group in groups) {
    if (group.workspaceId == workspaceId) return group;
  }
  return null;
}

String _workspaceGroupsRevision(List<SidebarConversationGroup> groups) {
  return groups.map(_sidebarGroupRevision).join('||');
}

String _sidebarGroupRevision(SidebarConversationGroup group) {
  return [
    group.workspaceId,
    group.state.name,
    group.hasMore,
    group.isLoadingMore,
    for (final session in group.sessions)
      '${session.id}|${session.title}|${session.updatedAt.toIso8601String()}|'
          '${session.lastMessageAt?.toIso8601String()}|${session.metadata}',
  ].join('::');
}

class _SidebarStatusBanner extends StatelessWidget {
  final DeviceConfig device;
  final bool isDrawerMode;
  final Future<void> Function() onRetry;

  const _SidebarStatusBanner({
    required this.device,
    required this.isDrawerMode,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return BlocSelector<SessionSidebarCubit, SessionSidebarState, bool>(
      selector: (state) =>
          state.workspacesState == ConversationResourceState.staleError ||
          state.sectionStates.values.contains(ConversationResourceState.staleError),
      builder: (context, hasStaleError) {
        if (!hasStaleError && device.isOnline) {
          return const SizedBox.shrink();
        }
        final theme = Theme.of(context);
        final messages = <String>[
          if (!device.isOnline) 'Offline — showing cached conversations',
          if (hasStaleError) 'Could not refresh all sections',
        ];
        return Padding(
          padding: const EdgeInsets.fromLTRB(
            8,
            8,
            8,
            4,
          ),
          child: Semantics(
            container: true,
            liveRegion: true,
            label: messages.join('. '),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: theme.colorScheme.outline.withValues(alpha: 0.4)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    !device.isOnline ? Icons.cloud_off_outlined : (hasStaleError ? Icons.info_outline : Icons.sync),
                    size: 16,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      messages.join(' • '),
                      style: TextStyle(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontSize: 11,
                        height: 1.35,
                      ),
                    ),
                  ),
                  if (hasStaleError || !device.isOnline)
                    TextButton(
                      onPressed: onRetry,
                      style: TextButton.styleFrom(
                        minimumSize: const Size(44, 36),
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        tapTargetSize: MaterialTapTargetSize.padded,
                      ),
                      child: const Text('Retry'),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _NewSessionButton extends StatelessWidget {
  final DeviceConfig device;
  final bool isDrawerMode;
  final VoidCallback onTap;

  const _NewSessionButton({
    required this.device,
    required this.isDrawerMode,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: 0,
        vertical: 0,
      ),
      child: Material(
        key: const Key('sidebar_new_session_btn'),
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          hoverColor: theme.colorScheme.surfaceContainer.withValues(alpha: 0.8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Row(
              children: [
                Icon(
                  Symbols.edit_square,
                  size: 16,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'New Session',
                    style: TextStyle(
                      color: theme.colorScheme.onSurface,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
