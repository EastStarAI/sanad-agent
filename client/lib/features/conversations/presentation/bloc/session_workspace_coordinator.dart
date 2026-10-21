import 'dart:async';

import 'package:path/path.dart' as p;
import 'package:sanad_client/features/conversations/data/repositories/conversation_cache_repository.dart';
import 'package:sanad_client/features/conversations/domain/models/conversation_resource_state.dart';
import 'package:sanad_client/features/conversations/domain/models/device_conversation_cache_snapshot.dart';
import 'package:sanad_client/features/conversations/domain/models/device_workspace.dart';
import 'package:sanad_client/features/conversations/domain/models/session.dart';
import 'package:sanad_client/features/conversations/domain/models/workspace_tree_snapshot.dart';
import 'package:sanad_client/features/conversations/domain/repositories/conversation_repository.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_messages_state.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/devices/domain/stores/device_capabilities_store.dart';
import 'package:sanad_client/infrastructure/local_tools/local_tool_runtime_service.dart';
import 'package:sanad_client/infrastructure/local_tools/workspace_policy.dart';
import 'package:sanad_client/infrastructure/local_tools/workspace_tool_runtime_context.dart';

/// Encapsulates workspace resolution, caching, selection, browsing, folder creation,
/// permission modes, and local tool broadcasting for [SessionMessagesCubit].
class SessionWorkspaceCoordinator {
  final ConversationRepository conversationRepository;
  final ConversationCacheRepository? conversationCacheRepository;
  final DeviceCapabilitiesStore? capabilitiesStore;
  final LocalToolRuntimeService? localToolRuntime;
  final WorkspaceToolRuntimeContext? workspaceRuntimeContext;
  final SessionCubit sessionCubit;
  final DeviceConfig? Function() getCurrentAgent;

  /// The cubit's selected session id; a permission change made while a
  /// session is selected records or clears that session's explicit downgrade.
  final String? Function() getSelectedSessionId;
  final SessionMessagesState Function() getState;
  final void Function(SessionMessagesState) emit;
  final bool Function() getIsClosed;

  final Map<String, List<DeviceWorkspace>> _workspacesByAgentId = {};
  final Map<String, DeviceWorkspace> _selectedWorkspaceByAgentId = {};
  final Set<String> _loadingWorkspaceAgentIds = {};
  final Map<String, WorkspacePermissionMode> _permissionModesByWorkspaceId = {};

  /// Sessions whose full-access metadata the user explicitly downgraded.
  final Set<String> _downgradedSessionIds = {};
  final Set<String> _loadingPermissionModeWorkspaceIds = {};
  final Map<String, int> _workspacePolicyLoadIds = {};
  StreamSubscription<WorkspacePolicy>? _workspacePolicySubscription;

  SessionWorkspaceCoordinator({
    required this.conversationRepository,
    this.conversationCacheRepository,
    this.capabilitiesStore,
    this.localToolRuntime,
    this.workspaceRuntimeContext,
    required this.sessionCubit,
    required this.getCurrentAgent,
    required this.getSelectedSessionId,
    required this.getState,
    required this.emit,
    required this.getIsClosed,
  });

  List<DeviceWorkspace> workspacesForAgent(String agentId) =>
      _workspacesByAgentId[agentId] ?? const [];

  bool isLoadingWorkspaces(String agentId) =>
      _loadingWorkspaceAgentIds.contains(agentId);

  void handleCacheSnapshot(DeviceConversationCacheSnapshot snapshot) {
    final agent = getCurrentAgent();
    if (agent == null) return;
    final cachedWorkspaces = snapshot.contexts[agent.id]?.workspaces;
    if (cachedWorkspaces == null || !cachedWorkspaces.state.hasUsableSnapshot) return;

    final workspaces = List<DeviceWorkspace>.unmodifiable(cachedWorkspaces.workspaces);
    _workspacesByAgentId[agent.id] = workspaces;

    final currentSelection = _selectedWorkspaceByAgentId[agent.id];
    var selectedWorkspace = currentSelection;
    if (currentSelection != null) {
      for (final workspace in workspaces) {
        if (workspace.id == currentSelection.id) {
          selectedWorkspace = workspace;
          break;
        }
      }
      _selectedWorkspaceByAgentId[agent.id] = selectedWorkspace!;
      workspaceRuntimeContext?.setActiveWorkspace(selectedWorkspace);
    }

    if (!getIsClosed()) {
      emit(
        getState().copyWith(
          availableWorkspaces: workspaces,
          selectedWorkspace: selectedWorkspace,
          clearSelectedWorkspace: selectedWorkspace == null,
        ),
      );
    }
  }

