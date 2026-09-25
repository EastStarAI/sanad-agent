import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/data/repositories/conversation_cache_repository.dart';
import 'package:sanad_client/features/conversations/domain/models/conversation_resource_state.dart';
import 'package:sanad_client/features/conversations/domain/models/device_workspace.dart';
import 'package:sanad_client/features/conversations/domain/models/session.dart';
import 'package:sanad_client/features/conversations/domain/models/session_query.dart';
import 'package:sanad_client/features/conversations/domain/repositories/conversation_repository.dart';
import 'package:sanad_client/features/conversations/domain/stores/conversation_cache_store.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_sidebar_cubit.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';

class _ControllableTransport implements ConversationRepository {
  final List<Completer<List<DeviceWorkspace>>> pendingWorkspaces = [];
  final List<Completer<SessionQueryResult>> pendingRefreshSessions = [];
  final List<Completer<SessionQueryResult>> pendingGetSessions = [];

  final List<SessionQueryRequest?> refreshSessionQueries = [];
  final List<SessionQueryRequest?> getSessionQueries = [];
  int getWorkspacesCalls = 0;
  int refreshSessionsCalls = 0;
  int getSessionsCalls = 0;

  @override
  Future<List<DeviceWorkspace>> getWorkspaces(DeviceConfig agent) {
    getWorkspacesCalls++;
    final completer = Completer<List<DeviceWorkspace>>();
    pendingWorkspaces.add(completer);
    return completer.future;
  }

  @override
  Future<SessionQueryResult> refreshSessions(
    DeviceConfig agent, {
    SessionQueryRequest? query,
  }) {
    refreshSessionsCalls++;
    refreshSessionQueries.add(query);
    final completer = Completer<SessionQueryResult>();
    pendingRefreshSessions.add(completer);
    return completer.future;
  }

