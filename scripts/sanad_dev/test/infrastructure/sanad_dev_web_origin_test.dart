import 'dart:io';

import 'package:test/test.dart';

import 'package:sanad_dev/src/infrastructure/cloud_endpoints.dart';
import 'package:sanad_dev/src/infrastructure/web_origin.dart';

void main() {
  group('deterministic Web origin derivation', () {
    const home = '/Users/dev/.sanad/dev/homes/test-home-2-1a2b3c4d';

    test('is stable for one Home, slot, and environment', () {
      final first = deriveSanadDevWebPort(
        sanadHome: home,
        clientEnvironment: 'local',
        clientInstanceSlot: 'web-primary',
      );
      final second = deriveSanadDevWebPort(
        sanadHome: home,
        clientEnvironment: 'local',
        clientInstanceSlot: 'web-primary',
      );

      expect(first, second);
      expect(first, greaterThanOrEqualTo(sanadDevWebPortRangeStart));
      expect(first, lessThanOrEqualTo(sanadDevWebPortRangeEnd));
    });

    test('stays inside the reserved range and clear of other runtimes', () {
      expect(sanadDevWebPortRangeStart, greaterThan(51999));
      expect(sanadDevWebPortRangeEnd, lessThan(58085));

      for (final slot in ['', 'web-primary', 'web-secondary', 'ios-primary']) {
        for (final environment in ['local', 'dev', 'staging', 'prod']) {
          final port = deriveSanadDevWebPort(
            sanadHome: home,
            clientEnvironment: environment,
            clientInstanceSlot: slot.isEmpty ? null : slot,
          );
          expect(port, inInclusiveRange(52000, 52999));
        }
      }
    });

    test('separates slots, environments, and Homes', () {
      final base = deriveSanadDevWebPort(
        sanadHome: home,
        clientEnvironment: 'local',
      );
      final otherSlot = deriveSanadDevWebPort(
        sanadHome: home,
        clientEnvironment: 'local',
        clientInstanceSlot: 'web-secondary',
      );
      final otherEnvironment = deriveSanadDevWebPort(
        sanadHome: home,
        clientEnvironment: 'prod',
      );
      final otherHome = deriveSanadDevWebPort(
        sanadHome: '$home-other',
        clientEnvironment: 'local',
      );

      expect(
        {base, otherSlot, otherEnvironment, otherHome},
        hasLength(4),
        reason: 'a shared origin would share browser storage across identities',
      );
    });

    test('rejects a missing Home or environment', () {
      expect(
        () =>
            deriveSanadDevWebPort(sanadHome: '  ', clientEnvironment: 'local'),
        throwsFormatException,
      );
      expect(
        () => deriveSanadDevWebPort(sanadHome: home, clientEnvironment: ''),
        throwsFormatException,
      );
    });
  });

  group('Web origin resolution', () {
    const home = '/Users/dev/.sanad/dev/homes/test-home-2-1a2b3c4d';

    test('derives when no override is set', () {
      final port = resolveSanadDevWebPort(
        sanadHome: home,
        clientEnvironment: 'local',
        processEnvironment: const {},
      );

      expect(
        port,
        deriveSanadDevWebPort(sanadHome: home, clientEnvironment: 'local'),
      );
    });

    test('keeps an explicit deployment-pinned port', () {
      expect(
        resolveSanadDevWebPort(
          sanadHome: home,
          clientEnvironment: 'local',
          processEnvironment: const {sanadDevWebPortEnvironmentKey: '55025'},
        ),
        55025,
      );
      expect(
        resolveSanadDevWebPort(
          sanadHome: home,
          clientEnvironment: 'local',
          processEnvironment: const {sanadDevWebPortEnvironmentKey: '55025'},
          clientInstanceSlot: 'web-primary',
        ),
        55025,
      );
    });

    test('rejects an invalid override instead of falling back', () {
      for (final value in ['70000', '0', '-1', 'http://localhost']) {
        expect(
          () => resolveSanadDevWebPort(
            sanadHome: home,
            clientEnvironment: 'local',
            processEnvironment: {sanadDevWebPortEnvironmentKey: value},
          ),
          throwsFormatException,
          reason: value,
        );
      }
    });
  });

  group('origin availability', () {
    test('reports a busy port instead of choosing another one', () async {
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(socket.close);

      await expectLater(
        () => assertSanadDevWebPortAvailable(
          port: socket.port,
          clientEnvironment: 'local',
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            allOf(
              contains('http://localhost:${socket.port}'),
              contains(sanadDevWebPortEnvironmentKey),
            ),
          ),
        ),
      );
    });

    test('accepts a free port', () async {
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = socket.port;
      await socket.close();

      await assertSanadDevWebPortAvailable(
        port: port,
        clientEnvironment: 'local',
      );
    });
  });

  group('preflight authority', () {
    test('a loopback Portal is deployment-owned', () {
      for (final url in [
        'http://127.0.0.1:8083',
        'http://localhost:8083',
        'http://[::1]:8083',
      ]) {
        expect(
          sanadDevWebOriginAuthorityFor(url),
          SanadDevWebOriginAuthority.deploymentOwned,
          reason: url,
        );
      }
    });

    test('a hosted Portal registers one HTTPS app origin', () {
      for (final url in [
        'https://portal.sanad.eaststarai.com',
        'https://dev.portal.example.test',
      ]) {
        expect(
          sanadDevWebOriginAuthorityFor(url),
          SanadDevWebOriginAuthority.hostedPortal,
          reason: url,
        );
      }
    });
  });

  group('preflight decision', () {
    const origin = 'http://localhost:52043';

    test('refuses a hosted environment before launch', () {
      final preflight = evaluateSanadDevWebOriginPreflight(
        origin: origin,
        portalUrl: 'https://portal.sanad.eaststarai.com',
        cloudEnabled: true,
        deploymentAcceptsOrigin: null,
      );

      expect(preflight.isRefused, isTrue);
      expect(preflight.message, contains(origin));
      expect(
        preflight.message,
        contains('https://portal.sanad.eaststarai.com'),
      );
      expect(preflight.message, contains('invalid_redirect_uri'));
      expect(preflight.message, contains('--no-cloud'));
      expect(preflight.message, contains('-d macos'));
    });

    test('refuses a local Portal that rejects the derived origin', () {
      final preflight = evaluateSanadDevWebOriginPreflight(
        origin: origin,
        portalUrl: 'http://127.0.0.1:8083',
        cloudEnabled: true,
        deploymentAcceptsOrigin: false,
      );

      expect(preflight.isRefused, isTrue);
      expect(preflight.message, contains('SANAD_PORTAL_WEB_CLIENT_ORIGIN'));
      expect(preflight.message, contains('SANAD_PORTAL_CORS_ORIGINS'));
      expect(preflight.message, contains('BACKEND_CORS_ORIGINS'));
      expect(preflight.message, contains('$origin/oauth/callback'));
    });

    test('accepts a local Portal that allows the origin', () {
      final preflight = evaluateSanadDevWebOriginPreflight(
        origin: origin,
        portalUrl: 'http://127.0.0.1:8083',
        cloudEnabled: true,
        deploymentAcceptsOrigin: true,
      );

      expect(preflight.outcome, SanadDevWebOriginPreflightOutcome.ready);
      expect(preflight.message, isEmpty);
    });

    test('warns instead of refusing when the Portal cannot be asked', () {
      final preflight = evaluateSanadDevWebOriginPreflight(
        origin: origin,
        portalUrl: 'http://127.0.0.1:8083',
        cloudEnabled: true,
        deploymentAcceptsOrigin: null,
      );

      expect(preflight.isUnverified, isTrue);
      expect(preflight.isRefused, isFalse);
      expect(preflight.message, contains(origin));
    });

    test('warns when the cloud gateway is disabled', () {
      final preflight = evaluateSanadDevWebOriginPreflight(
        origin: origin,
        portalUrl: 'https://portal.sanad.eaststarai.com',
        cloudEnabled: false,
        deploymentAcceptsOrigin: null,
      );

      expect(preflight.isUnverified, isTrue);
      expect(preflight.message, contains(origin));
      expect(preflight.message, contains('--no-cloud'.substring(2)));
    });
  });

  group('Portal CORS preflight probe', () {
    test('accepts an origin the Portal allows', () async {
      final server = await _startPortal(allowOrigin: 'http://localhost:52043');
      addTearDown(server.close);

      expect(
        await probeSanadDevPortalWebOrigin(
          portalUrl: 'http://127.0.0.1:${server.port}',
          origin: 'http://localhost:52043',
        ),
        isTrue,
      );
    });

    test('rejects an origin the Portal does not allow', () async {
      final server = await _startPortal(
        allowOrigin: 'https://app.example.test',
      );
      addTearDown(server.close);

      expect(
        await probeSanadDevPortalWebOrigin(
          portalUrl: 'http://127.0.0.1:${server.port}',
          origin: 'http://localhost:52043',
        ),
        isFalse,
      );
    });

    test('reports an unreachable Portal as unverified', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      await server.close();

      expect(
        await probeSanadDevPortalWebOrigin(
          portalUrl: 'http://127.0.0.1:$port',
          origin: 'http://localhost:52043',
        ),
        isNull,
      );
    });
  });

  group('client environment resolution', () {
    test('reads ENVIRONMENT without the cloud gateway', () async {
      final temp = await Directory.systemTemp.createTemp('sanad-web-origin');
      addTearDown(() => temp.delete(recursive: true));
      final config = File('${temp.path}/local.json')
        ..writeAsStringSync('{"ENVIRONMENT":"local"}');

      expect(readSanadClientEnvironment(config), 'local');
      expect(readSanadCloudEndpoints(config).environment, 'local');
    });

    test('requires ENVIRONMENT', () async {
      final temp = await Directory.systemTemp.createTemp('sanad-web-origin');
      addTearDown(() => temp.delete(recursive: true));
      final config = File('${temp.path}/empty.json')..writeAsStringSync('{}');

      expect(() => readSanadClientEnvironment(config), throwsFormatException);
    });

    test('recovers the environment from a recorded launch profile', () async {
      final temp = await Directory.systemTemp.createTemp('sanad-web-origin');
      addTearDown(() => temp.delete(recursive: true));
      Directory('${temp.path}/config').createSync(recursive: true);
      File('${temp.path}/config/local.json')
          .writeAsStringSync('{"ENVIRONMENT":"local"}');

      expect(
        readSanadClientEnvironmentFromLaunchArguments(
          arguments: const [
            'flutter',
            'run',
            '-d',
            'chrome',
            '--dart-define-from-file=config/local.json',
          ],
          clientDirectory: temp.path,
        ),
        'local',
      );
      expect(
        readSanadClientEnvironmentFromLaunchArguments(
          arguments: const ['flutter', 'run', '-d', 'chrome'],
          clientDirectory: temp.path,
        ),
        isNull,
      );
      expect(
        readSanadClientEnvironmentFromLaunchArguments(
          arguments: const ['--dart-define-from-file=config/missing.json'],
          clientDirectory: temp.path,
        ),
        isNull,
      );
    });
  });

  group('launch preparation', () {
    test('refuses the tracked production profile before any process', () async {
      final config = File('../../client/config/prod.json');
      final launch = await prepareSanadDevWebOriginLaunch(
        configFile: config,
        cloudEndpoints: readSanadCloudEndpoints(config),
        sanadHome: '/Users/dev/.sanad/dev/homes/web-origin-refusal',
        cloudEnabled: true,
        processEnvironment: const {},
        clientInstanceSlot: 'web-primary',
      );

      expect(launch.isRefused, isTrue);
      expect(launch.exitStatus, 1);
      expect(
        launch.startupFailureReason,
        'client web origin cannot authenticate',
      );
      expect(launch.port, isNull);
    });

    test('launches against a local Portal that registers the origin', () async {
      final temp = await Directory.systemTemp.createTemp('sanad-web-launch');
      addTearDown(() => temp.delete(recursive: true));

      // Pick a Home whose derived origin is bindable on this host, so the test
      // never depends on which ports happen to be taken.
      int? port;
      var home = temp.path;
      for (var attempt = 0; attempt < 20 && port == null; attempt++) {
        home = '${temp.path}-$attempt';
        final candidate = deriveSanadDevWebPort(
          sanadHome: home,
          clientEnvironment: 'local',
          clientInstanceSlot: 'web-primary',
        );
        try {
          final socket = await ServerSocket.bind(
            InternetAddress.loopbackIPv4,
            candidate,
          );
          await socket.close();
          port = candidate;
        } on SocketException {
          continue;
        }
      }
      expect(port, isNotNull, reason: 'no free derived Web port on this host');

      final portal = await _startPortal(allowOrigin: 'http://localhost:$port');
      addTearDown(portal.close);

      final config = File('${temp.path}/local.json')
        ..writeAsStringSync(
          '{"ENVIRONMENT":"local","PORTAL_URL":"http://127.0.0.1:${portal.port}"}',
        );
      final launch = await prepareSanadDevWebOriginLaunch(
        configFile: config,
        cloudEndpoints: readSanadCloudEndpoints(config),
        sanadHome: home,
        cloudEnabled: true,
        processEnvironment: const {},
        clientInstanceSlot: 'web-primary',
      );

      expect(launch.isRefused, isFalse);
      expect(launch.port, isNotNull);
      expect(launch.port, inInclusiveRange(52000, 52999));
    });
  });

  test('the launcher wires the derived origin into every Web command line', () {
    // The run path and the additional-Client path are library-private, so their
    // call sites are guarded here next to the pure functions they must use.
    final packageDir = Directory.current.path.endsWith('sanad_dev')
        ? Directory.current
        : Directory('scripts/sanad_dev');

    final runSource = File(
      '${packageDir.path}/lib/src/runtime/lifecycle/runtime_run.dart',
    ).readAsStringSync();
    expect(runSource, contains('prepareSanadDevWebOriginLaunch('));
    expect(runSource, contains('applySanadDevWebPort('));
    expect(
      runSource.indexOf('prepareSanadDevWebOriginLaunch('),
      lessThan(runSource.indexOf('applySanadDevWebPort(')),
    );

    final controllerSource = File(
      '${packageDir.path}/lib/src/runtime/switch/switch_controller.dart',
    ).readAsStringSync();
    expect(controllerSource, contains('isSanadDevWebDevice('));
    expect(
      controllerSource.indexOf('assertSanadDevWebPortAvailable('),
      lessThan(controllerSource.indexOf('applySanadDevWebPort(')),
    );
  });
}

Future<HttpServer> _startPortal({required String allowOrigin}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    if (request.method != 'OPTIONS') {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    final origin = request.headers.value('origin') ?? '';
    if (origin == allowOrigin) {
      request.response.headers.set(
        HttpHeaders.accessControlAllowOriginHeader,
        origin,
      );
      request.response.headers.set(
        HttpHeaders.accessControlAllowCredentialsHeader,
        'true',
      );
      request.response.statusCode = HttpStatus.ok;
    } else {
      request.response.statusCode = HttpStatus.badRequest;
    }
    await request.response.close();
  });
  return server;
}
