import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../../../scripts/flutter_driver_cli/cli_runner.dart';
import '../../../../scripts/flutter_driver_cli/flutter_vm_controller.dart';
import '../../../../scripts/flutter_driver_cli/models.dart';

void main() {
  group('Flutter VM driver CLI', () {
    test('help does not require a running client', () async {
      expect(await CliRunner(const ['--help']).run(), 0);
    });

    test('enter-text rejects a selector value as implicit input text', () async {
      expect(
        await CliRunner(const ['enter-text', '--key', 'chat_input']).run(),
        1,
      );
    });

    test('batch reports a missing recipe before connecting', () async {
      expect(
        await CliRunner(const [
          'batch',
          '--file',
          'does-not-exist.json',
        ]).run(),
        1,
      );
    });

    test('scroll rejects contradictory terminal targets before connecting', () async {
      expect(
        await CliRunner(const [
          'scroll',
          '--to',
          'bottom',
          '--until-visible',
          'target',
        ]).run(),
        1,
      );
    });

    test('driver text entry preserves the operating system input channel', () {
      final driverSource = File('lib/driver_main.dart').readAsStringSync();
      final controllerSource = File(
        '../scripts/flutter_driver_cli/flutter_vm_controller.dart',
      ).readAsStringSync();

      expect(
        driverSource,
        contains(
          'enableFlutterDriverExtension(enableTextEntryEmulation: false)',
        ),
      );
      expect(
        driverSource,
        contains("registerExtension('ext.sanad_client.enter_text'"),
      );
      expect(
        controllerSource,
        contains("_discoverIsolateId('ext.sanad_client.enter_text')"),
      );
    });

    test('explicit VM URL wins without platform process discovery', () async {
      expect(
        await FlutterVmController.resolveVmServiceUrl(
          explicitUrl: 'http://127.0.0.1:51000/token/',
        ),
        'http://127.0.0.1:51000/token/',
      );
    });

    test('auth-url selects the isolate that advertises the extension', () async {
      const expectedUrl = 'https://portal.example.test/authorize?id=active';
      final fakeService = await _FakeVmService.start(
        extensionResult: const {'status': 'ok', 'auth_url': expectedUrl},
      );
      final controller = await FlutterVmController.connect(
        explicitUrl: fakeService.httpUrl,
        connectDriver: false,
      );
      try {
        expect(await controller.authUrl(), expectedUrl);
        expect(fakeService.authUrlIsolateIds, ['isolates/main']);
      } finally {
        await controller.close();
        await fakeService.close();
      }
    });

    test('auth-url fails when the selected VM is not driver-enabled', () async {
      final fakeService = await _FakeVmService.start(advertiseExtension: false);
      final controller = await FlutterVmController.connect(
        explicitUrl: fakeService.httpUrl,
        connectDriver: false,
      );
      try {
        await expectLater(
          controller.authUrl(),
          throwsA(
            predicate<Object>(
              (error) => error.toString().contains(
                'No Flutter isolate exposes ext.sanad_client.auth_url',
              ),
            ),
          ),
        );
      } finally {
        await controller.close();
        await fakeService.close();
      }
    });

    test('auth-url fails when the selected client has no active challenge', () async {
      final fakeService = await _FakeVmService.start(
        extensionError: 'No active authentication challenge',
      );
      final controller = await FlutterVmController.connect(
        explicitUrl: fakeService.httpUrl,
        connectDriver: false,
      );
      try {
        await expectLater(
          controller.authUrl(),
          throwsA(
            predicate<Object>(
              (error) => error.toString().contains(
                'No active authentication challenge',
              ),
            ),
          ),
        );
      } finally {
        await controller.close();
        await fakeService.close();
      }
    });

    test('auth-url rejects a non-HTTP URL without echoing it', () async {
      final fakeService = await _FakeVmService.start(
        extensionResult: const {
          'status': 'ok',
          'auth_url': 'file:///private/auth-attempt',
        },
      );
      final controller = await FlutterVmController.connect(
        explicitUrl: fakeService.httpUrl,
        connectDriver: false,
      );
      try {
        await expectLater(
          controller.authUrl(),
          throwsA(
            predicate<Object>(
              (error) =>
                  error.toString() == 'The client returned an invalid authentication URL.' &&
                  !error.toString().contains('private/auth-attempt'),
            ),
          ),
        );
      } finally {
        await controller.close();
        await fakeService.close();
      }
    });

    test('auth-url command prints only the active URL in human mode', () async {
      const expectedUrl = 'https://portal.example.test/authorize?id=current';
      final fakeService = await _FakeVmService.start(
        extensionResult: const {'status': 'ok', 'auth_url': expectedUrl},
      );
      final output = <String>[];
      try {
        final code = await runZoned(
          () => CliRunner([
            'auth-url',
            '--vm-url',
            fakeService.httpUrl,
          ]).run(),
          zoneSpecification: ZoneSpecification(
            print: (self, parent, zone, line) => output.add(line),
          ),
        );
        expect(code, 0);
        expect(output, [expectedUrl]);
      } finally {
        await fakeService.close();
      }
    });

    test('auth-url JSON mode emits one parseable value', () async {
      const expectedUrl = 'https://portal.example.test/authorize?id=json';
      final fakeService = await _FakeVmService.start(
        extensionResult: const {'status': 'ok', 'auth_url': expectedUrl},
      );
      final output = <String>[];
      try {
        final code = await runZoned(
          () => CliRunner([
            'auth-url',
            '--json',
            '--vm-url',
            fakeService.httpUrl,
          ]).run(),
          zoneSpecification: ZoneSpecification(
            print: (self, parent, zone, line) => output.add(line),
          ),
        );
        expect(code, 0);
        expect(output, hasLength(1));
        expect(json.decode(output.single), {
          'status': 'ok',
          'auth_url': expectedUrl,
        });
      } finally {
        await fakeService.close();
      }
    });

    test('driver suppresses Flutter autogenerated text keys', () {
      final driverSource = File('lib/driver_main.dart').readAsStringSync();
      expect(driverSource, contains("trimmed.startsWith('[#')"));
    });

    test('driver authentication URL stays outside UI snapshots', () {
      final driverSource = File('lib/driver_main.dart').readAsStringSync();
      expect(
        driverSource,
        contains("registerExtension('ext.sanad_client.auth_url'"),
      );
      final inspectStart = driverSource.indexOf(
        "registerExtension('ext.sanad_client.inspect_ui'",
      );
      final inspectEnd = driverSource.indexOf(
        "registerExtension('ext.sanad_client.enter_text'",
      );
      expect(
        driverSource.substring(inspectStart, inspectEnd),
        isNot(contains('auth_url')),
      );
    });
  });

  group('Flutter VM driver models', () {
    test('UI matching covers agent-facing labels', () {
      const element = UiElement(
        type: 'IconButton',
        key: 'send_message_btn',
        tooltip: 'Send message',
        semanticsLabel: 'Submit conversation message',
        selected: true,
        button: true,
      );

      expect(element.matches(keyFilter: 'send_message_btn'), isTrue);
      expect(element.matches(query: 'send message'), isTrue);
      expect(element.matches(query: 'submit conversation'), isTrue);
      expect(element.matches(typeFilter: 'Button'), isTrue);
      expect(element.matches(textFilter: 'Send message'), isFalse);
      expect(element.toJson()['selected'], isTrue);
      expect(element.toJson()['button'], isTrue);
    });

    test('batch step accepts documented aliases', () {
      final step = BatchStep.fromJson(const {
        'action': 'scroll',
        'until_visible': 'conversation-row',
        'timeout': 9,
        'delay': 25,
        'within': 'conversation-list',
        'index': 2,
        'continue_on_error': true,
      });

      expect(step.action, 'scroll');
      expect(step.untilVisibleKey, 'conversation-row');
      expect(step.timeoutSeconds, 9);
      expect(step.delayMs, 25);
      expect(step.within, 'conversation-list');
      expect(step.index, 2);
      expect(step.continueOnError, isTrue);
    });
  });
}

