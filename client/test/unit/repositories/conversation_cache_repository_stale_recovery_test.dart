import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/data/conversation_client_registry_impl.dart';
import 'package:sanad_client/features/conversations/data/repositories/conversation_cache_repository.dart';
import 'package:sanad_client/features/conversations/data/repositories/socket_conversation_repository.dart';
import 'package:sanad_client/features/conversations/domain/models/conversation_resource_state.dart';
import 'package:sanad_client/features/conversations/domain/models/device_conversation_context.dart';
import 'package:sanad_client/features/conversations/domain/stores/conversation_cache_store.dart';
import 'package:sanad_client/features/devices/data/device_connection_coordinator.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/devices/domain/stores/device_capabilities_store.dart';

import '../../helpers/fake_socket.dart';

/// Live r3 D5 sequence on the real Client wiring: cache repository, socket
/// repository, conversation registry, socket conversation client, command
/// gateway and a fake cloud socket. Request timeouts run on the fake clock.
void main() {
  const deviceId = 'agent-remote-1';
  const workspaceId = 'ws-1';
  const requestTimeout = Duration(seconds: 11);

  late FakeSanadSocketService cloudSocket;
  late FakeSanadSocketService localSocket;
  late DeviceConnectionCoordinator coordinator;
  late DeviceCapabilitiesStore capabilitiesStore;
  late ConversationClientRegistryImpl registry;
  late ConversationCacheStore store;
  late ConversationCacheRepository repository;
  late Set<String> answered;
  final device = DeviceConfig(id: deviceId, name: 'Remote', hardwareId: 'remote-device', isOnline: true);

  void setUpWiring() {
    cloudSocket = FakeSanadSocketService(hardwareId: 'device-1')..setConnected(true);
    localSocket = FakeSanadSocketService(hardwareId: 'device-1');
    coordinator = DeviceConnectionCoordinator(
      cloudSocketService: cloudSocket,
      localSocketService: localSocket,
      currentDeviceId: 'device-1',
    );
    capabilitiesStore = DeviceCapabilitiesStore(coordinator);
    registry = ConversationClientRegistryImpl(coordinator, capabilitiesStore);
    store = ConversationCacheStore();
    repository = ConversationCacheRepository(cache: store, transport: SocketConversationRepository(registry));
    answered = <String>{};
  }

  Future<void> tearDownWiring(WidgetTester tester) async {
    repository.dispose();
    registry.dispose();
    capabilitiesStore.dispose();
    coordinator.dispose();
    store.dispose();
    cloudSocket.dispose();
    localSocket.dispose();
    await tester.pump();
  }

  List<Map<String, dynamic>> pending(String command) => [
    for (final entry in cloudSocket.capturedCommands)
      if (entry['command'] == command)
        if (Map<String, dynamic>.from(entry['payload'] as Map) case final payload
            when !answered.contains(payload['request_id']))
          payload,
  ];

  bool isLegacyPage(Map<String, dynamic> payload) =>
      payload['workspace_id'] == null && payload['unscoped_only'] != true;

  void reply(Map<String, dynamic> request, String event, Map<String, dynamic> body) {
    final requestId = request['request_id'] as String;
    answered.add(requestId);
    cloudSocket.eventRouter.routeEvent({
      'device_id': deviceId,
      'event': event,
      'payload': {'request_id': requestId, ...body},
    });
  }

  /// Marks every currently pending request as lost (it timed out unanswered).
  void dropPending() {
    for (final command in const ['get_sessions', 'list_workspaces']) {
      for (final request in pending(command)) {
        answered.add(request['request_id'] as String);
      }
    }
  }

  Map<String, dynamic> sessionJson(String id) => {
    'session_id': id,
    'title': id,
    'created_at': '2026-01-01T00:00:00Z',
    'updated_at': '2026-01-01T00:00:00Z',
  };

  Future<void> answerAll(WidgetTester tester, {bool workspaces = true}) async {
    for (var round = 0; round < 5; round++) {
      for (final request in workspaces ? pending('list_workspaces') : const <Map<String, dynamic>>[]) {
        reply(request, 'workspaces_list', {
          'workspaces': [
            {'id': workspaceId, 'name': 'Workspace', 'path': '/w/ws-1'},
          ],
        });
      }
      for (final request in pending('get_sessions')) {
        final scoped = request['workspace_id'] == workspaceId;
        reply(request, 'sessions_list', {
          'sessions': [sessionJson(scoped ? 'scoped-1' : 'unscoped-1')],
          'has_more': false,
        });
      }
      await tester.pump();
    }
  }

  DeviceConversationContext context() => store.snapshot.contexts[deviceId]!;

  bool anyStale() {
    final ctx = context();
    return ctx.workspaces.state == ConversationResourceState.staleError ||
        ctx.unscopedConversations.state == ConversationResourceState.staleError ||
        ctx.workspaceConversationPages.values.any((page) => page.state == ConversationResourceState.staleError);
  }

  Future<void> loadReadySidebar(WidgetTester tester) async {
    final first = repository.refreshDeviceSidebar(device);
    await tester.pump();
    await answerAll(tester);
    await first;
    expect(anyStale(), isFalse);
  }

  group('a Gateway error reply to a section query (Task 124 D7, live r3 d5-b)', () {
    testWidgets('marks the section stale instead of empty, and a later success repairs it', (tester) async {
      setUpWiring();
      await loadReadySidebar(tester);
      expect(context().unscopedConversations.sessions, isNotEmpty);

      // The Agent restarts while the section queries are in flight: the
      // Gateway answers each one with a correlated `error` event.
      final refresh = repository.refreshDeviceSidebar(device, force: true);
      await tester.pump();
      for (final request in pending('list_workspaces')) {
        reply(request, 'workspaces_list', {
          'workspaces': [
            {'id': workspaceId, 'name': 'Workspace', 'path': '/w/ws-1'},
          ],
        });
      }
      await tester.pump();
      for (final request in pending('get_sessions')) {
        reply(request, 'error', {'code': 'device_unavailable', 'message': 'The device did not answer.'});
      }
      await tester.pump();
      await refresh;

      expect(context().unscopedConversations.state, ConversationResourceState.staleError);
      expect(context().unscopedConversations.sessions, isNotEmpty, reason: 'never "No conversations"');
      expect(context().workspaceConversationPages[workspaceId]!.state, ConversationResourceState.staleError);

      // A later successful fetch refreshes the stale sections.
      final later = repository.refreshWorkspaces(device, force: true);
      await tester.pump();
      await answerAll(tester);
      await later;
      expect(anyStale(), isFalse);

      await tearDownWiring(tester);
    });
  });

  group('stale sidebar sections recover on the real wiring (Task 124 D5, live r3)', () {
    testWidgets('a successful scoped reply refreshes a workspace list that timed out', (tester) async {
      setUpWiring();
      await loadReadySidebar(tester);

      // Live d5-e: the Agent is frozen. `list_workspaces` and the unscoped
      // `get_sessions` both time out.
      final refresh = repository.refreshDeviceSidebar(device, force: true);
      await tester.pump();
      expect(pending('list_workspaces'), hasLength(1));
      dropPending();
      await tester.pump(requestTimeout);
      expect(context().workspaces.state, ConversationResourceState.staleError);

      // The Agent resumes: the section requests sent after the timeout succeed.
      await answerAll(tester, workspaces: false);
      await refresh;
      expect(context().unscopedConversations.state, ConversationResourceState.ready);
      expect(context().workspaceConversationPages[workspaceId]!.state, ConversationResourceState.ready);

      // Those successes prove the device answers again, so the stale workspace
      // list is refreshed once.
      expect(pending('list_workspaces'), hasLength(1));
      await answerAll(tester);
      expect(context().workspaces.state, ConversationResourceState.ready);
      expect(pending('list_workspaces'), isEmpty);
      expect(pending('get_sessions'), isEmpty);

      await tearDownWiring(tester);
    });

    testWidgets('the device Online re-sync refreshes sections that timed out', (tester) async {
      setUpWiring();
      registry.getOrCreateConversationClientForAgent(device);
      await loadReadySidebar(tester);

      // Every section request of a forced refresh times out.
      final refresh = repository.refreshDeviceSidebar(device, force: true);
      await tester.pump();
      for (final request in pending('list_workspaces')) {
        reply(request, 'workspaces_list', {
          'workspaces': [
            {'id': workspaceId, 'name': 'Workspace', 'path': '/w/ws-1'},
          ],
        });
      }
      await tester.pump();
      dropPending();
      await tester.pump(requestTimeout);
      await refresh;
      expect(context().unscopedConversations.state, ConversationResourceState.staleError);
      expect(context().workspaceConversationPages[workspaceId]!.state, ConversationResourceState.staleError);

      // Live R4: the Agent restarts. B sees it go offline, then Online, and
      // re-syncs the default session list.
      registry.retainClientsFor([device.copyWith(isOnline: false)]);
      await tester.pump();
      registry.retainClientsFor([device.copyWith(isOnline: true)]);
      await tester.pump();
      final resync = pending('get_sessions').where(isLegacyPage).toList();
      expect(resync, hasLength(1));
      reply(resync.single, 'sessions_list', {
        'sessions': [sessionJson('unscoped-1')],
        'has_more': false,
      });
      await tester.pump();

      // The re-sync must refresh the stale sections and clear their banners.
      final sectionRequests = pending('get_sessions').where((request) => !isLegacyPage(request)).toList();
      expect(sectionRequests, hasLength(2));
      await answerAll(tester);
      expect(anyStale(), isFalse);

      await tearDownWiring(tester);
    });

    testWidgets('the device Online re-sync refreshes a workspace list that timed out', (tester) async {
      setUpWiring();
      registry.getOrCreateConversationClientForAgent(device);
      await loadReadySidebar(tester);

      // Live d5-e: `list_workspaces` and the unscoped `get_sessions` time out,
      // and the late replies to them are discarded.
      final refresh = repository.refreshDeviceSidebar(device, force: true);
      await tester.pump();
      dropPending();
      await tester.pump(requestTimeout);
      // The section requests sent after that timeout are lost too.
      dropPending();
      await tester.pump(requestTimeout);
      await refresh;
      expect(context().workspaces.state, ConversationResourceState.staleError);

      // Live R4: the Agent restarts and comes back Online.
      registry.retainClientsFor([device.copyWith(isOnline: false)]);
      await tester.pump();
      registry.retainClientsFor([device.copyWith(isOnline: true)]);
      await tester.pump();
      await answerAll(tester);
      expect(anyStale(), isFalse);

      await tearDownWiring(tester);
    });
  });
}
