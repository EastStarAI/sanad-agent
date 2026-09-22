import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:args/args.dart';
import 'package:args/command_runner.dart';

import 'commands.dart';
import '../client/cli_turn_client.dart';
import '../client/local_gateway_cli_client.dart';
import '../oneshot/oneshot_runner.dart';
import '../repl/repl_line_reader.dart';
import '../workspace/workspace_cli_service.dart';

/// Top-level command runner for the Sanad Agent CLI platform.
class SanadCommandRunner extends CommandRunner<int> {
  final StringSink stdoutSink;
  final StringSink stderrSink;

  SanadCommandRunner({
    StringSink? stdoutSink,
    StringSink? stderrSink,
    FutureOr<int> Function(List<String> args)? onChat,
    FutureOr<int> Function(List<String> args)? onDaemon,
    FutureOr<int> Function(List<String> args)? onService,
    FutureOr<int> Function(List<String> args)? onSetup,
    FutureOr<int> Function(List<String> args)? onLogin,
    FutureOr<int> Function()? onLogout,
    FutureOr<int> Function()? onRestart,
    Map<String, FutureOr<int> Function(SanadCommand command)>? customHandlers,
    StdinReader? stdinReader,
    ClientFactory? clientFactory,
    CliTurnClient? client,
    WorkspaceCliService? workspaceService,
    ReplLineReader? lineReader,
  }) : stdoutSink = stdoutSink ?? stdout,
       stderrSink = stderrSink ?? stderr,
       super(
         'sanad',
         '⚕ Sanad Agent — Standalone CLI and autonomous local AI assistant',
       ) {
    _configureGlobalFlags();
    _registerCommands(
      onChat: onChat,
      onDaemon: onDaemon,
      onService: onService,
      onSetup: onSetup,
      onLogin: onLogin,
      onLogout: onLogout,
      onRestart: onRestart,
      handlers: customHandlers,
      stdinReader: stdinReader,
      clientFactory: clientFactory,
      client: client,
      workspaceService: workspaceService,
      lineReader: lineReader,
    );
  }

  void _configureGlobalFlags() {
    argParser
      ..addOption(
        'prompt',
        abbr: 'p',
        help:
            'Execute a one-shot task or instruction without entering interactive chat',
      )
      ..addOption(
        'workspace',
        abbr: 'w',
        help: 'Path or ID of the active workspace',
      )
      ..addOption(
        'session',
        abbr: 's',
        help: 'Target session ID to resume or attach',
      )
      ..addOption(
        'model',
        abbr: 'm',
        help: 'Model name override for agent reasoning turn',
      )
      ..addOption(
        'provider',
        help: 'LLM provider override (e.g. openai, anthropic, ollama)',
      )
      ..addFlag(
        'thinking',
        help: 'Enable deep reasoning/thinking output stream',
        negatable: true,
        defaultsTo: false,
      )
      ..addFlag(
        'quiet',
        abbr: 'q',
        help: 'Suppress non-essential progress output and banners',
        negatable: false,
      )
      ..addFlag(
        'json',
        help: 'Output responses and streaming events as newline-delimited JSON',
        negatable: false,
      )
      ..addOption(
        'timeout',
        help: 'Maximum one-shot runtime in seconds (1-86400)',
        valueHelp: 'seconds',
      )
      ..addOption('account', help: 'Account identifier or email')
      ..addFlag(
        'standalone',
        help: 'Force in-process standalone execution without daemon',
        negatable: false,
      )
      ..addOption('home', help: 'Path to custom Sanad home directory')
      ..addOption(
        'gateway-url',
        help: 'Override Local Gateway WebSocket endpoint URL',
      )
      ..addFlag(
        'version',
        abbr: 'v',
        help: 'Show current agent version and architecture',
        negatable: false,
      )
      ..addFlag(
        'child-process',
        hide: true,
        help: 'Internal child process indicator',
        negatable: false,
      );
  }

