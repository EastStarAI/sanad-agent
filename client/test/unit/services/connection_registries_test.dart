import 'package:sanad_client/features/devices/data/device_client_registry_impl.dart';
import 'package:sanad_client/features/devices/data/device_connection_coordinator.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/devices/domain/stores/device_capabilities_store.dart';
import 'package:sanad_client/features/conversations/data/conversation_client_registry_impl.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';
import 'package:sanad_client/infrastructure/devices/transport/universal_device_client.dart';
import 'package:sanad_client/infrastructure/socket/sanad_socket_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fake_socket.dart';

void main() {
  test('agent and conversation registries pick the local socket through the coordinator', () {
    final cloudSocket = FakeSanadSocketService(hardwareId: 'device-1')..setConnected(true);
    final localSocket = FakeSanadSocketService(hardwareId: 'device-1')..setConnected(true);
    final resolver = DeviceConnectionCoordinator(
      cloudSocketService: cloudSocket,
      localSocketService: localSocket,
      currentDeviceId: 'device-1',
    );
    final capabilitiesStore = DeviceCapabilitiesStore(resolver);

    final agentRegistry = DeviceClientRegistryImpl(resolver);
    final conversationRegistry = ConversationClientRegistryImpl(resolver, capabilitiesStore);
    final agent = DeviceConfig(id: 'agent-1', name: 'SanadAgent', hardwareId: 'device-1', isOnline: true);

    final lowLevelClient = agentRegistry.getOrCreateClientForAgent(agent);
    final conversationClient = conversationRegistry.getOrCreateConversationClientForAgent(agent);

    expect(lowLevelClient, isA<UniversalDeviceClient>());
    expect((lowLevelClient as UniversalDeviceClient).controller, same(localSocket));
    expect(conversationClient, isNotNull);

    conversationRegistry.dispose();
    agentRegistry.dispose();
    capabilitiesStore.dispose();
    resolver.dispose();
    cloudSocket.dispose();
    localSocket.dispose();
  });

  test(
    'conversation registry keeps the same client and visible messages when the same agent switches from local to cloud',
    () async {
      final cloudSocket = FakeSanadSocketService(hardwareId: 'device-1')..setConnected(true);
      final localSocket = FakeSanadSocketService(hardwareId: 'device-1')..setConnected(true);
      final resolver = DeviceConnectionCoordinator(
        cloudSocketService: cloudSocket,
        localSocketService: localSocket,
        currentDeviceId: 'device-1',
      );
      final capabilitiesStore = DeviceCapabilitiesStore(resolver);
      final conversationRegistry = ConversationClientRegistryImpl(resolver, capabilitiesStore);

      final localAgent = DeviceConfig(
        id: 'agent-1',
        name: 'SanadAgent',
        hardwareId: 'device-1',
        isOnline: true,
        metadata: const {'preferred_connection_scope': 'local'},
      );
      final cloudAgent = localAgent.copyWith(metadata: const {'preferred_connection_scope': 'cloud'});

      final localClient = conversationRegistry.getOrCreateConversationClientForAgent(localAgent);
      localClient.activateSession('session-1');
      localSocket.debugEmitEvent({
        'type': 'device_event',
        'event': 'final_answer',
        'device_id': localAgent.id,
        'session_id': 'session-1',
        'payload': {
          'session_id': 'session-1',
          'content': 'Local reply',
        },
      }, route: true);
      await Future<void>.delayed(Duration.zero);

      expect(localClient.currentMessages, hasLength(1));
      expect(localClient.currentMessages.single.kind, EventKind.finalAnswer);
      expect(localClient.currentMessages.single.text, 'Local reply');

      final cloudClient = conversationRegistry.getOrCreateConversationClientForAgent(cloudAgent);

      expect(identical(localClient, cloudClient), isTrue);
      expect(cloudClient.currentMessages, hasLength(1));
      expect(cloudClient.currentMessages.single.kind, EventKind.finalAnswer);
      expect(cloudClient.currentMessages.single.text, 'Local reply');

      conversationRegistry.dispose();
      capabilitiesStore.dispose();
      resolver.dispose();
      cloudSocket.dispose();
      localSocket.dispose();
    },
  );

  test('conversation registry hydrates once when a local candidate finishes switching to local', () async {
    final cloudSocket = FakeSanadSocketService(hardwareId: 'device-1')..setConnected(true);
    final localSocket = FakeSanadSocketService(hardwareId: 'device-1');
    final resolver = DeviceConnectionCoordinator(
      cloudSocketService: cloudSocket,
      localSocketService: localSocket,
      currentDeviceId: 'device-1',
    );
    final capabilitiesStore = DeviceCapabilitiesStore(resolver);
    final conversationRegistry = ConversationClientRegistryImpl(resolver, capabilitiesStore);

    final agent = DeviceConfig(id: 'agent-1', name: 'SanadAgent', hardwareId: 'device-1', isOnline: true);

    conversationRegistry.getOrCreateConversationClientForAgent(agent);

    localSocket.setLifecycleState(SocketLifecycleState.connecting);
    await Future<void>.delayed(Duration.zero);
    localSocket.setLifecycleState(SocketLifecycleState.authenticating);
    await Future<void>.delayed(Duration.zero);

    final earlyCloudSessionCommands = cloudSocket.capturedCommands
        .where((entry) => entry['command'] == 'get_sessions')
        .toList();
    final earlyLocalSessionCommands = localSocket.capturedCommands
        .where((entry) => entry['command'] == 'get_sessions')
        .toList();

    expect(earlyCloudSessionCommands, isEmpty);
    expect(earlyLocalSessionCommands, isEmpty);

    localSocket.setConnected(true);
    await Future<void>.delayed(Duration.zero);

    final localSessionCommands = localSocket.capturedCommands
        .where((entry) => entry['command'] == 'get_sessions')
        .toList();
    final cloudSessionCommands = cloudSocket.capturedCommands
        .where((entry) => entry['command'] == 'get_sessions')
        .toList();

    expect(localSessionCommands, hasLength(1));
    expect(localSessionCommands.single['command'], 'get_sessions');
    expect(cloudSessionCommands, isEmpty);

    conversationRegistry.dispose();
    capabilitiesStore.dispose();
    resolver.dispose();
    cloudSocket.dispose();
    localSocket.dispose();
  });

  test('conversation registry rehydrates on cloud reconnect for non-local agents', () async {
    final cloudSocket = FakeSanadSocketService(hardwareId: 'device-1');
    final localSocket = FakeSanadSocketService(hardwareId: 'device-1');
    final resolver = DeviceConnectionCoordinator(
      cloudSocketService: cloudSocket,
      localSocketService: localSocket,
      currentDeviceId: 'device-1',
    );
    final capabilitiesStore = DeviceCapabilitiesStore(resolver);
    final conversationRegistry = ConversationClientRegistryImpl(resolver, capabilitiesStore);

    final agent = DeviceConfig(
      id: 'agent-remote-1',
      name: 'SanadAgent Remote',
      hardwareId: 'remote-device',
      isOnline: true,
    );

    conversationRegistry.getOrCreateConversationClientForAgent(agent);

    cloudSocket.setConnected(true);
    await Future<void>.delayed(Duration.zero);

    final cloudSessionCommands = cloudSocket.capturedCommands
        .where((entry) => entry['command'] == 'get_sessions')
        .toList();

    expect(cloudSessionCommands, hasLength(1));
    expect(cloudSessionCommands.single['command'], 'get_sessions');

    conversationRegistry.dispose();
    capabilitiesStore.dispose();
    resolver.dispose();
    cloudSocket.dispose();
    localSocket.dispose();
  });

  test(
    'offline local snapshot rehydrates active history when daemon becomes ready',
    () async {
      final cloudSocket = FakeSanadSocketService(hardwareId: 'device-1')..setConnected(true);
      final localSocket = FakeSanadSocketService(hardwareId: 'device-1');
      final resolver = DeviceConnectionCoordinator(
        cloudSocketService: cloudSocket,
        localSocketService: localSocket,
        currentDeviceId: 'device-1',
      );
      final capabilitiesStore = DeviceCapabilitiesStore(resolver);
      final conversationRegistry = ConversationClientRegistryImpl(
        resolver,
        capabilitiesStore,
      );
      final staleOfflineAgent = DeviceConfig(
        id: 'agent-1',
        name: 'SanadAgent',
        hardwareId: 'device-1',
        isOnline: false,
      );
      final client = conversationRegistry.getOrCreateConversationClientForAgent(staleOfflineAgent);
      client.activateSession('session-1');

      localSocket.setConnected(true);
      await Future<void>.delayed(Duration.zero);

      final sessionsCommand = localSocket.capturedCommands.where((entry) => entry['command'] == 'get_sessions').single;
      final sessionsRequestId = (sessionsCommand['payload'] as Map)['request_id'] as String;
      localSocket.eventRouter.routeEvent({
        'device_id': staleOfflineAgent.id,
        'event': 'sessions_list',
        'request_id': sessionsRequestId,
        'payload': {
          'request_id': sessionsRequestId,
          'sessions': [
            {
              'id': 'session-1',
              'device_id': staleOfflineAgent.id,
              'title': 'Restored after daemon restart',
            },
          ],
        },
      });
      await Future<void>.delayed(Duration.zero);

      final historyCommand = localSocket.capturedCommands
          .where((entry) => entry['command'] == 'get_session_history')
          .single;
      final historyRequestId = (historyCommand['payload'] as Map)['request_id'] as String;
      localSocket.eventRouter.routeEvent({
        'device_id': staleOfflineAgent.id,
        'event': 'session_history',
        'request_id': historyRequestId,
        'payload': {
          'request_id': historyRequestId,
          'messages': [
            {
              'id': 'event-after-reconnect',
              'sender': 'ai',
              'type': 'final_answer',
              'content': 'Visible after local reconnect',
              'created_at': '2026-08-11T23:55:11Z',
            },
          ],
        },
      });
      await Future<void>.delayed(Duration.zero);

      expect(client.currentMessages, hasLength(1));
      expect(client.currentMessages.single.text, 'Visible after local reconnect');
      expect(
        cloudSocket.capturedCommands.where(
          (entry) => entry['command'] == 'get_sessions',
        ),
        isEmpty,
      );

      conversationRegistry.dispose();
      capabilitiesStore.dispose();
      resolver.dispose();
      cloudSocket.dispose();
      localSocket.dispose();
    },
  );

  test(
    'conversation registry keeps a local client pinned during daemon restart grace',
    () async {
      final cloudSocket = FakeSanadSocketService(hardwareId: 'device-1')..setConnected(true);
      final localSocket = FakeSanadSocketService(hardwareId: 'device-1')..setConnected(true);
      final resolver = DeviceConnectionCoordinator(
        cloudSocketService: cloudSocket,
        localSocketService: localSocket,
        currentDeviceId: 'device-1',
      );
      final capabilitiesStore = DeviceCapabilitiesStore(resolver);
      final conversationRegistry = ConversationClientRegistryImpl(
        resolver,
        capabilitiesStore,
        localReconnectGracePeriod: const Duration(seconds: 1),
      );
      final agent = DeviceConfig(
        id: 'agent-1',
        name: 'SanadAgent',
        hardwareId: 'device-1',
        isOnline: true,
      );

      conversationRegistry.getOrCreateConversationClientForAgent(agent);
      localSocket.setConnected(false);
      await Future<void>.delayed(Duration.zero);
      conversationRegistry.getOrCreateConversationClientForAgent(agent);

      expect(
        cloudSocket.capturedCommands.where(
          (entry) => entry['command'] == 'get_sessions',
        ),
        isEmpty,
      );

      localSocket.setConnected(true);
      await Future<void>.delayed(Duration.zero);
      expect(
        localSocket.capturedCommands.where(
          (entry) => entry['command'] == 'get_sessions',
        ),
        hasLength(1),
      );

      conversationRegistry.dispose();
      capabilitiesStore.dispose();
      resolver.dispose();
      cloudSocket.dispose();
      localSocket.dispose();
    },
  );
}
