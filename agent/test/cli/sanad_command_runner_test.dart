import 'package:sanad_agent/cli/runner/commands.dart';
import 'package:sanad_agent/cli/runner/sanad_command_runner.dart';
import 'package:test/test.dart';
import '../support/isolated_sanad_test_home.dart';

void main() {
  useIsolatedSanadTestHome();
  group('SanadCommandRunner Global Flags & Defaults', () {
    late StringBuffer stdoutBuffer;
    late StringBuffer stderrBuffer;

    setUp(() {
      stdoutBuffer = StringBuffer();
      stderrBuffer = StringBuffer();
    });

    test('defaults to chat command when args is empty', () async {
      var chatInvoked = false;
      final runner = SanadCommandRunner(
        stdoutSink: stdoutBuffer,
        stderrSink: stderrBuffer,
        onChat: (args) {
          chatInvoked = true;
          return 0;
        },
      );

      final result = await runner.run([]);
      expect(result, 0);
      expect(chatInvoked, isTrue);
    });

    test(
      'defaults to chat command when only global options are provided',
      () async {
        String? capturedWorkspace;
        String? capturedModel;
        bool? capturedThinking;

        final runner = SanadCommandRunner(
          stdoutSink: stdoutBuffer,
          stderrSink: stderrBuffer,
          customHandlers: {
            'chat': (cmd) {
              capturedWorkspace = cmd.workspace;
              capturedModel = cmd.model;
              capturedThinking = cmd.thinking;
              return 0;
            },
          },
        );

        final result = await runner.run([
          '--workspace',
          '/test/workspace',
          '-m',
          'claude-3-7-sonnet',
          '--thinking',
        ]);

        expect(result, 0);
        expect(capturedWorkspace, '/test/workspace');
        expect(capturedModel, 'claude-3-7-sonnet');
        expect(capturedThinking, isTrue);
      },
    );

    test('parses all common global options and flags correctly', () async {
      SanadCommand? captured;

      final runner = SanadCommandRunner(
        stdoutSink: stdoutBuffer,
        stderrSink: stderrBuffer,
        customHandlers: {
          'run': (cmd) {
            captured = cmd;
            return 0;
          },
        },
      );

      final result = await runner.run([
        '--workspace',
        '/my/ws',
        '--session',
        'sess-42',
        '--model',
        'gpt-4o',
        '--provider',
        'openai',
        '--thinking',
        '--quiet',
        '--json',
        '--account',
        'user@example.com',
        '--standalone',
        '--gateway-url',
        'ws://127.0.0.1:58085/ws',
        'run',
        'do something',
      ]);

      expect(result, 0);
      expect(captured, isNotNull);
      expect(captured!.workspace, '/my/ws');
      expect(captured!.session, 'sess-42');
      expect(captured!.model, 'gpt-4o');
      expect(captured!.provider, 'openai');
      expect(captured!.thinking, isTrue);
      expect(captured!.quiet, isTrue);
      expect(captured!.json, isTrue);
      expect(captured!.account, 'user@example.com');
      expect(captured!.standalone, isTrue);
      expect(captured!.gatewayUrl, 'ws://127.0.0.1:58085/ws');
    });

    test('--version flag prints version and returns 0', () async {
      final runner = SanadCommandRunner(
        stdoutSink: stdoutBuffer,
        stderrSink: stderrBuffer,
      );

      final result = await runner.run(['--version']);
      expect(result, 0);
      expect(stdoutBuffer.toString(), contains('Sanad Agent'));
      expect(stdoutBuffer.toString(), contains('Version:'));
    });

    test('-v alias prints version and returns 0', () async {
      final runner = SanadCommandRunner(
        stdoutSink: stdoutBuffer,
        stderrSink: stderrBuffer,
      );

      final result = await runner.run(['-v']);
      expect(result, 0);
      expect(stdoutBuffer.toString(), contains('Sanad Agent'));
      expect(stdoutBuffer.toString(), contains('Version:'));
    });

    test('--help flag prints usage and returns 0', () async {
      final runner = SanadCommandRunner(
        stdoutSink: stdoutBuffer,
        stderrSink: stderrBuffer,
      );

      final result = await runner.run(['--help']);
      expect(result, 0);
      expect(
        stdoutBuffer.toString(),
        contains('Usage: sanad <command> [arguments]'),
      );
      expect(stdoutBuffer.toString(), contains('Available commands:'));
      expect(stdoutBuffer.toString(), contains('chat'));
      expect(stdoutBuffer.toString(), contains('workspace'));
    });
  });

  group('Command Routing & Aliases', () {
    late StringBuffer stdoutBuffer;
    late StringBuffer stderrBuffer;

    setUp(() {
      stdoutBuffer = StringBuffer();
      stderrBuffer = StringBuffer();
    });

    test('routes to chat command directly and via cli alias', () async {
      var callCount = 0;
      final runner = SanadCommandRunner(
        stdoutSink: stdoutBuffer,
        stderrSink: stderrBuffer,
        onChat: (args) {
          callCount++;
          return 0;
        },
      );

      expect(await runner.run(['chat']), 0);
      expect(await runner.run(['cli']), 0);
      expect(callCount, 2);
    });

    test('routes to daemon command directly and via start alias', () async {
      var callCount = 0;
      final runner = SanadCommandRunner(
        stdoutSink: stdoutBuffer,
        stderrSink: stderrBuffer,
        onDaemon: (args) {
          callCount++;
          return 0;
        },
      );

      expect(await runner.run(['daemon']), 0);
      expect(await runner.run(['start']), 0);
      expect(callCount, 2);
    });

    test('routes to service command and subcommands', () async {
      String? capturedSubcommand;
      final runner = SanadCommandRunner(
        stdoutSink: stdoutBuffer,
        stderrSink: stderrBuffer,
        onService: (args) {
          capturedSubcommand = args.first;
          return 0;
        },
      );

      await runner.run(['service', 'status']);
      expect(capturedSubcommand, 'status');

      await runner.run(['service', 'restart']);
      expect(capturedSubcommand, 'restart');

      await runner.run(['service', 'stop']);
      expect(capturedSubcommand, 'stop');

      await runner.run(['service', 'start']);
      expect(capturedSubcommand, 'start');

      await runner.run(['service', 'uninstall']);
      expect(capturedSubcommand, 'uninstall');
    });

    test('routes to root restart command', () async {
      var restartInvoked = false;
      final runner = SanadCommandRunner(
        stdoutSink: stdoutBuffer,
        stderrSink: stderrBuffer,
        onRestart: () {
          restartInvoked = true;
          return 0;
        },
      );

      final result = await runner.run(['restart']);
      expect(result, 0);
      expect(restartInvoked, isTrue);
    });

    test('routes to setup command and subcommands', () async {
      List<String>? capturedArgs;
      final runner = SanadCommandRunner(
        stdoutSink: stdoutBuffer,
        stderrSink: stderrBuffer,
        onSetup: (args) {
          capturedArgs = args;
          return 0;
        },
      );

      await runner.run(['setup']);
      expect(capturedArgs, isEmpty);

      await runner.run(['setup', 'list']);
      expect(capturedArgs, ['list']);

      await runner.run(['setup', 'status']);
      expect(capturedArgs, ['status']);

      await runner.run(['setup', 'remove', 'anthropic']);
      expect(capturedArgs, ['remove', 'anthropic']);
    });

    test('routes to login and logout commands', () async {
      List<String>? loginArgs;
      var logoutCalled = false;

      final runner = SanadCommandRunner(
        stdoutSink: stdoutBuffer,
        stderrSink: stderrBuffer,
        onLogin: (args) {
          loginArgs = args;
          return 0;
        },
        onLogout: () {
          logoutCalled = true;
          return 0;
        },
      );

      await runner.run(['login', '--status']);
      expect(loginArgs, contains('--status'));

      await runner.run(['logout']);
      expect(logoutCalled, isTrue);
    });

    test('routes to version and update commands', () async {
      var updateCalled = false;
      final runner = SanadCommandRunner(
        stdoutSink: stdoutBuffer,
        stderrSink: stderrBuffer,
        customHandlers: {
          'update': (cmd) {
            updateCalled = true;
            return 0;
          },
        },
      );

      final verResult = await runner.run(['version']);
      expect(verResult, 0);
      expect(stdoutBuffer.toString(), contains('Sanad Agent'));

      final upResult = await runner.run(['update']);
      expect(upResult, 0);
      expect(updateCalled, isTrue);
    });

    test('routes to workspace command and ws alias', () async {
      var wsCalled = false;
      final runner = SanadCommandRunner(
        stdoutSink: stdoutBuffer,
        stderrSink: stderrBuffer,
        customHandlers: {
          'workspace': (cmd) {
            wsCalled = true;
            return 0;
          },
        },
      );

      expect(await runner.run(['workspace']), 0);
      expect(wsCalled, isTrue);

      wsCalled = false;
      expect(await runner.run(['ws']), 0);
      expect(wsCalled, isTrue);
    });

    test('routes to session command and subcommands', () async {
      final subcommandsCalled = <String>[];
      final runner = SanadCommandRunner(
        stdoutSink: stdoutBuffer,
        stderrSink: stderrBuffer,
        customHandlers: {
          'session': (cmd) {
            subcommandsCalled.add(cmd.name);
            stdoutBuffer.writeln('Active sessions:');
            return 0;
          },
        },
      );

      expect(await runner.run(['session', 'list']), 0);
      expect(subcommandsCalled, contains('list'));
      expect(stdoutBuffer.toString(), contains('Active sessions:'));

      expect(await runner.run(['session', 'new']), 0);
      expect(subcommandsCalled, contains('new'));
    });

    test('routes to doctor command and prints diagnostics checklist', () async {
      final runner = SanadCommandRunner(
        stdoutSink: stdoutBuffer,
        stderrSink: stderrBuffer,
      );

      final result = await runner.run(['doctor']);
      expect(result, 0);
      expect(stdoutBuffer.toString(), contains('Sanad Agent Doctor'));
      expect(stdoutBuffer.toString(), contains('Platform:'));
      expect(stdoutBuffer.toString(), contains('Sanad Home:'));
    });

    test(
      'routes to models, providers, skills, mcp, memory, schedule commands',
      () async {
        final runner = SanadCommandRunner(
          stdoutSink: stdoutBuffer,
          stderrSink: stderrBuffer,
        );

        expect(await runner.run(['models']), 0);
        expect(
          stdoutBuffer.toString(),
          contains('No local state database found'),
        );

        stdoutBuffer.clear();
        expect(await runner.run(['skills']), 0);
        expect(stdoutBuffer.toString(), contains('Skills:'));

        stdoutBuffer.clear();
        expect(await runner.run(['mcp', 'list']), 0);
        expect(stdoutBuffer.toString(), contains('MCP'));

        stdoutBuffer.clear();
        expect(await runner.run(['memory', 'list']), 0);
        expect(stdoutBuffer.toString(), contains('Memories'));

        stdoutBuffer.clear();
        expect(await runner.run(['schedule', 'list']), 0);
        expect(stdoutBuffer.toString(), contains('Scheduled'));
      },
    );
  });

  group('Command Error Handling & Validations', () {
    late StringBuffer stdoutBuffer;
    late StringBuffer stderrBuffer;

    setUp(() {
      stdoutBuffer = StringBuffer();
      stderrBuffer = StringBuffer();
    });

    test('returns exit code 64 on unknown command', () async {
      final runner = SanadCommandRunner(
        stdoutSink: stdoutBuffer,
        stderrSink: stderrBuffer,
      );

      final result = await runner.run(['nonexistent-cmd']);
      expect(result, 64);
      expect(
        stderrBuffer.toString(),
        contains('Could not find a command named "nonexistent-cmd"'),
      );
    });

    test('returns exit code 64 on unknown flag', () async {
      final runner = SanadCommandRunner(
        stdoutSink: stdoutBuffer,
        stderrSink: stderrBuffer,
      );

      final result = await runner.run(['--invalid-flag']);
      expect(result, 64);
      expect(
        stderrBuffer.toString(),
        contains('Could not find an option named "--invalid-flag"'),
      );
    });

    test('run command requires a non-empty prompt', () async {
      final runner = SanadCommandRunner(
        stdoutSink: stdoutBuffer,
        stderrSink: stderrBuffer,
      );

      final result = await runner.run(['run']);
      expect(result, 1);
      expect(
        stderrBuffer.toString(),
        contains('Error: No prompt or instruction provided.'),
      );
    });

    test('workspace select requires path or ID', () async {
      final runner = SanadCommandRunner(
        stdoutSink: stdoutBuffer,
        stderrSink: stderrBuffer,
      );

      final result = await runner.run(['workspace', 'select']);
      expect(result, 1);
      expect(
        stderrBuffer.toString(),
        contains('Error: Workspace path or ID is required.'),
      );
    });

    test('session show requires session ID', () async {
      final runner = SanadCommandRunner(
        stdoutSink: stdoutBuffer,
        stderrSink: stderrBuffer,
      );

      final result = await runner.run(['session', 'show']);
      expect(result, 1);
      expect(
        stderrBuffer.toString(),
        contains('Error: Session ID is required.'),
      );
    });

    test(
      'handleEarlyDaemonHelpOrInvalidArguments validates early supervisor startup',
      () {
        final earlyStdout = StringBuffer();
        final earlyStderr = StringBuffer();

        // Help check
        final helpHandled =
            SanadCommandRunner.handleEarlyDaemonHelpOrInvalidArguments(
              ['daemon', '--help'],
              stdoutOutput: earlyStdout,
              stderrOutput: earlyStderr,
            );
        expect(helpHandled, isTrue);
        expect(earlyStdout.toString(), contains('Usage: sanad daemon'));

        // Unknown argument check
        final unknownHandled =
            SanadCommandRunner.handleEarlyDaemonHelpOrInvalidArguments(
              ['daemon', '--unknown-arg'],
              stdoutOutput: earlyStdout,
              stderrOutput: earlyStderr,
            );
        expect(unknownHandled, isTrue);
        expect(
          earlyStderr.toString(),
          contains('Unknown daemon argument: --unknown-arg'),
        );

        // Non-daemon check
        final chatHandled =
            SanadCommandRunner.handleEarlyDaemonHelpOrInvalidArguments(
              ['chat'],
              stdoutOutput: earlyStdout,
              stderrOutput: earlyStderr,
            );
        expect(chatHandled, isFalse);
      },
    );
  });
}
