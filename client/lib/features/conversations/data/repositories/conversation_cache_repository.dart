import 'dart:async';

import 'package:sanad_client/core/navigation/conversation_destination.dart';
import 'package:sanad_client/features/conversations/domain/models/conversation_draft.dart';
import 'package:sanad_client/features/conversations/domain/models/conversation_resource_state.dart';
import 'package:sanad_client/features/conversations/domain/models/device_conversation_cache_snapshot.dart';
import 'package:sanad_client/features/conversations/domain/models/device_sidebar_snapshot.dart';
import 'package:sanad_client/features/conversations/domain/models/device_workspace.dart';
import 'package:sanad_client/features/conversations/domain/models/session.dart';
import 'package:sanad_client/features/conversations/domain/models/session_query.dart';
import 'package:sanad_client/features/conversations/domain/models/workspace_tree_snapshot.dart';
import 'package:sanad_client/features/conversations/domain/repositories/conversation_repository.dart';
import 'package:sanad_client/features/conversations/domain/stores/conversation_cache_store.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';

/// Intent-based facade over [ConversationCacheStore] plus the daemon-backed
/// [ConversationRepository].
///
/// This is the single consumer-facing API described in Plan 32 §"API المقدم
/// للواجهة". Widgets and cubits call intent methods here; they never touch the
/// store's pagination merging, cursor arithmetic, serialization, or generation
/// tokens directly.
///
/// The repository owns the transport (daemon is authoritative); the cache store
/// owns the client memory/persistent snapshot. This facade coordinates the two:
/// it issues transport requests, feeds the results into the cache store, and
/// exposes immutable snapshots for the UI.
class ConversationCacheRepository {
  final ConversationCacheStore _cache;
  final ConversationRepository _transport;
  final Future<void> Function()? _flushPersistence;

  ConversationCacheRepository({
    required ConversationCacheStore cache,
    required ConversationRepository transport,
    Future<void> Function()? flushPersistence,
  }) : _cache = cache,
       _transport = transport,
       _flushPersistence = flushPersistence;

  // ---------------------------------------------------------------------------
  // Device context
  // ---------------------------------------------------------------------------

  String? get activeDeviceId => _cache.activeDeviceId;

  Stream<DeviceConversationCacheSnapshot> get snapshotStream => _cache.snapshotStream;

  Stream<String?> get activeDeviceStream => _cache.activeDeviceStream;

  DeviceConversationCacheSnapshot get snapshot => _cache.snapshot;

  /// Switch the active device context. Renders the cached slice instantly;
  /// caller may follow with [refreshWorkspaces] / [refreshUnscopedConversations].
  void selectDevice(String? deviceId) {
    _cache.setActiveDevice(deviceId);
  }

  DeviceSidebarSnapshot? sidebarSnapshotFor(String deviceId) => _cache.sidebarSnapshotFor(deviceId);

  List<Session> sessionsForDevice(String deviceId) => _cache.sessionsForDevice(deviceId);

  String? sessionViewportAnchor(String deviceId, String sessionId) => _cache.sessionViewportAnchor(deviceId, sessionId);

  void recordSessionViewportAnchor(String deviceId, String sessionId, String eventId) {
    _cache.recordSessionViewportAnchor(deviceId, sessionId, eventId);
  }

  // ---------------------------------------------------------------------------
  // Workspaces
  // ---------------------------------------------------------------------------

  Future<void> refreshWorkspaces(DeviceConfig device) async {
    final generation = _cache.advanceWorkspacesGeneration(device.id);
    _cache.setWorkspacesLoading(device.id);
    try {
      final workspaces = await _transport.getWorkspaces(device);
      _cache.applyWorkspacesRefreshed(device.id, workspaces, generation: generation);
    } catch (e) {
      _cache.applyWorkspacesError(device.id, e.toString(), generation: generation);
    }
  }

  /// Refresh all sidebar resources for one device while preserving its cached
  /// snapshot until each authoritative response arrives.
  Future<void> refreshDeviceSidebar(DeviceConfig device) async {
    await refreshWorkspaces(device);
    final context = _cache.snapshot.contexts[device.id];
    final workspaceIds =
        context?.workspaces.workspaces
            .where((workspace) {
              final page = context.workspaceConversationPages[workspace.id];
              final isExpanded = context.workspaceExpansion[workspace.id] ?? true;
              return isExpanded || (page != null && page.state != ConversationResourceState.notLoaded);
            })
            .map((workspace) => workspace.id)
            .toList(growable: false) ??
        const <String>[];
    await Future.wait([
      refreshUnscopedConversations(device),
      for (final workspaceId in workspaceIds) refreshWorkspaceConversations(device, workspaceId),
    ]);
  }

