import 'package:sanad_client/core/navigation/conversation_destination.dart';
import 'package:sanad_client/features/conversations/domain/models/conversation_resource_state.dart';
import 'package:sanad_client/features/conversations/domain/models/conversation_section_page.dart';
import 'package:sanad_client/features/conversations/domain/models/device_conversation_cache_snapshot.dart';
import 'package:sanad_client/features/conversations/domain/models/device_conversation_context.dart';
import 'package:sanad_client/features/conversations/domain/models/device_sidebar_snapshot.dart';
import 'package:sanad_client/features/conversations/domain/models/request_generation.dart';
import 'package:sanad_client/features/conversations/domain/models/session.dart';
import 'package:sanad_client/features/conversations/domain/models/sidebar_conversation_group.dart';
import 'package:sanad_client/features/conversations/domain/stores/cache_generation_guard.dart';
import 'package:sanad_client/features/conversations/domain/stores/conversation_draft_cache.dart';

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

/// Owns conversation sections, sessions, selection, loading and error flags.
class SessionSectionCache {
  final Map<String, DeviceConversationContext> _contexts = {};
  final Map<String, String> _sessionViewportAnchors = {};

  final Set<String> _loadingMoreSections = {};
  final Set<String> _sectionRequestsInFlight = {};
  final Map<String, List<_SectionMutation>> _pendingSectionMutations = {};

  final CacheGenerationGuard _generationGuard;
  final ConversationDraftCache _draftCache;
  final void Function() _notify;

  SessionSectionCache({
    required CacheGenerationGuard generationGuard,
    required ConversationDraftCache draftCache,
    required void Function() notify,
  })  : _generationGuard = generationGuard,
        _draftCache = draftCache,
        _notify = notify;

  Map<String, DeviceConversationContext> get contexts => Map.unmodifiable(_contexts);
  Map<String, String> get sessionViewportAnchors => Map.unmodifiable(_sessionViewportAnchors);

  DeviceConversationContext contextFor(String deviceId) =>
      _contexts[deviceId] ?? DeviceConversationContext.empty();

  void ensureDeviceContext(String deviceId) {
    _contexts.putIfAbsent(deviceId, () => DeviceConversationContext.empty());
  }

  void updateContext(String deviceId, DeviceConversationContext context) {
    _contexts[deviceId] = context;
  }

  void restoreFrom({
    required Map<String, DeviceConversationContext> contexts,
    required Map<String, String> viewportAnchors,
  }) {
    _contexts
      ..clear()
      ..addAll(contexts);
    _sessionViewportAnchors
      ..clear()
      ..addAll(viewportAnchors);
    _loadingMoreSections.clear();
    _sectionRequestsInFlight.clear();
    _pendingSectionMutations.clear();
  }

  void clearDevice(String deviceId) {
    _contexts.remove(deviceId);
    _loadingMoreSections.removeWhere((key) => key.startsWith('$deviceId|'));
    _sessionViewportAnchors.removeWhere((key, _) => key.startsWith('$deviceId|'));
  }

  void dispose() {
    _sectionRequestsInFlight.clear();
    _pendingSectionMutations.clear();
  }

  String _sectionKey(String deviceId, String? workspaceId) =>
      _generationGuard.sectionKey(deviceId, workspaceId);

  void markSectionRequestInFlight(String deviceId, String? workspaceId) {
    final key = _sectionKey(deviceId, workspaceId);
    _sectionRequestsInFlight.add(key);
    _pendingSectionMutations.remove(key);
  }

  ConversationSectionPage _pageFor(String deviceId, String? workspaceId) {
    final ctx = contextFor(deviceId);
    return workspaceId == null
        ? ctx.unscopedConversations
        : (ctx.workspaceConversationPages[workspaceId] ?? ConversationSectionPage.notLoaded());
  }

  void setSectionLoading(String deviceId, String? workspaceId) {
    ensureDeviceContext(deviceId);
    final ctx = contextFor(deviceId);
    final page = _pageFor(deviceId, workspaceId);
    final hasSnapshot = page.sessions.isNotEmpty || page.state.hasUsableSnapshot;
    final next = page.copyWith(
      state: hasSnapshot ? ConversationResourceState.refreshing : ConversationResourceState.loading,
    );
    _contexts[deviceId] = _withPage(ctx, workspaceId, next);
    _notify();
  }

  void applySectionRefreshed(
    String deviceId,
    String? workspaceId,
    List<Session> sessions, {
    required String? nextCursor,
    required bool hasMore,
    required RequestGeneration generation,
  }) {
    if (!_generationGuard.isCurrent(generation, deviceId, workspaceId)) return;
    ensureDeviceContext(deviceId);
    final ctx = contextFor(deviceId);
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
    _notify();
  }

  void applySectionPageAppended(
    String deviceId,
    String? workspaceId,
    List<Session> sessions, {
    required String? nextCursor,
    required bool hasMore,
    required RequestGeneration generation,
  }) {
    if (!_generationGuard.isCurrent(generation, deviceId, workspaceId)) return;
    final key = _sectionKey(deviceId, workspaceId);
    _loadingMoreSections.remove(key);
    ensureDeviceContext(deviceId);
    final ctx = contextFor(deviceId);
    final existing = _pageFor(deviceId, workspaceId);
    final merged = _applyPendingSectionMutations(
      key,
      _mergeAppendPage(existing.sessions, sessions),
    );
    _finishSectionRequest(key);
    final page = existing.copyWith(
      sessions: merged,
      nextCursor: nextCursor,
      clearCursor: nextCursor == null,
      hasMore: hasMore,
      state: ConversationResourceState.ready,
      lastRefreshedAt: DateTime.now(),
    );
    _contexts[deviceId] = _withPage(ctx, workspaceId, page);
    _notify();
  }

