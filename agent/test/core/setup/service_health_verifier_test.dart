import 'dart:convert';
import 'dart:io';

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
    credential = await LocalGatewayCredentials.loadOrCreate();
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