  // ---------------------------------------------------------------------------
  // Conversation sections
  // ---------------------------------------------------------------------------

  Future<void> refreshUnscopedConversations(DeviceConfig device) async {
    await _refreshSection(device, workspaceId: null);
  }

  Future<void> refreshWorkspaceConversations(
    DeviceConfig device,
    String workspaceId,
  ) async {
    await _refreshSection(device, workspaceId: workspaceId);
  }

  Future<void> _refreshSection(
    DeviceConfig device, {
    required String? workspaceId,
  }) async {
    final generation = _cache.advanceGeneration(device.id, workspaceId);
    _cache.setSectionLoading(device.id, workspaceId);
    try {
      final result = await _transport.refreshSessions(
        device,
        query: SessionQueryRequest(
          workspaceId: workspaceId,
          unscopedOnly: workspaceId == null,
          limit: _firstPageSize,
        ),
      );
      _cache.applySectionRefreshed(
        device.id,
        workspaceId,
        result.sessions,
        nextCursor: result.nextCursor,
        hasMore: result.hasMore,
        generation: generation,
      );
    } catch (e) {
      _cache.applySectionError(device.id, workspaceId, e.toString(), generation: generation);
    }
  }

  /// Load the next page for a section (unscoped if [workspaceId] is null).
  Future<void> loadMore(
    DeviceConfig device, {
    required String? workspaceId,
  }) async {
    final page = _cache.snapshot.contexts[device.id];
    final section = workspaceId == null ? page?.unscopedConversations : page?.workspaceConversationPages[workspaceId];
    if (section == null ||
        !section.hasMore ||
        section.nextCursor == null ||
        section.state.isLoading ||
        _cache.isSectionLoadingMore(device.id, workspaceId)) {
      return;
    }
    final generation = _cache.advanceGeneration(device.id, workspaceId);
    _cache.setSectionLoadMoreInProgress(device.id, workspaceId);
    try {
      final result = await _transport.getSessions(
        device,
        query: SessionQueryRequest(
          workspaceId: workspaceId,
          unscopedOnly: workspaceId == null,
          limit: _nextPageSize,
          cursor: section.nextCursor,
        ),
      );
      _cache.applySectionPageAppended(
        device.id,
        workspaceId,
        result.sessions,
        nextCursor: result.nextCursor,
        hasMore: result.hasMore,
        generation: generation,
      );
    } catch (e) {
      _cache.applySectionError(device.id, workspaceId, e.toString(), generation: generation);
    }
  }

  // ---------------------------------------------------------------------------
  // Workspace creation, expansion + last session
  // ---------------------------------------------------------------------------

  /// Create a workspace via the transport and optimistically place it in the
  /// cache so the sidebar renders it before the next refresh. Returns the
  /// created [DeviceWorkspace], or `null` if the transport call failed.
  ///
  /// The canonical list is owned by the daemon; a subsequent
  /// [refreshWorkspaces] replaces the optimistic entry. This facade mirrors
  /// the legacy `SessionMessagesCubit.createWorkspace` path so the sidebar can
  /// trigger workspace creation without going through the input cubit.
  Future<DeviceWorkspace?> createWorkspace(
    DeviceConfig device, {
    String? path,
    String? name,
    String? description,
  }) async {
    try {
      final workspace = await _transport.createWorkspace(
        device,
        path: path,
        name: name,
        description: description,
      );
      _cache.applyWorkspaceCreated(device.id, workspace);
      return workspace;
    } catch (_) {
      return null;
    }
  }

  Future<DeviceWorkspace> renameWorkspace(
    DeviceConfig device, {
    required String workspaceId,
    required String displayName,
  }) async {
    final workspace = await _transport.renameWorkspace(
      device,
      workspaceId: workspaceId,
      displayName: displayName,
    );
    _cache.applyWorkspaceUpdated(device.id, workspace);
    return workspace;
  }

  Future<void> removeWorkspace(
    DeviceConfig device, {
    required String workspaceId,
  }) async {
    await _transport.removeWorkspace(device, workspaceId: workspaceId);
    _cache.applyWorkspaceRemoved(device.id, workspaceId);
  }

  Future<DeviceWorkspace> relocateWorkspace(
    DeviceConfig device, {
    required String workspaceId,
    required String newPath,
  }) async {
    final workspace = await _transport.relocateWorkspace(
      device,
      workspaceId: workspaceId,
      newPath: newPath,
    );
    _cache.applyWorkspaceUpdated(device.id, workspace);
    return workspace;
  }

  Future<WorkspaceTreeSnapshot> browseWorkspaceTree(
    DeviceConfig device, {
    String? workspaceId,
    String? path,
  }) {
    return _transport.browseWorkspaceTree(
      device,
      workspaceId: workspaceId,
      path: path,
    );
  }

