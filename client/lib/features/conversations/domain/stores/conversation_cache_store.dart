import 'dart:async';

import 'package:sanad_client/core/navigation/conversation_destination.dart';
import 'package:sanad_client/features/conversations/domain/models/conversation_draft.dart';
import 'package:sanad_client/features/conversations/domain/models/device_conversation_cache_snapshot.dart';
import 'package:sanad_client/features/conversations/domain/models/device_sidebar_snapshot.dart';
import 'package:sanad_client/features/conversations/domain/models/device_workspace.dart';
import 'package:sanad_client/features/conversations/domain/models/request_generation.dart';
import 'package:sanad_client/features/conversations/domain/models/session.dart';
import 'package:sanad_client/features/conversations/domain/stores/cache_generation_guard.dart';
import 'package:sanad_client/features/conversations/domain/stores/conversation_draft_cache.dart';
import 'package:sanad_client/features/conversations/domain/stores/session_section_cache.dart';
import 'package:sanad_client/features/conversations/domain/stores/workspace_cache_projection.dart';

/// Canonical facade of conversation cache, drafts, and per-device state.
///
/// This store is the single in-memory source of truth described in Plan 32 §4.
/// It exposes immutable snapshots to cubits/widgets and hides all pagination
/// merging, cursor arithmetic, draft persistence, and stale-response rejection.
///
/// Internal responsibilities are decomposed across cohesive owners:
/// - [CacheGenerationGuard]: device, workspace, and request generations and staleness rejection.
/// - [WorkspaceCacheProjection]: workspace created/updated/removed/refreshed/error application.
/// - [SessionSectionCache]: sections, sessions, selection, loading and error flags.
/// - [ConversationDraftCache]: draft read/write/clear for sessions and New Conversation.
class ConversationCacheStore {
  final StreamController<DeviceConversationCacheSnapshot> _snapshotController =
      StreamController<DeviceConversationCacheSnapshot>.broadcast();
  final StreamController<String?> _activeDeviceController = StreamController<String?>.broadcast();

  String? _activeDeviceId;

  final CacheGenerationGuard _generationGuard;
  late final SessionSectionCache _sessionSectionCache;
  late final WorkspaceCacheProjection _workspaceProjection;
  late final ConversationDraftCache _draftCache;

  ConversationCacheStore({
    CacheGenerationGuard? generationGuard,
    SessionSectionCache? sessionSectionCache,
    WorkspaceCacheProjection? workspaceProjection,
    ConversationDraftCache? draftCache,
  }) : _generationGuard = generationGuard ?? CacheGenerationGuard() {
    _draftCache = draftCache ??
        ConversationDraftCache(
          getContext: (deviceId) => _sessionSectionCache.contextFor(deviceId),
          updateContext: (deviceId, ctx) => _sessionSectionCache.updateContext(deviceId, ctx),
          ensureDeviceContext: (deviceId) => _sessionSectionCache.ensureDeviceContext(deviceId),
          notify: _emit,
        );
    _sessionSectionCache = sessionSectionCache ??
        SessionSectionCache(
          generationGuard: _generationGuard,
          draftCache: _draftCache,
          notify: _emit,
        );
    _workspaceProjection = workspaceProjection ??
        WorkspaceCacheProjection(
          generationGuard: _generationGuard,
          getContext: (deviceId) => _sessionSectionCache.contextFor(deviceId),
          updateContext: (deviceId, ctx) => _sessionSectionCache.updateContext(deviceId, ctx),
          ensureDeviceContext: (deviceId) => _sessionSectionCache.ensureDeviceContext(deviceId),
          notify: _emit,
        );
  }

  /// Bulk-restore state from a persisted snapshot without emitting per-field
  /// events. Used by [ConversationCachePersistor.hydrate] at startup.
  void restoreFromSnapshot(DeviceConversationCacheSnapshot snapshot) {
    _activeDeviceId = snapshot.activeDeviceId;
    _sessionSectionCache.restoreFrom(
      contexts: snapshot.contexts,
      viewportAnchors: snapshot.sessionViewportAnchors,
    );
    _draftCache.restoreFrom(snapshot.sessionDrafts);
    _generationGuard.reset();
    _emit();
    if (!_activeDeviceController.isClosed) {
      _activeDeviceController.add(_activeDeviceId);
    }
  }