class _FakeVmService {
  _FakeVmService._(
    this._server, {
    required this.extensionResult,
    required this.extensionError,
    required this.advertiseExtension,
  });

  final HttpServer _server;
  final Map<String, dynamic>? extensionResult;
  final String? extensionError;
  final bool advertiseExtension;
  final List<WebSocket> _sockets = [];
  final List<String> authUrlIsolateIds = [];

  String get httpUrl => 'http://127.0.0.1:${_server.port}/';

  static Future<_FakeVmService> start({
    Map<String, dynamic>? extensionResult,
    String? extensionError,
    bool advertiseExtension = true,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final service = _FakeVmService._(
      server,
      extensionResult: extensionResult,
      extensionError: extensionError,
      advertiseExtension: advertiseExtension,
    );
    server.listen(service._handleRequest);
    return service;
  }

  Future<void> _handleRequest(HttpRequest request) async {
    if (!WebSocketTransformer.isUpgradeRequest(request)) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    final socket = await WebSocketTransformer.upgrade(request);
    _sockets.add(socket);
    socket.listen((message) {
      final rpc = json.decode(message as String) as Map<String, dynamic>;
      final method = rpc['method'] as String;
      final params = Map<String, dynamic>.from(rpc['params'] as Map? ?? {});
      final response = <String, dynamic>{'jsonrpc': '2.0', 'id': rpc['id']};

      switch (method) {
        case 'getVM':
          response['result'] = {
            'isolates': [
              {'id': 'isolates/background'},
              {'id': 'isolates/main'},
            ],
          };
        case 'getIsolate':
          response['result'] = {
            'extensionRPCs': advertiseExtension && params['isolateId'] == 'isolates/main'
                ? ['ext.sanad_client.auth_url']
                : ['ext.unrelated'],
          };
        case 'ext.sanad_client.auth_url':
          authUrlIsolateIds.add(params['isolateId'] as String);
          if (extensionError != null) {
            response['error'] = {
              'code': -32000,
              'message': 'Service extension failed',
              'data': {
                'details': json.encode({'error': extensionError}),
              },
            };
          } else {
            response['result'] = extensionResult;
          }
        default:
          response['error'] = {
            'code': -32601,
            'message': 'Method not found',
          };
      }
      socket.add(json.encode(response));
    });
  }

  Future<void> close() async {
    for (final socket in _sockets) {
      await socket.close();
    }
    await _server.close(force: true);
  }
}
