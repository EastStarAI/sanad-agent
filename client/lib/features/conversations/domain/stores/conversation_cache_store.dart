import 'dart:async';

import 'package:sanad_client/core/navigation/conversation_destination.dart';
import 'package:sanad_client/features/conversations/domain/models/cached_workspace_section.dart';
import 'package:sanad_client/features/conversations/domain/models/conversation_resource_state.dart';
import 'package:sanad_client/features/conversations/domain/models/conversation_section_page.dart';
import 'package:sanad_client/features/conversations/domain/models/device_conversation_cache_snapshot.dart';
import 'package:sanad_client/features/conversations/domain/models/device_conversation_context.dart';
import 'package:sanad_client/features/conversations/domain/models/device_sidebar_snapshot.dart';
import 'package:sanad_client/features/conversations/domain/models/device_workspace.dart';
import 'package:sanad_client/features/conversations/domain/models/request_generation.dart';
import 'package:sanad_client/features/conversations/domain/models/session.dart';
import 'package:sanad_client/features/conversations/domain/models/sidebar_conversation_group.dart';
import 'package:sanad_client/features/conversations/domain/models/conversation_draft.dart';

enum _SectionMutationKind { upsert, delete, bump }

class _SectionMutation {
  final _SectionMutationKind kind;
  final String sessionId;
  final Session? session;
  final DateTime? timestamp;

  const _SectionMutation._(this.kind, this.sessionId, {this.session, this.timestamp});

  factory _SectionMutation.upsert(Session session) =>
      _SectionMutation._(_SectionMutationKind.upsert, session.id, session: session);

  factory _SectionMutation.delete(String sessionId) => _SectionMutation._(_SectionMutationKind.delete, sessionId);

  factory _SectionMutation.bump(String sessionId, DateTime timestamp) =>
      _SectionMutation._(_SectionMutationKind.bump, sessionId, timestamp: timestamp);
}

/// Canonical owner of conversation cache, drafts, and per-device state.
///
/// This store is the single in-memory source of truth described in Plan 32 §4.
/// It exposes immutable snapshots to cubits/widgets and hides all pagination
/// merging, cursor arithmetic, draft persistence, and stale-response rejection.
///
/// Responsibilities:
/// - Hold per-device cache slices (workspaces, conversation pages, drafts).
/// - Merge paginated responses by `deviceId + sessionId` without duplicates.
/// - Reject stale responses via [RequestGeneration].
/// - Apply canonical session events (created/updated/deleted/user-message).
/// - Track per-resource lifecycle states for stale-while-revalidate.
///
/// Persistence is delegated to a [ConversationCachePersistence] backend; this
/// class owns the live memory state and emits changes.
class ConversationCacheStore {
  final StreamController<DeviceConversationCacheSnapshot> _snapshotController =
      StreamController<DeviceConversationCacheSnapshot>.broadcast();
  final StreamController<String?> _activeDeviceController = StreamController<String?>.broadcast();

  String? _activeDeviceId;
  final Map<String, DeviceConversationContext> _contexts = {};
  final Map<String, ConversationDraft> _sessionDrafts = {};
  final Map<String, String> _sessionViewportAnchors = {};

  /// Per-section in-flight generation tokens, keyed by `deviceId|sectionKey`.
  /// A response whose generation is older than the current value is rejected.
  final Map<String, RequestGeneration> _sectionGenerations = {};
  final Map<String, RequestGeneration> _workspaceGenerations = {};

  /// Per-section "load more" in-flight flags, keyed by `deviceId|sectionKey`.
  final Set<String> _loadingMoreSections = {};
  final Set<String> _sectionRequestsInFlight = {};
  final Map<String, List<_SectionMutation>> _pendingSectionMutations = {};

  ConversationCacheStore();

  /// Bulk-restore state from a persisted snapshot without emitting per-field
  /// events. Used by [ConversationCachePersistor.hydrate] at startup.
  void restoreFromSnapshot(DeviceConversationCacheSnapshot snapshot) {
    _activeDeviceId = snapshot.activeDeviceId;
    _contexts
      ..clear()
      ..addAll(snapshot.contexts);
    _sessionDrafts
      ..clear()
      ..addAll(snapshot.sessionDrafts);
    _sessionViewportAnchors
      ..clear()
      ..addAll(snapshot.sessionViewportAnchors);
    _sectionGenerations.clear();
    _workspaceGenerations.clear();
    _loadingMoreSections.clear();
    _sectionRequestsInFlight.clear();
    _pendingSectionMutations.clear();
    _emit();
    if (!_activeDeviceController.isClosed) {
      _activeDeviceController.add(_activeDeviceId);
    }
  }

  Stream<DeviceConversationCacheSnapshot> get snapshotStream => _snapshotController.stream;
  Stream<String?> get activeDeviceStream => _activeDeviceController.stream;

  DeviceConversationCacheSnapshot get snapshot => DeviceConversationCacheSnapshot(
    activeDeviceId: _activeDeviceId,
    contexts: Map.unmodifiable(_contexts),
    sessionDrafts: Map.unmodifiable(_sessionDrafts),
    sessionViewportAnchors: Map.unmodifiable(_sessionViewportAnchors),
  );

