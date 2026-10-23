import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:args/args.dart';
import 'package:args/command_runner.dart';

import '../../core/constants.dart';

import 'commands.dart';
import '../artifacts/run_artifacts.dart';
import '../client/cli_turn_client.dart';
import '../client/local_gateway_cli_client.dart';
import '../discovery/local_gateway_discovery.dart';
import '../oneshot/oneshot_runner.dart';
import '../repl/repl_line_reader.dart';
import '../workspace/workspace_cli_service.dart';

/// Top-level command runner for the Sanad Agent CLI platform.
class SanadCommandRunner extends CommandRunner<int> {
  final StringSink stdoutSink;
  final StringSink stderrSink;
  final void Function(RunLifecycleEvent event)? eventSink;
  final Stream<ProcessSignal>? signalStream;

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
    this.eventSink,
    this.signalStream,
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
        'execution-root',
        help:
            'Temporary unregistered filesystem context for top-level --prompt',
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
      ..addOption(
        'thinking-mode',
        help:
            'Explicit thinking option id for the route (for example: high, off)',
        allowed: cliThinkingModes,
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
        aliases: const ['url'],
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
        signalStream: signalStream,
        eventSink: eventSink,
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
    } on GatewayDiscoveryException catch (error) {
      // Endpoint resolution is an environment/configuration answer, not an
      // internal failure: report the actionable message and the
      // configuration exit code instead of a stack-trace-shaped exception.
      // The envelope carries the discovery code so a machine consumer can tell
      // a stale record from a foreign one without parsing English.
      stderrSink.writeln('Error: ${error.message}');
      if (jsonOutput) {
        stdoutSink.writeln(
          jsonEncode(
            OneshotResult(
              exitCode: 78,
              text: '',
              sessionId: '',
              error: error.message,
              errorCode: error.code,
            ).toJson(),
          ),
        );
      }
      return 78;
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
  /// Whether [arguments] only print version or usage text, or the read-only
  /// `service definition` report.
  ///
  /// Such queries run before any Sanad Home preparation and never create or
  /// write anything there: installed-agent probes (`--version`,
  /// `help service install`) must be side-effect free. Classification only
  /// parses the arguments; an unparseable command line is not a query.
  static bool isPureQuery(List<String> arguments) {
    if (arguments.isEmpty || arguments.contains('--child-process')) {
      return false;
    }
    final ArgResults results;
    try {
      results = SanadCommandRunner().parse(arguments);
    } catch (_) {
      return false;
    }
    if (results['version'] == true || results['help'] == true) return true;
    final name = results.command?.name;
    if (name == 'version' || name == 'help') return true;
    if (name == 'service' && results.command?.command?.name == 'definition') {
      return true;
    }
    for (
      var command = results.command;
      command != null;
      command = command.command
    ) {
      if (command.options.contains('help') && command['help'] == true) {
        return true;
      }
    }
    return false;
  }

  /// Commands whose every subcommand is served by the Local Gateway or by local
  /// files, and that therefore never read or write an Agent secret.
  ///
  /// `session` is the gateway-only surface the Client and automation poll;
  /// `workspace` and `memory` are gateway or file operations.
  static const Set<String> secretFreeCommandFamilies = {
    'session',
    'workspace',
    // `workspace` also answers to `ws`, and the parsed command name keeps the
    // alias the caller typed.
    'ws',
    'memory',
  };

  /// Individual subcommands of an otherwise secret-bearing family that are
  /// still secret-free, so an unrelated subcommand of the same family keeps the
  /// vault instead of inheriting a blanket exemption.
  ///
  /// `schedule list` reads the agent-state database read-only, and
  /// `skills list` reads the bundled and user skill directories.
  static const Map<String, Set<String>> secretFreeSubcommands = {
    'schedule': {'list'},
    'skills': {'list'},
  };

  /// Whether [arguments] must open the Agent vault before the command runs.
  ///
  /// The Agent vault is the OS credential vault (macOS Keychain, Windows DPAPI,
  /// Linux Secret Service). Opening it reads each namespace owner index, and an
  /// item that was created by a *different* code identity (an earlier Agent
  /// build, or the JIT `dartvm` a source checkout ran) makes macOS answer with
  /// an interactive authorization dialog instead of data. A process with no
  /// person in front of it — the Client, a scheduler, a delegate relay, a pipe —
  /// cannot show that dialog, so the read blocks inside the security framework:
  /// the process produces no output, opens no socket, and never exits. Only a
  /// command that can read or write a secret therefore opens the vault at all.
  ///
  /// Classification is per subcommand, so an exemption never widens to sibling
  /// subcommands. Everything unrecognized keeps the conservative answer and
  /// opens the vault, so a new command can never silently lose its credentials.
  static bool requiresSecretVault(List<String> arguments) {
    if (arguments.isEmpty || arguments.contains('--child-process')) return true;
    final ArgResults results;
    try {
      results = SanadCommandRunner().parse(arguments);
    } catch (_) {
      return true;
    }
    if (results['version'] == true || results['help'] == true) return false;
    final command = results.command;
    if (command == null) return true;
    final name = command.name;
    if (name == 'version' || name == 'help') return false;
    if (secretFreeCommandFamilies.contains(name)) return false;
    final freeSubcommands = secretFreeSubcommands[name];
    if (freeSubcommands == null) return true;
    final subcommand = command.command?.name;
    if (subcommand == null) return true;
    return !freeSubcommands.contains(subcommand);
  }

  /// Whether [arguments] dispatch to the daemon instead of running a CLI
  /// command.
  ///
  /// The daemon owns its own Keychain interaction policy, so an entry point must
  /// not classify its command from the daemon's stdio shape. The private
  /// `--child-process` marker is tolerated in any position, because a supervised
  /// child must be recognized before it opens the vault, not after.
  static bool dispatchesToDaemon(List<String> arguments) {
    if (arguments.isEmpty) return false;
    final visible = arguments
        .where((argument) => argument != '--child-process')
        .toList(growable: false);
    if (visible.isEmpty) return false;
    try {
      final command = SanadCommandRunner().parse(visible).command;
      if (command == null) return false;
      return command.name == 'daemon' || command.name == 'start';
    } catch (_) {
      return false;
    }
  }

  /// The Sanad Home that [arguments] select, resolved exactly as
  /// [SanadCommand.sanadHome] resolves it: the innermost command's `--home`
  /// (`--home <path>` or `--home=<path>`) wins over the top-level option, and
  /// the value is normalized by [normalizeSanadHomeOption].
  ///
  /// `parsed` is `false` when the command line does not parse; such a command
  /// line only produces a usage error and must not touch any Home. Entry
  /// points call this before any Home access.
  static ({bool parsed, String? home}) selectedHome(List<String> arguments) {
    final ArgResults results;
    try {
      results = SanadCommandRunner().parse(arguments);
    } catch (_) {
      return (parsed: false, home: null);
    }
    final chain = <ArgResults>[];
    for (ArgResults? level = results; level != null; level = level.command) {
      chain.add(level);
    }
    for (final level in chain.reversed) {
      if (level.options.contains('home') && level.wasParsed('home')) {
        return (
          parsed: true,
          home: normalizeSanadHomeOption(level['home'] as String?),
        );
      }
    }
    return (parsed: true, home: null);
  }

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
