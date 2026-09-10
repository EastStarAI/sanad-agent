import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sanad_agent/core/auth/auth_manager.dart';
import 'package:sanad_agent/core/auth/colocated_auth_coupling.dart';
import 'package:sanad_agent/core/auth/device_authorization_client.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/interfaces/models/gateway_event.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/delivery_presence_controller.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/local_daemon_server_platform.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/local_gateway_credentials.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/local_gateway_security.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/sanad_protocol_bridge.dart';
import 'package:sanad_agent/interfaces/runtime/platform_runtime_bridge.dart';
import 'package:test/test.dart';

import '../../../support/memory_agent_secret_store.dart';

class _TransportTestConfig extends Config {
  _TransportTestConfig(this._port);

  final int _port;

  @override
  String get localGatewayHost => '127.0.0.1';

  @override
  int get localGatewayPort => _port;

  @override
  String get localGatewayUrl => 'http://127.0.0.1:$_port';
}

class _ExchangeAuthManager extends AuthManager {
  _ExchangeAuthManager() : super(secretStore: MemoryAgentSecretStore());

  final _controller = StreamController<void>.broadcast();
  int reloadCalls = 0;
  int logoutCalls = 0;
  String? cloudDeviceCredential;

  @override
  String? get deviceToken => cloudDeviceCredential;

  @override
  String? get hardwareId => 'hardware-1';

  @override
  Stream<void> get changes => _controller.stream;

  @override
  Future<bool> reload({bool notifyIfChanged = false}) async {
    reloadCalls += 1;
    if (notifyIfChanged) _controller.add(null);
    return true;
  }

  @override
  Future<void> logout() async {
    logoutCalls += 1;
    cloudDeviceCredential = null;
    _controller.add(null);
  }

  Future<void> close() => _controller.close();
}

Future<int> _reserveFreePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

