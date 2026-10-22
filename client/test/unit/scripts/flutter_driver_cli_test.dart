import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../../../scripts/flutter_driver_cli/cli_runner.dart';
import '../../../../scripts/flutter_driver_cli/flutter_vm_controller.dart';
import '../../../../scripts/flutter_driver_cli/models.dart';
import '../../../../scripts/flutter_driver_cli/tree_state.dart';

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

    test('batch message-body evidence is bounded and event-scoped', () {
      final controllerSource = File(
        '../scripts/flutter_driver_cli/flutter_vm_controller.dart',
      ).readAsStringSync();

      expect(controllerSource, contains("case 'message_bodies':"));
      expect(controllerSource, contains('const maxMessageBodies = 50;'));
      expect(controllerSource, contains("startsWith('user_message_body:')"));
      expect(
        controllerSource,
        contains("startsWith('assistant_message_body:')"),
      );
      expect(controllerSource, contains("'truncated':"));
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

    test('driver does not skip layout noise widgets if explicitly keyed', () {
      final driverSource = File('lib/driver_main.dart').readAsStringSync();
      expect(
        driverSource,
        contains('// Skip layout noise widgets unless explicitly keyed'),
      );
      expect(
        driverSource,
        contains('final rawKey = key is ValueKey ? key.value.toString() : key?.toString();'),
      );
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

  group('Flutter VM driver actions', () {
    late Directory tempDir;
    late UiTreeGenerationStore generationStore;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('sanad-dev-ui-driver');
      generationStore = UiTreeGenerationStore(File('${tempDir.path}/gen'));
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('snapshot reports a monotonic generation across invocations', () async {
      final fake = await _FakeDriverVm.start();
      try {
        final first = await _runCli(
          ['snapshot', '--json', '--vm-url', fake.httpUrl],
          store: generationStore,
        );
        final second = await _runCli(
          ['snapshot', '--json', '--vm-url', fake.httpUrl],
          store: generationStore,
        );

        expect(first.code, 0);
        expect(second.code, 0);
        final firstJson = json.decode(first.lines.single);
        final secondJson = json.decode(second.lines.single);
        expect(secondJson['generation'], greaterThan(firstJson['generation']));
        expect(firstJson['fresh'], isFalse);
        expect(firstJson['signature'], isA<String>());
      } finally {
        await fake.close();
      }
    });

    test('snapshot --fresh returns a settled tree and flags it', () async {
      final fake = await _FakeDriverVm.start();
      try {
        final result = await _runCli([
          'snapshot',
          '--json',
          '--fresh',
          '--vm-url',
          fake.httpUrl,
        ], store: generationStore);

        expect(result.code, 0);
        final payload = json.decode(result.lines.single);
        expect(payload['fresh'], isTrue);
        expect(fake.inspectCalls, greaterThan(1));
      } finally {
        await fake.close();
      }
    });

    test('wait-for --key returns ok with the elapsed wait time', () async {
      final fake = await _FakeDriverVm.start(
        elements: [
          {'type': 'InkWell', 'key': 'send_message_btn', 'text': 'Send'},
        ],
      );
      try {
        final result = await _runCli([
          'wait-for',
          '--key',
          'send_message_btn',
          '--json',
          '--vm-url',
          fake.httpUrl,
        ], store: generationStore);

        expect(result.code, 0);
        final payload = json.decode(result.lines.single);
        expect(payload['success'], isTrue);
        expect(payload['verified'], 'present');
        expect(payload['data']['waited_ms'], isA<int>());
        expect(payload['duration_ms'], isA<int>());
      } finally {
        await fake.close();
      }
    });

    test('wait-for retries until a late element appears', () async {
      final fake = await _FakeDriverVm.start(
        elements: [
          {'type': 'Text', 'text': 'Idle'},
        ],
        appearAfterInspectCalls: 2,
        appearElement: {'type': 'Text', 'key': 'ready_banner'},
      );
      try {
        final result = await _runCli([
          'wait-for',
          '--key',
          'ready_banner',
          '--timeout',
          '5',
          '--json',
          '--vm-url',
          fake.httpUrl,
        ], store: generationStore);

        expect(result.code, 0);
        expect(json.decode(result.lines.single)['data']['waited_ms'], greaterThan(0));
      } finally {
        await fake.close();
      }
    });

    test('wait-for --absent fails closed on a persistent element', () async {
      final fake = await _FakeDriverVm.start(
        elements: [
          {'type': 'Text', 'key': 'stuck_banner'},
        ],
      );
      try {
        final result = await _runCli([
          'wait-for',
          '--key',
          'stuck_banner',
          '--absent',
          '--timeout',
          '1',
          '--json',
          '--vm-url',
          fake.httpUrl,
        ], store: generationStore);

        expect(result.code, 1);
        final payload = json.decode(result.lines.single);
        expect(payload['success'], isFalse);
        expect(payload['data']['waited_ms'], greaterThanOrEqualTo(1000));
      } finally {
        await fake.close();
      }
    });

    test('scroll --until-visible fails fast for an unreachable target', () async {
      final fake = await _FakeDriverVm.start(
        elements: [
          {'type': 'Text', 'key': 'visible_row'},
        ],
      );
      try {
        final started = DateTime.now();
        final result = await _runCli([
          'scroll',
          '--until-visible',
          'offscreen_row',
          '--timeout',
          '30',
          '--json',
          '--vm-url',
          fake.httpUrl,
        ], store: generationStore);

        expect(result.code, 1);
        expect(
          json.decode(result.lines.single)['message'],
          contains('target offstage/not found; navigate first'),
        );
        expect(DateTime.now().difference(started).inSeconds, lessThan(5));
      } finally {
        await fake.close();
      }
    });

    test('scroll --until-visible succeeds when the target is already visible',
        () async {
      final fake = await _FakeDriverVm.start(
        elements: [
          {
            'type': 'Text',
            'key': 'visible_row',
            'bounds': {'x': 0, 'y': 10, 'width': 20, 'height': 10},
          },
        ],
      );
      try {
        final result = await _runCli([
          'scroll',
          '--until-visible',
          'visible_row',
          '--json',
          '--vm-url',
          fake.httpUrl,
        ], store: generationStore);

        expect(result.code, 0);
        final payload = json.decode(result.lines.single);
        expect(payload['success'], isTrue);
        expect(payload['data']['attempts'], 0);
        expect(fake.scrollCalls, 0);
      } finally {
        await fake.close();
      }
    });

    test('tap reports the resolved key, coordinates, and verification', () async {
      final fake = await _FakeDriverVm.start(
        elements: [
          {'type': 'InkWell', 'key': 'send_message_btn', 'text': 'Send'},
        ],
        mutateOnTapKey: 'send_message_btn',
        tapAdds: {'type': 'Text', 'key': 'pending_banner'},
      );
      try {
        final result = await _runCli([
          'tap',
          '--key',
          'send_message_btn',
          '--json',
          '--vm-url',
          fake.httpUrl,
        ], store: generationStore);

        expect(result.code, 0);
        final payload = json.decode(result.lines.single);
        expect(payload['success'], isTrue);
        expect(payload['key'], 'send_message_btn');
        expect(payload['x'], 12);
        expect(payload['y'], 34);
        expect(payload['verified'], 'tree');
        expect(payload['generation'], isA<int>());
        expect(payload['duration_ms'], isA<int>());
      } finally {
        await fake.close();
      }
    });

    test('tap fails when the tree does not change and no expectation is given',
        () async {
      final fake = await _FakeDriverVm.start(
        elements: [
          {'type': 'InkWell', 'key': 'noop_btn', 'text': 'Noop'},
        ],
      );
      try {
        final result = await _runCli([
          'tap',
          '--key',
          'noop_btn',
          '--verify-timeout',
          '150',
          '--json',
          '--vm-url',
          fake.httpUrl,
        ], store: generationStore);

        expect(result.code, 1);
        final payload = json.decode(result.lines.single);
        expect(payload['success'], isFalse);
        expect(payload['verified'], 'none');
        expect(payload['message'], contains('--expect'));
        expect(payload['message'], contains('--no-verify'));
      } finally {
        await fake.close();
      }
    });

    test('tap --expect fails when the expected key never appears', () async {
      final fake = await _FakeDriverVm.start(
        elements: [
          {'type': 'InkWell', 'key': 'noop_btn'},
        ],
      );
      try {
        final result = await _runCli([
          'tap',
          '--key',
          'noop_btn',
          '--expect',
          'pending_banner',
          '--verify-timeout',
          '150',
          '--json',
          '--vm-url',
          fake.httpUrl,
        ], store: generationStore);

        expect(result.code, 1);
        expect(
          json.decode(result.lines.single)['message'],
          contains('expected pending_banner to be present'),
        );
      } finally {
        await fake.close();
      }
    });

    test('tap --expect passes when the expected key appears', () async {
      final fake = await _FakeDriverVm.start(
        elements: [
          {'type': 'InkWell', 'key': 'send_message_btn'},
        ],
        mutateOnTapKey: 'send_message_btn',
        tapAdds: {'type': 'Text', 'key': 'pending_banner'},
      );
      try {
        final result = await _runCli([
          'tap',
          '--key',
          'send_message_btn',
          '--expect',
          'pending_banner',
          '--json',
          '--vm-url',
          fake.httpUrl,
        ], store: generationStore);

        expect(result.code, 0);
        expect(json.decode(result.lines.single)['verified'], 'key');
      } finally {
        await fake.close();
      }
    });

    test('tap --no-verify accepts a deliberate no-op', () async {
      final fake = await _FakeDriverVm.start(
        elements: [
          {'type': 'InkWell', 'key': 'noop_btn'},
        ],
      );
      try {
        final result = await _runCli([
          'tap',
          '--key',
          'noop_btn',
          '--no-verify',
          '--json',
          '--vm-url',
          fake.httpUrl,
        ], store: generationStore);

        expect(result.code, 0);
        expect(json.decode(result.lines.single)['verified'], isNull);
      } finally {
        await fake.close();
      }
    });

    test('enter-text verifies the rendered field value without echoing it',
        () async {
      final fake = await _FakeDriverVm.start(
        elements: [
          {'type': 'TextField', 'key': 'chat_input', 'text': 'old'},
        ],
      );
      try {
        final result = await _runCli([
          'enter-text',
          '--key',
          'chat_input',
          '--text',
          'draft-message',
          '--json',
          '--vm-url',
          fake.httpUrl,
        ], store: generationStore);

        expect(result.code, 0);
        final payload = json.decode(result.lines.single);
        expect(payload['verified'], 'text');
        expect(result.lines.single, isNot(contains('draft-message')));
        expect(fake.enteredTexts, ['draft-message']);
      } finally {
        await fake.close();
      }
    });

    test('enter-text fails when an obscured field shows no observable effect',
        () async {
      final fake = await _FakeDriverVm.start(
        elements: [
          {'type': 'TextField', 'key': 'password_input'},
        ],
        obscuredKeys: {'password_input'},
      );
      try {
        final result = await _runCli([
          'enter-text',
          '--key',
          'password_input',
          '--text',
          'secret-value',
          '--verify-timeout',
          '150',
          '--json',
          '--vm-url',
          fake.httpUrl,
        ], store: generationStore);

        expect(result.code, 1);
        final payload = json.decode(result.lines.single);
        expect(payload['success'], isFalse);
        expect(payload['message'], contains('--no-verify'));
        expect(result.lines.single, isNot(contains('secret-value')));
      } finally {
        await fake.close();
      }
    });

    test('enter-text --no-verify accepts an obscured field', () async {
      final fake = await _FakeDriverVm.start(
        elements: [
          {'type': 'TextField', 'key': 'password_input'},
        ],
        obscuredKeys: {'password_input'},
      );
      try {
        final result = await _runCli([
          'enter-text',
          '--key',
          'password_input',
          '--text',
          'secret-value',
          '--no-verify',
          '--json',
          '--vm-url',
          fake.httpUrl,
        ], store: generationStore);

        expect(result.code, 0);
        expect(json.decode(result.lines.single)['verified'], isNull);
      } finally {
        await fake.close();
      }
    });

    test('batch chains an action with a wait in one call', () async {
      final fake = await _FakeDriverVm.start(
        elements: [
          {'type': 'InkWell', 'key': 'send_message_btn'},
        ],
        mutateOnTapKey: 'send_message_btn',
        tapAdds: {'type': 'Text', 'key': 'assistant_message_body:e1'},
      );
      try {
        final result = await _runCli([
          'batch',
          '--json-steps',
          json.encode([
            {'action': 'tap', 'key': 'send_message_btn'},
            {
              'action': 'wait_for',
              'key': 'assistant_message_body:e1',
              'timeout': 5,
            },
          ]),
          '--json',
          '--vm-url',
          fake.httpUrl,
        ], store: generationStore);

        expect(result.code, 0);
        final payload = json.decode(result.lines.single);
        expect(payload['total'], 2);
        expect(payload['passed'], 2);
        expect(payload['results'][1]['action'], 'wait_for');
        expect(payload['results'][1]['data']['waited_ms'], isA<int>());
      } finally {
        await fake.close();
      }
    });
  });

  group('Flutter VM driver tree state', () {
    test('signature tracks element changes but stays stable otherwise', () {
      const base = [
        UiElement(type: 'InkWell', key: 'send_message_btn', text: 'Send'),
        UiElement(type: 'Text', text: 'Hello'),
      ];
      const reordered = [
        UiElement(type: 'InkWell', key: 'send_message_btn', text: 'Send'),
        UiElement(type: 'Text', text: 'Hello'),
      ];
      const changed = [
        UiElement(type: 'InkWell', key: 'send_message_btn', text: 'Sending'),
        UiElement(type: 'Text', text: 'Hello'),
      ];

      expect(uiTreeSignature(reordered), uiTreeSignature(base));
      expect(uiTreeSignature(changed), isNot(uiTreeSignature(base)));
    });

    test('generation store increments monotonically and survives failures', () {
      final directory = Directory.systemTemp.createTempSync('sanad-dev-gen');
      try {
        final store = UiTreeGenerationStore(File('${directory.path}/gen'));
        expect(store.peek(), 0);
        expect(store.next(), 1);
        expect(store.next(), 2);
        expect(store.peek(), 2);
      } finally {
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      }

      final unwritable = UiTreeGenerationStore(File('/dev/null/gen'));
      expect(unwritable.next(), greaterThanOrEqualTo(1));
    });

    test('generation store keys only on the endpoint authority', () {
      final store = UiTreeGenerationStore.forVmServiceUrl(
        'http://127.0.0.1:51084/secret-token-value/',
      );
      expect(store.file.path, contains('127.0.0.1-51084'));
      expect(store.file.path, isNot(contains('secret-token-value')));
    });

    test('default action timeout is 30 seconds', () {
      expect(defaultActionTimeoutSeconds, 30);
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

    test('UI element round-trips enabled state and omits it when unknown', () {
      final disabled = UiElement.fromJson(const {
        'type': 'IconButton',
        'key': 'workspace_browser_rename_button:alpha',
        'enabled': false,
      });
      expect(disabled.enabled, isFalse);
      expect(disabled.toJson()['enabled'], isFalse);

      final enabled = UiElement.fromJson(const {
        'type': 'InkWell',
        'key': 'permission_option_once',
        'enabled': true,
      });
      expect(enabled.toJson()['enabled'], isTrue);

      final plain = UiElement.fromJson(const {'type': 'Text', 'text': 'Hi'});
      expect(plain.enabled, isNull);
      expect(plain.toJson().containsKey('enabled'), isFalse);
    });

    test('driver snapshots project keyed and interactive enabled state', () {
      final driverSource = File('lib/driver_main.dart').readAsStringSync();
      final inspectStart = driverSource.indexOf(
        "registerExtension('ext.sanad_client.inspect_ui'",
      );
      final inspectEnd = driverSource.indexOf(
        "registerExtension('ext.sanad_client.enter_text'",
      );
      final inspect = driverSource.substring(inspectStart, inspectEnd);
      expect(inspect, contains('inspectableElementEnabled(element)'));
      expect(inspect, contains('inspectableWidgetEnabled(widget)'));
      expect(inspect, contains("data['enabled']"));
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

Future<({int code, List<String> lines})> _runCli(
  List<String> args, {
  UiTreeGenerationStore? store,
}) async {
  final output = <String>[];
  final code = await runZoned(
    () => CliRunner(args, generationStore: store).run(),
    zoneSpecification: ZoneSpecification(
      print: (self, parent, zone, line) => output.add(line),
    ),
  );
  return (code: code, lines: output);
}

/// Stateful fake driver-enabled Client for action and verification tests.
class _FakeDriverVm {
  _FakeDriverVm._(this._server, this._elements);

  final HttpServer _server;
  final List<Map<String, dynamic>> _elements;
  final List<WebSocket> _sockets = [];

  final List<String> enteredTexts = [];
  final Set<String> obscuredKeys = {};
  String? mutateOnTapKey;
  Map<String, dynamic>? tapAdds;
  int? appearAfterInspectCalls;
  Map<String, dynamic>? appearElement;
  int inspectCalls = 0;
  int scrollCalls = 0;

  String get httpUrl => 'http://127.0.0.1:${_server.port}/tok/';

  static Future<_FakeDriverVm> start({
    List<Map<String, dynamic>>? elements,
    String? mutateOnTapKey,
    Map<String, dynamic>? tapAdds,
    int? appearAfterInspectCalls,
    Map<String, dynamic>? appearElement,
    Set<String>? obscuredKeys,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = _FakeDriverVm._(
      server,
      (elements ??
              [
                {'type': 'InkWell', 'key': 'send_message_btn', 'text': 'Send'},
              ])
          .map((element) => Map<String, dynamic>.from(element))
          .toList(),
    );
    fake.mutateOnTapKey = mutateOnTapKey;
    fake.tapAdds = tapAdds;
    fake.appearAfterInspectCalls = appearAfterInspectCalls;
    fake.appearElement = appearElement;
    if (obscuredKeys != null) fake.obscuredKeys.addAll(obscuredKeys);
    server.listen(fake._handleRequest);
    return fake;
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
            'extensionRPCs': params['isolateId'] == 'isolates/main'
                ? const [
                    'ext.sanad_client.inspect_ui',
                    'ext.sanad_client.tap',
                    'ext.sanad_client.enter_text',
                    'ext.sanad_client.scroll',
                    'ext.sanad_client.auth_url',
                  ]
                : const ['ext.unrelated'],
          };
        case 'ext.sanad_client.inspect_ui':
          inspectCalls++;
          final appearAt = appearAfterInspectCalls;
          final appeared = appearElement;
          if (appearAt != null &&
              appeared != null &&
              inspectCalls >= appearAt &&
              !_elements.any((element) => element['key'] == appeared['key'])) {
            _elements.add(Map<String, dynamic>.from(appeared));
          }
          response['result'] = {
            'elements': _elements
                .map((element) => Map<String, dynamic>.from(element))
                .toList(),
          };
        case 'ext.sanad_client.tap':
          final key = params['key'] as String?;
          if (key != null && key == mutateOnTapKey) {
            final adds = tapAdds;
            if (adds != null &&
                !_elements.any((element) => element['key'] == adds['key'])) {
              _elements.add(Map<String, dynamic>.from(adds));
            }
          }
          response['result'] = {
            'status': 'ok',
            'tapped_at': {'x': 12, 'y': 34},
          };
        case 'ext.sanad_client.enter_text':
          final key = params['key'] as String?;
          final text = params['text'] as String? ?? '';
          enteredTexts.add(text);
          if (key != null && !obscuredKeys.contains(key)) {
            for (final element in _elements) {
              if (element['key'] == key) {
                element['text'] = text;
              }
            }
          }
          response['result'] = {'status': 'ok'};
        case 'ext.sanad_client.scroll':
          scrollCalls++;
          response['result'] = {
            'status': 'ok',
            'offset': 0.0,
            'min_extent': 0.0,
            'max_extent': 100.0,
          };
        case 'ext.sanad_client.auth_url':
          response['result'] = const {
            'status': 'ok',
            'auth_url': 'https://portal.example.test/authorize',
          };
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