  Stream<DeviceConversationCacheSnapshot> get snapshotStream => _snapshotController.stream;
  Stream<String?> get activeDeviceStream => _activeDeviceController.stream;

  DeviceConversationCacheSnapshot get snapshot => DeviceConversationCacheSnapshot(
    activeDeviceId: _activeDeviceId,
    contexts: _sessionSectionCache.contexts,
    sessionDrafts: _draftCache.sessionDrafts,
    sessionViewportAnchors: _sessionSectionCache.sessionViewportAnchors,
  );

  String? get activeDeviceId => _activeDeviceId;

  // ---------------------------------------------------------------------------
  // Device context
  // ---------------------------------------------------------------------------

  void ensureDeviceContext(String deviceId) => _sessionSectionCache.ensureDeviceContext(deviceId);

  /// Atomically switch the active device. Does not discard other devices' cache.
  void setActiveDevice(String? deviceId) {
    if (_activeDeviceId == deviceId) return;
    _activeDeviceId = deviceId;
    if (deviceId != null) {
      ensureDeviceContext(deviceId);
    }
    _emit();
    if (!_activeDeviceController.isClosed) {
      _activeDeviceController.add(_activeDeviceId);
    }
  }

  // ---------------------------------------------------------------------------
  // Generations (stale response rejection)
  // ---------------------------------------------------------------------------

  /// Advance and return the generation for a section refresh. Callers must
  /// capture the returned token and pass it to the matching merge method so
  /// a late response cannot clobber a newer snapshot.
  RequestGeneration advanceGeneration(String deviceId, String? workspaceId) {
    final next = _generationGuard.advanceGeneration(deviceId, workspaceId);
    _sessionSectionCache.markSectionRequestInFlight(deviceId, workspaceId);
    return next;
  }

  RequestGeneration advanceWorkspacesGeneration(String deviceId) =>
      _generationGuard.advanceWorkspacesGeneration(deviceId);

  // ---------------------------------------------------------------------------
  // Workspaces
  // ---------------------------------------------------------------------------

  void setWorkspacesLoading(String deviceId) => _workspaceProjection.setWorkspacesLoading(deviceId);

  /// Optimistically place a single newly created [workspace] into the cached
  /// list without forcing a full `refreshWorkspaces` round-trip. The canonical
  /// workspace list from the next refresh replaces it; this only keeps the
  /// sidebar in sync while that refresh is in flight.
  ///
  /// Used by [ConversationCacheRepository.createWorkspace] so a freshly created
  /// workspace appears immediately under the "Workspaces" heading.
  void applyWorkspaceCreated(String deviceId, DeviceWorkspace workspace) =>
      _workspaceProjection.applyWorkspaceCreated(deviceId, workspace);

  void applyWorkspaceUpdated(String deviceId, DeviceWorkspace workspace) =>
      _workspaceProjection.applyWorkspaceUpdated(deviceId, workspace);

  void applyWorkspaceRemoved(String deviceId, String workspaceId) =>
      _workspaceProjection.applyWorkspaceRemoved(deviceId, workspaceId);

  void applyWorkspacesRefreshed(
    String deviceId,
    List<DeviceWorkspace> workspaces, {
    required RequestGeneration generation,
  }) =>
      _workspaceProjection.applyWorkspacesRefreshed(
        deviceId,
        workspaces,
        generation: generation,
      );

  void applyWorkspacesError(
    String deviceId,
    String error, {
    required RequestGeneration generation,
  }) =>
      _workspaceProjection.applyWorkspacesError(
        deviceId,
        error,
        generation: generation,
      );

  // ---------------------------------------------------------------------------
  // Conversation pages & sections
  // ---------------------------------------------------------------------------

  void setSectionLoading(String deviceId, String? workspaceId) =>
      _sessionSectionCache.setSectionLoading(deviceId, workspaceId);

  /// Replace the section with an authoritative first page. The stale snapshot
  /// remains visible only while the request is in flight; once the daemon
  /// responds, rows absent from that first page must not survive indefinitely.
  void applySectionRefreshed(
    String deviceId,
    String? workspaceId,
    List<Session> sessions, {
    required String? nextCursor,
    required bool hasMore,
    required RequestGeneration generation,
  }) =>
      _sessionSectionCache.applySectionRefreshed(
        deviceId,
        workspaceId,
        sessions,
        nextCursor: nextCursor,
        hasMore: hasMore,
        generation: generation,
      );

