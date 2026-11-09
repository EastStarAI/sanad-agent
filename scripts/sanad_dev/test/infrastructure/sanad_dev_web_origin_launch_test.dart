import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'package:sanad_dev/src/infrastructure/cloud_endpoints.dart';
import 'package:sanad_dev/src/infrastructure/web_origin.dart';

const _hostedPortal = 'https://portal.sanad.eaststarai.com';

void main() {
  group('Web command line', () {
    test('pins port and loopback host for a Web device', () {
      final arguments = <String>['flutter', 'run', '-d', 'chrome'];

      applySanadDevWebPort(arguments, device: 'chrome', port: 52043);

      expect(arguments, contains('--web-port=52043'));
      expect(arguments, contains('--web-hostname=localhost'));
    });

    test('replaces an inherited origin instead of duplicating it', () {
      final arguments = <String>[
        'flutter',
        'run',
        '-d',
        'web-server',
        '--web-port=49998',
        '--web-hostname',
        'any',
      ];

      applySanadDevWebPort(arguments, device: 'web-server', port: 52043);
      applySanadDevWebPort(arguments, device: 'web-server', port: 52043);

      expect(arguments.where((a) => a.startsWith('--web-port')), hasLength(1));
      expect(arguments, contains('--web-port=52043'));
      expect(arguments, isNot(contains('--web-port=49998')));
      expect(
        arguments.where((a) => a.startsWith('--web-hostname')),
        hasLength(1),
      );
    });

    test('leaves a native device untouched', () {
      final arguments = <String>['flutter', 'run', '-d', 'macos'];

      applySanadDevWebPort(arguments, device: 'macos', port: 52043);

      expect(arguments, ['flutter', 'run', '-d', 'macos']);
    });

    test('refuses to launch a Web device without an origin', () {
      expect(
        () => applySanadDevWebPort(
          <String>['flutter', 'run'],
          device: 'chrome',
          port: null,
        ),
        throwsStateError,
      );
    });
  });

  group('launch preparation', () {
    late Directory directory;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('sanad-dev-web-prep-');
      addTearDown(() => directory.delete(recursive: true));
    });

    Future<File> configFor({
      required String environment,
      String? portalUrl,
    }) async {
      final file = File('${directory.path}/config.json');
      await file.writeAsString(
        jsonEncode({
          'ENVIRONMENT': environment,
          if (portalUrl != null) 'PORTAL_URL': portalUrl,
        }),
      );
      return file;
    }

    test(
      'launches a hosted Portal on the derived origin with one warning',
      () async {
        final launch = await prepareSanadDevWebOriginLaunch(
          configFile: await configFor(environment: 'prod'),
          cloudEndpoints: const SanadCloudEndpoints(
            environment: 'prod',
            gatewayUrl: 'https://api.sanad.eaststarai.com',
            portalUrl: _hostedPortal,
          ),
          sanadHome: directory.path,
          processEnvironment: const {},
          portIsFree: (_) async => true,
          probePortal: (_, __) async => true,
        );

        expect(
          launch.port,
          deriveSanadDevWebPort(
            sanadHome: directory.path,
            clientEnvironment: 'prod',
          ),
          reason: 'a hosted Portal no longer changes which port is served',
        );
        expect(launch.warnings, hasLength(1));
        final warning = launch.warnings.single;
        expect(warning, contains('cannot sign in to or call'));
        expect(warning, contains('CORS'));
        expect(warning, contains('config/local.json'));
        expect(warning, contains('sanad-dev run client -d chrome'));
        expect(
          warning,
          isNot(contains('already allows')),
          reason: 'hosted CORS no longer mirrors any loopback origin',
        );
      },
    );

    test('honours an explicit override on a hosted Portal', () async {
      final launch = await prepareSanadDevWebOriginLaunch(
        configFile: await configFor(environment: 'prod'),
        cloudEndpoints: const SanadCloudEndpoints(
          environment: 'prod',
          gatewayUrl: 'https://api.sanad.eaststarai.com',
          portalUrl: _hostedPortal,
        ),
        sanadHome: directory.path,
        processEnvironment: const {sanadDevWebPortEnvironmentKey: '5173'},
        portIsFree: (_) async => true,
        probePortal: (_, __) async => false,
      );

      expect(launch.port, 5173);
      expect(launch.warnings, hasLength(1));
    });

    test('tells a local Portal exactly which origin to register', () async {
      final launch = await prepareSanadDevWebOriginLaunch(
        configFile: await configFor(environment: 'local'),
        cloudEndpoints: const SanadCloudEndpoints(
          environment: 'local',
          gatewayUrl: 'http://127.0.0.1:8000',
          portalUrl: 'http://127.0.0.1:8083',
        ),
        sanadHome: directory.path,
        processEnvironment: const {},
        probePortal: (_, __) async => false,
      );

      expect(launch.port, isNotNull);
      final warnings = launch.warnings.join('\n');
      expect(warnings, contains('SANAD_PORTAL_WEB_CLIENT_ORIGIN='));
      expect(warnings, contains('http://localhost:${launch.port}'));
    });

    test('stays quiet about registration when the Portal accepts', () async {
      final launch = await prepareSanadDevWebOriginLaunch(
        configFile: await configFor(environment: 'local'),
        cloudEndpoints: const SanadCloudEndpoints(
          environment: 'local',
          gatewayUrl: 'http://127.0.0.1:8000',
          portalUrl: 'http://127.0.0.1:8083',
        ),
        sanadHome: directory.path,
        processEnvironment: const {},
        probePortal: (_, __) async => true,
      );

      expect(launch.port, isNotNull);
      expect(launch.warnings, isEmpty);
    });

    test('launches when the Portal cannot be asked at all', () async {
      final launch = await prepareSanadDevWebOriginLaunch(
        configFile: await configFor(environment: 'local'),
        cloudEndpoints: const SanadCloudEndpoints(
          environment: 'local',
          gatewayUrl: 'http://127.0.0.1:8000',
          portalUrl: 'http://127.0.0.1:8083',
        ),
        sanadHome: directory.path,
        processEnvironment: const {},
        probePortal: (_, __) async => null,
      );

      expect(launch.port, isNotNull);
      expect(launch.warnings, isEmpty);
    });

    test('yields no origin when the environment is unreadable', () async {
      final launch = await prepareSanadDevWebOriginLaunch(
        configFile: File('${directory.path}/missing.json'),
        cloudEndpoints: null,
        sanadHome: directory.path,
        processEnvironment: const {},
        portIsFree: (_) async => true,
      );

      expect(launch.port, isNull);
      expect(launch.warnings, isNotEmpty);
    });

    test('yields no origin when the derived origin is busy', () async {
      final launch = await prepareSanadDevWebOriginLaunch(
        configFile: await configFor(environment: 'local'),
        cloudEndpoints: null,
        sanadHome: directory.path,
        processEnvironment: const {},
        portIsFree: (_) async => false,
      );

      expect(launch.port, isNull);
      expect(launch.warnings.join('\n'), contains('already in use'));
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
    late Directory directory;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp(
        'sanad-dev-web-config-',
      );
      addTearDown(() => directory.delete(recursive: true));
    });

    test('reads ENVIRONMENT and the Portal from a recorded launch', () async {
      final config = File('${directory.path}/prod.json');
      await config.writeAsString(
        jsonEncode({
          'ENVIRONMENT': 'prod',
          'PORTAL_URL': _hostedPortal,
          'BACKEND_URL': 'https://api.sanad.eaststarai.com',
        }),
      );
      final arguments = <String>[
        'flutter',
        'run',
        '--dart-define-from-file=${config.path}',
      ];

      expect(
        readSanadClientEnvironmentFromLaunchArguments(
          arguments: arguments,
          clientDirectory: directory.path,
        ),
        'prod',
      );
      final endpoints = readSanadCloudEndpointsFromLaunchArguments(
        arguments: arguments,
        clientDirectory: directory.path,
      );
      expect(endpoints?.portalUrl, _hostedPortal);
      expect(endpoints?.environment, 'prod');
    });

    test('requires ENVIRONMENT', () async {
      final config = File('${directory.path}/bare.json');
      await config.writeAsString(jsonEncode({'PORTAL_URL': _hostedPortal}));

      expect(() => readSanadClientEnvironment(config), throwsFormatException);
    });

    test('reports nothing for an unreadable launch configuration', () {
      expect(
        readSanadCloudEndpointsFromLaunchArguments(
          arguments: const ['flutter', 'run'],
          clientDirectory: directory.path,
        ),
        isNull,
      );
      expect(
        readSanadCloudEndpointsFromLaunchArguments(
          arguments: const ['--dart-define-from-file=missing.json'],
          clientDirectory: directory.path,
        ),
        isNull,
      );
    });
  });

  test('the launcher and the switch path share one origin decision', () {
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
    expect(runSource, contains('webPort: requestedWebPort'));
    expect(runSource.contains('isRefused'), isFalse);
    expect(
      runSource.indexOf('prepareSanadDevWebOriginLaunch('),
      lessThan(runSource.indexOf('applySanadDevWebPort(')),
    );

    final controllerSource = File(
      '${packageDir.path}/lib/src/runtime/switch/switch_controller.dart',
    ).readAsStringSync();
    expect(controllerSource, contains('isSanadDevWebDevice('));
    expect(controllerSource, contains('request.webPort'));
    expect(controllerSource, contains('chooseSanadDevWebPort('));
    expect(
      controllerSource.indexOf('chooseSanadDevWebPort('),
      lessThan(controllerSource.indexOf('applySanadDevWebPort(')),
    );

    final controlSource = File(
      '${packageDir.path}/lib/src/infrastructure/runtime_component_control.dart',
    ).readAsStringSync();
    expect(controlSource, contains("'web_port': webPort"));
    expect(controlSource, contains("_optionalControlInt(json['web_port'])"));
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