  void _registerCommands({
    FutureOr<int> Function(List<String> args)? onChat,
    FutureOr<int> Function(List<String> args)? onDaemon,
    FutureOr<int> Function(List<String> args)? onService,
    FutureOr<int> Function(List<String> args)? onSetup,
    FutureOr<int> Function(List<String> args)? onLogin,
    FutureOr<int> Function()? onLogout,
    FutureOr<int> Function()? onRestart,
    Map<String, FutureOr<int> Function(SanadCommand command)>? handlers,
    StdinReader? stdinReader,
    ClientFactory? clientFactory,
    CliTurnClient? client,
    WorkspaceCliService? workspaceService,
    ReplLineReader? lineReader,
  }) {
    FutureOr<int> Function(SanadCommand)? handlerFor(String name) =>
        handlers?[name];

    addCommand(
      ChatCommand(
        onChat: onChat,
        customAction: handlerFor('chat') ?? handlerFor('cli'),
        clientFactory: clientFactory,
        clientOverride: client is LocalGatewayCliClient ? client : null,
        workspaceService: workspaceService,
        lineReader: lineReader,
      ),
    );
    addCommand(
      RunCommand(
        customAction: handlerFor('run'),
        stdinReader: stdinReader,
        clientFactory: clientFactory,
        clientOverride: client,
      ),
    );
    addCommand(
      DaemonCommand(
        onDaemon: onDaemon,
        customAction: handlerFor('daemon') ?? handlerFor('start'),
      ),
    );
    addCommand(
      ServiceCommand(onService: onService, customAction: handlerFor('service')),
    );
    addCommand(
      RestartCommand(onRestart: onRestart, customAction: handlerFor('restart')),
    );
    addCommand(DoctorCommand(customAction: handlerFor('doctor')));
    addCommand(
      SetupCommand(onSetup: onSetup, customAction: handlerFor('setup')),
    );
    addCommand(
      LoginCommand(onLogin: onLogin, customAction: handlerFor('login')),
    );
    addCommand(
      LogoutCommand(onLogout: onLogout, customAction: handlerFor('logout')),
    );
    addCommand(UpdateCommand(customAction: handlerFor('update')));
    addCommand(
      VersionCommand(output: stdoutSink, customAction: handlerFor('version')),
    );
    addCommand(
      WorkspaceCommand(
        serviceOverride: workspaceService,
        customAction: handlerFor('workspace') ?? handlerFor('ws'),
      ),
    );
    addCommand(
      SessionCommand(
        clientFactory: clientFactory,
        clientOverride: client is LocalGatewayCliClient ? client : null,
        customAction: handlerFor('session'),
      ),
    );
    addCommand(ModelsCommand(customAction: handlerFor('models')));
    addCommand(ProvidersCommand(customAction: handlerFor('providers')));
    addCommand(SkillsCommand(customAction: handlerFor('skills')));
    addCommand(McpCommand(customAction: handlerFor('mcp')));
    addCommand(MemoryCommand(customAction: handlerFor('memory')));
    addCommand(ScheduleCommand(customAction: handlerFor('schedule')));
  }

  @override
  Future<int?> runCommand(ArgResults topLevelResults) async {
    if (topLevelResults['version'] == true) {
      printVersion(output: stdoutSink);
      return 0;
    }

    if (topLevelResults.command == null) {
      if (topLevelResults['help'] == true) {
        printUsage();
        return 0;
      }

      // Check if one-shot prompt was provided via -p / --prompt
      if (topLevelResults.wasParsed('prompt') ||
          (topLevelResults['prompt'] != null &&
              (topLevelResults['prompt'] as String).trim().isNotEmpty)) {
        final runCmd = commands['run'];
        if (runCmd != null) {
          if (runCmd is SanadCommand) {
            runCmd.overrideGlobalResults = topLevelResults;
          }
          return await runCmd.run();
        }
      }

      if (topLevelResults.rest.isNotEmpty) {
        throw UsageException(
          'Could not find a command named "${topLevelResults.rest.first}".',
          usage,
        );
      }

      // Default fallback: Execute interactive chat (REPL)
      final chatCmd = commands['chat'];
      if (chatCmd != null) {
        if (chatCmd is SanadCommand) {
          chatCmd.overrideGlobalResults = topLevelResults;
        }
        return await chatCmd.run();
      }
      printUsage();
      return 0;
    }

    final commandResults = topLevelResults.command!;
    final cmd = commands[commandResults.name];
    if (cmd != null &&
        cmd.subcommands.isNotEmpty &&
        commandResults.command == null) {
      if (commandResults['help'] == true) {
        cmd.printUsage();
        return 0;
      }
      return await cmd.run();
    }

    return await super.runCommand(topLevelResults);
  }

  @override
  Future<int> run(Iterable<String> args) async {
    final arguments = args.toList(growable: false);
    final jsonOutput = arguments.contains('--json');
    try {
      final exitStatus = await super.run(arguments);
      return exitStatus ?? 0;
    } on UsageException catch (error) {
      stderrSink.writeln(error.message);
      stderrSink.writeln('');
      stderrSink.writeln(error.usage);
      if (jsonOutput) {
        stdoutSink.writeln(
          jsonEncode(
            OneshotResult(
              exitCode: 64,
              text: '',
              sessionId: '',
              error: error.message,
            ).toJson(),
          ),
        );
      }
      return 64;
    } catch (error) {
      stderrSink.writeln('Error: $error');
      if (jsonOutput) {
        stdoutSink.writeln(
          jsonEncode(
            OneshotResult(
              exitCode: 1,
              text: '',
              sessionId: '',
              error: error.toString(),
            ).toJson(),
          ),
        );
      }
      return 1;
    }
  }

  @override
  void printUsage() {
    stdoutSink.writeln(usage);
  }

  /// Guards early daemon execution before Home bootstrap and process supervisor startup.
  static bool handleEarlyDaemonHelpOrInvalidArguments(
    List<String> arguments, {
    StringSink? stdoutOutput,
    StringSink? stderrOutput,
  }) {
    if (arguments.isEmpty ||
        !const {'daemon', 'start'}.contains(arguments.first.toLowerCase())) {
      return false;
    }
    final remaining = arguments.sublist(1);
    final visible = remaining
        .where((value) => value != '--child-process')
        .toList();

    if (visible.length == 1 &&
        const {'help', '-h', '--help'}.contains(visible.single)) {
      final out = stdoutOutput ?? stdout;
      out.writeln('Usage: sanad daemon');
      out.writeln('Starts the supervised Sanad Agent daemon.');
      return true;
    }

    if (visible.isNotEmpty) {
      final err = stderrOutput ?? stderr;
      err.writeln('Unknown daemon argument: ${visible.first}');
      err.writeln('Usage: sanad daemon');
      exitCode = 64;
      return true;
    }

    return false;
  }
}