  Future<void> refreshWorkspaces() async {
    final agent = getCurrentAgent();
    if (agent == null) return;
    await ensureWorkspacesForAgent(agent, force: true);
  }

  Future<WorkspaceTreeSnapshot> browseWorkspaceTree({String? path}) async {
    final agent = getCurrentAgent();
    if (agent == null) {
      throw StateError('No active agent selected.');
    }

    return conversationRepository.browseWorkspaceTree(
      agent,
      path: path,
    );
  }

  void selectWorkspace(DeviceWorkspace workspace) {
    final agent = getCurrentAgent();
    if (agent == null) return;
    _selectedWorkspaceByAgentId[agent.id] = workspace;
    workspaceRuntimeContext?.setActiveWorkspace(workspace);
    unawaited(loadPermissionModeForWorkspace(workspace));
    unawaited(registerToolsForWorkspace(agent, workspace.id));
    emit(
      getState().copyWith(
        selectedWorkspace: workspace,
        availableWorkspaces: _workspacesByAgentId[agent.id] ?? const [],
        isLoadingWorkspaces: _loadingWorkspaceAgentIds.contains(agent.id),
        requiresWorkspace: requiresWorkspace(agent),
        permissionMode: permissionModeForWorkspace(workspace),
        isLoadingPermissionMode: isLoadingPermissionModeForWorkspace(workspace),
        error: null,
      ),
    );
  }

  void clearWorkspace() {
    final agent = getCurrentAgent();
    if (agent == null) return;
    _selectedWorkspaceByAgentId.remove(agent.id);
    workspaceRuntimeContext?.setActiveWorkspace(null);
    emit(
      getState().copyWith(
        clearSelectedWorkspace: true,
        availableWorkspaces: _workspacesByAgentId[agent.id] ?? const [],
        isLoadingWorkspaces: _loadingWorkspaceAgentIds.contains(agent.id),
        requiresWorkspace: requiresWorkspace(agent),
        permissionMode: WorkspacePermissionMode.defaultMode,
        isLoadingPermissionMode: false,
        error: null,
      ),
    );
  }

  Future<DeviceWorkspace?> createWorkspace({
    String? path,
    String? name,
    String? description,
  }) async {
    final agent = getCurrentAgent();
    if (agent == null) return null;

    try {
      final workspace = conversationCacheRepository == null
          ? await conversationRepository.createWorkspace(
              agent,
              path: path,
              name: name,
              description: description,
            )
          : await conversationCacheRepository!.createWorkspace(
              agent,
              path: path,
              name: name,
              description: description,
            );
      if (workspace == null) return null;
      final currentList = List<DeviceWorkspace>.from(_workspacesByAgentId[agent.id] ?? const []);
      currentList.removeWhere((item) => item.id == workspace.id);
      currentList.insert(0, workspace);
      _workspacesByAgentId[agent.id] = currentList;
      _selectedWorkspaceByAgentId[agent.id] = workspace;
      workspaceRuntimeContext?.setActiveWorkspace(workspace);
      unawaited(loadPermissionModeForWorkspace(workspace));
      unawaited(registerToolsForWorkspace(agent, workspace.id));
      emit(
        getState().copyWith(
          availableWorkspaces: currentList,
          selectedWorkspace: workspace,
          isLoadingWorkspaces: _loadingWorkspaceAgentIds.contains(agent.id),
          requiresWorkspace: requiresWorkspace(agent),
          permissionMode: permissionModeForWorkspace(workspace),
          isLoadingPermissionMode: isLoadingPermissionModeForWorkspace(workspace),
          error: null,
        ),
      );
      return workspace;
    } catch (e) {
      emit(getState().copyWith(error: e.toString()));
      return null;
    }
  }

