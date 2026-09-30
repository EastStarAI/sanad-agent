import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';

import '../../core/constants.dart';
import 'sanad_command_runner.dart';

const cliThinkingModes = [
  'none',
  'minimal',
  'low',
  'medium',
  'high',
  'xhigh',
  'max',
  'fast',
  'balanced',
  'normal',
  'deep',
];

/// Base command for all Sanad CLI commands.
abstract class SanadCommand extends Command<int> {
  /// Optional custom action callback for testing and custom injection.
  final FutureOr<int> Function(SanadCommand command)? customAction;

  /// Optional top-level parsed results when invoked as default fallback.
  ArgResults? overrideGlobalResults;

  SanadCommand({this.customAction});

  /// Output sink for standard output messages.
  StringSink get stdoutSink =>
      (runner as SanadCommandRunner?)?.stdoutSink ?? stdout;

  /// Output sink for error messages.
  StringSink get stderrSink =>
      (runner as SanadCommandRunner?)?.stderrSink ?? stderr;

  /// Adds common global CLI options to a subcommand [parser].
  /// This allows flags like `--workspace` or `--model` to appear either before
  /// or after the subcommand name (e.g. `sanad chat -w /app` or `sanad -w /app chat`).
  void addCommonOptions(ArgParser parser) {
    parser
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
        help: 'Model name override for agent tasks',
      )
      ..addOption(
        'provider',
        help: 'LLM provider override (e.g. openai, anthropic, ollama)',
      )
      ..addFlag(
        'thinking',
        help: 'Enable deep reasoning/thinking mode',
        negatable: true,
        defaultsTo: false,
      )
      ..addFlag(
        'quiet',
        abbr: 'q',
        help: 'Suppress non-essential progress output',
        negatable: false,
      )
      ..addFlag(
        'json',
        help: 'Output one machine-readable JSON result object',
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
      ..addOption(
        'home',
        help:
            'Path to custom Sanad home directory (defaults to SANAD_HOME env or ~/.sanad)',
      )
      ..addOption(
        'gateway-url',
        help: 'Override Local Gateway WebSocket endpoint URL',
      );
  }

  /// Retrieves an option value from [argResults] first, falling back to [globalResults]
  /// or [overrideGlobalResults].
  String? getOption(String name) {
    final globals = overrideGlobalResults ?? globalResults;
    if (argResults != null &&
        argResults!.options.contains(name) &&
        argResults!.wasParsed(name)) {
      return argResults![name] as String?;
    }
    if (globals != null &&
        globals.options.contains(name) &&
        globals.wasParsed(name)) {
      return globals[name] as String?;
    }
    return null;
  }

  /// Retrieves a boolean flag from [argResults] first, falling back to [globalResults]
  /// or [overrideGlobalResults].
  bool getFlag(String name) {
    final globals = overrideGlobalResults ?? globalResults;
    if (argResults != null &&
        argResults!.options.contains(name) &&
        argResults!.wasParsed(name)) {
      return argResults![name] as bool;
    }
    if (globals != null && globals.options.contains(name)) {
      return globals[name] as bool;
    }
    return false;
  }

  // Convenience getters for standard CLI flags.
  String? get prompt => getOption('prompt');
  String? get workspace => getOption('workspace');
  String? get session => getOption('session');
  String? get model => getOption('model');
  String? get provider => getOption('provider');
  String? get timeoutSeconds => getOption('timeout');
  bool get thinking => getFlag('thinking');
  String? get thinkingMode => getOption('thinking-mode');
  bool get quiet => getFlag('quiet');
  bool get json => getFlag('json');
  String? get account => getOption('account');
  bool get standalone => getFlag('standalone');
  String? get gatewayUrl => getOption('gateway-url');
  String get sanadHome => getOption('home') ?? getSanadHome();

  @override
  Future<int> run() async {
    if (customAction != null) {
      return await customAction!(this);
    }
    return await execute();
  }

  /// Implementation of the command logic.
  FutureOr<int> execute();
}
