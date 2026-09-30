import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../data/repositories/conversation_cache_repository.dart';
import '../../domain/models/conversation_resource_state.dart';
import '../../domain/models/device_conversation_cache_snapshot.dart';
import '../../domain/models/device_conversation_context.dart';
import '../../domain/models/device_sidebar_snapshot.dart';
import '../../../devices/domain/models/device_config.dart';
import 'session_sidebar_state.dart';

/// Presentation owner for the redesigned device workspace sidebar (Plan 32c).
///
/// This cubit is a thin intent dispatcher. It subscribes to the
/// [ConversationCacheRepository] snapshot stream (the single source of truth
/// owned by Plan 32b) and projects a [SessionSidebarState] for the active
/// device. All session/workspace/cache data lives in the store; this cubit owns
/// only presentation-specific overlays (refresh indicator, initial-loading
/// gate) and translates user intents into repository calls.
///
/// Ownership rule (Plan 32c §قاعدة التنفيذ): any missing store capability is
/// reported back to 32b; the cubit never synthesizes a local cache map or
/// pagination cursor.
class SessionSidebarCubit extends Cubit<SessionSidebarState> {
  final ConversationCacheRepository _cacheRepository;

  StreamSubscription<DeviceConversationCacheSnapshot>? _snapshotSubscription;
  StreamSubscription<String?>? _activeDeviceSubscription;

  SessionSidebarCubit({
    required ConversationCacheRepository cacheRepository,
  }) : _cacheRepository = cacheRepository,
       super(const SessionSidebarState(showInitialLoading: true)) {
    _snapshotSubscription = _cacheRepository.snapshotStream.listen(_applyCacheSnapshot);
    _activeDeviceSubscription = _cacheRepository.activeDeviceStream.listen(_onActiveDeviceChanged);
    _hydrateFromCurrentCache();
  }

  // ---------------------------------------------------------------------------
  // Snapshot projection
  // ---------------------------------------------------------------------------

  void _hydrateFromCurrentCache() {
    _applyCacheSnapshot(_cacheRepository.snapshot);
    _onActiveDeviceChanged(_cacheRepository.activeDeviceId);
  }

  void _onActiveDeviceChanged(String? deviceId) {
    final snapshot = deviceId == null ? null : _cacheRepository.sidebarSnapshotFor(deviceId);
    final hadUsableSnapshot = _hasUsableSnapshot(snapshot);
    emit(
      state.copyWith(
        activeDeviceId: deviceId,
        clearActiveDevice: deviceId == null,
        snapshot: snapshot,
        clearSnapshot: snapshot == null,
        isRefreshing: false,
        showInitialLoading: deviceId != null && !hadUsableSnapshot,
      ),
    );
  }

  void _applyCacheSnapshot(DeviceConversationCacheSnapshot cacheSnapshot) {
    final deviceId = cacheSnapshot.activeDeviceId;
    if (deviceId == null) {
      emit(
        state.copyWith(
          clearActiveDevice: true,
          clearSnapshot: true,
          sectionStates: const {},
          loadingMoreSections: const <String?>{},
          workspacesState: ConversationResourceState.notLoaded,
          isRefreshing: false,
          showInitialLoading: true,
        ),
      );
      return;
    }

    final sidebarSnapshot = cacheSnapshot.contexts[deviceId] == null
        ? null
        : _cacheRepository.sidebarSnapshotFor(deviceId);
    final sectionStates = <String?, ConversationResourceState>{};
    final loadingMoreSections = <String?>{};

    final context = cacheSnapshot.contexts[deviceId];
    if (context != null) {
      sectionStates[null] = context.unscopedConversations.state;
      if (context.unscopedConversations.hasMore && _isSectionLoadingMore(deviceId, null)) {
        loadingMoreSections.add(null);
      }
      for (final entry in context.workspaceConversationPages.entries) {
        sectionStates[entry.key] = entry.value.state;
        if (entry.value.hasMore && _isSectionLoadingMore(deviceId, entry.key)) {
          loadingMoreSections.add(entry.key);
        }
      }
    }

    final hadUsableSnapshot = _hasUsableSnapshot(sidebarSnapshot);
    emit(
      state.copyWith(
        activeDeviceId: deviceId,
        snapshot: sidebarSnapshot,
        sectionStates: sectionStates,
        loadingMoreSections: loadingMoreSections,
        workspacesState: context?.workspaces.state ?? ConversationResourceState.notLoaded,
        isRefreshing: _computeRefreshing(context),
        showInitialLoading: !hadUsableSnapshot && _isInitialLoading(context),
      ),
    );
  }

  bool _isSectionLoadingMore(String deviceId, String? workspaceId) =>
      _cacheRepository.isSectionLoadingMore(deviceId, workspaceId);

