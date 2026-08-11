import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sanad_agent/core/auth/auth_manager.dart';
import 'package:sanad_agent/core/auth/colocated_auth_coupling.dart';
import 'package:sanad_agent/core/auth/device_authorization_client.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/local_daemon_server_platform.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/local_gateway_credentials.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/local_gateway_security.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/sanad_protocol_bridge.dart';
import 'package:sanad_agent/interfaces/runtime/platform_runtime_bridge.dart';
import 'package:test/test.dart';

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
  final _controller = StreamController<void>.broadcast();
  int reloadCalls = 0;
  String? cloudDeviceCredential;

  @override
  String? get deviceToken => cloudDeviceCredential;

  @override
  Stream<void> get changes => _controller.stream;

  @override
  Future<bool> reload({bool notifyIfChanged = false}) async {
    reloadCalls += 1;
    if (notifyIfChanged) _controller.add(null);
    return true;
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
    platform = LocalDaemonServerPlatform(
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
    await getIt.reset();
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