  Future<void> createFolder(
    DeviceConfig device, {
    required String parentPath,
    required String name,
  }) {
    return _transport.createFolder(
      device,
      parentPath: parentPath,
      name: name,
    );
  }

  Future<void> renameFolder(
    DeviceConfig device, {
    required String path,
    required String newName,
  }) {
    return _transport.renameFolder(
      device,
      path: path,
      newName: newName,
    );
  }

  Future<void> deleteFolder(
    DeviceConfig device, {
    required String path,
  }) {
    return _transport.deleteFolder(device, path: path);
  }

  void setWorkspaceExpansion(String deviceId, String workspaceId, bool expanded) {
    _cache.setWorkspaceExpansion(deviceId, workspaceId, expanded);
  }

  void recordLastDestination(ConversationDestination destination) {
    _cache.recordLastDestination(destination);
  }

  ConversationDestination? lastDestination(String deviceId) => _cache.snapshot.contexts[deviceId]?.lastDestination;

  ConversationDestination restartDestination(String deviceId) {
    final destination = lastDestination(deviceId);
    if (destination == null || destination.isConversationsList) {
      return ConversationDestination.newConversation(deviceId: deviceId);
    }
    final workspaceId = destination.workspaceId;
    if (destination.isNewConversation && workspaceId != null && isWorkspaceKnownMissing(deviceId, workspaceId)) {
      return ConversationDestination.newConversation(deviceId: deviceId);
    }
    return destination;
  }

  bool containsWorkspace(String deviceId, String workspaceId) {
    final workspaces = _cache.snapshot.contexts[deviceId]?.workspaces.workspaces;
    return workspaces?.any((workspace) => workspace.id == workspaceId) ?? false;
  }

  bool isWorkspaceKnownMissing(String deviceId, String workspaceId) {
    final section = _cache.snapshot.contexts[deviceId]?.workspaces;
    if (section == null || section.state != ConversationResourceState.ready) {
      return false;
    }
    return section.workspaces.every((workspace) => workspace.id != workspaceId);
  }

  Session? lastSelectedSession(String deviceId) {
    final context = _cache.snapshot.contexts[deviceId];
    final sessionId = context?.lastSelectedSessionId;
    if (context == null || sessionId == null) return null;

    for (final session in context.unscopedConversations.sessions) {
      if (session.id == sessionId) return session;
    }
    for (final page in context.workspaceConversationPages.values) {
      for (final session in page.sessions) {
        if (session.id == sessionId) return session;
      }
    }
    return null;
  }

  bool isSectionLoadingMore(String deviceId, String? workspaceId) => _cache.isSectionLoadingMore(deviceId, workspaceId);

  // ---------------------------------------------------------------------------
  // Drafts
  // ---------------------------------------------------------------------------

  ConversationDraft? sessionDraft(String deviceId, String sessionId) => _cache.sessionDraft(deviceId, sessionId);

  void setSessionDraft(String deviceId, String sessionId, ConversationDraft draft) {
    _cache.setSessionDraft(deviceId, sessionId, draft);
  }

  void markSessionDraftAwaitingAcceptance(
    String deviceId,
    String sessionId,
    String requestId,
  ) {
    _cache.markSessionDraftAwaitingAcceptance(deviceId, sessionId, requestId);
  }

  void clearSessionDraft(String deviceId, String sessionId) {
    _cache.clearSessionDraft(deviceId, sessionId);
  }

  bool prependStopRecovery(
    String deviceId,
    String sessionId, {
    required String stopRequestId,
    required Iterable<String> texts,
  }) => _cache.prependStopRecovery(
    deviceId,
    sessionId,
    stopRequestId: stopRequestId,
    texts: texts,
  );

  Future<bool> prependStopRecoveryAndFlush(
    String deviceId,
    String sessionId, {
    required String stopRequestId,
    required Iterable<String> texts,
  }) async {
    final changed = prependStopRecovery(
      deviceId,
      sessionId,
      stopRequestId: stopRequestId,
      texts: texts,
    );
    if (!changed) return false;
    await _flushPersistence?.call();
    return true;
  }

  void markStopRecoveryPending(
    String deviceId,
    String sessionId,
    String stopRequestId, {
    String? ownerToken,
  }) => _cache.markStopRecoveryPending(
    deviceId,
    sessionId,
    stopRequestId,
    ownerToken: ownerToken,
  );

  Future<void> markStopRecoveryPendingAndFlush(
    String deviceId,
    String sessionId,
    String stopRequestId, {
    String? ownerToken,
  }) async {
    _cache.markStopRecoveryPending(
      deviceId,
      sessionId,
      stopRequestId,
      ownerToken: ownerToken,
    );
    await _flushPersistence?.call();
  }