  String? get activeDeviceId => _activeDeviceId;

  // ---------------------------------------------------------------------------
  // Device context
  // ---------------------------------------------------------------------------

  DeviceConversationContext _contextFor(String deviceId) => _contexts[deviceId] ?? DeviceConversationContext.empty();

  void ensureDeviceContext(String deviceId) {
    _contexts.putIfAbsent(deviceId, () => DeviceConversationContext.empty());
  }

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

  String _sectionKey(String deviceId, String? workspaceId) =>
      workspaceId == null ? '$deviceId|__unscoped__' : '$deviceId|$workspaceId';

  /// Advance and return the generation for a section refresh. Callers must
  /// capture the returned token and pass it to the matching merge method so
  /// a late response cannot clobber a newer snapshot.
  RequestGeneration advanceGeneration(String deviceId, String? workspaceId) {
    final key = _sectionKey(deviceId, workspaceId);
    final current = _sectionGenerations[key] ?? RequestGeneration.initial;
    final next = current.next();
    _sectionGenerations[key] = next;
    _sectionRequestsInFlight.add(key);
    _pendingSectionMutations.remove(key);
    return next;
  }

  RequestGeneration advanceWorkspacesGeneration(String deviceId) {
    final current = _workspaceGenerations[deviceId] ?? RequestGeneration.initial;
    final next = current.next();
    _workspaceGenerations[deviceId] = next;
    return next;
  }

  RequestGeneration _currentGeneration(String deviceId, String? workspaceId) {
    return _sectionGenerations[_sectionKey(deviceId, workspaceId)] ?? RequestGeneration.initial;
  }

  bool _isCurrent(RequestGeneration generation, String deviceId, String? workspaceId) {
    final current = _currentGeneration(deviceId, workspaceId);
    return generation == current;
  }

  bool _isCurrentWorkspaceGeneration(
    RequestGeneration generation,
    String deviceId,
  ) => generation == (_workspaceGenerations[deviceId] ?? RequestGeneration.initial);

  // ---------------------------------------------------------------------------
  // Workspaces
  // ---------------------------------------------------------------------------

  void setWorkspacesLoading(String deviceId) {
    ensureDeviceContext(deviceId);
    final ctx = _contextFor(deviceId);
    final hasSnapshot = ctx.workspaces.workspaces.isNotEmpty || ctx.workspaces.state.hasUsableSnapshot;
    final next = ctx.workspaces.copyWith(
      state: hasSnapshot ? ConversationResourceState.refreshing : ConversationResourceState.loading,
    );
    _contexts[deviceId] = ctx.copyWith(workspaces: next);
    _emit();
  }

  /// Optimistically place a single newly created [workspace] into the cached
  /// list without forcing a full `refreshWorkspaces` round-trip. The canonical
  /// workspace list from the next refresh replaces it; this only keeps the
  /// sidebar in sync while that refresh is in flight.
  ///
  /// Used by [ConversationCacheRepository.createWorkspace] so a freshly created
  /// workspace appears immediately under the "Workspaces" heading.
  void applyWorkspaceCreated(String deviceId, DeviceWorkspace workspace) {
    advanceWorkspacesGeneration(deviceId);
    ensureDeviceContext(deviceId);
    final ctx = _contextFor(deviceId);
    final current = List<DeviceWorkspace>.from(ctx.workspaces.workspaces)
      ..removeWhere((existing) => existing.id == workspace.id);
    current.insert(0, workspace);
    final expansion = Map<String, bool>.from(ctx.workspaceExpansion);
    expansion[workspace.id] = expansion[workspace.id] ?? true;
    _contexts[deviceId] = ctx.copyWith(
      workspaces: CachedWorkspaceSection(
        workspaces: List.unmodifiable(current),
        state: ConversationResourceState.ready,
        lastRefreshedAt: ctx.workspaces.lastRefreshedAt,
        lastErrorAt: null,
        lastError: null,
      ),
      workspaceExpansion: expansion,
    );
    _emit();
  }

  void applyWorkspaceUpdated(String deviceId, DeviceWorkspace workspace) {
    ensureDeviceContext(deviceId);
    final ctx = _contextFor(deviceId);
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
    _contexts[deviceId] = ctx.copyWith(
      workspaces: ctx.workspaces.copyWith(
        workspaces: List.unmodifiable(current),
      ),
      workspaceConversationPages: pages,
    );
    _emit();
  }