  Future<void> ensureWorkspacesForAgent(DeviceConfig agent, {bool force = false}) async {
    final caps = capabilitiesStore != null
        ? await capabilitiesStore!.ensureFreshForAgent(agent, force: force)
        : null;
    final supportsWorkspaceFlow =
        (caps?.supportsWorkspaces ?? false) || (caps?.workspaceRequired ?? false);
    if (!supportsWorkspaceFlow) {
      _workspacesByAgentId.remove(agent.id);
      _selectedWorkspaceByAgentId.remove(agent.id);
      if (getCurrentAgent()?.id == agent.id) {
        emit(
          getState().copyWith(
            availableWorkspaces: const [],
            clearSelectedWorkspace: true,
            isLoadingWorkspaces: false,
            requiresWorkspace: false,
            permissionMode: WorkspacePermissionMode.defaultMode,
            isLoadingPermissionMode: false,
          ),
        );
      }
      return;
    }

    if (_workspacesByAgentId.containsKey(agent.id) && !force) {
      if (getCurrentAgent()?.id == agent.id) {
        emit(
          getState().copyWith(
            availableWorkspaces: _workspacesByAgentId[agent.id] ?? const [],
            selectedWorkspace: selectedWorkspaceForAgent(agent),
            isLoadingWorkspaces: false,
            requiresWorkspace: requiresWorkspace(agent),
            permissionMode: permissionModeForWorkspace(selectedWorkspaceForAgent(agent)),
            isLoadingPermissionMode:
                isLoadingPermissionModeForWorkspace(selectedWorkspaceForAgent(agent)),
          ),
        );
      }
      return;
    }

    _loadingWorkspaceAgentIds.add(agent.id);
    if (getCurrentAgent()?.id == agent.id) {
      emit(getState().copyWith(
        isLoadingWorkspaces: true,
        requiresWorkspace: requiresWorkspace(agent),
      ));
    }

    try {
      final workspaces = await conversationRepository.getWorkspaces(agent);
      _workspacesByAgentId[agent.id] = workspaces;
      final selectedWorkspace = _selectedWorkspaceByAgentId[agent.id];
      if (selectedWorkspace != null) {
        for (final workspace in workspaces) {
          if (workspace.id == selectedWorkspace.id) {
            _selectedWorkspaceByAgentId[agent.id] = workspace;
            break;
          }
        }
      }
    } catch (e) {
      if (getCurrentAgent()?.id == agent.id) {
        emit(getState().copyWith(error: e.toString()));
      }
    } finally {
      _loadingWorkspaceAgentIds.remove(agent.id);
      if (getCurrentAgent()?.id == agent.id) {
        emit(
          getState().copyWith(
            availableWorkspaces: _workspacesByAgentId[agent.id] ?? const [],
            selectedWorkspace: selectedWorkspaceForAgent(agent),
            isLoadingWorkspaces: false,
            requiresWorkspace: requiresWorkspace(agent),
            permissionMode: permissionModeForWorkspace(selectedWorkspaceForAgent(agent)),
            isLoadingPermissionMode:
                isLoadingPermissionModeForWorkspace(selectedWorkspaceForAgent(agent)),
          ),
        );
      }
    }
  }

