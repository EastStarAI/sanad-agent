import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/conversations/data/transport/conversation_command_gateway.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../mocks/mock_socket_service.dart';

void main() {
  late FakeSanadSocketService socket;
  late SocketConversationCommandGateway gateway;

  setUp(() {
    socket = FakeSanadSocketService();
    socket.setConnected(true);
    gateway = SocketConversationCommandGateway(
      config: DeviceConfig(id: 'agent-1', name: 'SanadAgent'),
      controller: socket,
    );
  });

  tearDown(() {
    gateway.dispose();
    socket.dispose();
  });

  test('request sends one command and completes from matching request_id', () async {
    final future = gateway.request(command: 'get_sessions', payload: {'request_id': 'req-1'}, requestId: 'req-1');

    expect(socket.capturedCommands, hasLength(1));
    expect(socket.capturedCommands.single['command'], 'get_sessions');

    socket.eventRouter.routeEvent({
      'device_id': 'agent-1',
      'event': 'sessions_list',
      'payload': {
        'request_id': 'req-1',
        'sessions': [],
      },
    });

    final response = await future;
    expect(response?['event'], 'sessions_list');
  });

  test('merged cloud identity completes a local-keyed request', () async {
    final mergedGateway = SocketConversationCommandGateway(
      config: DeviceConfig(
        id: 'hardware-1',
        name: 'Merged SanadAgent',
        metadata: const {'cloud_device_id': 'cloud-1'},
      ),
      controller: socket,
    );
    addTearDown(mergedGateway.dispose);

    final future = mergedGateway.request(
      command: 'get_sessions',
      payload: {'request_id': 'req-cloud'},
      requestId: 'req-cloud',
    );
    expect(socket.capturedCommands.last['device_id'], 'cloud-1');

    socket.eventRouter.routeEvent({
      'device_id': 'cloud-1',
      'event': 'sessions_list',
      'payload': {'request_id': 'req-cloud', 'sessions': []},
    });

    expect((await future)?['event'], 'sessions_list');
  });

  test('duplicate request id is rejected without replacing the original waiter', () async {
    final first = gateway.request(
      command: 'get_sessions',
      payload: {'request_id': 'req-duplicate'},
      requestId: 'req-duplicate',
    );

    await expectLater(
      gateway.request(
        command: 'get_sessions',
        payload: {'request_id': 'req-duplicate'},
        requestId: 'req-duplicate',
      ),
      throwsA(isA<StateError>()),
    );
    expect(socket.capturedCommands, hasLength(1));

    socket.eventRouter.routeEvent({
      'device_id': 'agent-1',
      'event': 'sessions_list',
      'payload': {
        'request_id': 'req-duplicate',
        'sessions': [],
      },
    });

    expect(await first, isNotNull);
  });

  test('sendCommand does not emit when socket is disconnected', () {
    socket.setConnected(false);

    gateway.sendCommand(command: 'think', payload: {'message': 'hello'});

    expect(socket.capturedCommands, isEmpty);
  });
}
