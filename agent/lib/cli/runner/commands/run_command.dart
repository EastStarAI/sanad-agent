import 'dart:async';

import 'package:args/command_runner.dart';

import '../../client/local_gateway_cli_client.dart';
import '../../oneshot/oneshot_runner.dart';
import '../sanad_command.dart';

/// Command to execute a one-shot task or instruction without entering interactive chat.
class RunCommand extends SanadCommand {
  final OneshotRunner? runnerOverride;
  final StdinReader? stdinReader;
  final ClientFactory? clientFactory;
  final LocalGatewayCliClient? clientOverride;

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
    final restArgs = argResults?.rest ?? const [];
    final restPrompt = restArgs.join(' ').trim();

    String effectivePrompt = '';
    final opt = promptOption?.trim() ?? '';
    if (opt.isNotEmpty && restPrompt.isNotEmpty) {
      effectivePrompt = '$opt $restPrompt';
    } else if (opt.isNotEmpty) {
      effectivePrompt = opt;
    } else if (restPrompt.isNotEmpty) {
      effectivePrompt = restPrompt;
    }

    final timeout = _parseTimeout(timeoutSeconds);
    final runner =
        runnerOverride ??
        OneshotRunner(stdinReader: stdinReader, clientFactory: clientFactory);

    return await runner.run(
      prompt: effectivePrompt,
      workspace: workspace,
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