  @override
  Future<SessionQueryResult> getSessions(
    DeviceConfig agent, {
    SessionQueryRequest? query,
  }) {
    getSessionsCalls++;
    getSessionQueries.add(query);
    final completer = Completer<SessionQueryResult>();
    pendingGetSessions.add(completer);
    return completer.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late ConversationCacheStore store;
  late _ControllableTransport transport;
  final device = DeviceConfig(id: 'device-1', name: 'Test Device', isOnline: true);

  setUp(() {
    store = ConversationCacheStore();
    transport = _ControllableTransport();
  });

  tearDown(() {
    store.dispose();
  });

  group('Deterministic Reproduction & Pagination Efficiency (Task 97i)', () {
    test('coalesces concurrent in-flight refreshUnscopedConversations calls to exactly 1 transport fetch', () async {
      final repo = ConversationCacheRepository(cache: store, transport: transport);

      // Launch 3 concurrent unscoped refresh calls before transport resolves.
      final f1 = repo.refreshUnscopedConversations(device);
      final f2 = repo.refreshUnscopedConversations(device);
      final f3 = repo.refreshUnscopedConversations(device);

      expect(transport.refreshSessionsCalls, 1, reason: 'Must coalesce 3 concurrent calls into 1 transport request');
      expect(transport.pendingRefreshSessions.length, 1);

      // Complete the single in-flight transport call.
      final session = Session(
        id: 's-1',
        title: 'Unscoped Session',
        deviceId: device.id,
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 1),
      );
      transport.pendingRefreshSessions.first.complete(
        SessionQueryResult(sessions: [session], hasMore: false),
      );

      await Future.wait([f1, f2, f3]);

      final context = store.snapshot.contexts[device.id]!;
      expect(context.unscopedConversations.sessions.single.id, 's-1');
      expect(context.unscopedConversations.state, ConversationResourceState.ready);
      expect(transport.refreshSessionsCalls, 1);
    });

    test('coalesces concurrent in-flight refreshWorkspaceConversations for the same workspace into 1 fetch', () async {
      final repo = ConversationCacheRepository(cache: store, transport: transport);

      final f1 = repo.refreshWorkspaceConversations(device, 'ws-1');
      final f2 = repo.refreshWorkspaceConversations(device, 'ws-1');

      expect(transport.refreshSessionsCalls, 1);

      final session = Session(
        id: 'ws-s-1',
        title: 'Workspace Session',
        deviceId: device.id,
        workspaceId: 'ws-1',
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 1),
      );
      transport.pendingRefreshSessions.first.complete(
        SessionQueryResult(sessions: [session], hasMore: false),
      );

      await Future.wait([f1, f2]);

      final context = store.snapshot.contexts[device.id]!;
      expect(context.workspaceConversationPages['ws-1']?.sessions.single.id, 'ws-s-1');
      expect(transport.refreshSessionsCalls, 1);
    });

    test('preserves independent transport calls for different workspaces', () async {
      final repo = ConversationCacheRepository(cache: store, transport: transport);

      final f1 = repo.refreshWorkspaceConversations(device, 'ws-1');
      final f2 = repo.refreshWorkspaceConversations(device, 'ws-2');

      expect(transport.refreshSessionsCalls, 2, reason: 'Different workspaces must not coalesce with each other');

      transport.pendingRefreshSessions[0].complete(
        SessionQueryResult(
          sessions: [
            Session(
              id: 's-ws1',
              title: 'W1',
              deviceId: device.id,
              workspaceId: 'ws-1',
              createdAt: DateTime.utc(2026, 1, 1),
              updatedAt: DateTime.utc(2026, 1, 1),
            ),
          ],
          hasMore: false,
        ),
      );
      transport.pendingRefreshSessions[1].complete(
        SessionQueryResult(
          sessions: [
            Session(
              id: 's-ws2',
              title: 'W2',
              deviceId: device.id,
              workspaceId: 'ws-2',
              createdAt: DateTime.utc(2026, 1, 1),
              updatedAt: DateTime.utc(2026, 1, 1),
            ),
          ],
          hasMore: false,
        ),
      );

      await Future.wait([f1, f2]);

      final context = store.snapshot.contexts[device.id]!;
      expect(context.workspaceConversationPages['ws-1']?.sessions.single.id, 's-ws1');
      expect(context.workspaceConversationPages['ws-2']?.sessions.single.id, 's-ws2');
    });

    test('coalesces concurrent in-flight loadMore calls and awaits single cursor fetch', () async {
      final repo = ConversationCacheRepository(cache: store, transport: transport);

      // Seed initial section state with nextCursor = 'cursor-page-2' and hasMore = true.
      store.setActiveDevice(device.id);
      store.applySectionRefreshed(
        device.id,
        null,
        [
          Session(
            id: 's-0',
            title: 'S0',
            deviceId: device.id,
            createdAt: DateTime.utc(2026, 1, 1),
            updatedAt: DateTime.utc(2026, 1, 1),
          ),
        ],
        nextCursor: 'cursor-page-2',
        hasMore: true,
        generation: store.advanceGeneration(device.id, null),
      );

      // Two concurrent calls to loadMore before transport resolves.
      final f1 = repo.loadMore(device, workspaceId: null);
      final f2 = repo.loadMore(device, workspaceId: null);

      expect(transport.getSessionsCalls, 1, reason: 'Only 1 transport request for the cursor should be in flight');
      expect(transport.getSessionQueries.single?.cursor, 'cursor-page-2');

      // Complete transport.
      transport.pendingGetSessions.first.complete(
        SessionQueryResult(
          sessions: [
            Session(
              id: 's-1',
              title: 'S1',
              deviceId: device.id,
              createdAt: DateTime.utc(2026, 1, 2),
              updatedAt: DateTime.utc(2026, 1, 2),
            ),
          ],
          nextCursor: null,
          hasMore: false,
        ),
      );

      await Future.wait([f1, f2]);

      final context = store.snapshot.contexts[device.id]!;
      expect(context.unscopedConversations.sessions.length, 2);
      expect(context.unscopedConversations.hasMore, isFalse);
      expect(context.unscopedConversations.nextCursor, isNull);
      expect(transport.getSessionsCalls, 1);
    });

    test('coalesces concurrent in-flight refreshWorkspaces into exactly 1 transport fetch', () async {
      final repo = ConversationCacheRepository(cache: store, transport: transport);

      final f1 = repo.refreshWorkspaces(device);
      final f2 = repo.refreshWorkspaces(device);

      expect(transport.getWorkspacesCalls, 1);

      transport.pendingWorkspaces.first.complete([
        const DeviceWorkspace(id: 'ws-1', name: 'Workspace 1', path: '/tmp/1'),
      ]);

      await Future.wait([f1, f2]);

      final context = store.snapshot.contexts[device.id]!;
      expect(context.workspaces.workspaces.single.id, 'ws-1');
      expect(transport.getWorkspacesCalls, 1);
    });

    test('coalesces concurrent in-flight refreshDeviceSidebar into 1 coordinated fetch', () async {
      final repo = ConversationCacheRepository(cache: store, transport: transport);

      final f1 = repo.refreshDeviceSidebar(device);
      final f2 = repo.refreshDeviceSidebar(device);

      expect(transport.getWorkspacesCalls, 1);

      transport.pendingWorkspaces.first.complete([
        const DeviceWorkspace(id: 'ws-1', name: 'Workspace 1', path: '/tmp/1'),
      ]);
      await Future<void>.delayed(Duration.zero);

      // Now unscoped + ws-1 refreshes are in flight.
      expect(transport.refreshSessionsCalls, 2); // 1 unscoped + 1 workspace ws-1

      // Complete both.
      for (final completer in transport.pendingRefreshSessions) {
        if (!completer.isCompleted) {
          completer.complete(SessionQueryResult(sessions: const [], hasMore: false));
        }
      }

      await Future.wait([f1, f2]);

      expect(transport.getWorkspacesCalls, 1);
      expect(transport.refreshSessionsCalls, 2);
    });

    test('refreshDeviceSidebar skips collapsed workspaces', () async {
      final repo = ConversationCacheRepository(cache: store, transport: transport);
      store.setActiveDevice(device.id);

      // Pre-seed 2 workspaces where ws-2 is collapsed
      store.applyWorkspacesRefreshed(
        device.id,
        [
          const DeviceWorkspace(id: 'ws-1', name: 'Expanded', path: '/tmp/1'),
          const DeviceWorkspace(id: 'ws-2', name: 'Collapsed', path: '/tmp/2'),
        ],
        generation: store.advanceWorkspacesGeneration(device.id),
      );
      store.setWorkspaceExpansion(device.id, 'ws-2', false);

      final f = repo.refreshDeviceSidebar(device);
      transport.pendingWorkspaces.first.complete([
        const DeviceWorkspace(id: 'ws-1', name: 'Expanded', path: '/tmp/1'),
        const DeviceWorkspace(id: 'ws-2', name: 'Collapsed', path: '/tmp/2'),
      ]);
      await Future<void>.delayed(Duration.zero);

      // Should only refresh unscoped + ws-1 (expanded), NOT ws-2 (collapsed)
      expect(transport.refreshSessionsCalls, 2); // 1 unscoped + 1 ws-1

      for (final completer in transport.pendingRefreshSessions) {
        if (!completer.isCompleted) {
          completer.complete(SessionQueryResult(sessions: const [], hasMore: false));
        }
      }
      await f;
    });

    test('enforces 500ms debounce on rapid non-forced duplicate refresh calls', () async {
      final repo = ConversationCacheRepository(
        cache: store,
        transport: transport,
        debounceDuration: const Duration(milliseconds: 500),
      );

      // Initial refresh.
      final f1 = repo.refreshUnscopedConversations(device);
      transport.pendingRefreshSessions.first.complete(
        SessionQueryResult(sessions: const [], hasMore: false),
      );
      await f1;
      expect(transport.refreshSessionsCalls, 1);

      // Immediate non-forced duplicate call within 500ms.
      await repo.refreshUnscopedConversations(device, force: false);
      expect(transport.refreshSessionsCalls, 1, reason: 'Duplicate non-forced call within 500ms must be debounced');

      // Forced call bypasses debounce.
      final f3 = repo.refreshUnscopedConversations(device, force: true);
      expect(transport.refreshSessionsCalls, 2, reason: 'Forced call must bypass debounce');
      transport.pendingRefreshSessions.last.complete(
        SessionQueryResult(sessions: const [], hasMore: false),
      );
      await f3;
    });

    test('SessionSidebarCubit loadWorkspaceConversationsIfNeeded avoids duplicate fetch during in-flight', () async {
      final repo = ConversationCacheRepository(cache: store, transport: transport);
      final cubit = SessionSidebarCubit(cacheRepository: repo);
      addTearDown(cubit.close);

      store.setActiveDevice(device.id);

      final f1 = cubit.loadWorkspaceConversationsIfNeeded(device, 'ws-1');
      final f2 = cubit.loadWorkspaceConversationsIfNeeded(device, 'ws-1');

      expect(transport.refreshSessionsCalls, 1);

      transport.pendingRefreshSessions.first.complete(
        SessionQueryResult(sessions: const [], hasMore: false),
      );

      await Future.wait([f1, f2]);
      expect(transport.refreshSessionsCalls, 1);
    });
  });
}
