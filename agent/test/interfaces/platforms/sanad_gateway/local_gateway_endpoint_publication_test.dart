import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'package:sanad_agent/core/auth/auth_manager.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/sanad_home/sanad_home_bootstrap.dart';
import 'package:sanad_agent/core/sanad_home/sanad_home_identity.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/local_daemon_server_platform.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/local_gateway_credentials.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/local_gateway_endpoint_record.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/local_gateway_security.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/sanad_protocol_bridge.dart';
import 'package:sanad_agent/interfaces/runtime/platform_runtime_bridge.dart';

import '../../../support/ephemeral_loopback_port.dart';
import '../../../support/memory_agent_secret_store.dart';

class _PublicationConfig extends Config {
  _PublicationConfig(this._port);

  final int _port;

  @override
  String get localGatewayHost => '127.0.0.1';

  @override
  int get localGatewayPort => _port;

  @override
  String get localGatewayUrl => 'http://127.0.0.1:$_port';
}

void main() {
  const token = LocalGatewayCredential('publication-test-token');

  late Directory root;
  late LocalDaemonServerPlatform platform;
  late int port;

  setUp(() async {
    root = Directory(
      Directory.systemTemp
          .createTempSync('sanad-endpoint-publication-')
          .resolveSymbolicLinksSync(),
    );
    final home = Directory('${root.path}/home')..createSync();
    setSanadHomeOverride(home.path);
    setSanadStateHomeOverride(home.path);
    await SanadHomeBootstrap.prepareAll();

    await bindOnReservedLoopbackPort((candidatePort) async {
      await getIt.reset();
      port = candidatePort;
      getIt.registerSingleton<Config>(_PublicationConfig(candidatePort));
      getIt.registerSingleton<AuthManager>(
        AuthManager(secretStore: MemoryAgentSecretStore()),
      );
      getIt.registerSingleton<SanadProtocolBridge>(SanadProtocolBridge());
      getIt.registerSingleton<PlatformRuntimeBridge>(PlatformRuntimeBridge());
      platform = LocalDaemonServerPlatform(
        security: LocalGatewaySecurity(
          config: LocalGatewaySecurityConfig(allowedPort: candidatePort),
          expectedToken: token,
        ),
      );
      try {
        await platform.initialize();
      } on SocketException {
        // Another suite won this reservation between probe and bind.
        await platform.dispose();
        await getIt.reset();
        rethrow;
      }
    });
  });

  tearDown(() async {
    await platform.dispose();
    await getIt.reset();
    setSanadHomeOverride(null);
    setSanadStateHomeOverride(null);
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  File recordFile() => File(
    SanadHomeBootstrap.resolveChild(LocalGatewayEndpointRecord.relativePath),
  );

  Future<Map<String, dynamic>> health() async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse('http://127.0.0.1:$port/health'));
      request.headers.set(LocalGatewayCredentials.headerName, token.value);
      final response = await request.close();
      expect(response.statusCode, HttpStatus.ok);
      final body = await utf8.decoder.bind(response).join();
      return jsonDecode(body) as Map<String, dynamic>;
    } finally {
      client.close(force: true);
    }
  }

  test('the daemon publishes the endpoint it bound for this Home', () {
    final record = LocalGatewayEndpointRecord.tryRead();

    expect(record, isNotNull);
    expect(record!.port, port);
    expect(record.host, '127.0.0.1');
    expect(record.homeId, sanadHomeIdentity(getSanadHome()));
    expect(record.ownerProcessId, pid);
    if (!Platform.isWindows) {
      expect(recordFile().statSync().mode & 0x1ff, 0x180);
    }
  });

  test('health reports the same Home identity as the record', () async {
    final payload = await health();
    final record = LocalGatewayEndpointRecord.tryRead();

    expect(payload['status'], 'ok');
    expect(payload['home_id'], record!.homeId);
    expect(payload['home_id'], sanadHomeIdentity(getSanadHome()));
  });

  test('disposal removes the record so a stopped Home fails closed', () async {
    await platform.dispose();
    expect(recordFile().existsSync(), isFalse);

    // The tearDown disposes again; a missing record must stay harmless.
    platform = LocalDaemonServerPlatform(
      security: LocalGatewaySecurity(
        config: LocalGatewaySecurityConfig(allowedPort: port),
        expectedToken: token,
      ),
    );
  });
}
