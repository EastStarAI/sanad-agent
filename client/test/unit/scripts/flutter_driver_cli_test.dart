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
