import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:http/http.dart' as http;
import 'package:sanad_agent/cli/client/local_gateway_cli_client.dart';
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

  /// `host:port` to the HTTP status that refuses the presented credential.
  ///
  /// A runtime that answers `401`/`403` is running but has just proven it is not
  /// the Home whose token was presented.
  final Map<String, int> rejections = {};

  final List<Uri> requests = [];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request.url);
    final key = '${request.url.host}:${request.url.port}';
    final rejection = rejections[key];
    if (rejection != null) {
      return http.StreamedResponse(
        Stream<List<int>>.value(utf8.encode('{"status":"unauthorized"}')),
        rejection,
        headers: const {'content-type': 'application/json'},
      );
    }
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

/// A process id that cannot be live: the kernel never issues one this high.
const int deadProcessId = 4194304;

void main() {
  useIsolatedSanadTestHome();

  late Directory root;
  late Directory home;
  late Directory otherHome;
  late _RecordingHttpClient client;

  /// Writes [contents], then restricts the file to 0600 on POSIX so the readers
  /// that now require owner-only files accept it.
  ///
  /// The mode is part of the contract under test, so tests that need a *wide*
  /// mode write first and widen afterwards.
  void writeOwnerOnly(String path, String contents) {
    File(path).writeAsStringSync(contents);
    if (!Platform.isWindows) Process.runSync('chmod', ['600', path]);
  }

  void writeRecord(
    Directory selected, {
    required int port,
    String? homeId,
    int? ownerProcessId,
    String host = '127.0.0.1',
  }) {
    writeOwnerOnly(
      p.join(selected.path, LocalGatewayEndpointRecord.relativePath),
      jsonEncode({
        'schema': LocalGatewayEndpointRecord.schemaVersion,
        'home_id': homeId ?? sanadHomeIdentity(selected.path),
        'host': host,
        'port': port,
        'pid': ownerProcessId ?? pid,
      }),
    );
  }

  String healthBody(Directory owner) =>
      jsonEncode({'status': 'ok', 'home_id': sanadHomeIdentity(owner.path)});

  /// Forces the Home-selection decision (production decides from the
  /// environment; see the detection group below).
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

  setUp(() {
    root = Directory(
      Directory.systemTemp
          .createTempSync('sanad-home-endpoint-isolation-')
          .resolveSymbolicLinksSync(),
    );
    home = Directory(p.join(root.path, 'home'))..createSync();
    otherHome = Directory(p.join(root.path, 'other-home'))..createSync();
    writeOwnerOnly(
      p.join(home.path, LocalGatewayCredentials.relativePath),
      'home-token',
    );
    client = _RecordingHttpClient(endpoints: {});
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  /// A daemon released before this contract reports no `home_id` at all.
  const String legacyHealthBody = '{"status":"ok","version":"1.0.18"}';

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

    test(
      'a record whose owner process is gone is stale, not an endpoint',
      () async {
        writeRecord(home, port: 58311, ownerProcessId: deadProcessId);
        client.endpoints['127.0.0.1:58311'] = healthBody(home);

        await expectLater(
          discoveryFor(
            home,
          ).discover(probeTimeout: const Duration(milliseconds: 200)),
          throwsA(
            isA<GatewayDiscoveryException>()
                .having((error) => error.code, 'code', 'home_runtime_stale')
                .having(
                  (error) => error.message,
                  'message',
                  contains('$deadProcessId'),
                ),
          ),
        );
        // No credential is sent to a port a dead record still names.
        expect(client.requests, isEmpty);
      },
    );

    test('a record naming a non-loopback host is unusable', () async {
      writeRecord(home, port: 58311, host: '10.0.0.5');
      client.endpoints['10.0.0.5:58311'] = healthBody(home);

      await expectLater(
        discoveryFor(
          home,
        ).discover(probeTimeout: const Duration(milliseconds: 200)),
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

    test('a record that is not owner-only is unusable', () async {
      if (Platform.isWindows) return;
      writeRecord(home, port: 58311);
      final recordFile = File(
        p.join(home.path, LocalGatewayEndpointRecord.relativePath),
      );
      Process.runSync('chmod', ['644', recordFile.path]);
      client.endpoints['127.0.0.1:58311'] = healthBody(home);

      await expectLater(
        discoveryFor(
          home,
        ).discover(probeTimeout: const Duration(milliseconds: 200)),
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

    test(
      'an inherited SANAD_GATEWAY_URL never receives a Home token',
      () async {
        writeRecord(home, port: 58311);
        client.endpoints['127.0.0.1:58311'] = healthBody(home);
        client.endpoints['127.0.0.1:58320'] = healthBody(otherHome);

        final result = await discoveryWithEnvironment(
          home,
          environment: const {
            'SANAD_GATEWAY_URL': 'ws://127.0.0.1:58320/gateway',
          },
          selectedFlag: true,
        ).discover(probeTimeout: const Duration(milliseconds: 200));

        expect(result.port, 58311);
        expect(client.requests.map((uri) => uri.port), [58311]);
      },
    );

    test(
      'an inherited URL cannot mask a selected Home without a runtime',
      () async {
        client.endpoints['127.0.0.1:58320'] = healthBody(home);

        await expectLater(
          discoveryWithEnvironment(
            home,
            environment: const {
              'LOCAL_GATEWAY_URL': 'ws://127.0.0.1:58320/gateway',
            },
            selectedFlag: true,
          ).discover(probeTimeout: const Duration(milliseconds: 200)),
          throwsA(
            isA<GatewayDiscoveryException>().having(
              (error) => error.code,
              'code',
              'home_runtime_missing',
            ),
          ),
        );
        // Not even the Home's own runtime: the record is the only evidence a
        // selected Home accepts, and nothing was sent to the inherited URL.
        expect(client.requests, isEmpty);
      },
    );

    test('an explicit --gateway-url must prove it serves the Home', () async {
      writeRecord(home, port: 58311);
      client.endpoints['127.0.0.1:58312'] = healthBody(otherHome);

      await expectLater(
        discoveryFor(home).discover(
          urlOverride: 'ws://127.0.0.1:58312/gateway',
          probeTimeout: const Duration(milliseconds: 200),
        ),
        throwsA(
          isA<GatewayDiscoveryException>().having(
            (error) => error.code,
            'code',
            'home_identity_mismatch',
          ),
        ),
      );
      expect(client.requests.map((uri) => uri.port), [58312]);
    });

    test('an explicit --gateway-url to this Home is accepted', () async {
      writeRecord(home, port: 58311);
      client.endpoints['127.0.0.1:58312'] = healthBody(home);

      final result = await discoveryFor(home).discover(
        urlOverride: 'ws://127.0.0.1:58312/gateway',
        probeTimeout: const Duration(milliseconds: 200),
      );

      expect(result.isDaemonRunning, isTrue);
      expect(result.port, 58312);
      expect(client.requests.map((uri) => uri.port), [58312]);
    });

    test('an explicit --port must prove it serves the Home', () async {
      client.endpoints['127.0.0.1:58312'] = healthBody(otherHome);

      await expectLater(
        discoveryFor(home).discover(
          portOverride: 58312,
          probeTimeout: const Duration(milliseconds: 200),
        ),
        throwsA(
          isA<GatewayDiscoveryException>().having(
            (error) => error.code,
            'code',
            'home_identity_mismatch',
          ),
        ),
      );
      expect(client.requests.map((uri) => uri.port), [58312]);
    });

    test(
      'an explicit --gateway-url that refuses the credential is a mismatch',
      () async {
        // The foreign runtime answers 401: it is running, and its refusal is
        // proof that it is not this Home's daemon. Reporting "not running"
        // here let the caller connect and fail later with an opaque
        // WebSocket 401 and exit 1.
        client.rejections['127.0.0.1:58312'] = HttpStatus.unauthorized;

        await expectLater(
          discoveryFor(home).discover(
            urlOverride: 'ws://127.0.0.1:58312/gateway',
            probeTimeout: const Duration(milliseconds: 200),
          ),
          throwsA(
            isA<GatewayDiscoveryException>()
                .having((error) => error.code, 'code', 'home_identity_mismatch')
                .having(
                  (error) => error.message,
                  'message',
                  contains('401'),
                ),
          ),
        );
        expect(client.requests.map((uri) => uri.port), [58312]);
      },
    );

    test('an explicit --port that forbids the credential is a mismatch', () async {
      client.rejections['127.0.0.1:58313'] = HttpStatus.forbidden;

      await expectLater(
        discoveryFor(home).discover(
          portOverride: 58313,
          probeTimeout: const Duration(milliseconds: 200),
        ),
        throwsA(
          isA<GatewayDiscoveryException>().having(
            (error) => error.code,
            'code',
            'home_identity_mismatch',
          ),
        ),
      );
    });

    test(
      'an explicit target that never answers still means "not running"',
      () async {
        // `--standalone` depends on this: an absent endpoint is not a mismatch.
        final result = await discoveryFor(home).discover(
          urlOverride: 'ws://127.0.0.1:58314/gateway',
          probeTimeout: const Duration(milliseconds: 50),
        );

        expect(result.isDaemonRunning, isFalse);
        expect(result.port, 58314);
      },
    );

    test(
      'a recorded endpoint that refuses the credential is not this Home',
      () async {
        // The record's pid is alive, but another runtime now holds the port it
        // names and rejects this Home's token.
        writeRecord(home, port: 58311);
        client.rejections['127.0.0.1:58311'] = HttpStatus.unauthorized;

        await expectLater(
          discoveryFor(
            home,
          ).discover(probeTimeout: const Duration(milliseconds: 200)),
          throwsA(
            isA<GatewayDiscoveryException>()
                .having((error) => error.code, 'code', 'home_identity_mismatch')
                .having(
                  (error) => error.message,
                  'message',
                  contains('refused this Home'),
                ),
          ),
        );
      },
    );

    test(
      'a selected Home never accepts a daemon that omits its identity',
      () async {
        // A daemon released before `home_id` existed answers on this Home's
        // record; the default-Home legacy tolerance must not reach a named Home.
        writeRecord(home, port: 58311);
        client.endpoints['127.0.0.1:58311'] = legacyHealthBody;

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
      },
    );

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

    test(
      'a pre-PR daemon on 58085 is still reachable from the default Home',
      () async {
        // Backward compatibility: the daemon bundled with an older desktop app
        // reports no `home_id`, and the default Home must keep working while
        // that daemon runs.
        client.endpoints['127.0.0.1:${LocalGatewayDiscovery.defaultPort}'] =
            legacyHealthBody;

        final result = await discoveryFor(
          home,
          selectedFlag: false,
        ).discover(probeTimeout: const Duration(milliseconds: 200));

        expect(result.isDaemonRunning, isTrue);
        expect(result.port, LocalGatewayDiscovery.defaultPort);
        expect(result.healthData?['version'], '1.0.18');
      },
    );

    test('a mismatching identity on 58085 is never accepted', () async {
      client.endpoints['127.0.0.1:${LocalGatewayDiscovery.defaultPort}'] =
          healthBody(otherHome);

      final result = await discoveryFor(
        home,
        selectedFlag: false,
      ).discover(probeTimeout: const Duration(milliseconds: 200));

      expect(result.isDaemonRunning, isFalse);
      expect(result.port, LocalGatewayDiscovery.defaultPort);
    });

    test('the legacy tolerance never reaches a scanned port', () async {
      client.endpoints['127.0.0.1:${LocalGatewayDiscovery.defaultPort}'] =
          legacyHealthBody;
      client.endpoints['127.0.0.1:58086'] = legacyHealthBody;

      final result = await discoveryFor(
        home,
        selectedFlag: false,
      ).discover(probeTimeout: const Duration(milliseconds: 25));

      // 58085 answered with an acceptable (legacy) identity, so the scan never
      // runs; a scanned answer without `home_id` is not evidence of anything.
      expect(result.port, LocalGatewayDiscovery.defaultPort);

      client.requests.clear();
      client.endpoints.remove('127.0.0.1:${LocalGatewayDiscovery.defaultPort}');

      final scanned = await discoveryFor(
        home,
        selectedFlag: false,
      ).discover(probeTimeout: const Duration(milliseconds: 25));

      expect(scanned.isDaemonRunning, isFalse);
      expect(client.requests.map((uri) => uri.port), contains(58086));
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

    test('an inherited URL that serves another Home fails closed', () async {
      client.endpoints['127.0.0.1:58320'] = healthBody(otherHome);

      await expectLater(
        discoveryWithEnvironment(
          home,
          environment: const {'SANAD_GATEWAY_URL': 'ws://127.0.0.1:58320/w'},
          selectedFlag: false,
        ).discover(probeTimeout: const Duration(milliseconds: 200)),
        throwsA(
          isA<GatewayDiscoveryException>().having(
            (error) => error.code,
            'code',
            'home_identity_mismatch',
          ),
        ),
      );
    });

    test(
      'a rejected credential keeps the historical answer without a selection',
      () async {
        // The fail-closed credential rule belongs to a selected Home, whose
        // token is on the line. No selection keeps the pre-PR answer so the
        // legacy default-Home flow is unchanged.
        client.rejections['127.0.0.1:58085'] = HttpStatus.unauthorized;

        final result = await discoveryFor(
          home,
          selectedFlag: false,
        ).discover(probeTimeout: const Duration(milliseconds: 25));

        expect(result.isDaemonRunning, isFalse);
        expect(client.requests.first.port, 58085);
      },
    );
  });

  group('Explicit target with a selected Home', () {
    test('refuses to connect when the target rejects the credential', () async {
      // A real loopback endpoint is the only way to observe the *absence* of a
      // WebSocket connect: it answers `/health` with 401 and records any upgrade
      // attempt, so an upgrade would appear here instead of as an opaque
      // `CliClientException(connection_failed)` in production.
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final healthPaths = <String>[];
      final upgradePaths = <String>[];
      server.listen((request) async {
        if (WebSocketTransformer.isUpgradeRequest(request)) {
          upgradePaths.add(request.uri.path);
          request.response.statusCode = HttpStatus.unauthorized;
        } else {
          healthPaths.add(request.uri.path);
          request.response.statusCode = HttpStatus.unauthorized;
        }
        await request.response.close();
      });

      await expectLater(
        LocalGatewayCliClient.discoverAndConnect(
          sanadHomeOverride: home.path,
          urlOverride: 'ws://127.0.0.1:${server.port}/gateway',
        ),
        throwsA(
          isA<GatewayDiscoveryException>().having(
            (error) => error.code,
            'code',
            'home_identity_mismatch',
          ),
        ),
      );

      expect(healthPaths, ['/health']);
      expect(upgradePaths, isEmpty);
    });
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

    test('a literal ~/ SANAD_HOME resolves to the user Home', () {
      final discovery = LocalGatewayDiscovery(
        environment: {'HOME': p.join('/tmp', 'user'), 'SANAD_HOME': '~/lab'},
      );

      expect(discovery.resolveSanadHome(), p.join('/tmp', 'user', 'lab'));
      expect(discovery.homeIsSelected, isTrue);
    });

    test('a --home equal to the default Home is not a selection', () async {
      // No forced flag: discovery classifies this from the environment, exactly
      // as production does, and then keeps the default-port probe.
      final userHome = Directory(p.join(root.path, 'user'))..createSync();
      final defaultHome = Directory(p.join(userHome.path, '.sanad'))
        ..createSync();
      writeOwnerOnly(
        p.join(defaultHome.path, LocalGatewayCredentials.relativePath),
        'default-token',
      );
      client.endpoints['127.0.0.1:${LocalGatewayDiscovery.defaultPort}'] =
          healthBody(defaultHome);

      final discovery = LocalGatewayDiscovery(
        sanadHomeOverride: defaultHome.path,
        environment: {'HOME': userHome.path},
        clientFactory: () => client,
      );

      expect(discovery.homeIsSelected, isFalse);
      final result = await discovery.discover(
        probeTimeout: const Duration(milliseconds: 200),
      );
      expect(result.port, LocalGatewayDiscovery.defaultPort);
      expect(result.isDaemonRunning, isTrue);
    });

    test(
      'SANAD_HOME alone drives the Home-selected path in discovery',
      () async {
        // No `homeSelected` and no `sanadHomeOverride`: the selection comes from
        // the environment, which is the production path for `SANAD_HOME`.
        final env = <String, String>{
          'HOME': p.join(root.path, 'user'),
          'SANAD_HOME': home.path,
          // An inherited URL must be ignored for a selected Home.
          'SANAD_GATEWAY_URL': 'ws://127.0.0.1:58320/gateway',
        };
        writeRecord(home, port: 58311);
        client.endpoints['127.0.0.1:58311'] = healthBody(home);
        client.endpoints['127.0.0.1:58320'] = healthBody(otherHome);

        final discovery = LocalGatewayDiscovery(
          environment: env,
          clientFactory: () => client,
        );

        expect(discovery.homeIsSelected, isTrue);
        final result = await discovery.discover(
          probeTimeout: const Duration(milliseconds: 200),
        );
        expect(result.port, 58311);
        expect(client.requests.map((uri) => uri.port), [58311]);
      },
    );
  });

  group('Credential binding', () {
    test('readToken refuses a token bound to another Home', () async {
      writeOwnerOnly(
        p.join(home.path, LocalGatewayCredentials.relativePath),
        'shared-token',
      );
      writeOwnerOnly(
        p.join(home.path, LocalGatewayCredentials.bindingRelativePath),
        sanadHomeIdentity(otherHome.path),
      );

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

    test('readToken rejects a token any other user can read', () async {
      if (Platform.isWindows) return;
      final tokenFile = File(
        p.join(home.path, LocalGatewayCredentials.relativePath),
      );
      Process.runSync('chmod', ['644', tokenFile.path]);

      await expectLater(
        discoveryFor(home).readToken(),
        throwsA(
          isA<GatewayDiscoveryException>()
              .having((error) => error.code, 'code', 'token_permissions')
              .having(
                (error) => error.message,
                'message',
                contains('chmod 600'),
              ),
        ),
      );
    });

    test(
      'a permission failure stays distinct from an unreadable token',
      () async {
        final missing = Directory(p.join(root.path, 'missing-home'))
          ..createSync();

        await expectLater(
          discoveryFor(missing).readToken(),
          throwsA(
            isA<GatewayDiscoveryException>().having(
              (error) => error.code,
              'code',
              'token_not_found',
            ),
          ),
        );
      },
    );
  });

  group('Home identity canonicalisation', () {
    test('a literal ~/ SANAD_HOME has the identity of the expanded path', () {
      final userHome = Platform.environment['HOME'];
      expect(userHome, isNotNull, reason: 'POSIX test hosts define HOME');

      expect(
        sanadHomeIdentity('~/sanad-identity-does-not-exist'),
        sanadHomeIdentity(p.join(userHome!, 'sanad-identity-does-not-exist')),
      );
    });

    test('a symlinked Home has the identity of its target', () {
      final real = Directory(p.join(root.path, 'real-home'))..createSync();
      final link = Link(p.join(root.path, 'linked-home'))
        ..createSync(real.path);

      expect(sanadHomeIdentity(link.path), sanadHomeIdentity(real.path));
    });
  });
}
