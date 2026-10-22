import 'package:args/args.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/client_cli/domain/models/client_cli_relay_policy.dart';

/// Builds the Agent's own grammar for one `session` subcommand.
///
/// The Agent CLI declares these options on `SanadCommand.addCommonOptions` and
/// on each subcommand class; the relay policy must resolve a session exactly as
/// `package:args` does for that grammar, so this table is the test's authority
/// for the four subcommands the relay approves by session.
ArgParser _agentSessionParser(String subcommand) {
  final parser = ArgParser()
    ..addOption('workspace', abbr: 'w')
    ..addOption('session', abbr: 's')
    ..addOption('model', abbr: 'm')
    ..addOption('provider')
    ..addFlag('thinking', negatable: true)
    ..addOption('thinking-mode')
    ..addFlag('quiet', abbr: 'q', negatable: false)
    ..addFlag('json', negatable: false)
    ..addOption('timeout')
    ..addOption('account')
    ..addFlag('standalone', negatable: false)
    ..addOption('home')
    ..addOption('gateway-url', aliases: const ['url']);

  switch (subcommand) {
    case 'steer':
      parser
        ..addOption('message')
        ..addOption('message-file', abbr: 'f');
    case 'answer':
      parser
        ..addOption('request-id', abbr: 'r')
        ..addOption('answer', abbr: 'a')
        ..addOption('file', abbr: 'f');
    case 'stop':
    case 'retry':
      break;
  }
  return parser;
}