  void setSectionLoadMoreInProgress(String deviceId, String? workspaceId) {
    _loadingMoreSections.add(_sectionKey(deviceId, workspaceId));
    _notify();
  }

  bool isSectionLoadingMore(String deviceId, String? workspaceId) =>
      _loadingMoreSections.contains(_sectionKey(deviceId, workspaceId));

  void applySectionError(
    String deviceId,
    String? workspaceId,
    String error, {
    required RequestGeneration generation,
  }) {
    if (!_generationGuard.isCurrent(generation, deviceId, workspaceId)) return;
    final key = _sectionKey(deviceId, workspaceId);
    _loadingMoreSections.remove(key);
    _finishSectionRequest(key);
    ensureDeviceContext(deviceId);
    final ctx = contextFor(deviceId);
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
    _notify();
  }

  void applySessionCreated(String deviceId, Session session) {
    _recordSectionMutation(
      _sectionKey(deviceId, session.workspaceId),
      _SectionMutation.upsert(session),
    );
    ensureDeviceContext(deviceId);
    final ctx = contextFor(deviceId);
    final workspaceId = session.workspaceId;
    final page = _pageFor(deviceId, workspaceId);
    if (page.sessions.any((s) => s.id == session.id)) {
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
    _notify();
  }

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
    var ctx = contextFor(deviceId);
    ctx = _removeSessionFromAllSections(ctx, updated.id);
    final workspaceId = updated.workspaceId;
    final page = workspaceId == null
        ? ctx.unscopedConversations
        : (ctx.workspaceConversationPages[workspaceId] ?? ConversationSectionPage.notLoaded());
    if (page.state == ConversationResourceState.notLoaded) {
      _contexts[deviceId] = ctx;
    } else {
      final sessions = [updated, ...page.sessions.where((s) => s.id != updated.id)];
      _contexts[deviceId] = _withPage(ctx, workspaceId, page.copyWith(sessions: _sorted(sessions)));
    }
    _notify();
  }

  void applySessionDeleted(String deviceId, String sessionId) {
    _recordMutationForInFlightDeviceSections(
      deviceId,
      _SectionMutation.delete(sessionId),
    );
    var ctx = contextFor(deviceId);
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
    _draftCache.removeSessionDraft(deviceId, sessionId);
    _sessionViewportAnchors.remove(
      DeviceConversationCacheSnapshot.sessionViewportKey(deviceId, sessionId),
    );
    _notify();
  }

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
    final ctx = contextFor(deviceId);
    Session? found;
    String? foundWorkspaceId;
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
    final clearedDraft = _draftCache.clearMatchingPendingDraft(
      deviceId,
      sessionId,
      requestId,
    );
    if (found == null) {
      if (clearedDraft || clearedViewportAnchor) {
        _notify();
      }
      return;
    }
    final bumped = found.copyWith(
      lastMessageAt: now,
      updatedAt: now,
    );
    final page = _pageFor(deviceId, foundWorkspaceId);
    final sessions = [bumped, ...page.sessions.where((s) => s.id != sessionId)];
    final currentContext = contextFor(deviceId);
    _contexts[deviceId] = _withPage(
      currentContext,
      foundWorkspaceId,
      page.copyWith(sessions: _sorted(sessions)),
    );
    _notify();
  }

  void recordLastDestination(ConversationDestination destination) {
    if (destination.isConversationsList) {
      throw ArgumentError.value(
        destination,
        'destination',
        'Conversation lists are not restorable destinations',
      );
    }
    ensureDeviceContext(destination.deviceId);
    final ctx = contextFor(destination.deviceId);
    _contexts[destination.deviceId] = ctx.copyWith(
      lastDestination: destination,
      lastSelectedSessionId: destination.isSession ? destination.sessionId : null,
    );
    _notify();
  }

  void clearLastDestination(String deviceId) {
    ensureDeviceContext(deviceId);
    _contexts[deviceId] = contextFor(deviceId).copyWith(clearLastDestination: true);
    _notify();
  }

  String? sessionViewportAnchor(String deviceId, String sessionId) =>
      _sessionViewportAnchors[DeviceConversationCacheSnapshot.sessionViewportKey(deviceId, sessionId)];

  void recordSessionViewportAnchor(String deviceId, String sessionId, String eventId) {
    final normalizedEventId = eventId.trim();
    if (normalizedEventId.isEmpty) return;
    final key = DeviceConversationCacheSnapshot.sessionViewportKey(deviceId, sessionId);
    if (_sessionViewportAnchors[key] == normalizedEventId) return;
    _sessionViewportAnchors[key] = normalizedEventId;
    _notify();
  }

  void clearSessionViewportAnchor(String deviceId, String sessionId) {
    final key = DeviceConversationCacheSnapshot.sessionViewportKey(deviceId, sessionId);
    if (_sessionViewportAnchors.remove(key) != null) {
      _notify();
    }
  }

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

  List<Session> sessionsForDevice(String deviceId) {
    final context = _contexts[deviceId];
    if (context == null) return const [];
    final sessions = <Session>[
      ...context.unscopedConversations.sessions,
      for (final page in context.workspaceConversationPages.values) ...page.sessions,
    ];
    return List.unmodifiable(_deduplicatedSorted(sessions));
  }

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
}
