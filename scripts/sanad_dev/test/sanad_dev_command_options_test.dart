import 'package:test/test.dart';

import 'package:sanad_dev/command_options.dart';

void main() {
  test('public source runs use the production client profile by default', () {
    expect(defaultSanadDevClientConfig, 'config/prod.json');
  });

  test('setup stages and outcomes are typed', () {
    const result = SanadDevSetupStageResult(
      SanadDevSetupStage.flutterSdk,
      SanadDevSetupStageStatus.skipped,
    );
    expect(result.stage, SanadDevSetupStage.flutterSdk);
    expect(result.status, SanadDevSetupStageStatus.skipped);
  });

  group('component command targets', () {
    test('run and stop default to all', () {
      expect(
        parseSanadDevComponentCommand(const ['run']).target,
        SanadDevComponentTarget.all,
      );
      expect(
        parseSanadDevComponentCommand(const ['stop']).target,
        SanadDevComponentTarget.all,
      );
    });

    test('accepts explicit agent, client, and all targets', () {
      expect(
        parseSanadDevComponentCommand(const ['run', 'agent']).target,
        SanadDevComponentTarget.agent,
      );
      expect(
        parseSanadDevComponentCommand(const ['run', 'client']).target,
        SanadDevComponentTarget.client,
      );
      expect(
        parseSanadDevComponentCommand(const ['stop', 'all']).target,
        SanadDevComponentTarget.all,
      );
    });

    test('rejects unknown targets', () {
      expect(
        () => parseSanadDevComponentCommand(const ['run', 'daemon']),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('Supported targets: all, agent, client'),
          ),
        ),
      );
    });
  });

  group('device option', () {
    test('accepts -d and --device for client-owning run commands', () {
      final short = parseSanadDevComponentCommand(const [
        'run',
        'client',
        '-d',
        'macos',
      ]);
      final long = parseSanadDevComponentCommand(const [
        'run',
        'all',
        '--device=chrome',
      ]);

      expect(short.device, 'macos');
      expect(short.deviceWasSpecified, isTrue);
      expect(long.device, 'chrome');
    });

    test('accepts device-targeted client stop', () {
      final command = parseSanadDevComponentCommand(const [
        'stop',
        'client',
        '-d',
        'macos',
      ]);

      expect(command.target, SanadDevComponentTarget.client);
      expect(command.device, 'macos');
    });

    test('rejects device for agent run and non-client stop', () {
      expect(
        () => parseSanadDevComponentCommand(const [
          'run',
          'agent',
          '-d',
          'macos',
        ]),
        throwsFormatException,
      );
      expect(
        () =>
            parseSanadDevComponentCommand(const ['stop', 'all', '-d', 'macos']),
        throwsFormatException,
      );
    });

    test('rejects a missing device value', () {
      expect(
        () => parseSanadDevComponentCommand(const ['stop', 'client', '-d']),
        throwsFormatException,
      );
    });
  });

  group('force option', () {
    test('accepts force for agent-owning stop targets', () {
      expect(
        parseSanadDevComponentCommand(const ['stop', 'agent', '--force']).force,
        isTrue,
      );
      expect(
        parseSanadDevComponentCommand(const ['stop', 'all', '--force']).force,
        isTrue,
      );
    });

    test('rejects force for run commands', () {
      expect(
        () => parseSanadDevComponentCommand(const ['run', '--force']),
        throwsFormatException,
      );
    });

    test('rejects misleading stop client --force', () {
      expect(
        () =>
            parseSanadDevComponentCommand(const ['stop', 'client', '--force']),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('does not accept --force'),
          ),
        ),
      );
    });
  });
}
