import 'package:sanad_client/core/navigation/conversation_destination.dart';
import 'package:sanad_client/features/conversations/domain/models/cached_workspace_section.dart';
import 'package:sanad_client/features/conversations/domain/models/conversation_resource_state.dart';
import 'package:sanad_client/features/conversations/domain/models/conversation_section_page.dart';
import 'package:sanad_client/features/conversations/domain/models/device_conversation_context.dart';
import 'package:sanad_client/features/conversations/domain/models/device_workspace.dart';
import 'package:sanad_client/features/conversations/domain/models/request_generation.dart';
import 'package:sanad_client/features/conversations/domain/stores/cache_generation_guard.dart';

/// Owns workspace created/updated/removed/refreshed/error application and expansion.
class WorkspaceCacheProjection {
  final CacheGenerationGuard _generationGuard;
  final DeviceConversationContext Function(String deviceId) _getContext;
  final void Function(String deviceId, DeviceConversationContext context) _updateContext;
  final void Function(String deviceId) _ensureDeviceContext;
  final void Function() _notify;

  WorkspaceCacheProjection({
    required CacheGenerationGuard generationGuard,
    required DeviceConversationContext Function(String deviceId) getContext,
    required void Function(String deviceId, DeviceConversationContext context) updateContext,
    required void Function(String deviceId) ensureDeviceContext,
    required void Function() notify,
  })  : _generationGuard = generationGuard,
        _getContext = getContext,
        _updateContext = updateContext,
        _ensureDeviceContext = ensureDeviceContext,
        _notify = notify;

  void setWorkspacesLoading(String deviceId) {
    _ensureDeviceContext(deviceId);
    final ctx = _getContext(deviceId);
    final hasSnapshot = ctx.workspaces.workspaces.isNotEmpty || ctx.workspaces.state.hasUsableSnapshot;
    final next = ctx.workspaces.copyWith(
      state: hasSnapshot ? ConversationResourceState.refreshing : ConversationResourceState.loading,
    );
    _updateContext(deviceId, ctx.copyWith(workspaces: next));
    _notify();
  }

  void applyWorkspaceCreated(String deviceId, DeviceWorkspace workspace) {
    _generationGuard.advanceWorkspacesGeneration(deviceId);
    _ensureDeviceContext(deviceId);
    final ctx = _getContext(deviceId);
    final current = List<DeviceWorkspace>.from(ctx.workspaces.workspaces)
      ..removeWhere((existing) => existing.id == workspace.id);
    current.insert(0, workspace);
    final expansion = Map<String, bool>.from(ctx.workspaceExpansion);
    expansion[workspace.id] = expansion[workspace.id] ?? true;
    _updateContext(
      deviceId,
      ctx.copyWith(
        workspaces: CachedWorkspaceSection(
          workspaces: List.unmodifiable(current),
          state: ConversationResourceState.ready,
          lastRefreshedAt: ctx.workspaces.lastRefreshedAt,
          lastErrorAt: null,
          lastError: null,
        ),
        workspaceExpansion: expansion,
      ),
    );
    _notify();
  }

  void applyWorkspaceUpdated(String deviceId, DeviceWorkspace workspace) {
    _generationGuard.advanceWorkspacesGeneration(deviceId);
    _ensureDeviceContext(deviceId);
    final ctx = _getContext(deviceId);
    final current = List<DeviceWorkspace>.from(ctx.workspaces.workspaces);
    final index = current.indexWhere((item) => item.id == workspace.id);
    if (index < 0) {
      current.insert(0, workspace);
    } else {
      current[index] = workspace;
    }
    final pages = ctx.workspaceConversationPages.map(
      (workspaceId, page) => MapEntry(
        workspaceId,
        page.copyWith(
          sessions: page.sessions
              .map(
                (session) => session.workspaceId == workspace.id
                    ? session.copyWith(
                        workspaceName: workspace.name,
                        workspacePath: workspace.path,
                      )
                    : session,
              )
              .toList(growable: false),
        ),
      ),
    );
    _updateContext(
      deviceId,
      ctx.copyWith(
        workspaces: ctx.workspaces.copyWith(
          workspaces: List.unmodifiable(current),
        ),
        workspaceConversationPages: pages,
      ),
    );
    _notify();
  }

