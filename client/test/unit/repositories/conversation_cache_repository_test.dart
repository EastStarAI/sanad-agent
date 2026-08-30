import 'package:sanad_client/core/navigation/conversation_destination.dart';
import 'package:sanad_client/features/conversations/data/repositories/conversation_cache_repository.dart';
import 'package:sanad_client/features/conversations/domain/models/device_workspace.dart';
import 'package:sanad_client/features/conversations/domain/models/session.dart';
import 'package:sanad_client/features/conversations/domain/models/session_query.dart';
import 'package:sanad_client/features/conversations/domain/repositories/conversation_repository.dart';
import 'package:sanad_client/features/conversations/domain/stores/conversation_cache_store.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fake transport that records calls and returns canned results.
class _FakeTransport implements ConversationRepository {
  List<Session> sessionsToReturn = [];
  List<DeviceWorkspace> workspacesToReturn = [];
  String? error;
  Object? workspaceMutationError;
  int getWorkspacesCalls = 0;
  int getSessionsCalls = 0;
  final List<SessionQueryRequest?> sessionQueries = [];

  @override
  Future<List<DeviceWorkspace>> getWorkspaces(DeviceConfig agent) async {
    getWorkspacesCalls++;
    if (error != null) throw Exception(error);
    return workspacesToReturn;
  }

  @override
  Future<SessionQueryResult> getSessions(DeviceConfig agent, {SessionQueryRequest? query}) async {
    getSessionsCalls++;
    sessionQueries.add(query);
    if (error != null) throw Exception(error);
    return SessionQueryResult(
      sessions: sessionsToReturn,
      nextCursor: null,
      hasMore: false,
    );
  }

  @override
  Future<SessionQueryResult> refreshSessions(
    DeviceConfig agent, {
    SessionQueryRequest? query,
  }) => getSessions(agent, query: query);

  @override
  Future<DeviceWorkspace> relocateWorkspace(
    DeviceConfig agent, {
    required String workspaceId,
    required String newPath,
  }) async {
    final mutationError = workspaceMutationError;
    if (mutationError != null) throw mutationError;
    return DeviceWorkspace(
      id: workspaceId,
      name: 'Workspace',
      path: newPath,
    );
  }

  @override
  Future<void> removeWorkspace(
    DeviceConfig agent, {
    required String workspaceId,
  }) async {
    final mutationError = workspaceMutationError;
    if (mutationError != null) throw mutationError;
  }

  // The rest of the interface is not needed for these tests.
  @override
  dynamic noSuchMethod(Invocation invocation) {}
}

