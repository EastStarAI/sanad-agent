import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/client_cli/domain/models/client_cli_relay_policy.dart';

void main() {
  group('clientCliRelayTimeoutSecondsFor', () {
    test('keeps the protocol default when the command declares no timeout', () {
      expect(
        clientCliRelayTimeoutSecondsFor(['run', '--workspace', 'ws-core']),
        clientCliRelayDefaultTimeoutSeconds,
      );
      expect(clientCliRelayDefaultTimeoutSeconds, 300);
    });

    test('derives the relay window from the command timeout plus grace', () {
      expect(
        clientCliRelayTimeoutSecondsFor([
          'run',
          '--workspace',
          'ws-core',
          '--timeout',
          '5400',
        ]),
        5430,
      );
      expect(
        clientCliRelayTimeoutSecondsFor(['run', '--timeout=120']),
        120 + clientCliRelayTimeoutGraceSeconds,
      );
    });

    test('the last timeout wins and a terminator ends option scanning', () {
      expect(
        clientCliRelayTimeoutSecondsFor([
          'run',
          '--timeout',
          '600',
          '--timeout',
          '1800',
        ]),
        1830,
      );
      expect(
        clientCliRelayTimeoutSecondsFor(['run', '--', '--timeout', '5400']),
        clientCliRelayDefaultTimeoutSeconds,
      );
    });

    test('falls back to the default for a value the command rejects', () {
      expect(
        clientCliRelayTimeoutSecondsFor(['run', '--timeout', 'forever']),
        clientCliRelayDefaultTimeoutSeconds,
      );
      expect(
        clientCliRelayTimeoutSecondsFor(['run', '--timeout']),
        clientCliRelayDefaultTimeoutSeconds,
      );
    });

    test('clamps to the protocol bounds', () {
      expect(
        clientCliRelayTimeoutSecondsFor(['run', '--timeout', '86400']),
        clientCliRelayMaxTimeoutSeconds,
      );
      // A rejected value still leaves a usable relay window so the command's
      // own usage error is relayed back.
      expect(
        clientCliRelayTimeoutSecondsFor(['run', '--timeout', '0']),
        clientCliRelayTimeoutGraceSeconds,
      );
      expect(
        clientCliRelayTimeoutSecondsFor(['run', '--timeout', '-30']),
        clientCliRelayMinTimeoutSeconds,
      );
      expect(
        clientCliRelayTimeoutSecondsFor(['run', '--timeout', '-86400']),
        clientCliRelayMinTimeoutSeconds,
      );
    });
  });

  group('clientCliRelayConsumesStdin', () {
    test('a run without a prompt or brief file reads standard input', () {
      expect(clientCliRelayConsumesStdin(['run', '-w', 'ws-core']), isTrue);
      expect(clientCliRelayConsumesStdin(['chat']), isTrue);
      expect(clientCliRelayConsumesStdin(['cli', '--json']), isTrue);
    });

    test('a supplied prompt never reads standard input', () {
      final cases = <List<String>>[
        ['run', '-w', 'ws-core', '--brief-file', 'brief.md'],
        ['run', '-w', 'ws-core', '-b', 'brief.md'],
        ['run', '-w', 'ws-core', '--brief-file=brief.md'],
        ['run', '-w', 'ws-core', '--prompt', 'do the thing'],
        ['run', '-w', 'ws-core', '-p', 'do the thing'],
        ['run', '-w', 'ws-core', '--prompt=do the thing'],
        ['run', '-w', 'ws-core', 'do the thing'],
        ['run', '--', 'do the thing'],
      ];
      for (final argv in cases) {
        expect(clientCliRelayConsumesStdin(argv), isFalse, reason: '$argv');
      }
    });

    test('a command that takes no prompt never reads standard input', () {
      expect(clientCliRelayConsumesStdin(['providers', 'list']), isFalse);
      expect(clientCliRelayConsumesStdin(['ws', 'list', '--json']), isFalse);
      expect(clientCliRelayConsumesStdin(['session', 'list']), isFalse);
      expect(clientCliRelayConsumesStdin(const []), isFalse);
    });

    test('an option value is not mistaken for a positional prompt', () {
      expect(
        clientCliRelayConsumesStdin(['run', '--thinking-mode', 'high']),
        isTrue,
      );
      expect(clientCliRelayConsumesStdin(['run', '--model', 'deepseek']), isTrue);
    });
  });

  group('host-local stdin flag', () {
    test('is opt-in only', () {
      expect(clientCliHasForwardStdinFlag(['run', '--stdin']), isTrue);
      expect(clientCliHasForwardStdinFlag(['run']), isFalse);
    });
  });
}