  /// Append the next page from a "load more" request, deduplicating by session
  /// id and preserving server order for the new rows.
  void applySectionPageAppended(
    String deviceId,
    String? workspaceId,
    List<Session> sessions, {
    required String? nextCursor,
    required bool hasMore,
    required RequestGeneration generation,
  }) =>
      _sessionSectionCache.applySectionPageAppended(
        deviceId,
        workspaceId,
        sessions,
        nextCursor: nextCursor,
        hasMore: hasMore,
        generation: generation,
      );

  void setSectionLoadMoreInProgress(String deviceId, String? workspaceId) =>
      _sessionSectionCache.setSectionLoadMoreInProgress(deviceId, workspaceId);

  bool isSectionLoadingMore(String deviceId, String? workspaceId) =>
      _sessionSectionCache.isSectionLoadingMore(deviceId, workspaceId);

  void applySectionError(
    String deviceId,
    String? workspaceId,
    String error, {
    required RequestGeneration generation,
  }) =>
      _sessionSectionCache.applySectionError(
        deviceId,
        workspaceId,
        error,
        generation: generation,
      );

  // ---------------------------------------------------------------------------
  // Session canonical events
  // ---------------------------------------------------------------------------

  /// Place a newly created session into the correct section based on its
  /// `workspaceId`, then re-sort that section.
  void applySessionCreated(String deviceId, Session session) =>
      _sessionSectionCache.applySessionCreated(deviceId, session);

  /// Update a session in whichever section it currently lives. If the update
  /// changes `workspaceId`, the session is moved between sections.
  void applySessionUpdated(String deviceId, Session updated) =>
      _sessionSectionCache.applySessionUpdated(deviceId, updated);

  /// Remove a session from every section, its draft, and last-selected pointer.
  void applySessionDeleted(String deviceId, String sessionId) =>
      _sessionSectionCache.applySessionDeleted(deviceId, sessionId);

  /// Apply a canonical user-message acceptance: bump the session's
  /// `lastMessageAt`/`updatedAt` and re-sort its section so it moves to the top.
  void applyUserMessageAccepted(
    String deviceId,
    String sessionId, {
    DateTime? timestamp,
    String? requestId,
  }) =>
      _sessionSectionCache.applyUserMessageAccepted(
        deviceId,
        sessionId,
        timestamp: timestamp,
        requestId: requestId,
      );

  // ---------------------------------------------------------------------------
  // Workspace expansion + last selected session
  // ---------------------------------------------------------------------------

  void setWorkspaceExpansion(String deviceId, String workspaceId, bool expanded) =>
      _workspaceProjection.setWorkspaceExpansion(deviceId, workspaceId, expanded);

  /// Persists the exact typed route used for restart recovery.
  ///
  /// Session destinations also advance the separate last-selected reference
  /// used to inherit context when a later New Conversation is opened.
  void recordLastDestination(ConversationDestination destination) =>
      _sessionSectionCache.recordLastDestination(destination);

  void clearLastDestination(String deviceId) =>
      _sessionSectionCache.clearLastDestination(deviceId);

  // ---------------------------------------------------------------------------
  // Session viewport anchors
  // ---------------------------------------------------------------------------

  String? sessionViewportAnchor(String deviceId, String sessionId) =>
      _sessionSectionCache.sessionViewportAnchor(deviceId, sessionId);

  void recordSessionViewportAnchor(String deviceId, String sessionId, String eventId) =>
      _sessionSectionCache.recordSessionViewportAnchor(deviceId, sessionId, eventId);

  void clearSessionViewportAnchor(String deviceId, String sessionId) =>
      _sessionSectionCache.clearSessionViewportAnchor(deviceId, sessionId);

  // ---------------------------------------------------------------------------
  // Drafts
  // ---------------------------------------------------------------------------

  ConversationDraft? sessionDraft(String deviceId, String sessionId) =>
      _draftCache.sessionDraft(deviceId, sessionId);

  void setSessionDraft(String deviceId, String sessionId, ConversationDraft draft) =>
      _draftCache.setSessionDraft(deviceId, sessionId, draft);