void main() {
  const token = LocalGatewayCredential('transport-test-token');
  late LocalDaemonServerPlatform platform;
  late DeliveryPresenceController deliveryPresence;
  late _ExchangeAuthManager authManager;
  late int port;
  Future<void> Function()? upgradeHook;

  setUp(() async {
    await getIt.reset();
    upgradeHook = null;
    port = await _reserveFreePort();
    getIt.registerSingleton<Config>(_TransportTestConfig(port));
    authManager = _ExchangeAuthManager()
      ..cloudDeviceCredential = 'vault-only-device-credential';
    getIt.registerSingleton<AuthManager>(
      authManager,
      dispose: (manager) => authManager.close(),
    );
    getIt.registerSingleton<SanadProtocolBridge>(SanadProtocolBridge());
    getIt.registerSingleton<PlatformRuntimeBridge>(PlatformRuntimeBridge());
    deliveryPresence = DeliveryPresenceController();
    platform = LocalDaemonServerPlatform(
      deliveryPresence: deliveryPresence,
      authCoupling: ColocatedAuthCoupling(
        authManager: authManager,
        authorizationClient: DeviceAuthorizationClient(
          portalUrl: 'https://portal.test',
          authManager: authManager,
        ),
      ),
      security: LocalGatewaySecurity(
        config: LocalGatewaySecurityConfig(
          allowedPort: port,
          preauthBudgetPerPeer: 1,
        ),
        expectedToken: token,
      ),
      beforeUpgradeAuthentication: () async {
        await upgradeHook?.call();
      },
    );
    await platform.initialize();
  });

  tearDown(() async {
    await platform.dispose();
    await deliveryPresence.dispose();
    await getIt.reset();
  });

  test('local dispatch is attempted with zero connected clients', () async {
    expect(deliveryPresence.localInstanceIds, isEmpty);
    deliveryPresence.acceptInterest({
      'protocol': deliveryPresenceProtocol,
      'version': deliveryPresenceVersion,
      'type': 'cloud.delivery_interest',
      'revision': 1,
      'cloud_recipient_instances_complete': true,
      'cloud_recipient_instance_ids': const <String>[],
      'lease_ms': 30000,
    });

    await platform.sendResponse(
      GatewayResponse(
        sessionId: 'no-local-recipients',
        message: Message(role: MessageRole.assistant, content: 'ready'),
      ),
    );

    expect(deliveryPresence.metrics, {'local': 1, 'cloud': 0, 'suppressed': 0});
  });

  test('HTTP rejects missing credentials before health logic', () async {
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final request = await client.getUrl(
      Uri.parse('http://127.0.0.1:$port/health'),
    );
    final response = await request.close();
    final body = jsonDecode(await response.transform(utf8.decoder).join());

    expect(response.statusCode, HttpStatus.unauthorized);
    expect(body['reason'], 'missing_credential');
  });

  test('HTTP rejects a hostile Host with a valid credential', () async {
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final request = await client.getUrl(
      Uri.parse('http://127.0.0.1:$port/health'),
    );
    request.headers.set(LocalGatewayCredentials.headerName, token.value);
    request.headers.set(HttpHeaders.hostHeader, 'attacker.example');
    final response = await request.close();
    final body = jsonDecode(await response.transform(utf8.decoder).join());

    expect(response.statusCode, HttpStatus.forbidden);
    expect(body['reason'], 'host_not_allowed');
  });

  test('HTTP accepts a valid credential and loopback Host', () async {
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final request = await client.getUrl(
      Uri.parse('http://127.0.0.1:$port/health'),
    );
    request.headers.set(LocalGatewayCredentials.headerName, token.value);
    final response = await request.close();
    final body = jsonDecode(await response.transform(utf8.decoder).join());

    expect(response.statusCode, HttpStatus.ok);
    expect(body['status'], 'ok');
  });

  test('co-located auth endpoint returns status without credentials', () async {
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final request = await client.postUrl(
      Uri.parse('http://127.0.0.1:$port/auth/coupling'),
    );
    request.headers.set(LocalGatewayCredentials.headerName, token.value);
    final response = await request.close();
    final bodyText = await response.transform(utf8.decoder).join();
    final body = jsonDecode(bodyText) as Map<String, dynamic>;

    expect(response.statusCode, HttpStatus.ok);
    expect(body, {'status': 'already_authorized'});
    expect(bodyText, isNot(contains('vault-only-device-credential')));
    expect(bodyText, isNot(contains('access_token')));
    expect(bodyText, isNot(contains('device_credential')));
  });

  test(
    'co-located auth endpoint accepts credential-free cancellation',
    () async {
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final request = await client.deleteUrl(
        Uri.parse('http://127.0.0.1:$port/auth/coupling'),
      );
      request.headers.set(LocalGatewayCredentials.headerName, token.value);
      final response = await request.close();
      final bodyText = await response.transform(utf8.decoder).join();

      expect(response.statusCode, HttpStatus.ok);
      expect(jsonDecode(bodyText), {'status': 'cancelled'});
      expect(bodyText, isNot(contains('token')));
      expect(bodyText, isNot(contains('device_code')));
    },
  );

  test('co-located auth endpoint rejects query payloads', () async {
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final request = await client.getUrl(
      Uri.parse('http://127.0.0.1:$port/auth/coupling?token=forbidden'),
    );
    request.headers.set(LocalGatewayCredentials.headerName, token.value);
    final response = await request.close();

    expect(response.statusCode, HttpStatus.badRequest);
  });

  test('co-located auth endpoint rejects request bodies', () async {
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final request = await client.postUrl(
      Uri.parse('http://127.0.0.1:$port/auth/coupling'),
    );
    request.headers.set(LocalGatewayCredentials.headerName, token.value);
    request.write(jsonEncode({'access_token': 'forbidden'}));
    final response = await request.close();

    expect(response.statusCode, HttpStatus.badRequest);
  });

  test(
    'authenticated POST logout invokes Agent logout and keeps Local Gateway',
    () async {
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final request = await client.postUrl(
        Uri.parse('http://127.0.0.1:$port/auth/logout'),
      );
      request.headers.set(LocalGatewayCredentials.headerName, token.value);
      final response = await request.close();
      final bodyText = await response.transform(utf8.decoder).join();

      expect(response.statusCode, HttpStatus.ok);
      expect(jsonDecode(bodyText), {'status': 'logged_out'});
      expect(authManager.logoutCalls, 1);
      expect(bodyText, isNot(contains('vault-only-device-credential')));
      expect(bodyText, isNot(contains('token')));

      final healthRequest = await client.getUrl(
        Uri.parse('http://127.0.0.1:$port/health'),
      );
      healthRequest.headers.set(
        LocalGatewayCredentials.headerName,
        token.value,
      );
      final healthResponse = await healthRequest.close();
      expect(healthResponse.statusCode, HttpStatus.ok);
    },
  );

  test('logout endpoint rejects GET, query, and body requests', () async {
    final client = HttpClient();
    addTearDown(() => client.close(force: true));

    final getRequest = await client.getUrl(
      Uri.parse('http://127.0.0.1:$port/auth/logout'),
    );
    getRequest.headers.set(LocalGatewayCredentials.headerName, token.value);
    expect((await getRequest.close()).statusCode, HttpStatus.badRequest);

    final queryRequest = await client.postUrl(
      Uri.parse('http://127.0.0.1:$port/auth/logout?extra=forbidden'),
    );
    queryRequest.headers.set(LocalGatewayCredentials.headerName, token.value);
    expect((await queryRequest.close()).statusCode, HttpStatus.badRequest);

    final bodyRequest = await client.postUrl(
      Uri.parse('http://127.0.0.1:$port/auth/logout'),
    );
    bodyRequest.headers.set(LocalGatewayCredentials.headerName, token.value);
    bodyRequest.write(jsonEncode({'extra': 'forbidden'}));
    expect((await bodyRequest.close()).statusCode, HttpStatus.badRequest);

    expect(authManager.logoutCalls, 0);
  });

  test('logout endpoint rejects unauthenticated callers', () async {
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final request = await client.postUrl(
      Uri.parse('http://127.0.0.1:$port/auth/logout'),
    );
    final response = await request.close();

    expect(response.statusCode, HttpStatus.unauthorized);
    expect(authManager.logoutCalls, 0);
  });

  test('HTTP rejects a loopback Host on the wrong port', () async {
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final request = await client.getUrl(
      Uri.parse('http://127.0.0.1:$port/health'),
    );
    request.headers.set(LocalGatewayCredentials.headerName, token.value);
    request.headers.set(HttpHeaders.hostHeader, '127.0.0.1:${port + 1}');
    final response = await request.close();
    final body = jsonDecode(await response.transform(utf8.decoder).join());

    expect(response.statusCode, HttpStatus.forbidden);
    expect(body['reason'], 'host_not_allowed');
  });

  test('WebSocket handshake rejects missing credentials', () async {
    await expectLater(
      WebSocket.connect('ws://127.0.0.1:$port/ws'),
      throwsA(isA<WebSocketException>()),
    );
  });

  test('WebSocket handshake rejects an unlisted Origin', () async {
    await expectLater(
      WebSocket.connect(
        'ws://127.0.0.1:$port/ws',
        headers: {
          LocalGatewayCredentials.headerName: token.value,
          'origin': 'http://localhost:3000',
        },
      ),
      throwsA(isA<WebSocketException>()),
    );
  });

  test('WebSocket handshake accepts valid native credentials', () async {
    final socket = await WebSocket.connect(
      'ws://127.0.0.1:$port/ws',
      headers: {LocalGatewayCredentials.headerName: token.value},
    );
    final firstFrame = jsonDecode(await socket.first as String);

    expect(firstFrame['type'], 'register_success');
    await socket.close();
  });

  test(
    'platform broadcast before the first command uses local inventory identity',
    () async {
      final socket = await WebSocket.connect(
        'ws://127.0.0.1:$port/ws',
        headers: {LocalGatewayCredentials.headerName: token.value},
      );
      final frames = StreamIterator<dynamic>(socket);
      expect(await frames.moveNext(), isTrue); // register_success

      await platform.sendResponse(
        GatewayResponse(
          sessionId: 'unbound-session',
          message: Message(role: MessageRole.assistant, content: 'ready'),
        ),
      );

      expect(await frames.moveNext(), isTrue);
      final event = jsonDecode(frames.current as String);
      expect(event['type'], 'device_event');
      expect(event['device_id'], 'hardware-1');

      await frames.cancel();
      await socket.close();
    },
  );

  test(
    'session response preserves explicit identity after unrelated command',
    () async {
      final socket = await WebSocket.connect(
        'ws://127.0.0.1:$port/ws',
        headers: {LocalGatewayCredentials.headerName: token.value},
      );
      final frames = StreamIterator<dynamic>(socket);
      expect(await frames.moveNext(), isTrue); // register_success

      socket.add(
        jsonEncode({
          'type': 'execute_command',
          'command': 'test_identity_binding_only',
          'device_id': 'session-device',
          'hardware_id': 'session-hardware',
          'payload': {'session_id': 'session-a'},
        }),
      );
      socket.add(
        jsonEncode({
          'type': 'execute_command',
          'command': 'test_identity_binding_only',
          'device_id': 'unrelated-device',
          'hardware_id': 'unrelated-hardware',
          'payload': {'session_id': 'session-b'},
        }),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await platform.sendResponse(
        GatewayResponse(
          sessionId: 'session-a',
          eventId: 'session-identity-event',
          message: Message(role: MessageRole.assistant, content: 'ready'),
        ),
      );

      expect(await frames.moveNext(), isTrue);
      final event = jsonDecode(frames.current as String);
      expect(event['device_id'], 'session-device');
      expect(event['hardware_id'], 'session-hardware');
      await frames.cancel();
      await socket.close();
    },
  );

  test(
    'platform-family dispatch records every connected Local instance',
    () async {
      const instances = [
        '11111111-1111-4111-8111-111111111111',
        '22222222-2222-4222-8222-222222222222',
      ];
      final sockets = <WebSocket>[];
      final frames = <StreamIterator<dynamic>>[];
      for (final instanceId in instances) {
        final socket = await WebSocket.connect(
          'ws://127.0.0.1:$port/ws',
          headers: {LocalGatewayCredentials.headerName: token.value},
        );
        sockets.add(socket);
        final iterator = StreamIterator<dynamic>(socket);
        frames.add(iterator);
        expect(await iterator.moveNext(), isTrue); // register_success
        socket.add(
          jsonEncode({
            'type': 'client.hello',
            'protocol': 'sanad.identity_presence',
            'version': 1,
            'client_instance_id': instanceId,
          }),
        );
        expect(await iterator.moveNext(), isTrue); // client.hello_ack
      }
      deliveryPresence.acceptInterest({
        'protocol': deliveryPresenceProtocol,
        'version': deliveryPresenceVersion,
        'type': 'cloud.delivery_interest',
        'revision': 1,
        'cloud_recipient_instances_complete': true,
        'cloud_recipient_instance_ids': [
          ...instances,
          '33333333-3333-4333-8333-333333333333',
        ],
        'lease_ms': 30000,
      });

      await platform.sendResponse(
        GatewayResponse(
          sessionId: 'multi-local',
          eventId: 'event-multi-local',
          message: Message(role: MessageRole.assistant, content: 'ready'),
        ),
      );

      for (final iterator in frames) {
        expect(await iterator.moveNext(), isTrue);
        expect(
          jsonDecode(iterator.current as String)['event_id'],
          'event-multi-local',
        );
      }
      expect(deliveryPresence.takeLocalDelivery('event-multi-local'), {
        ...instances,
      });
      for (final iterator in frames) {
        await iterator.cancel();
      }
      for (final socket in sockets) {
        await socket.close();
      }
    },
  );

  test('authenticated client hello binds a valid instance identity', () async {
    final socket = await WebSocket.connect(
      'ws://127.0.0.1:$port/ws',
      headers: {LocalGatewayCredentials.headerName: token.value},
    );
    final frames = StreamIterator<dynamic>(socket);
    expect(await frames.moveNext(), isTrue); // register_success compatibility

    socket.add(
      jsonEncode({
        'type': 'client.hello',
        'protocol': 'sanad.identity_presence',
        'version': 1,
        'client_instance_id': '11111111-1111-4111-8111-111111111111',
        'metadata': {'platform_family': 'macos'},
      }),
    );
    expect(await frames.moveNext(), isTrue);
    final accepted = jsonDecode(frames.current as String);
    expect(accepted, {
      'type': 'client.hello_ack',
      'protocol': 'sanad.identity_presence',
      'version': 1,
    });
    expect(deliveryPresence.localInstanceIds, {
      '11111111-1111-4111-8111-111111111111',
    });
    deliveryPresence.acceptInterest({
      'protocol': deliveryPresenceProtocol,
      'version': deliveryPresenceVersion,
      'type': 'cloud.delivery_interest',
      'revision': 1,
      'cloud_recipient_instances_complete': true,
      'cloud_recipient_instance_ids': const [
        '11111111-1111-4111-8111-111111111111',
        '22222222-2222-4222-8222-222222222222',
      ],
      'lease_ms': 30000,
    });
    await platform.sendResponse(
      GatewayResponse(
        sessionId: 'session-1',
        eventId: 'event-1',
        message: Message(role: MessageRole.assistant, content: 'ready'),
      ),
    );
    expect(await frames.moveNext(), isTrue);
    expect(jsonDecode(frames.current as String)['event_id'], 'event-1');
    expect(deliveryPresence.takeLocalDelivery('event-1'), {
      '11111111-1111-4111-8111-111111111111',
    });

    socket.add(
      jsonEncode({
        'type': 'client.hello',
        'protocol': 'sanad.identity_presence',
        'version': 1,
        'client_instance_id': 'device-or-sid-substitution',
      }),
    );
    expect(await frames.moveNext(), isTrue);
    final rejected = jsonDecode(frames.current as String);
    expect(rejected['code'], 'INVALID_CLIENT_INSTANCE');

    await frames.cancel();
    await socket.close();
    await Future<void>.delayed(Duration.zero);
    expect(deliveryPresence.localInstanceIds, isEmpty);
  });

  test(
    'authentication exchange reloads file state without returning credentials',
    () async {
      final socket = await WebSocket.connect(
        'ws://127.0.0.1:$port/ws',
        headers: {LocalGatewayCredentials.headerName: token.value},
      );
      final frames = StreamIterator<dynamic>(socket);
      expect(await frames.moveNext(), isTrue); // register_success

      socket.add(
        jsonEncode({
          'type': 'authentication_exchange',
          'access_token': 'must-not-be-trusted-or-returned',
        }),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(authManager.reloadCalls, 0);

      socket.add(jsonEncode({'type': 'authentication_exchange'}));
      expect(await frames.moveNext(), isTrue);
      final exchange = jsonDecode(frames.current as String);
      expect(exchange, {'type': 'authentication_exchange'});
      expect(authManager.reloadCalls, 1);

      await frames.cancel();
      await socket.close();
    },
  );

  test(
    'WebSocket transport rejects excess simultaneous pre-auth work',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      upgradeHook = () async {
        if (!entered.isCompleted) entered.complete();
        await release.future;
      };
      final first = WebSocket.connect(
        'ws://127.0.0.1:$port/ws',
        headers: {LocalGatewayCredentials.headerName: token.value},
      );
      await entered.future;

      await expectLater(
        WebSocket.connect(
          'ws://127.0.0.1:$port/ws',
          headers: {LocalGatewayCredentials.headerName: token.value},
        ),
        throwsA(isA<WebSocketException>()),
      );

      release.complete();
      final socket = await first;
      await socket.close();
    },
  );
}