void main() {
  late ConversationCacheStore store;
  late _FakeTransport transport;
  late ConversationCacheRepository repo;
  final device = DeviceConfig(id: 'device-1', name: 'Test', isOnline: true);

  setUp(() {
    store = ConversationCacheStore();
    transport = _FakeTransport();
    repo = ConversationCacheRepository(cache: store, transport: transport);
  });

  tearDown(() {
    store.dispose();
  });

  group('ConversationCacheRepository', () {
    test('restartDestination restores typed routes and drops only known-missing workspaces', () {
      expect(
        repo.restartDestination(device.id),
        ConversationDestination.newConversation(deviceId: device.id),
      );

      final withWorkspace = ConversationDestination.newConversation(
        deviceId: device.id,
        workspaceId: 'ws-1',
      );
      repo.recordLastDestination(withWorkspace);
      expect(repo.restartDestination(device.id), withWorkspace);

      store.applyWorkspacesRefreshed(
        device.id,
        const [DeviceWorkspace(id: 'ws-1', name: 'Project', path: '/p')],
        generation: store.advanceWorkspacesGeneration(device.id),
      );
      expect(repo.restartDestination(device.id), withWorkspace);

      store.applyWorkspacesRefreshed(
        device.id,
        const [],
        generation: store.advanceWorkspacesGeneration(device.id),
      );
      expect(
        repo.restartDestination(device.id),
        ConversationDestination.newConversation(deviceId: device.id),
      );
    });

    test('refreshWorkspaces fetches and caches workspaces', () async {
      transport.workspacesToReturn = [
        DeviceWorkspace(id: 'ws-1', name: 'Project', path: '/p'),
      ];
      await repo.refreshWorkspaces(device);

      final ctx = store.snapshot.contexts['device-1']!;
      expect(ctx.workspaces.workspaces.single.id, 'ws-1');
      expect(transport.getWorkspacesCalls, 1);
    });

    test('workspace relocation preserves transport errors for presentation', () async {
      final error = StateError(
        'That folder is already connected to another workspace.',
      );
      transport.workspaceMutationError = error;

      await expectLater(
        repo.relocateWorkspace(
          device,
          workspaceId: 'workspace-1',
          newPath: '/repo/already-connected',
        ),
        throwsA(same(error)),
      );
      expect(store.snapshot.contexts[device.id], isNull);
    });

    test('workspace removal updates only workspace projections', () async {
      transport.workspacesToReturn = const [
        DeviceWorkspace(id: 'ws-1', name: 'Project', path: '/project'),
      ];
      await repo.refreshWorkspaces(device);
      store.recordLastDestination(
        ConversationDestination.newConversation(
          deviceId: device.id,
          workspaceId: 'ws-1',
        ),
      );

      await repo.removeWorkspace(device, workspaceId: 'ws-1');

      final context = store.snapshot.contexts[device.id]!;
      expect(context.workspaces.workspaces, isEmpty);
      expect(
        context.lastDestination,
        ConversationDestination.newConversation(deviceId: device.id),
      );
    });

    test('refreshUnscopedConversations fetches and caches sessions', () async {
      transport.sessionsToReturn = [
        Session(
          id: 's-1',
          title: 'Chat',
          deviceId: 'device-1',
          createdAt: DateTime.utc(2026, 7, 1),
          updatedAt: DateTime.utc(2026, 7, 13),
        ),
      ];
      await repo.refreshUnscopedConversations(device);

      final ctx = store.snapshot.contexts['device-1']!;
      expect(ctx.unscopedConversations.sessions.single.id, 's-1');
      expect(transport.sessionQueries.single?.unscopedOnly, isTrue);
    });

    test('refresh failure keeps stale snapshot and sets staleError state', () async {
      // First, seed a successful snapshot.
      transport.sessionsToReturn = [
        Session(
          id: 's-1',
          title: 'Chat',
          deviceId: 'device-1',
          createdAt: DateTime.utc(2026, 7, 1),
          updatedAt: DateTime.utc(2026, 7, 13),
        ),
      ];
      await repo.refreshUnscopedConversations(device);

      // Now simulate a failure on refresh.
      transport.error = 'network down';
      await repo.refreshUnscopedConversations(device);

      final ctx = store.snapshot.contexts['device-1']!;
      // The session should still be present (stale snapshot retained).
      expect(ctx.unscopedConversations.sessions.any((s) => s.id == 's-1'), isTrue);
      // State should be staleError, not notLoaded.
      expect(
        ctx.unscopedConversations.state.toString(),
        'ConversationResourceState.staleError',
      );
    });

    test('device switch shows cached data for the new device only', () async {
      // Seed device-A.
      transport.sessionsToReturn = [
        Session(
          id: 'a-1',
          title: 'A',
          deviceId: 'device-A',
          createdAt: DateTime.utc(2026, 7, 1),
          updatedAt: DateTime.utc(2026, 7, 13),
        ),
      ];
      final deviceA = DeviceConfig(id: 'device-A', name: 'A', isOnline: true);
      await repo.refreshUnscopedConversations(deviceA);

      // Seed device-B.
      transport.sessionsToReturn = [
        Session(
          id: 'b-1',
          title: 'B',
          deviceId: 'device-B',
          createdAt: DateTime.utc(2026, 7, 1),
          updatedAt: DateTime.utc(2026, 7, 13),
        ),
      ];
      final deviceB = DeviceConfig(id: 'device-B', name: 'B', isOnline: true);
      await repo.refreshUnscopedConversations(deviceB);

      // Switch to device-B.
      repo.selectDevice('device-B');
      expect(store.activeDeviceId, 'device-B');
      // device-A cache is preserved.
      expect(store.snapshot.contexts.keys, containsAll(['device-A', 'device-B']));
      // No leakage: device-B sidebar has only b-1.
      final sidebarB = store.sidebarSnapshotFor('device-B')!;
      final bIds = sidebarB.conversationGroups
          .where((g) => g.isUnscoped)
          .expand((g) => g.sessions)
          .map((s) => s.id)
          .toSet();
      expect(bIds, {'b-1'});
    });

    test('applySessionCreated routes session into correct workspace section', () {
      repo.applySessionCreated(
        'device-1',
        Session(
          id: 's-new',
          title: 'New',
          deviceId: 'device-1',
          workspaceId: 'ws-1',
          createdAt: DateTime.utc(2026, 7, 13),
          updatedAt: DateTime.utc(2026, 7, 13),
        ),
      );
      final ctx = store.snapshot.contexts['device-1']!;
      expect(ctx.workspaceConversationPages['ws-1']?.sessions.any((s) => s.id == 's-new'), isTrue);
    });

    test('workspace query is scoped and is not marked unscoped-only', () async {
      await repo.refreshWorkspaceConversations(device, 'ws-1');

      final query = transport.sessionQueries.single!;
      expect(query.workspaceId, 'ws-1');
      expect(query.unscopedOnly, isFalse);
    });

    test('draft read/write through repository', () {
      repo.setNewConversationDraft('device-1', text: 'hello', model: 'gpt-5.2');
      final draft = repo.newConversationDraft('device-1');
      expect(draft.text, 'hello');
      expect(draft.model, 'gpt-5.2');
    });
  });
}
