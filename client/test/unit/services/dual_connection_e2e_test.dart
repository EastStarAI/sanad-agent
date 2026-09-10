import 'package:sanad_client/features/devices/data/device_connection_coordinator.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/devices/domain/stores/device_capabilities_store.dart';
import 'package:sanad_client/features/conversations/data/clients/socket_conversation_client.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fake_socket.dart';

void main() {
  test('routes a same-device sanadagent conversation through the local socket without duplicating the agent', () async {
    final cloudSocket = FakeSanadSocketService(hardwareId: 'device-1')..setConnected(true);
    final localSocket = FakeSanadSocketService(hardwareId: 'device-1')..setConnected(true);
    final resolver = DeviceConnectionCoordinator(
      cloudSocketService: cloudSocket,
      localSocketService: localSocket,
      currentDeviceId: 'device-1',
    );

    final agent = resolver.decorateAgent(
      DeviceConfig(id: 'agent-local', name: 'SanadAgent', hardwareId: 'device-1', isOnline: true),
    );

    final capabilitiesStore = DeviceCapabilitiesStore(resolver);
    final client = SocketConversationClient(
      config: agent,
      socketService: resolver.resolve(agent).socketService,
      capabilitiesStore: capabilitiesStore,
    );
    client.activateSession('session-local');

    await client.sendMessage('hello local', sessionId: 'session-local');

    final thinkCommand = localSocket.capturedCommands.where((entry) => entry['command'] == 'think').single;
    expect(thinkCommand['command'], 'think');
    expect(
      cloudSocket.capturedCommands.where((entry) => entry['command'] != null),
      isEmpty,
    );
    expect(agent.isLocalReachable, isTrue);

    localSocket.debugEmitEvent({
      'type': 'device_event',
      'device_id': 'agent-local',
      'event': 'final_answer',
      'payload': {
        'content': 'done locally',
        'session_id': 'session-local',
      },
    }, route: true);

    await Future<void>.delayed(Duration.zero);

    expect(client.currentMessages.last.kind, EventKind.finalAnswer);
    expect(client.currentMessages.last.text, 'done locally');

    client.dispose();
    capabilitiesStore.dispose();
    resolver.dispose();
    cloudSocket.dispose();
    localSocket.dispose();
  });
}
