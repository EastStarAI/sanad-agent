import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:http/http.dart' as http;
import 'package:sanad_agent/cli/discovery/local_gateway_discovery.dart';
import 'package:sanad_agent/core/sanad_home/sanad_home_identity.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/local_gateway_credentials.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/local_gateway_endpoint_record.dart';

import '../support/isolated_sanad_test_home.dart';

/// Records every probed URL and answers from an in-memory endpoint map.
///
/// Discovery must prove *where* it looked, not only what it returned, so the
/// fake never touches the network: a Home-selected call that probes the
/// default port is a recorded request, and a test fails on it instead of
/// depending on whichever daemon happens to run on this machine.
class _RecordingHttpClient extends http.BaseClient {
  _RecordingHttpClient({required this.endpoints});

  /// `host:port` to `/health` body. An absent endpoint refuses the connection.
  final Map<String, String> endpoints;
  final List<Uri> requests = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request.url);
    final key = '${request.url.host}:${request.url.port}';
    final body = endpoints[key];
    if (body == null) {
      throw const SocketException('connection refused');
    }
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(body)),
      HttpStatus.ok,
      headers: const {'content-type': 'application/json'},
    );
  }

  @override
  void close() {
    // A shared recording client stays usable across repeated probes.
  }
}

void main() {
  useIsolatedSanadTestHome();

  late Directory root;
  late Directory home;
  late Directory otherHome;
  late _RecordingHttpClient client;

  setUp(() {
    root = Directory(
      Directory.systemTemp
          .createTempSync('sanad-home-endpoint-isolation-')
          .resolveSymbolicLinksSync(),
    );
    home = Directory(p.join(root.path, 'home'))..createSync();
    otherHome = Directory(p.join(root.path, 'other-home'))..createSync();
    File(
      p.join(home.path, LocalGatewayCredentials.relativePath),
    ).writeAsStringSync('home-token');
    client = _RecordingHttpClient(endpoints: {});
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  LocalGatewayDiscovery discoveryFor(Directory selected, {bool? selectedFlag}) {
    return LocalGatewayDiscovery(
      sanadHomeOverride: selected.path,
      environment: const {},
      clientFactory: () => client,
      homeSelected: selectedFlag ?? true,
    );
  }

  LocalGatewayDiscovery discoveryWithEnvironment(
    Directory selected, {
    required Map<String, String> environment,
    bool? selectedFlag,
  }) {
    return LocalGatewayDiscovery(
      sanadHomeOverride: selected.path,
      environment: environment,
      clientFactory: () => client,
      homeSelected: selectedFlag,
    );
  }

  void writeRecord(
    Directory selected, {
    required int port,
    String? homeId,
    int ownerProcessId = 4242,
  }) {
    File(
      p.join(selected.path, LocalGatewayEndpointRecord.relativePath),
    ).writeAsStringSync(
      jsonEncode({
        'schema': LocalGatewayEndpointRecord.schemaVersion,
        'home_id': homeId ?? sanadHomeIdentity(selected.path),
        'host': '127.0.0.1',
        'port': port,
        'pid': ownerProcessId,
      }),
    );
  }

  String healthBody(Directory owner) =>
      jsonEncode({'status': 'ok', 'home_id': sanadHomeIdentity(owner.path)});

  group('Home-selected discovery', () {
    test('never probes the default port without a runtime record', () async {
      final discovery = discoveryFor(home);

      await expectLater(
        discovery.discover(probeTimeout: const Duration(milliseconds: 50)),
        throwsA(
          isA<GatewayDiscoveryException>().having(
            (error) => error.code,
            'code',
            'home_runtime_missing',
          ),
        ),
      );
      expect(client.requests, isEmpty);
    });

    test('resolves the endpoint from the Home runtime record only', () async {
      writeRecord(home, port: 58311);
      client.endpoints['127.0.0.1:58311'] = healthBody(home);

      final result = await discoveryFor(
        home,
      ).discover(probeTimeout: const Duration(milliseconds: 200));

      expect(result.isDaemonRunning, isTrue);
      expect(result.port, 58311);
      expect(result.gatewayWsUri.toString(), 'ws://127.0.0.1:58311/gateway');
      expect(client.requests.map((uri) => uri.port), [58311]);
      expect(
        client.requests.map((uri) => uri.port),
        isNot(contains(LocalGatewayDiscovery.defaultPort)),
      );
    });

    test('fails closed when the recorded endpoint is unhealthy', () async {
      writeRecord(home, port: 58311);

      await expectLater(
        discoveryFor(
          home,
        ).discover(probeTimeout: const Duration(milliseconds: 50)),
        throwsA(
          isA<GatewayDiscoveryException>().having(
            (error) => error.code,
            'code',
            'home_runtime_unhealthy',
          ),
        ),
      );
      expect(client.requests.map((uri) => uri.port), [58311]);
    });

    test(
      'fails closed when the answering daemon serves another Home',
      () async {
        writeRecord(home, port: 58311);
        client.endpoints['127.0.0.1:58311'] = healthBody(otherHome);

        await expectLater(
          discoveryFor(
            home,
          ).discover(probeTimeout: const Duration(milliseconds: 200)),
          throwsA(
            isA<GatewayDiscoveryException>().having(
              (error) => error.code,
              'code',
              'home_identity_mismatch',
            ),
          ),
        );
        expect(client.requests.map((uri) => uri.port), [58311]);
      },
    );

    test('rejects a runtime record published by another Home', () async {
      writeRecord(home, port: 58311, homeId: sanadHomeIdentity(otherHome.path));

      await expectLater(
        discoveryFor(
          home,
        ).discover(probeTimeout: const Duration(milliseconds: 50)),
        throwsA(
          isA<GatewayDiscoveryException>().having(
            (error) => error.code,
            'code',
            'home_runtime_foreign',
          ),
        ),
      );
      expect(client.requests, isEmpty);
    });

    test('an explicit --gateway-url still wins over the Home record', () async {
      writeRecord(home, port: 58311);
      client.endpoints['127.0.0.1:58312'] = healthBody(otherHome);

      final result = await discoveryFor(home).discover(
        urlOverride: 'ws://127.0.0.1:58312/gateway',
        probeTimeout: const Duration(milliseconds: 200),
      );

      expect(result.port, 58312);
      expect(client.requests.map((uri) => uri.port), [58312]);
    });

    test(
      'an inherited LOCAL_GATEWAY_PORT never redirects a Home call',
      () async {
        writeRecord(home, port: 58311);
        client.endpoints['127.0.0.1:58311'] = healthBody(home);
        client.endpoints['127.0.0.1:58320'] = healthBody(otherHome);

        final result = await discoveryWithEnvironment(
          home,
          environment: const {'LOCAL_GATEWAY_PORT': '58320'},
          selectedFlag: true,
        ).discover(probeTimeout: const Duration(milliseconds: 200));

        expect(result.port, 58311);
        expect(client.requests.map((uri) => uri.port), [58311]);
      },
    );
  });

  group('Default-Home discovery', () {
    test('keeps probing 58085 first when no Home is selected', () async {
      client.endpoints['127.0.0.1:${LocalGatewayDiscovery.defaultPort}'] =
          healthBody(home);

      final result = await discoveryFor(
        home,
        selectedFlag: false,
      ).discover(probeTimeout: const Duration(milliseconds: 200));

      expect(result.isDaemonRunning, isTrue);
      expect(result.port, LocalGatewayDiscovery.defaultPort);
      expect(client.requests.first.port, LocalGatewayDiscovery.defaultPort);
    });

    test('the scan rejects a daemon that serves another Home', () async {
      client.endpoints['127.0.0.1:${LocalGatewayDiscovery.defaultPort}'] =
          healthBody(otherHome);
      client.endpoints['127.0.0.1:58086'] = healthBody(otherHome);
      client.endpoints['127.0.0.1:58087'] = healthBody(home);

      final result = await discoveryFor(
        home,
        selectedFlag: false,
      ).discover(probeTimeout: const Duration(milliseconds: 200));

      expect(result.isDaemonRunning, isTrue);
      expect(result.port, 58087);
      expect(
        client.requests.map((uri) => uri.port),
        containsAll(<int>[LocalGatewayDiscovery.defaultPort, 58086, 58087]),
      );
    });

    test(
      'the scan reports no daemon when every candidate is foreign',
      () async {
        client.endpoints['127.0.0.1:${LocalGatewayDiscovery.defaultPort}'] =
            healthBody(otherHome);
        client.endpoints['127.0.0.1:58086'] = healthBody(otherHome);

        final result = await discoveryFor(
          home,
          selectedFlag: false,
        ).discover(probeTimeout: const Duration(milliseconds: 200));

        expect(result.isDaemonRunning, isFalse);
        expect(result.port, LocalGatewayDiscovery.defaultPort);
      },
    );
  });

  group('Home selection detection', () {
    test('the OS default Home is not a selection', () {
      final discovery = LocalGatewayDiscovery(
        sanadHomeOverride: '${p.join('/tmp', 'user')}/.sanad',
        environment: {'HOME': p.join('/tmp', 'user')},
      );
      expect(discovery.homeIsSelected, isFalse);
    });

    test('SANAD_HOME selects a Home', () {
      final discovery = LocalGatewayDiscovery(
        sanadHomeOverride: p.join('/tmp', 'temporary-home'),
        environment: {'HOME': p.join('/tmp', 'user'), 'SANAD_HOME': '/tmp/th'},
      );
      expect(discovery.homeIsSelected, isTrue);
    });

    test('a Home that differs from the default Home is a selection', () {
      final discovery = LocalGatewayDiscovery(
        sanadHomeOverride: p.join('/tmp', 'test-home-3'),
        environment: {'HOME': p.join('/tmp', 'user')},
      );
      expect(discovery.homeIsSelected, isTrue);
    });
  });

  group('Credential binding', () {
    test('readToken refuses a token bound to another Home', () async {
      File(
        p.join(home.path, LocalGatewayCredentials.relativePath),
      ).writeAsStringSync('shared-token');
      File(
        p.join(home.path, LocalGatewayCredentials.bindingRelativePath),
      ).writeAsStringSync(sanadHomeIdentity(otherHome.path));

      await expectLater(
        discoveryFor(home).readToken(),
        throwsA(
          isA<GatewayDiscoveryException>().having(
            (error) => error.code,
            'code',
            'token_bound_to_other_home',
          ),
        ),
      );
    });
  });
}