  bool _computeRefreshing(DeviceConversationContext? context) {
    if (context == null) return false;
    if (context.workspaces.state.isLoading) return true;
    if (context.unscopedConversations.state.isLoading) return true;
    return context.workspaceConversationPages.values.any((page) => page.state.isLoading);
  }

  bool _isInitialLoading(DeviceConversationContext? context) {
    if (context == null) return true;
    return context.workspaces.state == ConversationResourceState.notLoaded &&
        context.unscopedConversations.state == ConversationResourceState.notLoaded &&
        context.workspaceConversationPages.values.every((page) => page.state == ConversationResourceState.notLoaded);
  }

  bool _hasUsableSnapshot(DeviceSidebarSnapshot? snapshot) {
    if (snapshot == null) return false;
    if (snapshot.workspaces.isNotEmpty) return true;
    for (final group in snapshot.conversationGroups) {
      if (group.sessions.isNotEmpty) return true;
      if (group.state.hasUsableSnapshot) return true;
    }
    return false;
  }

  // ---------------------------------------------------------------------------
  // User intents (delegated to the cache repository — never owned locally)
  // ---------------------------------------------------------------------------

  /// Request a background refresh of all sidebar resources for the active
  /// device. Does not clear cache; the store applies stale-while-revalidate.
  Future<void> refreshDevice(DeviceConfig device, {bool force = false}) =>
      _cacheRepository.refreshDeviceSidebar(device, force: force);

  /// Refresh the workspaces list for the active device.
  Future<void> refreshWorkspaces(DeviceConfig device, {bool force = false}) =>
      _cacheRepository.refreshWorkspaces(device, force: force);

  /// Refresh the unscoped conversations section.
  Future<void> refreshUnscopedConversations(DeviceConfig device, {bool force = false}) =>
      _cacheRepository.refreshUnscopedConversations(device, force: force);

  /// Refresh a workspace-scoped conversations section.
  Future<void> refreshWorkspaceConversations(
    DeviceConfig device,
    String workspaceId, {
    bool force = false,
  }) => _cacheRepository.refreshWorkspaceConversations(device, workspaceId, force: force);

  /// Load the next page for a section (unscoped if [workspaceId] is null).
  Future<void> loadMore(DeviceConfig device, {required String? workspaceId}) =>
      _cacheRepository.loadMore(device, workspaceId: workspaceId);

  /// Toggle the expansion preference for a workspace and persist it.
  void toggleWorkspaceExpansion(String deviceId, String workspaceId) {
    final currentlyExpanded = state.isWorkspaceExpanded(workspaceId);
    _cacheRepository.setWorkspaceExpansion(deviceId, workspaceId, !currentlyExpanded);
  }

  /// Explicitly set expansion (used when a workspace is expanded for the first
  /// time to trigger lazy first-page fetch).
  void setWorkspaceExpansion(String deviceId, String workspaceId, bool expanded) {
    _cacheRepository.setWorkspaceExpansion(deviceId, workspaceId, expanded);
  }

  /// Prefix the New Conversation draft for the active device with [workspaceId]
  /// without creating a session. Plan 32 §3.2: pressing `+` inside a
  /// workspace opens New Conversation with the device and workspace preselected;
  /// the session is created only when the first message is sent.
  void prepareNewConversationWithWorkspace(String deviceId, String? workspaceId) {
    _cacheRepository.setNewConversationDraft(
      deviceId,
      workspaceId: workspaceId,
      clearWorkspace: workspaceId == null,
    );
  }

  /// Lazy fetch guard: when a workspace is expanded and its conversation page
  /// has never been loaded (state == notLoaded), trigger a remote first-page
  /// fetch. The cache renders existing data immediately if any; this only adds
  /// data for newly-expanded sections (Plan 32c §السلوك).
  Future<void> loadWorkspaceConversationsIfNeeded(
    DeviceConfig device,
    String workspaceId,
  ) async {
    final context = _cacheRepository.snapshot.contexts[device.id];
    final page = context?.workspaceConversationPages[workspaceId];
    if (page == null || page.state == ConversationResourceState.notLoaded) {
      await _cacheRepository.refreshWorkspaceConversations(device, workspaceId);
    }
  }

  /// Lazy fetch guard for the unscoped conversations section. When the
  /// unscoped page has never been loaded, trigger a remote first-page fetch.
  /// This ensures each section independently loads its first page lazily
  /// (Plan 32c Gate C2: "ربط lazy first page لكل قسم مستقل").
  Future<void> loadUnscopedConversationsIfNeeded(DeviceConfig device) async {
    final context = _cacheRepository.snapshot.contexts[device.id];
    final page = context?.unscopedConversations;
    if (page == null || page.state == ConversationResourceState.notLoaded) {
      await _cacheRepository.refreshUnscopedConversations(device);
    }
  }

  @override
  Future<void> close() {
    unawaited(_snapshotSubscription?.cancel());
    unawaited(_activeDeviceSubscription?.cancel());
    return super.close();
  }
}