  Future<void> setWorkspacePermissionMode(WorkspacePermissionMode permissionMode) async {
    final agent = getCurrentAgent();
    final workspace = agent == null ? null : selectedWorkspaceForAgent(agent);
    if (workspace == null || workspace.path.trim().isEmpty) {
      emit(getState().copyWith(error: 'Select a workspace before changing its permission mode.'));
      return;
    }

    _workspacePolicyLoadIds[workspace.id] =
        (_workspacePolicyLoadIds[workspace.id] ?? 0) + 1;
    final selectedSessionId = getSelectedSessionId();
    if (selectedSessionId != null) {
      if (permissionMode == WorkspacePermissionMode.defaultMode) {
        _downgradedSessionIds.add(selectedSessionId);
      } else if (permissionMode == WorkspacePermissionMode.fullAccess) {
        _downgradedSessionIds.remove(selectedSessionId);
      }
    }
    emit(getState().copyWith(isLoadingPermissionMode: true));
    try {
      final updatedPolicy = await conversationRepository.setWorkspacePermissionMode(
        agent!,
        workspaceId: workspace.id,
        workspacePath: workspace.path,
        mode: permissionMode,
      );
      _permissionModesByWorkspaceId[workspace.id] = updatedPolicy.permissionMode;
      emit(
        getState().copyWith(
          selectedWorkspace: workspace,
          permissionMode: updatedPolicy.permissionMode,
          isLoadingPermissionMode: false,
          error: null,
        ),
      );
    } catch (e) {
      emit(
        getState().copyWith(
          isLoadingPermissionMode: false,
          error: e.toString(),
        ),
      );
    }
  }

  /// Whether [session] belongs to [agent]: the same device id, an alias the
  /// agent represents, or an id-less session on the local inventory device.
  static bool sessionMatchesAgent(Session? session, DeviceConfig? agent) {
    if (session == null || agent == null) return false;
    if (session.deviceId == agent.id) return true;
    if (session.deviceId != null && agent.representsDeviceId(session.deviceId!)) return true;
    if (session.deviceId == null && agent.isLocalInventoryDevice) return true;
    return false;
  }

  DeviceWorkspace? selectedWorkspaceForAgent(DeviceConfig agent) {
    final selectedSession = sessionCubit.state.selectedSession;
    if (sessionMatchesAgent(selectedSession, agent)) {
      final sessionWorkspace = workspaceFromSession(selectedSession);
      if (sessionWorkspace != null) {
        return sessionWorkspace;
      }
    }
    return _selectedWorkspaceByAgentId[agent.id];
  }

  DeviceWorkspace? workspaceFromSession(Session? session) {
    final workspaceId = session?.workspaceId?.trim();
    final execRoot =
        session?.metadata?['execution_root']?.toString().trim() ??
        (session?.workspacePath?.trim().isNotEmpty == true ? session?.workspacePath!.trim() : null);

    if (workspaceId == null || workspaceId.isEmpty) {
      if (execRoot != null && execRoot.isNotEmpty) {
        final folderName = p.basename(execRoot);
        return DeviceWorkspace(
          id: 'exec_root:$execRoot',
          name: folderName.isNotEmpty ? folderName : 'Workspace',
          path: execRoot,
          trustState: 'untrusted',
        );
      }
      return null;
    }

    for (final workspaces in _workspacesByAgentId.values) {
      for (final workspace in workspaces) {
        if (workspace.id == workspaceId) return workspace;
      }
    }

    final folderName = session?.workspaceName?.trim().isNotEmpty == true
        ? session!.workspaceName!.trim()
        : (execRoot != null && execRoot.isNotEmpty ? p.basename(execRoot) : workspaceId);

    return DeviceWorkspace(
      id: workspaceId,
      name: folderName,
      path: session?.workspacePath?.trim() ?? (execRoot ?? ''),
      trustState: session?.workspaceTrustState?.trim().isNotEmpty == true
          ? session!.workspaceTrustState!.trim()
          : 'untrusted',
    );
  }

  bool requiresWorkspace(DeviceConfig agent) {
    final caps = capabilitiesStore?.getForAgent(agent.id);
    return caps?.workspaceRequired ?? false;
  }

  WorkspacePermissionMode permissionModeForWorkspace(DeviceWorkspace? workspace) {
    if (workspace == null) {
      return WorkspacePermissionMode.defaultMode;
    }
    final selectedSession = sessionCubit.state.selectedSession;
    final isExplicitlyDowngraded = selectedSession != null && _downgradedSessionIds.contains(selectedSession.id);
    if (!isExplicitlyDowngraded &&
        selectedSession != null &&
        (selectedSession.metadata?['allow_all_tools'] == true ||
            selectedSession.metadata?['permission_mode'] == 'full_access')) {
      return WorkspacePermissionMode.fullAccess;
    }
    return _permissionModesByWorkspaceId[workspace.id] ?? WorkspacePermissionMode.defaultMode;
  }

