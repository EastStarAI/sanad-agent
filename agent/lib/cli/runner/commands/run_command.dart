import 'dart:async';
import 'dart:io';

import 'package:args/command_runner.dart';

import '../../../capabilities/runtime/workspace_path_resolver.dart';
import '../../client/cli_turn_client.dart';
import '../../oneshot/oneshot_runner.dart';
import '../sanad_command.dart';

/// Command to execute a one-shot task or instruction without entering interactive chat.
class RunCommand extends SanadCommand {
  final OneshotRunner? runnerOverride;
  final StdinReader? stdinReader;
  final ClientFactory? clientFactory;
  final CliTurnClient? clientOverride;

  RunCommand({
    super.customAction,
    this.runnerOverride,
    this.stdinReader,
    this.clientFactory,
    this.clientOverride,
  }) {
    addCommonOptions(argParser);
    argParser
      ..addOption(
        'prompt',
        abbr: 'p',
        help: 'One-shot prompt or instruction to execute',
      )
      ..addOption(
        'brief-file',
        abbr: 'b',
        help: 'Path to brief file containing task prompt instructions',
      )
      ..addOption(
        'execution-root',
        help:
            'Execution root directory for tool execution and child process working directory',
      )
      ..addOption(
        'out-dir',
        abbr: 'o',
        help:
            'Output directory where result.json and timeline events are written',
      )
      ..addFlag(
        'events',
        help:
            'Stream machine-readable NDJSON lifecycle events during execution',
        negatable: false,
      )
      ..addFlag(
        'allow-all-tools',
        help: 'DANGER: automatically approve every gated tool for this one run',
        negatable: false,
      );
  }

  @override
  String get name => 'run';

  @override
  String get description =>
      'Execute a one-shot task or instruction without entering interactive chat';

  @override
  String get invocation => 'sanad run <prompt> [options]';

  String? get promptOption => getOption('prompt');
  bool get allowAllTools => getFlag('allow-all-tools');

  @override
  Future<int> execute() async {
    final briefFile = getOption('brief-file');
    final restArgs = argResults?.rest ?? const [];
    final restPrompt = restArgs.join(' ').trim();
    final optPrompt = promptOption?.trim() ?? '';

    String effectivePrompt = '';
    if (briefFile != null && briefFile.trim().isNotEmpty) {
      if (optPrompt.isNotEmpty || restPrompt.isNotEmpty) {
        stderrSink.writeln(
          'Error: Mutually exclusive: cannot specify both --brief-file and a positional/option prompt.',
        );
        return 2;
      }
      final file = File(briefFile.trim());
      if (!file.existsSync()) {
        stderrSink.writeln('Error: Brief file "$briefFile" does not exist.');
        return 2;
      }
      final content = file.readAsStringSync().trim();
      if (content.isEmpty) {
        stderrSink.writeln('Error: Brief file "$briefFile" is empty.');
        return 2;
      }
      effectivePrompt = content;
    } else {
      if (optPrompt.isNotEmpty && restPrompt.isNotEmpty) {
        effectivePrompt = '$optPrompt $restPrompt';
      } else if (optPrompt.isNotEmpty) {
        effectivePrompt = optPrompt;
      } else if (restPrompt.isNotEmpty) {
        effectivePrompt = restPrompt;
      }
    }

    final cdPath = getOption('execution-root');
    String? normalizedExecutionRoot;
    if (cdPath != null && cdPath.trim().isNotEmpty) {
      try {
        normalizedExecutionRoot = const WorkspacePathResolver()
            .validateAndNormalizeExecutionRoot(cdPath);
      } on FileSystemException catch (e) {
        stderrSink.writeln(
          'Error: Invalid execution root: ${e.message} (${e.path})',
        );
        return 2;
      }
    }

    final effectiveWorkspace = workspace;
    final outDir = getOption('out-dir');
    if (outDir != null && outDir.trim().isNotEmpty) {
      try {
        Directory(outDir.trim()).createSync(recursive: true);
      } catch (e) {
        stderrSink.writeln(
          'Error: Failed to create output directory "$outDir": $e',
        );
        return 2;
      }
    }

    final streamEvents = getFlag('events');
    final timeout = _parseTimeout(timeoutSeconds);
    final runner =
        runnerOverride ??
        OneshotRunner(stdinReader: stdinReader, clientFactory: clientFactory);

    return await runner.run(
      prompt: effectivePrompt,
      workspace: effectiveWorkspace,
      session: session,
      model: model,
      provider: provider,
      thinking: thinking,
      quiet: quiet,
      json: json,
      standalone: standalone,
      gatewayUrl: gatewayUrl,
      sanadHome: sanadHome,
      allowAllTools: allowAllTools,
      timeout: timeout,
      stdoutSink: stdoutSink,
      stderrSink: stderrSink,
      client: clientOverride,
      outDir: outDir?.trim(),
      streamEvents: streamEvents,
      executionRoot: normalizedExecutionRoot,
    );
  }

  Duration _parseTimeout(String? raw) {
    if (raw == null) return const Duration(minutes: 5);
    final seconds = int.tryParse(raw);
    if (seconds == null || seconds < 1 || seconds > 86400) {
      throw UsageException(
        '--timeout must be a whole number of seconds from 1 to 86400.',
        usage,
      );
    }
    return Duration(seconds: seconds);
  }
}
