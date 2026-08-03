import 'dart:async';
import 'dart:convert';
import 'dart:io';

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

Future<int> _reserveFreePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

void main() {
  const token = LocalGatewayCredential('transport-test-token');
  late LocalDaemonServerPlatform platform;
  late int port;
  Future<void> Function()? upgradeHook;

  setUp(() async {
    await getIt.reset();
    upgradeHook = null;
    port = await _reserveFreePort();
    getIt.registerSingleton<Config>(_TransportTestConfig(port));
    getIt.registerSingleton<SanadProtocolBridge>(SanadProtocolBridge());
    getIt.registerSingleton<PlatformRuntimeBridge>(PlatformRuntimeBridge());
    platform = LocalDaemonServerPlatform(
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