/// The session the Agent itself would act on for `['session', sub, ...rest]`.
///
/// This mirrors `_BaseSessionSubcommand.resolveSessionId`: the explicit
/// `--session` wins when the subcommand parsed one, otherwise the first
/// positional argument is the id. A usage error returns `null` because the
/// command exits before it acts on any session.
String? _agentSessionFor(List<String> argv) {
  try {
    final results = _agentSessionParser(argv[1]).parse(argv.skip(2));
    final explicit = results.wasParsed('session')
        ? (results['session'] as String?)?.trim()
        : null;
    if (explicit != null && explicit.isNotEmpty) return explicit;
    final positional = results.rest.isEmpty ? null : results.rest.first.trim();
    return (positional == null || positional.isEmpty) ? null : positional;
  } on ArgParserException {
    return null;
  }
}

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

  group('clientCliSessionTargetFor', () {
    test('reads the positional session id of a session subcommand', () {
      expect(
        clientCliSessionTargetFor(['session', 'steer', 'sess-B', '--message', 'x'])
            .sessionId,
        'sess-B',
      );
      expect(
        clientCliSessionTargetFor(['session', 'show', 'sess-A']).sessionId,
        'sess-A',
      );
      expect(
        clientCliSessionTargetFor(['session', 'answer', 'sess-A', 'req-1'])
            .sessionId,
        'sess-A',
      );
    });

    test('never reads an option value as a session flag', () {
      // `--message -s A` is the literal message `-s` plus a positional `A`;
      // the Agent targets `sess-B`, so the approval must too.
      final target = clientCliSessionTargetFor([
        'session',
        'steer',
        'sess-B',
        '--message',
        '-s',
        'sess-A',
      ]);
      expect(target.sessionId, 'sess-B');
      expect(target.conflict, isFalse);

      // The same rule for every value-taking option.
      expect(
        clientCliSessionTargetFor([
          'session',
          'steer',
          'sess-B',
          '--message-file',
          '--session',
          'sess-A',
        ]).sessionId,
        'sess-B',
      );
      expect(
        clientCliSessionTargetFor([
          'session',
          'permission',
          'sess-B',
          '--request-id',
          '--session',
          '--allow',
        ]).sessionId,
        'sess-B',
      );
    });

    test('reads an explicit --session option', () {
      expect(
        clientCliSessionTargetFor([
          'session',
          'steer',
          '--session',
          'sess-A',
          '--message',
          'x',
        ]).sessionId,
        'sess-A',
      );
      expect(
        clientCliSessionTargetFor(['session', 'stop', '--session=sess-A'])
            .sessionId,
        'sess-A',
      );
      expect(
        clientCliSessionTargetFor(['run', 'do the thing', '-s', 'sess-A'])
            .sessionId,
        'sess-A',
      );
    });

    test('fails closed when two different sessions are named', () {
      final conflict = clientCliSessionTargetFor([
        'session',
        'steer',
        'sess-B',
        '--session',
        'sess-A',
        '--message',
        'x',
      ]);
      expect(conflict.conflict, isTrue);
      expect(conflict.sessionId, isNull);
    });

    test('accepts an agreeing positional id and --session', () {
      final target = clientCliSessionTargetFor([
        'session',
        'steer',
        'sess-A',
        '--session',
        'sess-A',
        '--message',
        'x',
      ]);
      expect(target.conflict, isFalse);
      expect(target.sessionId, 'sess-A');
    });

    test('a non-session command has no positional session id', () {
      expect(
        clientCliSessionTargetFor(['run', 'do the thing']).sessionId,
        isNull,
      );
      expect(clientCliSessionTargetFor(['ws', 'list']).sessionId, isNull);
      expect(clientCliSessionTargetFor(const []).sessionId, isNull);
    });

    test('session subcommands without a session id name none', () {
      expect(clientCliSessionTargetFor(['session', 'list']).sessionId, isNull);
      expect(clientCliSessionTargetFor(['session', 'new']).sessionId, isNull);
    });
  });

  group('session target grammar (args parity)', () {
    test('a short option accepts an attached value', () {
      // `args` reads `-sA` as `--session A`, so the approval must name `A`
      // even though the positional id says `B`.
      final target = clientCliSessionTargetFor([
        'session',
        'steer',
        'sess-B',
        '-sA',
        '--message',
        'x',
      ]);
      expect(target.conflict, isTrue);
      expect(target.sessionId, isNull);

      // Alone, an attached short value is a provable target.
      expect(
        clientCliSessionTargetFor([
          'session',
          'steer',
          '-ssess-A',
          '--message',
          'x',
        ]).sessionId,
        'sess-A',
      );
      expect(
        clientCliSessionTargetFor(['session', 'stop', '-ssess-A']).sessionId,
        'sess-A',
      );
      // The attached text is the value verbatim: `-s=A` names `=A`.
      expect(
        clientCliSessionTargetFor([
          'session',
          'stop',
          '-s=sess-A',
        ]).sessionId,
        '=sess-A',
      );
    });

    test('the last --session wins in args, so an argv that disagrees is '
        'refused instead of approved', () {
      final target = clientCliSessionTargetFor([
        'session',
        'steer',
        '--session',
        'sess-A',
        '--session',
        'sess-B',
        '--message',
        'x',
      ]);
      expect(target.conflict, isTrue);
      expect(target.sessionId, isNull);

      // Repeating the same id is not a conflict.
      expect(
        clientCliSessionTargetFor([
          'session',
          'stop',
          '--session',
          'sess-A',
          '--session',
          'sess-A',
        ]).sessionId,
        'sess-A',
      );
      expect(
        clientCliSessionTargetFor([
          'session',
          'stop',
          '--session=sess-A',
          '-ssess-A',
        ]).sessionId,
        'sess-A',
      );
    });

    test('a session flag before the command still names the target', () {
      expect(
        clientCliSessionTargetFor([
          '--session',
          'sess-A',
          'session',
          'steer',
          '--message',
          'x',
        ]).sessionId,
        'sess-A',
      );
      expect(
        clientCliSessionTargetFor([
          '-wsess-ws',
          'session',
          'stop',
          'sess-A',
        ]).sessionId,
        'sess-A',
      );
    });

    test('an option value is never read as a session flag', () {
      // The value of `--workspace` or `-m` is skipped even when it looks like
      // a session flag.
      expect(
        clientCliSessionTargetFor([
          'session',
          'stop',
          'sess-A',
          '--workspace',
          '--session',
          'sess-B',
        ]).sessionId,
        'sess-A',
      );
      expect(
        clientCliSessionTargetFor([
          'session',
          'stop',
          '--message-file=--session',
          'sess-A',
        ]).sessionId,
        'sess-A',
      );
    });

    test('-- ends option parsing', () {
      expect(
        clientCliSessionTargetFor([
          'session',
          'stop',
          '--',
          '--session',
          'sess-A',
        ]).sessionId,
        '--session',
        reason: 'after -- every token is positional and the first is the id',
      );
      expect(
        clientCliSessionTargetFor([
          'session',
          'steer',
          'sess-B',
          '--',
          '--session',
          'sess-A',
        ]).sessionId,
        'sess-B',
      );
    });

    test('only the first positional after the subcommand is the session id', () {
      expect(
        clientCliSessionTargetFor([
          'session',
          'answer',
          'sess-A',
          'req-1',
          '--answer',
          'yes',
        ]).sessionId,
        'sess-A',
      );
    });

    test('every session subcommand the relay approves resolves its target', () {
      for (final subcommand in ['steer', 'answer', 'stop', 'retry']) {
        expect(
          clientCliSessionTargetFor([
            'session',
            subcommand,
            'sess-A',
          ]).sessionId,
          'sess-A',
          reason: subcommand,
        );
        expect(
          clientCliSessionTargetFor([
            'session',
            subcommand,
            '--session=sess-A',
          ]).sessionId,
          'sess-A',
          reason: subcommand,
        );
      }
    });

    test('the resolver never disagrees with the Agent parser', () {
      final cases = <List<String>>[
        ['session', 'steer', 'sess-A', '--message', 'x'],
        ['session', 'steer', '--message', 'x', '-ssess-A'],
        ['session', 'steer', '-s', 'sess-A', '--message', 'x'],
        ['session', 'steer', '--session=sess-A', '--message', 'x'],
        ['session', 'steer', 'sess-A', '-fsome-file'],
        ['session', 'steer', '--message', '-s', 'sess-A'],
        ['session', 'steer', 'sess-A', '--message', '-s'],
        ['session', 'steer', '--session', 'sess-A', '--session', 'sess-A'],
        ['session', 'stop', 'sess-A', '--timeout', '5'],
        ['session', 'stop', '-qsess-A'],
        ['session', 'stop', 'sess-A', '--'],
        ['session', 'answer', 'sess-A', 'req-1', '-ayes'],
        ['session', 'answer', '--request-id=req-1', 'sess-A'],
        ['session', 'retry', 'sess-A'],
        ['session', 'retry', '-ssess-A', '--provider', 'p'],
        ['session', 'retry', 'sess-A', '--model', 'm'],
        ['session', 'retry', '--provider', 'p', '--model', 'm', 'sess-A'],
      ];

      for (final argv in cases) {
        final agentTarget = _agentSessionFor(argv);
        final relayTarget = clientCliSessionTargetFor(argv);
        if (relayTarget.conflict) continue;
        expect(
          relayTarget.sessionId,
          agentTarget,
          reason:
              'the approval target must equal the session the Agent acts on '
              'for $argv',
        );
      }
    });

    test('a conflicting target is always one the Agent could act on', () {
      final cases = <List<String>>[
        ['session', 'steer', 'sess-B', '-sA', '--message', 'x'],
        ['session', 'steer', '--session', 'sess-A', '--session', 'sess-B'],
        ['session', 'stop', 'sess-B', '--session', 'sess-A'],
      ];
      for (final argv in cases) {
        final relayTarget = clientCliSessionTargetFor(argv);
        expect(relayTarget.conflict, isTrue, reason: '$argv');
        expect(
          _agentSessionFor(argv),
          isNotNull,
          reason: 'the Agent would still act on one of the named sessions',
        );
      }
    });
  });
}