  void applyWorkspaceRemoved(String deviceId, String workspaceId) {
    _generationGuard.advanceWorkspacesGeneration(deviceId);
    _ensureDeviceContext(deviceId);
    final ctx = _getContext(deviceId);
    final workspaces = List<DeviceWorkspace>.from(ctx.workspaces.workspaces)
      ..removeWhere((workspace) => workspace.id == workspaceId);
    final pages = Map<String, ConversationSectionPage>.from(
      ctx.workspaceConversationPages,
    )..remove(workspaceId);
    final expansion = Map<String, bool>.from(ctx.workspaceExpansion)..remove(workspaceId);
    final destination = ctx.lastDestination?.workspaceId == workspaceId
        ? ConversationDestination.newConversation(deviceId: deviceId)
        : ctx.lastDestination;
    _updateContext(
      deviceId,
      ctx.copyWith(
        workspaces: ctx.workspaces.copyWith(
          workspaces: List.unmodifiable(workspaces),
        ),
        workspaceConversationPages: pages,
        workspaceExpansion: expansion,
        lastDestination: destination,
        clearNewConversationDraftWorkspace: ctx.newConversationDraftWorkspaceId == workspaceId,
      ),
    );
    _notify();
  }

  void applyWorkspacesRefreshed(
    String deviceId,
    List<DeviceWorkspace> workspaces, {
    required RequestGeneration generation,
  }) {
    if (!_generationGuard.isCurrentWorkspaceGeneration(generation, deviceId)) return;
    _ensureDeviceContext(deviceId);
    final ctx = _getContext(deviceId);
    final remappedIds = <String, String>{};
    for (final workspace in workspaces) {
      for (final cached in ctx.workspaces.workspaces) {
        if (cached.id != workspace.id && cached.path == workspace.path) {
          remappedIds[cached.id] = workspace.id;
        }
      }
    }
    final workspaceIds = workspaces.map((workspace) => workspace.id).toSet();
    final pages = Map<String, ConversationSectionPage>.from(
      ctx.workspaceConversationPages,
    );
    final expansion = Map<String, bool>.from(ctx.workspaceExpansion);
    for (final remap in remappedIds.entries) {
      final page = pages.remove(remap.key);
      if (page != null) pages[remap.value] = page;
      final expanded = expansion.remove(remap.key);
      if (expanded != null) expansion[remap.value] = expanded;
    }
    pages.removeWhere((workspaceId, _) => !workspaceIds.contains(workspaceId));
    expansion.removeWhere((workspaceId, _) => !workspaceIds.contains(workspaceId));
    final draftWorkspaceId = ctx.newConversationDraftWorkspaceId;
    final remappedDraftWorkspaceId = draftWorkspaceId == null
        ? null
        : (remappedIds[draftWorkspaceId] ?? draftWorkspaceId);
    final destination = ctx.lastDestination;
    final remappedDestination =
        destination?.isNewConversation == true &&
            destination?.workspaceId != null &&
            remappedIds.containsKey(destination!.workspaceId)
        ? ConversationDestination.newConversation(
            deviceId: destination.deviceId,
            workspaceId: remappedIds[destination.workspaceId],
          )
        : destination;
    _updateContext(
      deviceId,
      ctx.copyWith(
        lastDestination: remappedDestination,
        newConversationDraftWorkspaceId: remappedDraftWorkspaceId,
        workspaces: CachedWorkspaceSection(
          workspaces: List.unmodifiable(workspaces),
          state: ConversationResourceState.ready,
          lastRefreshedAt: DateTime.now(),
          lastErrorAt: null,
          lastError: null,
        ),
        workspaceConversationPages: pages,
        workspaceExpansion: expansion,
      ),
    );
    _notify();
  }

  void applyWorkspacesError(
    String deviceId,
    String error, {
    required RequestGeneration generation,
  }) {
    if (!_generationGuard.isCurrentWorkspaceGeneration(generation, deviceId)) return;
    _ensureDeviceContext(deviceId);
    final ctx = _getContext(deviceId);
    final hadSnapshot = ctx.workspaces.state.hasUsableSnapshot;
    _updateContext(
      deviceId,
      ctx.copyWith(
        workspaces: ctx.workspaces.copyWith(
          state: hadSnapshot ? ConversationResourceState.staleError : ConversationResourceState.notLoaded,
          lastErrorAt: DateTime.now(),
          lastError: error,
        ),
      ),
    );
    _notify();
  }

  void setWorkspaceExpansion(String deviceId, String workspaceId, bool expanded) {
    _ensureDeviceContext(deviceId);
    final ctx = _getContext(deviceId);
    final nextExpansion = Map<String, bool>.from(ctx.workspaceExpansion);
    nextExpansion[workspaceId] = expanded;
    _updateContext(deviceId, ctx.copyWith(workspaceExpansion: nextExpansion));
    _notify();
  }
}
