import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/sanad_home/sanad_home_bootstrap.dart';
import 'package:sanad_agent/core/setup/service_health_verifier.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/local_gateway_credentials.dart';
import 'package:test/test.dart';

void main() {
  late Directory home;
  late HttpServer server;
  late LocalGatewayCredential credential;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('sanad-health-verifier-');
    setSanadHomeOverride(home.path);
    await SanadHomeBootstrap.identity().prepare();
    credential = await LocalGatewayCredentials.loadOrCreateForDaemonStart();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  });

  tearDown(() async {
    await server.close(force: true);
    setSanadHomeOverride(null);
    await home.delete(recursive: true);
  });

  test(
    'waits until version and cloud registration are both authoritative',
    () async {
      var requests = 0;
      server.listen((request) async {
        requests++;
        expect(
          request.headers.value(LocalGatewayCredentials.headerName),
          credential.value,
        );
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'status': 'ok',
            'version': '1.2.3',
            'cloud_registered': requests >= 2,
          }),
        );
        await request.response.close();
      });
      final verifier = ServiceHealthVerifier(
        config: Config(
          environment: {
            'LOCAL_GATEWAY_PORT': '${server.port}',
            'LOCAL_GATEWAY_HOST': '127.0.0.1',
          },
        ),
        delay: (_) async {},
      );

      final result = await verifier.verify(
        const ServiceHealthExpectation(
          expectedVersion: '1.2.3',
          requireCloudRegistration: true,
          timeout: Duration(seconds: 2),
        ),
      );

      expect(result.success, isTrue, reason: result.error);
      expect(result.attempts, 2);
    },
  );

  test(
    'polls until the daemon writes its credential after start',
    () async {
      // A freshly activated unit has not written `.local_token` yet: the daemon
      // issues it during its own startup, moments after `systemctl enable --now`
      // returns. The verifier must wait for it instead of failing at once.
      _removeCredential(home);
      var requests = 0;
      server.listen((request) async {
        requests++;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'status': 'ok',
            'version': '1.2.3',
            'cloud_registered': true,
          }),
        );
        await request.response.close();
      });
      var waits = 0;
      final verifier = ServiceHealthVerifier(
        config: Config(
          environment: {
            'LOCAL_GATEWAY_PORT': '${server.port}',
            'LOCAL_GATEWAY_HOST': '127.0.0.1',
          },
        ),
        delay: (_) async {
          waits++;
          if (waits == 2) {
            await LocalGatewayCredentials.loadOrCreateForDaemonStart();
          }
        },
      );

      final result = await verifier.verify(
        const ServiceHealthExpectation(
          expectedVersion: '1.2.3',
          requireCloudRegistration: true,
          timeout: Duration(seconds: 5),
          pollInterval: Duration(milliseconds: 1),
        ),
      );

      expect(result.success, isTrue, reason: result.error);
      // Two credential-less polls, then the poll that sees the token.
      expect(result.attempts, 3);
      expect(waits, 2);
      expect(requests, 1);
    },
  );

  test(
    'fails after the timeout when the credential never appears',
    () async {
      _removeCredential(home);
      var requests = 0;
      server.listen((request) async {
        requests++;
        await request.response.close();
      });
      final verifier = ServiceHealthVerifier(
        config: Config(
          environment: {
            'LOCAL_GATEWAY_PORT': '${server.port}',
            'LOCAL_GATEWAY_HOST': '127.0.0.1',
          },
        ),
        delay: (_) async {},
      );

      final result = await verifier.verify(
        const ServiceHealthExpectation(
          expectedVersion: '1.2.3',
          requireCloudRegistration: true,
          timeout: Duration(seconds: 1),
          pollInterval: Duration(milliseconds: 1),
        ),
      );

      expect(result.success, isFalse);
      expect(result.attempts, greaterThan(1));
      expect(result.error, contains('Local Gateway credential'));
      expect(result.error, contains('sanad service restart'));
      expect(requests, 0);
    },
  );

  test(
    'fails bounded verification when the running version is stale',
    () async {
      server.listen((request) async {
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'status': 'ok',
            'version': 'old-version',
            'cloud_registered': true,
          }),
        );
        await request.response.close();
      });
      final verifier = ServiceHealthVerifier(
        config: Config(
          environment: {
            'LOCAL_GATEWAY_PORT': '${server.port}',
            'LOCAL_GATEWAY_HOST': '127.0.0.1',
          },
        ),
        delay: (_) => Future<void>.delayed(const Duration(milliseconds: 1)),
      );

      final result = await verifier.verify(
        const ServiceHealthExpectation(
          expectedVersion: 'new-version',
          requireCloudRegistration: true,
          timeout: Duration(milliseconds: 20),
          pollInterval: Duration(milliseconds: 1),
        ),
      );

      expect(result.success, isFalse);
      expect(result.error, contains('version'));
      expect(result.attempts, greaterThan(0));
    },
  );
}

/// Removes the Local Gateway credential of [home] so a test can observe the
/// daemon writing it later, as it does during a real service activation.
void _removeCredential(Directory home) {
  for (final name in <String>[
    LocalGatewayCredentials.relativePath,
    LocalGatewayCredentials.bindingRelativePath,
  ]) {
    final file = File(p.join(home.path, name));
    if (file.existsSync()) file.deleteSync();
  }
}