  Future<void> clearStopRecoveryOwnerTokenAndFlush(
    String deviceId,
    String sessionId,
    String stopRequestId,
  ) async {
    _cache.clearStopRecoveryOwnerToken(deviceId, sessionId, stopRequestId);
    await _flushPersistence?.call();
  }

  Future<void> unmarkStopRecoveryPendingAndFlush(String deviceId, String sessionId, String stopRequestId) async {
    _cache.unmarkStopRecoveryPending(deviceId, sessionId, stopRequestId);
    await _flushPersistence?.call();
  }

  Future<void> setStopRecoveryClaimAndFlush(
    String deviceId,
    String sessionId,
    String stopRequestId,
    String claimId,
  ) async {
    _cache.setStopRecoveryClaim(deviceId, sessionId, stopRequestId, claimId);
    await _flushPersistence?.call();
  }

  Future<void> clearStopRecoveryClaimAndFlush(
    String deviceId,
    String sessionId,
    String stopRequestId,
  ) async {
    _cache.clearStopRecoveryClaim(deviceId, sessionId, stopRequestId);
    await _flushPersistence?.call();
  }

  ConversationDraft newConversationDraft(String deviceId) {
    final context = _cache.snapshot.contexts[deviceId];
    if (context == null) return ConversationDraft.empty();
    return ConversationDraft(
      text: context.newConversationDraftText,
      workspaceId: context.newConversationDraftWorkspaceId,
      providerId: context.newConversationDraftProviderId,
      model: context.newConversationDraftModel,
      thinkingMode: context.newConversationDraftThinkingMode,
      permissionMode: context.newConversationDraftPermissionMode,
      pendingRequestId: context.newConversationDraftPendingRequestId,
      updatedAt: context.newConversationDraftUpdatedAt,
    );
  }

  void setNewConversationDraft(
    String deviceId, {
    String? text,
    String? workspaceId,
    String? providerId,
    String? model,
    String? thinkingMode,
    String? permissionMode,
    bool clearWorkspace = false,
    bool clearProvider = false,
    bool clearModel = false,
    bool clearThinkingMode = false,
    bool clearPermissionMode = false,
    bool clearPendingRequest = false,
  }) {
    _cache.setNewConversationDraft(
      deviceId,
      text: text,
      workspaceId: workspaceId,
      providerId: providerId,
      model: model,
      thinkingMode: thinkingMode,
      permissionMode: permissionMode,
      clearWorkspace: clearWorkspace,
      clearProvider: clearProvider,
      clearModel: clearModel,
      clearThinkingMode: clearThinkingMode,
      clearPermissionMode: clearPermissionMode,
      clearPendingRequest: clearPendingRequest,
    );
  }

  void clearNewConversationDraft(String deviceId) {
    _cache.clearNewConversationDraft(deviceId);
  }

  void markNewConversationDraftAwaitingAcceptance(
    String deviceId,
    String requestId,
  ) {
    _cache.markNewConversationDraftAwaitingAcceptance(deviceId, requestId);
  }

  /// Move the New Conversation draft binding to a newly created session.
  void transferNewConversationDraftToSession(String deviceId, String sessionId) {
    _cache.transferNewConversationDraftToSession(deviceId, sessionId);
  }

  // ---------------------------------------------------------------------------
  // Canonical session events (applied to cache only; transport owns authority)
  // ---------------------------------------------------------------------------

  void applySessionCreated(String deviceId, Session session) {
    _cache.applySessionCreated(deviceId, session);
  }

  void applySessionUpdated(String deviceId, Session updated) {
    _cache.applySessionUpdated(deviceId, updated);
  }

  void applySessionDeleted(String deviceId, String sessionId) {
    _cache.applySessionDeleted(deviceId, sessionId);
  }

  void applyUserMessageAccepted(
    String deviceId,
    String sessionId, {
    DateTime? timestamp,
    String? requestId,
  }) {
    _cache.applyUserMessageAccepted(
      deviceId,
      sessionId,
      timestamp: timestamp,
      requestId: requestId,
    );
  }

  // ---------------------------------------------------------------------------
  // Logout / cleanup
  // ---------------------------------------------------------------------------

  void clearDevice(String deviceId) {
    _cache.clearDevice(deviceId);
  }

  void clearCloudUserScope(Set<String> cloudDeviceIds) {
    _cache.clearCloudUserScope(cloudDeviceIds);
  }

  // ---------------------------------------------------------------------------
  // Constants
  // ---------------------------------------------------------------------------

  /// Initial page size for a section refresh (Plan 32 §5: six sessions).
  static const int _firstPageSize = 6;

  /// Page size for "load more" (Plan 32 §5: ten additional sessions).
  static const int _nextPageSize = 10;
}