  bool isLoadingPermissionModeForWorkspace(DeviceWorkspace? workspace) {
    if (workspace == null) {
      return false;
    }
    return _loadingPermissionModeWorkspaceIds.contains(workspace.id);
  }

  Future<void> loadPermissionModeForWorkspace(DeviceWorkspace workspace) async {
    final workspaceId = workspace.id.trim();
    final workspacePath = workspace.path.trim();
    if (workspaceId.isEmpty || workspacePath.isEmpty) {
      return;
    }

    final loadId = (_workspacePolicyLoadIds[workspaceId] ?? 0) + 1;
    _workspacePolicyLoadIds[workspaceId] = loadId;

    _loadingPermissionModeWorkspaceIds.add(workspaceId);
    if (!getIsClosed() &&
        getCurrentAgent() != null &&
        selectedWorkspaceForAgent(getCurrentAgent()!)?.id == workspaceId) {
      emit(getState().copyWith(isLoadingPermissionMode: true));
    }

    unawaited(_workspacePolicySubscription?.cancel());
    final agent = getCurrentAgent();
    if (agent != null) {
      _workspacePolicySubscription = conversationRepository
          .watchWorkspacePolicy(agent, workspaceId)
          .listen((policy) {
        _permissionModesByWorkspaceId[workspaceId] = policy.permissionMode;
        if (!getIsClosed() &&
            getCurrentAgent()?.id == agent.id &&
            selectedWorkspaceForAgent(agent)?.id == workspaceId) {
          emit(getState().copyWith(permissionMode: policy.permissionMode));
        }
      });
    }

    try {
      final policy =
          await conversationRepository.getWorkspacePolicy(agent!, workspacePath);
      if (_workspacePolicyLoadIds[workspaceId] == loadId) {
        _permissionModesByWorkspaceId[workspaceId] = policy.permissionMode;
      }
    } catch (e) {
      if (!getIsClosed() &&
          getCurrentAgent() != null &&
          selectedWorkspaceForAgent(getCurrentAgent()!)?.id == workspaceId) {
        emit(getState().copyWith(error: e.toString()));
      }
    } finally {
      _loadingPermissionModeWorkspaceIds.remove(workspaceId);
      if (!getIsClosed() &&
          getCurrentAgent() != null &&
          selectedWorkspaceForAgent(getCurrentAgent()!)?.id == workspaceId) {
        emit(
          getState().copyWith(
            permissionMode: permissionModeForWorkspace(workspace),
            isLoadingPermissionMode: false,
          ),
        );
      }
    }
  }

  Future<void> registerToolsForWorkspace(DeviceConfig agent, String workspaceId) async {
    if (workspaceId.trim().isEmpty) return;
    await localToolRuntime?.broadcastAvailableTools(
      workspaceId: workspaceId,
    );
  }

  void setSessionWorkspace(
    DeviceConfig agent,
    DeviceWorkspace? sessionWorkspace, {
    String? nextSessionId,
  }) {
    if (sessionWorkspace != null) {
      _selectedWorkspaceByAgentId[agent.id] = sessionWorkspace;
      workspaceRuntimeContext?.setActiveWorkspace(sessionWorkspace);
      if (nextSessionId != null && nextSessionId.isNotEmpty) {
        workspaceRuntimeContext?.bindSessionWorkspace(nextSessionId, sessionWorkspace);
      }
      unawaited(loadPermissionModeForWorkspace(sessionWorkspace));
    } else {
      _selectedWorkspaceByAgentId.remove(agent.id);
      workspaceRuntimeContext?.setActiveWorkspace(null);
    }
  }

  void clearState() {
    _loadingPermissionModeWorkspaceIds.clear();
  }

  void cancelPolicySubscription() {
    unawaited(_workspacePolicySubscription?.cancel());
  }

  void dispose() {
    unawaited(_workspacePolicySubscription?.cancel());
  }
}
