import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/driver/ui_type_census.dart';

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

    test('snapshot --fresh reports an unsettled tree', () async {
      final fake = await _FakeDriverVm.start(mutateOnInspect: true);
      try {
        final result = await _runCli([
          'snapshot',
          '--json',
          '--fresh',
          '--timeout',
          '1',
          '--vm-url',
          fake.httpUrl,
        ], store: generationStore);

        expect(result.code, 0);
        final payload = json.decode(result.lines.single);
        expect(payload['fresh'], isTrue);
        expect(payload['settled'], isFalse);
      } finally {
        await fake.close();
      }
    });

    test('only a cold artifact call reports the compile cost as build_ms',
        () async {
      final fake = await _FakeDriverVm.start();
      try {
        final warm = await _runCli([
          'snapshot',
          '--json',
          '--vm-url',
          fake.httpUrl,
        ], store: generationStore);
        final cold = await _runCli([
          'snapshot',
          '--json',
          '--vm-url',
          fake.httpUrl,
        ], store: generationStore, buildMs: 2299);

        // A cached artifact has nothing to report, so the field stays absent
        // rather than being charged to every call.
        expect(json.decode(warm.lines.single).containsKey('build_ms'), isFalse);
        expect(json.decode(cold.lines.single)['build_ms'], 2299);
      } finally {
        await fake.close();
      }
    });

    test('generation store follows the resolved endpoint', () async {
      final fake = await _FakeDriverVm.start();
      try {
        final first = await _runCli([
          'snapshot',
          '--json',
          '--vm-url',
          fake.httpUrl,
        ], generationRoot: tempDir);
        final second = await _runCli([
          'snapshot',
          '--json',
          '--vm-url',
          fake.httpUrl,
        ], generationRoot: tempDir);

        expect(first.code, 0);
        expect(second.code, 0);
        final files = tempDir
            .listSync()
            .whereType<File>()
            .map((file) => file.uri.pathSegments.last)
            .where((name) => name.endsWith('.generation'))
            .toList();
        expect(files, ['127.0.0.1-${fake.port}.generation']);
        expect(
          json.decode(second.lines.single)['generation'],
          greaterThan(json.decode(first.lines.single)['generation']),
        );
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
        expect(payload['verified'], isTrue);
        expect(payload['verification'], 'present');
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
        // The failure states what was observed instead of reporting a timeout.
        expect(payload['message'], isNot(contains('Timed out')));
        expect(payload['message'], contains('stuck_banner is still present'));
        expect(payload['message'], contains('absence not observed'));
        expect(payload['data']['probes'], greaterThan(1));
      } finally {
        await fake.close();
      }
    });

    test('wait-for --type --absent uses the rendered type census', () async {
      final fake = await _FakeDriverVm.start(
        elements: [
          {'type': 'Text', 'key': 'idle_label'},
        ],
        typeCensusTypes: ['Column', 'Text', 'InkWell'],
      );
      try {
        final result = await _runCli([
          'wait-for',
          '--type',
          'CircularProgressIndicator',
          '--absent',
          '--timeout',
          '2',
          '--json',
          '--vm-url',
          fake.httpUrl,
        ], store: generationStore);

        expect(result.code, 0);
        final payload = json.decode(result.lines.single);
        expect(payload['success'], isTrue);
        expect(payload['verified'], isTrue);
        expect(payload['verification'], 'absent');
        expect(payload['data']['evidence'], 'type_census');
      } finally {
        await fake.close();
      }
    });

    test('wait-for --type --absent fails when only the census sees the type',
        () async {
      // CircularProgressIndicator carries no key, text, or interaction, so the
      // inspected tree omits it; treating it as absent would be a false pass.
      final fake = await _FakeDriverVm.start(
        elements: [
          {'type': 'Text', 'key': 'idle_label'},
        ],
        typeCensusTypes: ['Column', 'CircularProgressIndicator', 'Text'],
      );
      try {
        final result = await _runCli([
          'wait-for',
          '--type',
          'CircularProgressIndicator',
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
        // The message must name the evidence, never report a bare timeout.
        expect(payload['message'], isNot(contains('Timed out')));
        expect(
          payload['message'],
          contains('is still rendered (proven by the rendered type census)'),
        );
        expect(payload['message'], contains('absence not observed'));
        expect(payload['message'], contains('--no-wait'));
        expect(payload['verified'], isFalse);
        expect(payload['verification'], 'type_census');
        expect(payload['data']['evidence'], 'type_census');
        expect(payload['data']['still_rendered'], isTrue);
        expect(payload['data']['waited_ms'], greaterThanOrEqualTo(1000));
      } finally {
        await fake.close();
      }
    });

    test('wait-for --type --absent keeps polling until the type disappears',
        () async {
      // A rendered spinner is not a verdict: it can finish. The poll must keep
      // going and then report the absence it actually observed.
      final fake = await _FakeDriverVm.start(
        elements: [
          {'type': 'Text', 'key': 'idle_label'},
        ],
        typeCensusSequence: const [
          ['Column', 'CircularProgressIndicator', 'Text'],
          ['Column', 'CircularProgressIndicator', 'Text'],
          ['Column', 'Text'],
        ],
      );
      try {
        final result = await _runCli([
          'wait-for',
          '--type',
          'CircularProgressIndicator',
          '--absent',
          '--timeout',
          '5',
          '--json',
          '--vm-url',
          fake.httpUrl,
        ], store: generationStore);

        expect(result.code, 0);
        final payload = json.decode(result.lines.single);
        expect(payload['success'], isTrue);
        expect(payload['verified'], isTrue);
        expect(payload['verification'], 'absent');
        expect(payload['data']['evidence'], 'type_census');
        expect(fake.typeCensusCalls, greaterThanOrEqualTo(3));
      } finally {
        await fake.close();
      }
    });

    test('wait-for --type --absent --no-wait judges the first census',
        () async {
      final fake = await _FakeDriverVm.start(
        elements: [
          {'type': 'Text', 'key': 'idle_label'},
        ],
        typeCensusTypes: ['Column', 'CircularProgressIndicator', 'Text'],
      );
      try {
        final started = DateTime.now();
        final result = await _runCli([
          'wait-for',
          '--type',
          'CircularProgressIndicator',
          '--absent',
          '--no-wait',
          '--timeout',
          '30',
          '--json',
          '--vm-url',
          fake.httpUrl,
        ], store: generationStore);

        expect(result.code, 1);
        final payload = json.decode(result.lines.single);
        expect(payload['verified'], isFalse);
        expect(payload['verification'], 'type_census');
        expect(payload['data']['still_rendered'], isTrue);
        expect(payload['data']['waited_ms'], lessThan(5000));
        expect(
          payload['message'],
          contains('a single check'),
        );
        expect(payload['message'], contains('absence not observed'));
        expect(DateTime.now().difference(started).inSeconds, lessThan(6));
        expect(fake.typeCensusCalls, 1);
      } finally {
        await fake.close();
      }
    });

    test('wait-for --type fails fast for a rendered but uninspected type',
        () async {
      final fake = await _FakeDriverVm.start(
        elements: [
          {'type': 'Text', 'key': 'idle_label'},
        ],
        typeCensusTypes: ['CircularProgressIndicator', 'Text'],
      );
      try {
        final started = DateTime.now();
        final result = await _runCli([
          'wait-for',
          '--type',
          'CircularProgressIndicator',
          '--timeout',
          '30',
          '--json',
          '--vm-url',
          fake.httpUrl,
        ], store: generationStore);

        expect(result.code, 1);
        final payload = json.decode(result.lines.single);
        expect(payload['message'], contains('is not inspected'));
        expect(payload['message'], isNot(contains('Timed out')));
        expect(payload['verified'], isFalse);
        expect(payload['verification'], 'type_census');
        expect(payload['data']['evidence'], 'type_census');
        expect(payload['data']['still_rendered'], isTrue);
        expect(DateTime.now().difference(started).inSeconds, lessThan(5));
      } finally {
        await fake.close();
      }
    });

    test('wait-for --type --absent never passes on a truncated census',
        () async {
      final fake = await _FakeDriverVm.start(
        elements: [
          {'type': 'Text', 'key': 'idle_label'},
        ],
        typeCensusTypes: ['Column', 'Text'],
        typeCensusTruncated: true,
        typeCensusVisitedElements: 20000,
      );
      try {
        final result = await _runCli([
          'wait-for',
          '--type',
          'CircularProgressIndicator',
          '--absent',
          '--timeout',
          '2',
          '--json',
          '--vm-url',
          fake.httpUrl,
        ], store: generationStore);

        expect(result.code, 1);
        final payload = json.decode(result.lines.single);
        // Truncation is a census fact, not a slow-Client timeout: waiting
        // longer would never make the walk complete.
        expect(payload['message'], contains('type census truncated'));
        expect(payload['message'], contains('20000-element bound'));
        expect(payload['message'], isNot(contains('Timed out')));
        expect(payload['data']['census_truncated'], isTrue);
        expect(payload['data']['census_visited_elements'], 20000);
      } finally {
        await fake.close();
      }
    });

    test('type census bounds the element walk, never the distinct types', () {
      // A real Client legitimately renders hundreds of distinct widget types.
      // A cap on the distinct type set would mark every such tree truncated and
      // make every absence claim unprovable, so the bound belongs on the walk.
      final root = _CensusNode(
        'Root',
        List.generate(499, (index) => _CensusNode('WidgetType$index')),
      );

      final census = boundedRenderedTypeCensus<_CensusNode>(
        root: root,
        label: (node) => node.label,
        children: (node) => node.children,
      );

      expect(census.types, hasLength(500));
      expect(census.visitedElements, 500);
      expect(census.truncated, isFalse);
    });

    test('type census truncates when the element walk exceeds its bound', () {
      final root = _CensusNode(
        'Root',
        List.generate(20, (index) => _CensusNode('WidgetType$index')),
      );

      final census = boundedRenderedTypeCensus<_CensusNode>(
        root: root,
        label: (node) => node.label,
        children: (node) => node.children,
        maxElements: 5,
      );

      expect(census.visitedElements, 5);
      expect(census.types.length, lessThanOrEqualTo(5));
      expect(census.truncated, isTrue);
    });

    test('type census de-duplicates repeated rendered types', () {
      final root = _CensusNode(
        'Root',
        List.generate(40, (_) => _CensusNode('Text')),
      );

      final census = boundedRenderedTypeCensus<_CensusNode>(
        root: root,
        label: (node) => node.label,
        children: (node) => node.children,
      );

      expect(census.types, ['Root', 'Text']);
      expect(census.visitedElements, 41);
      expect(census.truncated, isFalse);
    });

    test('scroll --until-visible fails fast for an unreachable target', () async {      final fake = await _FakeDriverVm.start(
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
        expect(payload['verified'], isTrue);
        expect(payload['verification'], 'tree');
        expect(payload['generation'], isA<int>());
        expect(payload['duration_ms'], isA<int>());
      } finally {
        await fake.close();
      }
    });

    test('plain tap reports no observable change without failing', () async {
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

        expect(result.code, 0);
        final payload = json.decode(result.lines.single);
        expect(payload['success'], isTrue);
        expect(payload['verified'], isFalse);
        expect(payload['verification'], 'no_observable_change');
        expect(
          payload['message'],
          contains('tap dispatched; no observable change'),
        );
        expect(payload['message'], contains('do not retry blindly'));
      } finally {
        await fake.close();
      }
    });

    test('tap --verify fails when the tree does not change', () async {
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
          '--verify',
          '--verify-timeout',
          '150',
          '--json',
          '--vm-url',
          fake.httpUrl,
        ], store: generationStore);

        expect(result.code, 1);
        final payload = json.decode(result.lines.single);
        expect(payload['success'], isFalse);
        expect(payload['verified'], isFalse);
        // The same physical outcome as the plain tap: --verify changes the exit
        // status, never the evidence channel.
        expect(payload['verification'], 'no_observable_change');
        expect(
          payload['message'],
          contains('tap dispatched; no observable change'),
        );
        expect(payload['message'], contains('--expect'));
      } finally {
        await fake.close();
      }
    });

    test('tap captures its baseline after the reveal scroll', () async {
      // The reveal step simulates the extension's auto-scroll: it moves the
      // target bounds. The tap itself changes nothing, so verification must
      // report no change instead of crediting the scroll to the tap.
      final fake = await _FakeDriverVm.start(
        elements: [
          {
            'type': 'InkWell',
            'key': 'scroll_row',
            'bounds': {'x': 0, 'y': 900, 'width': 100, 'height': 40},
          },
        ],
        revealScrollsTo: 0,
      );
      try {
        final result = await _runCli([
          'tap',
          '--key',
          'scroll_row',
          '--verify-timeout',
          '150',
          '--json',
          '--vm-url',
          fake.httpUrl,
        ], store: generationStore);

        expect(result.code, 0);
        final payload = json.decode(result.lines.single);
        expect(payload['verified'], isFalse);
        expect(payload['verification'], 'no_observable_change');
        // Reveal must run before the baseline capture, which must precede tap.
        expect(fake.rpcOrder.take(3), ['reveal', 'inspect', 'tap']);
      } finally {
        await fake.close();
      }
    });

    test('tap on an older Client reports the auto-scroll caveat on success',
        () async {
      // A Client without the reveal extension still taps and verifies, but the
      // verified change may be an auto-scroll rather than the action, so the
      // success path must carry the same caveat the failure path carries.
      final fake = await _FakeDriverVm.start(
        elements: [
          {'type': 'InkWell', 'key': 'send_message_btn'},
        ],
        mutateOnTapKey: 'send_message_btn',
        tapAdds: {'type': 'Text', 'key': 'assistant_message_body:e1'},
        revealAvailable: false,
      );
      try {
        final result = await _runCli([
          'tap',
          '--key',
          'send_message_btn',
          '--expect',
          'assistant_message_body:e1',
          '--json',
          '--vm-url',
          fake.httpUrl,
        ], store: generationStore);

        expect(result.code, 0);
        final payload = json.decode(result.lines.single);
        expect(payload['success'], isTrue);
        expect(payload['verified'], isTrue);
        expect(payload['verification'], 'key');
        expect(payload['message'], contains('auto-scroll'));
        expect(fake.rpcOrder, isNot(contains('reveal')));
      } finally {
        await fake.close();
      }
    });

    test('tap on a newer Client stays free of the auto-scroll caveat', () async {
      final fake = await _FakeDriverVm.start(
        elements: [
          {'type': 'InkWell', 'key': 'send_message_btn'},
        ],
        mutateOnTapKey: 'send_message_btn',
        tapAdds: {'type': 'Text', 'key': 'assistant_message_body:e1'},
      );
      try {
        final result = await _runCli([
          'tap',
          '--key',
          'send_message_btn',
          '--expect',
          'assistant_message_body:e1',
          '--json',
          '--vm-url',
          fake.httpUrl,
        ], store: generationStore);

        expect(result.code, 0);
        final payload = json.decode(result.lines.single);
        expect(payload['verified'], isTrue);
        expect(payload['verification'], 'key');
        expect(payload['message'], isNot(contains('auto-scroll')));
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
        final payload = json.decode(result.lines.single);
        expect(payload['verified'], isTrue);
        expect(payload['verification'], 'key');
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
        final payload = json.decode(result.lines.single);
        // Both fields stay present and typed even when observation was skipped.
        expect(payload['verified'], isFalse);
        expect(payload['verification'], 'none');
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
        expect(payload['verified'], isTrue);
        expect(payload['verification'], 'text');
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

    test('enter-text verifies an obscured field by its tree change', () async {
      final fake = await _FakeDriverVm.start(
        elements: [
          {'type': 'TextField', 'key': 'password_input'},
        ],
        obscuredKeys: {'password_input'},
        enterTextAdds: {
          'password_input': {'type': 'Text', 'key': 'caps_lock_warning'},
        },
      );
      try {
        final result = await _runCli([
          'enter-text',
          '--key',
          'password_input',
          '--text',
          'secret-value',
          '--verify-timeout',
          '400',
          '--json',
          '--vm-url',
          fake.httpUrl,
        ], store: generationStore);

        expect(result.code, 0);
        final payload = json.decode(result.lines.single);
        expect(payload['success'], isTrue);
        expect(payload['verified'], isTrue);
        expect(payload['verification'], 'tree');
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
        final payload = json.decode(result.lines.single);
        expect(payload['verified'], isFalse);
        expect(payload['verification'], 'none');
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
        // Every step result keeps the typed contract, so a recipe consumer can
        // validate results without knowing which action produced them.
        for (final step in payload['results']) {
          expect(step['verified'], isA<bool>());
          expect(UiVerification.wireValues, contains(step['verification']));
        }
        expect(payload['results'][1]['verified'], isTrue);
        expect(payload['results'][1]['verification'], 'present');
      } finally {
        await fake.close();
      }
    });

    test('batch wait_for can judge the first census instead of waiting',
        () async {
      final fake = await _FakeDriverVm.start(
        elements: [
          {'type': 'Text', 'key': 'idle_label'},
        ],
        typeCensusTypes: ['Column', 'CircularProgressIndicator', 'Text'],
      );
      try {
        final started = DateTime.now();
        final result = await _runCli([
          'batch',
          '--json-steps',
          json.encode([
            {
              'action': 'wait_for',
              'type': 'CircularProgressIndicator',
              'absent': true,
              'no_wait': true,
              'timeout': 30,
            },
          ]),
          '--json',
          '--vm-url',
          fake.httpUrl,
        ], store: generationStore);

        expect(result.code, 1);
        final payload = json.decode(result.lines.single);
        final step = payload['results'][0];
        expect(step['verified'], isFalse);
        expect(step['verification'], 'type_census');
        expect(step['data']['still_rendered'], isTrue);
        expect(DateTime.now().difference(started).inSeconds, lessThan(6));
      } finally {
        await fake.close();
      }
    });
    test('batch persists each completed step to the report file', () async {
      final fake = await _FakeDriverVm.start(
        elements: [
          {'type': 'InkWell', 'key': 'send_message_btn'},
        ],
        mutateOnTapKey: 'send_message_btn',
        tapAdds: {'type': 'Text', 'key': 'assistant_message_body:e1'},
      );
      final report = '${tempDir.path}/batch-report.json';
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
          '--report-file',
          report,
          '--json',
          '--vm-url',
          fake.httpUrl,
        ], store: generationStore);

        expect(result.code, 0);
        final payload = json.decode(File(report).readAsStringSync());
        expect(payload['steps_total'], 2);
        expect(payload['completed'], 2);
        expect(payload['results'], hasLength(2));
      } finally {
        await fake.close();
      }
    });

    test('batch stops at a failed step and keeps the completed evidence',
        () async {
      final fake = await _FakeDriverVm.start(
        elements: [
          {'type': 'Text', 'key': 'idle_label', 'text': 'Idle'},
        ],
      );
      final report = '${tempDir.path}/batch-report-failed.json';
      try {
        final result = await _runCli([
          'batch',
          '--json-steps',
          json.encode([
            {
              'action': 'wait_for',
              'text': 'Idle',
              'timeout': 2,
            },
            {
              'action': 'wait_for',
              'key': 'never_present',
              'timeout': 1,
            },
          ]),
          '--report-file',
          report,
          '--json',
          '--vm-url',
          fake.httpUrl,
        ], store: generationStore);

        expect(result.code, 1);
        final payload = json.decode(File(report).readAsStringSync());
        expect(payload['steps_total'], 2);
        expect(payload['completed'], 2);
        expect(payload['results'][0]['success'], isTrue);
        expect(payload['results'][1]['success'], isFalse);
      } finally {
        await fake.close();
      }
    });

    test('batch --timeout is the deadline a step without a timeout runs under',
        () async {
      // The launcher budgets the whole recipe with the batch --timeout, so the
      // driver must apply the same value instead of a hidden 30 s default.
      final fake = await _FakeDriverVm.start(
        elements: [
          {'type': 'Text', 'key': 'idle_label', 'text': 'Idle'},
        ],
      );
      try {
        final started = DateTime.now();
        final result = await _runCli([
          'batch',
          '--timeout',
          '1',
          '--json-steps',
          json.encode([
            {'action': 'wait_for', 'key': 'never_present'},
          ]),
          '--json',
          '--vm-url',
          fake.httpUrl,
        ], store: generationStore);

        expect(result.code, 1);
        final payload = json.decode(result.lines.single);
        final waited = payload['results'][0]['data']['waited_ms'] as int;
        expect(waited, greaterThanOrEqualTo(900));
        expect(waited, lessThan(5000));
        expect(DateTime.now().difference(started).inSeconds, lessThan(6));
      } finally {
        await fake.close();
      }
    });

    test('batch keeps a step deadline longer than its own timeout', () async {
      // The step owns a longer deadline than the batch default, and its first
      // inspection is slower than that default. The transport timeout must
      // follow the longest step, or a slow RPC is misreported as a failure.
      final fake = await _FakeDriverVm.start(
        elements: [
          {'type': 'Text', 'key': 'idle_label', 'text': 'Idle'},
        ],
        inspectDelayMs: 1200,
      );
      try {
        final result = await _runCli([
          'batch',
          '--timeout',
          '1',
          '--json-steps',
          json.encode([
            {'action': 'wait_for', 'key': 'idle_label', 'timeout': 15},
          ]),
          '--json',
          '--vm-url',
          fake.httpUrl,
        ], store: generationStore);

        expect(result.code, 0);
        expect(json.decode(result.lines.single)['passed'], 1);
      } finally {
        await fake.close();
      }
    });

    test('batch transport timeout covers the longest step deadline', () {
      const defaultStepTimeout = Duration(seconds: 5);

      // A step without a timeout inherits the batch deadline.
      expect(
        batchStepTimeout(
          const BatchStep(action: 'wait_for'),
          defaultStepTimeout,
        ),
        defaultStepTimeout,
      );
      // A step with its own timeout keeps it, even above the batch default.
      expect(
        batchRpcTimeout(
          const [
            BatchStep(action: 'wait_for'),
            BatchStep(action: 'tap', timeoutSeconds: 60),
          ],
          defaultStepTimeout,
        ),
        const Duration(seconds: 60),
      );
      expect(
        batchRpcTimeout(
          const [BatchStep(action: 'wait_for')],
          defaultStepTimeout,
        ),
        defaultStepTimeout,
      );
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
    test('verified is a boolean and verification is a documented channel', () {
      // A strict consumer types both fields. `verified` is never the channel
      // name, and `verification` is never outside the published set.
      expect(UiVerification.wireValues, [
        'key',
        'present',
        'absent',
        'text',
        'tree',
        'no_observable_change',
        'none',
        'type_census',
      ]);

      for (final channel in UiVerification.values) {
        final payload = DriverActionResult(
          success: channel.verified,
          action: 'wait_for',
          message: 'probe',
          duration: Duration.zero,
          verification: channel,
        ).toJson();

        expect(payload['verified'], isA<bool>());
        expect(payload['verified'], channel.verified);
        expect(payload['verification'], isA<String>());
        expect(UiVerification.wireValues, contains(payload['verification']));
        expect(UiVerification.fromWire(payload['verification'] as String), channel);
      }

      expect(UiVerification.fromWire('verified'), isNull);
      expect(
        UiVerification.values.where((channel) => channel.verified).toSet(),
        {
          UiVerification.key,
          UiVerification.present,
          UiVerification.absent,
          UiVerification.text,
          UiVerification.tree,
        },
      );
    });

    test('an action result always carries both fields', () {
      final payload = const DriverActionResult(
        success: true,
        action: 'snapshot',
        message: 'Extracted 0 UI elements',
        duration: Duration.zero,
        verification: UiVerification.none,
      ).toJson();

      expect(payload.containsKey('verified'), isTrue);
      expect(payload.containsKey('verification'), isTrue);
      expect(payload['verified'], isFalse);
      expect(payload['verification'], 'none');
    });

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

    test('driver exposes reveal and the rendered type census', () {
      final driverSource = File('lib/driver_main.dart').readAsStringSync();
      expect(
        driverSource,
        contains("registerExtension('ext.sanad_client.reveal'"),
      );
      expect(driverSource, contains("parameters['typeCensus'] == 'true'"));
      expect(driverSource, contains('boundedRenderedTypeCensus<Element>'));
      expect(driverSource, contains("'visited_elements': census.visitedElements"));
      // The census must be bounded by its walk: a distinct-type cap marks any
      // large tree truncated and makes every absence claim unprovable.
      expect(driverSource, isNot(contains('maxCensusTypes')));
      expect(driverSource, isNot(contains('types.length >')));
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
  Directory? generationRoot,
  int? buildMs,
}) async {
  final output = <String>[];
  final code = await runZoned(
    () => CliRunner(
      args,
      generationStore: store,
      generationRoot: generationRoot,
      buildMs: buildMs,
    ).run(),
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
  final Map<String, Map<String, dynamic>> enterTextAdds = {};

  /// Ordered record of driver RPCs, used to prove reveal-before-capture.
  final List<String> rpcOrder = [];

  String? mutateOnTapKey;
  Map<String, dynamic>? tapAdds;
  int? appearAfterInspectCalls;
  Map<String, dynamic>? appearElement;
  bool mutateOnInspect = false;

  /// When set, a reveal step moves the element at this index to this y value,
  /// simulating the auto-scroll that must not count as the tap's effect.
  int? revealScrollsTo;

  /// False models an older Client whose isolate does not advertise
  /// `ext.sanad_client.reveal`.
  bool revealAvailable = true;

  /// Delays a non-census inspection, modelling a Client slower than a short
  /// batch default so the transport timeout is observable.
  int inspectDelayMs = 0;
  List<String> typeCensusTypes = const [];

  /// Per-call census payloads, so a test can model a type that stops being
  /// rendered. The last entry repeats once the sequence is exhausted.
  List<List<String>>? typeCensusSequence;
  bool typeCensusTruncated = false;
  int? typeCensusVisitedElements;
  int inspectCalls = 0;
  int typeCensusCalls = 0;
  int scrollCalls = 0;

  int get port => _server.port;

  String get httpUrl => 'http://127.0.0.1:${_server.port}/tok/';

  static Future<_FakeDriverVm> start({
    List<Map<String, dynamic>>? elements,
    String? mutateOnTapKey,
    Map<String, dynamic>? tapAdds,
    int? appearAfterInspectCalls,
    Map<String, dynamic>? appearElement,
    Set<String>? obscuredKeys,
    Map<String, Map<String, dynamic>>? enterTextAdds,
    int? revealScrollsTo,
    List<String>? typeCensusTypes,
    List<List<String>>? typeCensusSequence,
    bool typeCensusTruncated = false,
    int? typeCensusVisitedElements,
    bool revealAvailable = true,
    int inspectDelayMs = 0,
    bool mutateOnInspect = false,
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
    fake.revealScrollsTo = revealScrollsTo;
    fake.typeCensusTypes = typeCensusTypes ?? const [];
    fake.typeCensusSequence = typeCensusSequence;
    fake.typeCensusTruncated = typeCensusTruncated;
    fake.typeCensusVisitedElements = typeCensusVisitedElements;
    fake.revealAvailable = revealAvailable;
    fake.inspectDelayMs = inspectDelayMs;
    fake.mutateOnInspect = mutateOnInspect;
    if (obscuredKeys != null) fake.obscuredKeys.addAll(obscuredKeys);
    if (enterTextAdds != null) fake.enterTextAdds.addAll(enterTextAdds);
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
                ? [
                    'ext.sanad_client.inspect_ui',
                    'ext.sanad_client.tap',
                    if (revealAvailable) 'ext.sanad_client.reveal',
                    'ext.sanad_client.enter_text',
                    'ext.sanad_client.scroll',
                    'ext.sanad_client.auth_url',
                  ]
                : const ['ext.unrelated'],
          };
        case 'ext.sanad_client.inspect_ui':
          rpcOrder.add('inspect');
          inspectCalls++;
          if (params['typeCensus'] == 'true') {
            typeCensusCalls++;
            final sequence = typeCensusSequence;
            final types = sequence == null || sequence.isEmpty
                ? typeCensusTypes
                : sequence[typeCensusCalls - 1 < sequence.length
                      ? typeCensusCalls - 1
                      : sequence.length - 1];
            response['result'] = {
              'status': 'ok',
              'types': types,
              'type_count': types.length,
              'truncated': typeCensusTruncated,
              'visited_elements': typeCensusVisitedElements ?? types.length,
            };
            break;
          }
          final appearAt = appearAfterInspectCalls;
          final appeared = appearElement;
          if (appearAt != null &&
              appeared != null &&
              inspectCalls >= appearAt &&
              !_elements.any((element) => element['key'] == appeared['key'])) {
            _elements.add(Map<String, dynamic>.from(appeared));
          }
          if (mutateOnInspect) {
            for (final element in _elements) {
              if (element['key'] == 'idle_label' ||
                  element['text'] != null) {
                element['text'] =
                    'tick-${DateTime.now().microsecondsSinceEpoch}-${_elements.length}';
                break;
              }
            }
          }
          response['result'] = {
            'elements': _elements
                .map((element) => Map<String, dynamic>.from(element))
                .toList(),
          };
        case 'ext.sanad_client.reveal':
          rpcOrder.add('reveal');
          if (!revealAvailable) {
            response['error'] = {'code': -32601, 'message': 'Method not found'};
            break;
          }
          final revealIndex = revealScrollsTo;
          if (revealIndex != null && revealIndex < _elements.length) {
            final element = _elements[revealIndex];
            final bounds = element['bounds'];
            if (bounds is Map) {
              element['bounds'] = {
                'x': bounds['x'],
                'y': revealIndex == 0 ? 12 : 0,
                'width': bounds['width'],
                'height': bounds['height'],
              };
            }
          }
          response['result'] = {
            'status': 'ok',
            'revealed': true,
            'match_count': _elements.length,
          };
        case 'ext.sanad_client.tap':
          rpcOrder.add('tap');
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
          final adds = key == null ? null : enterTextAdds[key];
          if (adds != null &&
              !_elements.any((element) => element['key'] == adds['key'])) {
            _elements.add(Map<String, dynamic>.from(adds));
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
      final delayMs =
          method == 'ext.sanad_client.inspect_ui' &&
              params['typeCensus'] != 'true'
          ? inspectDelayMs
          : 0;
      if (delayMs > 0) {
        Timer(
          Duration(milliseconds: delayMs),
          () => socket.add(json.encode(response)),
        );
      } else {
        socket.add(json.encode(response));
      }
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

/// Minimal rendered-tree node used to exercise the bounded type census walk.
class _CensusNode {
  _CensusNode(this.label, [this.children = const []]);

  final String label;
  final List<_CensusNode> children;
}