  void applyWorkspaceRemoved(String deviceId, String workspaceId) {
    ensureDeviceContext(deviceId);
    final ctx = _contextFor(deviceId);
    final workspaces = List<DeviceWorkspace>.from(ctx.workspaces.workspaces)
      ..removeWhere((workspace) => workspace.id == workspaceId);
    final pages = Map<String, ConversationSectionPage>.from(
      ctx.workspaceConversationPages,
    )..remove(workspaceId);
    final expansion = Map<String, bool>.from(ctx.workspaceExpansion)..remove(workspaceId);
    final destination = ctx.lastDestination?.workspaceId == workspaceId
        ? ConversationDestination.newConversation(deviceId: deviceId)
        : ctx.lastDestination;
    _contexts[deviceId] = ctx.copyWith(
      workspaces: ctx.workspaces.copyWith(
        workspaces: List.unmodifiable(workspaces),
      ),
      workspaceConversationPages: pages,
      workspaceExpansion: expansion,
      lastDestination: destination,
      clearNewConversationDraftWorkspace: ctx.newConversationDraftWorkspaceId == workspaceId,
    );
    _emit();
  }

  void applyWorkspacesRefreshed(
    String deviceId,
    List<DeviceWorkspace> workspaces, {
    required RequestGeneration generation,
  }) {
    if (!_isCurrentWorkspaceGeneration(generation, deviceId)) return;
    ensureDeviceContext(deviceId);
    final ctx = _contextFor(deviceId);
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
    _contexts[deviceId] = ctx.copyWith(
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
    );
    _emit();
  }

  void applyWorkspacesError(
    String deviceId,
    String error, {
    required RequestGeneration generation,
  }) {
    if (!_isCurrentWorkspaceGeneration(generation, deviceId)) return;
    ensureDeviceContext(deviceId);
    final ctx = _contextFor(deviceId);
    final hadSnapshot = ctx.workspaces.state.hasUsableSnapshot;
    _contexts[deviceId] = ctx.copyWith(
      workspaces: ctx.workspaces.copyWith(
        state: hadSnapshot ? ConversationResourceState.staleError : ConversationResourceState.notLoaded,
        lastErrorAt: DateTime.now(),
        lastError: error,
      ),
    );
    _emit();
  }

  // ---------------------------------------------------------------------------
  // Conversation pages
  // ---------------------------------------------------------------------------

  ConversationSectionPage _pageFor(String deviceId, String? workspaceId) {
    final ctx = _contextFor(deviceId);
    return workspaceId == null
        ? ctx.unscopedConversations
        : (ctx.workspaceConversationPages[workspaceId] ?? ConversationSectionPage.notLoaded());
  }