  void markSessionDraftAwaitingAcceptance(
    String deviceId,
    String sessionId,
    String requestId,
  ) =>
      _draftCache.markSessionDraftAwaitingAcceptance(deviceId, sessionId, requestId);

  void clearSessionDraft(String deviceId, String sessionId) =>
      _draftCache.clearSessionDraft(deviceId, sessionId);

  bool prependStopRecovery(
    String deviceId,
    String sessionId, {
    required String stopRequestId,
    required Iterable<String> texts,
  }) =>
      _draftCache.prependStopRecovery(
        deviceId,
        sessionId,
        stopRequestId: stopRequestId,
        texts: texts,
      );

  void markStopRecoveryPending(
    String deviceId,
    String sessionId,
    String stopRequestId, {
    String? ownerToken,
  }) =>
      _draftCache.markStopRecoveryPending(
        deviceId,
        sessionId,
        stopRequestId,
        ownerToken: ownerToken,
      );

  void unmarkStopRecoveryPending(String deviceId, String sessionId, String stopRequestId) =>
      _draftCache.unmarkStopRecoveryPending(deviceId, sessionId, stopRequestId);

  void clearStopRecoveryOwnerToken(
    String deviceId,
    String sessionId,
    String stopRequestId,
  ) =>
      _draftCache.clearStopRecoveryOwnerToken(deviceId, sessionId, stopRequestId);

  void setStopRecoveryClaim(
    String deviceId,
    String sessionId,
    String stopRequestId,
    String claimId,
  ) =>
      _draftCache.setStopRecoveryClaim(
        deviceId,
        sessionId,
        stopRequestId,
        claimId,
      );

  void clearStopRecoveryClaim(String deviceId, String sessionId, String stopRequestId) =>
      _draftCache.clearStopRecoveryClaim(deviceId, sessionId, stopRequestId);

  /// Move a New Conversation draft binding to a newly created session identity.
  /// Called once the daemon confirms session creation, before clearing the new
  /// draft after canonical acceptance.
  void transferNewConversationDraftToSession(
    String deviceId,
    String sessionId,
  ) =>
      _draftCache.transferNewConversationDraftToSession(deviceId, sessionId);

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
  }) =>
      _draftCache.setNewConversationDraft(
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

  void markNewConversationDraftAwaitingAcceptance(
    String deviceId,
    String requestId,
  ) =>
      _draftCache.markNewConversationDraftAwaitingAcceptance(deviceId, requestId);

  void clearNewConversationDraft(String deviceId) =>
      _draftCache.clearNewConversationDraft(deviceId);

  // ---------------------------------------------------------------------------
  // Logout / cleanup
  // ---------------------------------------------------------------------------

  /// Remove all data for a device (used when a device is unregistered).
  void clearDevice(String deviceId) {
    _sessionSectionCache.clearDevice(deviceId);
    _generationGuard.clearDevice(deviceId);
    _draftCache.clearDevice(deviceId);
    if (_activeDeviceId == deviceId) {
      _activeDeviceId = null;
    }
    _emit();
    if (!_activeDeviceController.isClosed) {
      _activeDeviceController.add(_activeDeviceId);
    }
  }

  /// Clear cloud-user-scoped data while preserving local desktop inventory.
  /// Caller passes the set of device ids that are cloud-owned.
  void clearCloudUserScope(Set<String> cloudDeviceIds) {
    for (final deviceId in cloudDeviceIds) {
      clearDevice(deviceId);
    }
  }

  // ---------------------------------------------------------------------------
  // Sidebar view-model
  // ---------------------------------------------------------------------------

  DeviceSidebarSnapshot? sidebarSnapshotFor(String deviceId) =>
      _sessionSectionCache.sidebarSnapshotFor(deviceId);

  /// Compatibility projection for consumers that still render a flat list.
  /// The cache remains the owner; callers receive a derived immutable view.
  List<Session> sessionsForDevice(String deviceId) =>
      _sessionSectionCache.sessionsForDevice(deviceId);

  void _emit() {
    if (!_snapshotController.isClosed) {
      _snapshotController.add(snapshot);
    }
  }

  void dispose() {
    _sessionSectionCache.dispose();
    unawaited(_snapshotController.close());
    unawaited(_activeDeviceController.close());
  }
}