  void setSectionLoading(String deviceId, String? workspaceId) {
    ensureDeviceContext(deviceId);
    final ctx = _contextFor(deviceId);
    final page = _pageFor(deviceId, workspaceId);
    final hasSnapshot = page.sessions.isNotEmpty || page.state.hasUsableSnapshot;
    final next = page.copyWith(
      state: hasSnapshot ? ConversationResourceState.refreshing : ConversationResourceState.loading,
    );
    _contexts[deviceId] = _withPage(ctx, workspaceId, next);
    _emit();
  }

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
  }) {
    if (!_isCurrent(generation, deviceId, workspaceId)) return;
    ensureDeviceContext(deviceId);
    final ctx = _contextFor(deviceId);
    _loadingMoreSections.remove(_sectionKey(deviceId, workspaceId));
    final key = _sectionKey(deviceId, workspaceId);
    final merged = _applyPendingSectionMutations(key, sessions);
    _finishSectionRequest(key);
    final page = ConversationSectionPage(
      sessions: merged,
      nextCursor: nextCursor,
      hasMore: hasMore,
      state: ConversationResourceState.ready,
      lastRefreshedAt: DateTime.now(),
      lastErrorAt: null,
      lastError: null,
    );
    _contexts[deviceId] = _withPage(ctx, workspaceId, page);
    _emit();
  }

  /// Append the next page from a "load more" request, deduplicating by session
  /// id and preserving server order for the new rows.
  void applySectionPageAppended(
    String deviceId,
    String? workspaceId,
    List<Session> sessions, {
    required String? nextCursor,
    required bool hasMore,
    required RequestGeneration generation,
  }) {
    if (!_isCurrent(generation, deviceId, workspaceId)) return;
    final key = _sectionKey(deviceId, workspaceId);
    _loadingMoreSections.remove(key);
    ensureDeviceContext(deviceId);
    final ctx = _contextFor(deviceId);
    final existing = _pageFor(deviceId, workspaceId);
    final merged = _applyPendingSectionMutations(
      key,
      _mergeAppendPage(existing.sessions, sessions),
    );
    _finishSectionRequest(key);
    final page = existing.copyWith(
      sessions: merged,
      nextCursor: nextCursor,
      hasMore: hasMore,
      state: ConversationResourceState.ready,
      lastRefreshedAt: DateTime.now(),
    );
    _contexts[deviceId] = _withPage(ctx, workspaceId, page);
    _emit();
  }

  void setSectionLoadMoreInProgress(String deviceId, String? workspaceId) {
    _loadingMoreSections.add(_sectionKey(deviceId, workspaceId));
    _emit();
  }

  bool isSectionLoadingMore(String deviceId, String? workspaceId) =>
      _loadingMoreSections.contains(_sectionKey(deviceId, workspaceId));

  void applySectionError(
    String deviceId,
    String? workspaceId,
    String error, {
    required RequestGeneration generation,
  }) {
    if (!_isCurrent(generation, deviceId, workspaceId)) return;
    final key = _sectionKey(deviceId, workspaceId);
    _loadingMoreSections.remove(key);
    _finishSectionRequest(key);
    ensureDeviceContext(deviceId);
    final ctx = _contextFor(deviceId);
    final page = _pageFor(deviceId, workspaceId);
    final hadSnapshot = page.state.hasUsableSnapshot;
    _contexts[deviceId] = _withPage(
      ctx,
      workspaceId,
      page.copyWith(
        state: hadSnapshot ? ConversationResourceState.staleError : ConversationResourceState.notLoaded,
        lastErrorAt: DateTime.now(),
        lastError: error,
      ),
    );
    _emit();
  }

  // ---------------------------------------------------------------------------
  // Session canonical events
  // ---------------------------------------------------------------------------

  /// Place a newly created session into the correct section based on its
  /// `workspaceId`, then re-sort that section.
  void applySessionCreated(String deviceId, Session session) {
    _recordSectionMutation(
      _sectionKey(deviceId, session.workspaceId),
      _SectionMutation.upsert(session),
    );
    ensureDeviceContext(deviceId);
    final ctx = _contextFor(deviceId);
    final workspaceId = session.workspaceId;
    final page = _pageFor(deviceId, workspaceId);
    if (page.sessions.any((s) => s.id == session.id)) {
      // Already present (e.g. optimistic insert); update in place.
      final updated = page.sessions.map((s) => s.id == session.id ? session : s).toList();
      _contexts[deviceId] = _withPage(
        ctx,
        workspaceId,
        page.copyWith(sessions: _sorted(updated)),
      );
    } else {
      final updated = [session, ...page.sessions];
      _contexts[deviceId] = _withPage(
        ctx,
        workspaceId,
        page.copyWith(sessions: _sorted(updated)),
      );
    }
    _emit();
  }

  /// Update a session in whichever section it currently lives. If the update
  /// changes `workspaceId`, the session is moved between sections.
  void applySessionUpdated(String deviceId, Session updated) {
    _recordMutationForInFlightDeviceSections(
      deviceId,
      _SectionMutation.delete(updated.id),
    );
    _recordSectionMutation(
      _sectionKey(deviceId, updated.workspaceId),
      _SectionMutation.upsert(updated),
    );
    ensureDeviceContext(deviceId);
    var ctx = _contextFor(deviceId);
    // Remove from all sections first, then re-insert into the correct one.
    ctx = _removeSessionFromAllSections(ctx, updated.id);
    final workspaceId = updated.workspaceId;
    final page = workspaceId == null
        ? ctx.unscopedConversations
        : (ctx.workspaceConversationPages[workspaceId] ?? ConversationSectionPage.notLoaded());
    if (page.state == ConversationResourceState.notLoaded) {
      // Section never loaded; we cannot know if the session belongs here. Drop
      // it to avoid inventing rows. It will appear on next refresh.
      _contexts[deviceId] = ctx;
    } else {
      final sessions = [updated, ...page.sessions.where((s) => s.id != updated.id)];
      _contexts[deviceId] = _withPage(ctx, workspaceId, page.copyWith(sessions: _sorted(sessions)));
    }
    _emit();
  }

  /// Remove a session from every section, its draft, and last-selected pointer.
  void applySessionDeleted(String deviceId, String sessionId) {
    _recordMutationForInFlightDeviceSections(
      deviceId,
      _SectionMutation.delete(sessionId),
    );
    var ctx = _contextFor(deviceId);
    ctx = _removeSessionFromAllSections(ctx, sessionId);
    final deletedCurrentDestination =
        ctx.lastDestination?.isSession == true && ctx.lastDestination?.sessionId == sessionId;
    if (ctx.lastSelectedSessionId == sessionId || deletedCurrentDestination) {
      ctx = ctx.copyWith(
        clearLastSelectedSession: ctx.lastSelectedSessionId == sessionId,
        clearLastDestination: deletedCurrentDestination,
      );
    }
    _contexts[deviceId] = ctx;
    _sessionDrafts.remove(DeviceConversationCacheSnapshot.sessionDraftKey(deviceId, sessionId));
    _sessionViewportAnchors.remove(
      DeviceConversationCacheSnapshot.sessionViewportKey(deviceId, sessionId),
    );
    _emit();
  }

  /// Apply a canonical user-message acceptance: bump the session's
  /// `lastMessageAt`/`updatedAt` and re-sort its section so it moves to the top.
  void applyUserMessageAccepted(
    String deviceId,
    String sessionId, {
    DateTime? timestamp,
    String? requestId,
  }) {
    final now = timestamp ?? DateTime.now();
    final clearedViewportAnchor =
        _sessionViewportAnchors.remove(
          DeviceConversationCacheSnapshot.sessionViewportKey(deviceId, sessionId),
        ) !=
        null;
    _recordMutationForInFlightDeviceSections(
      deviceId,
      _SectionMutation.bump(sessionId, now),
    );
    ensureDeviceContext(deviceId);
    final ctx = _contextFor(deviceId);
    Session? found;
    String? foundWorkspaceId;
    // Find the session across all sections.
    final unscopedMatch = ctx.unscopedConversations.sessions.where((s) => s.id == sessionId).firstOrNull;
    if (unscopedMatch != null) {
      found = unscopedMatch;
      foundWorkspaceId = null;
    } else {
      for (final entry in ctx.workspaceConversationPages.entries) {
        final match = entry.value.sessions.where((s) => s.id == sessionId).firstOrNull;
        if (match != null) {
          found = match;
          foundWorkspaceId = entry.key;
          break;
        }
      }
    }
    final draftKey = DeviceConversationCacheSnapshot.sessionDraftKey(
      deviceId,
      sessionId,
    );
    final draft = _sessionDrafts[draftKey];
    var clearedDraft = false;
    if (requestId != null && draft?.pendingRequestId == requestId) {
      _sessionDrafts.remove(draftKey);
      clearedDraft = true;
    } else if (requestId != null && ctx.newConversationDraftPendingRequestId == requestId) {
      _contexts[deviceId] = ctx.copyWith(clearNewConversationDraft: true);
      clearedDraft = true;
    }
    if (found == null) {
      if (clearedDraft || clearedViewportAnchor) {
        _emit();
      }
      return;
    }
    final bumped = found.copyWith(
      lastMessageAt: now,
      updatedAt: now,
    );
    final page = _pageFor(deviceId, foundWorkspaceId);
    final sessions = [bumped, ...page.sessions.where((s) => s.id != sessionId)];
    final currentContext = _contextFor(deviceId);
    _contexts[deviceId] = _withPage(
      currentContext,
      foundWorkspaceId,
      page.copyWith(sessions: _sorted(sessions)),
    );
    _emit();
  }

  // ---------------------------------------------------------------------------
  // Workspace expansion + last selected session
  // ---------------------------------------------------------------------------

  void setWorkspaceExpansion(String deviceId, String workspaceId, bool expanded) {
    ensureDeviceContext(deviceId);
    final ctx = _contextFor(deviceId);
    final nextExpansion = Map<String, bool>.from(ctx.workspaceExpansion);
    nextExpansion[workspaceId] = expanded;
    _contexts[deviceId] = ctx.copyWith(workspaceExpansion: nextExpansion);
    _emit();
  }

  /// Persists the exact typed route used for restart recovery.
  ///
  /// Session destinations also advance the separate last-selected reference
  /// used to inherit context when a later New Conversation is opened.
  void recordLastDestination(ConversationDestination destination) {
    if (destination.isConversationsList) {
      throw ArgumentError.value(
        destination,
        'destination',
        'Conversation lists are not restorable destinations',
      );
    }
    ensureDeviceContext(destination.deviceId);
    final ctx = _contextFor(destination.deviceId);
    _contexts[destination.deviceId] = ctx.copyWith(
      lastDestination: destination,
      lastSelectedSessionId: destination.isSession ? destination.sessionId : null,
    );
    _emit();
  }

  void clearLastDestination(String deviceId) {
    ensureDeviceContext(deviceId);
    _contexts[deviceId] = _contextFor(deviceId).copyWith(clearLastDestination: true);
    _emit();
  }

  // ---------------------------------------------------------------------------
  // Session viewport anchors
  // ---------------------------------------------------------------------------

  String? sessionViewportAnchor(String deviceId, String sessionId) =>
      _sessionViewportAnchors[DeviceConversationCacheSnapshot.sessionViewportKey(deviceId, sessionId)];

  void recordSessionViewportAnchor(String deviceId, String sessionId, String eventId) {
    final normalizedEventId = eventId.trim();
    if (normalizedEventId.isEmpty) return;
    final key = DeviceConversationCacheSnapshot.sessionViewportKey(deviceId, sessionId);
    if (_sessionViewportAnchors[key] == normalizedEventId) return;
    _sessionViewportAnchors[key] = normalizedEventId;
    _emit();
  }

  void clearSessionViewportAnchor(String deviceId, String sessionId) {
    final key = DeviceConversationCacheSnapshot.sessionViewportKey(deviceId, sessionId);
    if (_sessionViewportAnchors.remove(key) != null) {
      _emit();
    }
  }

  // ---------------------------------------------------------------------------
  // Drafts
  // ---------------------------------------------------------------------------

  ConversationDraft? sessionDraft(String deviceId, String sessionId) =>
      _sessionDrafts[DeviceConversationCacheSnapshot.sessionDraftKey(deviceId, sessionId)];

  void setSessionDraft(String deviceId, String sessionId, ConversationDraft draft) {
    _sessionDrafts[DeviceConversationCacheSnapshot.sessionDraftKey(deviceId, sessionId)] = draft;
    _emit();
  }

  void markSessionDraftAwaitingAcceptance(
    String deviceId,
    String sessionId,
    String requestId,
  ) {
    final key = DeviceConversationCacheSnapshot.sessionDraftKey(
      deviceId,
      sessionId,
    );
    final draft = _sessionDrafts[key];
    if (draft == null) return;
    _sessionDrafts[key] = draft.copyWith(pendingRequestId: requestId);
    _emit();
  }

  void clearSessionDraft(String deviceId, String sessionId) {
    if (_sessionDrafts.remove(DeviceConversationCacheSnapshot.sessionDraftKey(deviceId, sessionId)) != null) {
      _emit();
    }
  }

  bool prependStopRecovery(
    String deviceId,
    String sessionId, {
    required String stopRequestId,
    required Iterable<String> texts,
  }) {
    final key = DeviceConversationCacheSnapshot.sessionDraftKey(deviceId, sessionId);
    final current = _sessionDrafts[key] ?? ConversationDraft.empty();
    if (current.appliedStopRecoveryIds.contains(stopRequestId)) return false;
    final recovered = texts.map((text) => text.trim()).where((text) => text.isNotEmpty).join('\n');
    final nextText = [recovered, current.text].where((text) => text.isNotEmpty).join('\n');
    _sessionDrafts[key] = current.copyWith(
      text: nextText,
      appliedStopRecoveryIds: {...current.appliedStopRecoveryIds, stopRequestId},
      pendingStopRecoveryIds: {...current.pendingStopRecoveryIds}..remove(stopRequestId),
      updatedAt: DateTime.now().toUtc(),
    );
    _emit();
    return true;
  }

  void markStopRecoveryPending(
    String deviceId,
    String sessionId,
    String stopRequestId, {
    String? ownerToken,
  }) {
    final key = DeviceConversationCacheSnapshot.sessionDraftKey(deviceId, sessionId);
    final current = _sessionDrafts[key] ?? ConversationDraft.empty();
    _sessionDrafts[key] = current.copyWith(
      pendingStopRecoveryIds: {...current.pendingStopRecoveryIds, stopRequestId},
      stopRecoveryOwnerTokens: ownerToken == null
          ? current.stopRecoveryOwnerTokens
          : {...current.stopRecoveryOwnerTokens, stopRequestId: ownerToken},
      updatedAt: DateTime.now().toUtc(),
    );
    _emit();
  }

  void unmarkStopRecoveryPending(String deviceId, String sessionId, String stopRequestId) {
    final key = DeviceConversationCacheSnapshot.sessionDraftKey(deviceId, sessionId);
    final current = _sessionDrafts[key];
    if (current == null || !current.pendingStopRecoveryIds.contains(stopRequestId)) return;
    _sessionDrafts[key] = current.copyWith(
      pendingStopRecoveryIds: {...current.pendingStopRecoveryIds}..remove(stopRequestId),
      stopRecoveryOwnerTokens: {...current.stopRecoveryOwnerTokens}..remove(stopRequestId),
      updatedAt: DateTime.now().toUtc(),
    );
    _emit();
  }

  void clearStopRecoveryOwnerToken(
    String deviceId,
    String sessionId,
    String stopRequestId,
  ) {
    final key = DeviceConversationCacheSnapshot.sessionDraftKey(deviceId, sessionId);
    final current = _sessionDrafts[key];
    if (current == null || !current.stopRecoveryOwnerTokens.containsKey(stopRequestId)) return;
    _sessionDrafts[key] = current.copyWith(
      stopRecoveryOwnerTokens: {...current.stopRecoveryOwnerTokens}..remove(stopRequestId),
      updatedAt: DateTime.now().toUtc(),
    );
    _emit();
  }

  void setStopRecoveryClaim(
    String deviceId,
    String sessionId,
    String stopRequestId,
    String claimId,
  ) {
    final key = DeviceConversationCacheSnapshot.sessionDraftKey(deviceId, sessionId);
    final current = _sessionDrafts[key] ?? ConversationDraft.empty();
    _sessionDrafts[key] = current.copyWith(
      stopRecoveryClaimIds: {...current.stopRecoveryClaimIds, stopRequestId: claimId},
      updatedAt: DateTime.now().toUtc(),
    );
    _emit();
  }

  void clearStopRecoveryClaim(String deviceId, String sessionId, String stopRequestId) {
    final key = DeviceConversationCacheSnapshot.sessionDraftKey(deviceId, sessionId);
    final current = _sessionDrafts[key];
    if (current == null || !current.stopRecoveryClaimIds.containsKey(stopRequestId)) return;
    _sessionDrafts[key] = current.copyWith(
      stopRecoveryClaimIds: {...current.stopRecoveryClaimIds}..remove(stopRequestId),
      updatedAt: DateTime.now().toUtc(),
    );
    _emit();
  }

  /// Move a New Conversation draft binding to a newly created session identity.
  /// Called once the daemon confirms session creation, before clearing the new
  /// draft after canonical acceptance.
  void transferNewConversationDraftToSession(
    String deviceId,
    String sessionId,
  ) {
    final ctx = _contextFor(deviceId);
    final draft = ConversationDraft(
      text: ctx.newConversationDraftText,
      workspaceId: ctx.newConversationDraftWorkspaceId,
      providerId: ctx.newConversationDraftProviderId,
      model: ctx.newConversationDraftModel,
      thinkingMode: ctx.newConversationDraftThinkingMode,
      permissionMode: ctx.newConversationDraftPermissionMode,
      pendingRequestId: ctx.newConversationDraftPendingRequestId,
      updatedAt: ctx.newConversationDraftUpdatedAt,
    );
    if (!draft.isEmpty) {
      _sessionDrafts[DeviceConversationCacheSnapshot.sessionDraftKey(deviceId, sessionId)] = draft;
    }
    _contexts[deviceId] = ctx.copyWith(clearNewConversationDraft: true);
    _emit();
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
    ensureDeviceContext(deviceId);
    final ctx = _contextFor(deviceId);
    _contexts[deviceId] = ctx.copyWith(
      newConversationDraftText: text,
      newConversationDraftWorkspaceId: workspaceId,
      newConversationDraftProviderId: providerId,
      newConversationDraftModel: model,
      newConversationDraftThinkingMode: thinkingMode,
      newConversationDraftPermissionMode: permissionMode,
      newConversationDraftUpdatedAt: DateTime.now().toUtc(),
      clearNewConversationDraftWorkspace: clearWorkspace,
      clearNewConversationDraftProvider: clearProvider,
      clearNewConversationDraftModel: clearModel,
      clearNewConversationDraftThinkingMode: clearThinkingMode,
      clearNewConversationDraftPermissionMode: clearPermissionMode,
      clearNewConversationDraftPendingRequest: clearPendingRequest,
    );
    _emit();
  }

  void markNewConversationDraftAwaitingAcceptance(
    String deviceId,
    String requestId,
  ) {
    ensureDeviceContext(deviceId);
    final context = _contextFor(deviceId);
    _contexts[deviceId] = context.copyWith(
      newConversationDraftPendingRequestId: requestId,
    );
    _emit();
  }

  void clearNewConversationDraft(String deviceId) {
    ensureDeviceContext(deviceId);
    final ctx = _contextFor(deviceId);
    if (ctx.newConversationDraftText.isEmpty &&
        ctx.newConversationDraftWorkspaceId == null &&
        ctx.newConversationDraftProviderId == null &&
        ctx.newConversationDraftModel == null &&
        ctx.newConversationDraftThinkingMode == null &&
        ctx.newConversationDraftPermissionMode == null &&
        ctx.newConversationDraftPendingRequestId == null) {
      return;
    }
    _contexts[deviceId] = ctx.copyWith(clearNewConversationDraft: true);
    _emit();
  }

  // ---------------------------------------------------------------------------
  // Logout / cleanup
  // ---------------------------------------------------------------------------

  /// Remove all data for a device (used when a device is unregistered).
  void clearDevice(String deviceId) {
    _contexts.remove(deviceId);
    _sectionGenerations.removeWhere((key, _) => key.startsWith('$deviceId|'));
    _workspaceGenerations.remove(deviceId);
    _loadingMoreSections.removeWhere((key) => key.startsWith('$deviceId|'));
    _sessionDrafts.removeWhere((key, _) => key.startsWith('$deviceId|'));
    _sessionViewportAnchors.removeWhere((key, _) => key.startsWith('$deviceId|'));
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

  DeviceSidebarSnapshot? sidebarSnapshotFor(String deviceId) {
    final ctx = _contexts[deviceId];
    if (ctx == null) return null;
    final groups = <SidebarConversationGroup>[];
    for (final workspace in ctx.workspaces.workspaces) {
      final page = ctx.workspaceConversationPages[workspace.id] ?? ConversationSectionPage.notLoaded();
      groups.add(
        SidebarConversationGroup(
          workspaceId: workspace.id,
          workspaceName: workspace.name,
          workspacePath: workspace.path,
          sessions: page.sessions,
          state: page.state,
          hasMore: page.hasMore,
          isLoadingMore: _loadingMoreSections.contains(_sectionKey(deviceId, workspace.id)),
        ),
      );
    }
    groups.add(
      SidebarConversationGroup(
        workspaceId: null,
        workspaceName: null,
        workspacePath: null,
        sessions: ctx.unscopedConversations.sessions,
        state: ctx.unscopedConversations.state,
        hasMore: ctx.unscopedConversations.hasMore,
        isLoadingMore: _loadingMoreSections.contains(_sectionKey(deviceId, null)),
      ),
    );
    return DeviceSidebarSnapshot(
      deviceId: deviceId,
      workspaces: ctx.workspaces.workspaces,
      workspaceExpansion: Map.unmodifiable({
        for (final workspace in ctx.workspaces.workspaces) workspace.id: ctx.workspaceExpansion[workspace.id] ?? true,
      }),
      conversationGroups: groups,
    );
  }

  /// Compatibility projection for consumers that still render a flat list.
  /// The cache remains the owner; callers receive a derived immutable view.
  List<Session> sessionsForDevice(String deviceId) {
    final context = _contexts[deviceId];
    if (context == null) return const [];
    final sessions = <Session>[
      ...context.unscopedConversations.sessions,
      for (final page in context.workspaceConversationPages.values) ...page.sessions,
    ];
    return List.unmodifiable(_deduplicatedSorted(sessions));
  }

  // ---------------------------------------------------------------------------
  // Internal helpers
  // ---------------------------------------------------------------------------

  void _recordSectionMutation(String key, _SectionMutation mutation) {
    if (!_sectionRequestsInFlight.contains(key)) return;
    (_pendingSectionMutations[key] ??= <_SectionMutation>[]).add(mutation);
  }

  void _recordMutationForInFlightDeviceSections(
    String deviceId,
    _SectionMutation mutation,
  ) {
    final prefix = '$deviceId|';
    for (final key in _sectionRequestsInFlight.where((key) => key.startsWith(prefix))) {
      (_pendingSectionMutations[key] ??= <_SectionMutation>[]).add(mutation);
    }
  }

  List<Session> _applyPendingSectionMutations(String key, List<Session> sessions) {
    var merged = _deduplicatedSorted(sessions);
    for (final mutation in _pendingSectionMutations[key] ?? const <_SectionMutation>[]) {
      switch (mutation.kind) {
        case _SectionMutationKind.upsert:
          final session = mutation.session!;
          merged = [session, ...merged.where((candidate) => candidate.id != session.id)];
          break;
        case _SectionMutationKind.delete:
          merged = merged.where((candidate) => candidate.id != mutation.sessionId).toList();
          break;
        case _SectionMutationKind.bump:
          final index = merged.indexWhere((candidate) => candidate.id == mutation.sessionId);
          if (index >= 0) {
            final timestamp = mutation.timestamp!;
            merged[index] = merged[index].copyWith(
              lastMessageAt: timestamp,
              updatedAt: timestamp,
            );
          }
          break;
      }
    }
    return _sorted(merged);
  }

  void _finishSectionRequest(String key) {
    _sectionRequestsInFlight.remove(key);
    _pendingSectionMutations.remove(key);
  }

  DeviceConversationContext _withPage(
    DeviceConversationContext ctx,
    String? workspaceId,
    ConversationSectionPage page,
  ) {
    if (workspaceId == null) {
      return ctx.copyWith(unscopedConversations: page);
    }
    final pages = Map<String, ConversationSectionPage>.from(ctx.workspaceConversationPages);
    pages[workspaceId] = page;
    return ctx.copyWith(workspaceConversationPages: pages);
  }

  DeviceConversationContext _removeSessionFromAllSections(
    DeviceConversationContext ctx,
    String sessionId,
  ) {
    var next = ctx;
    if (next.unscopedConversations.sessions.any((s) => s.id == sessionId)) {
      next = next.copyWith(
        unscopedConversations: next.unscopedConversations.copyWith(
          sessions: next.unscopedConversations.sessions.where((s) => s.id != sessionId).toList(),
        ),
      );
    }
    if (next.workspaceConversationPages.isNotEmpty) {
      final pages = Map<String, ConversationSectionPage>.from(next.workspaceConversationPages);
      var changed = false;
      for (final entry in pages.entries) {
        if (entry.value.sessions.any((s) => s.id == sessionId)) {
          pages[entry.key] = entry.value.copyWith(
            sessions: entry.value.sessions.where((s) => s.id != sessionId).toList(),
          );
          changed = true;
        }
      }
      if (changed) {
        next = next.copyWith(workspaceConversationPages: pages);
      }
    }
    return next;
  }

  List<Session> _mergeAppendPage(List<Session> existing, List<Session> fresh) {
    final existingIds = existing.map((s) => s.id).toSet();
    final deduped = fresh.where((s) => !existingIds.contains(s.id)).toList();
    return _sorted([...existing, ...deduped]);
  }

  List<Session> _deduplicatedSorted(List<Session> sessions) {
    final byId = <String, Session>{};
    for (final session in sessions) {
      byId[session.id] = session;
    }
    return _sorted(byId.values.toList());
  }

  /// Sort by `lastMessageAt` descending (nulls last), then `updatedAt`
  /// descending, then `id` ascending as a stable tie-breaker.
  List<Session> _sorted(List<Session> sessions) {
    final list = List<Session>.from(sessions);
    list.sort((a, b) {
      final am = a.lastMessageAt;
      final bm = b.lastMessageAt;
      if (am != null && bm != null) {
        final cmp = bm.compareTo(am);
        if (cmp != 0) return cmp;
      } else if (am != null) {
        return -1;
      } else if (bm != null) {
        return 1;
      }
      final ucmp = b.updatedAt.compareTo(a.updatedAt);
      if (ucmp != 0) return ucmp;
      return a.id.compareTo(b.id);
    });
    return list;
  }

  void _emit() {
    if (!_snapshotController.isClosed) {
      _snapshotController.add(snapshot);
    }
  }

  void dispose() {
    _sectionRequestsInFlight.clear();
    _pendingSectionMutations.clear();
    unawaited(_snapshotController.close());
    unawaited(_activeDeviceController.close());
  }
}
