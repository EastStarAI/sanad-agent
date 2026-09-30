import 'dart:async';

import '../../client/local_gateway_cli_client.dart';
import '../../oneshot/oneshot_runner.dart';
import '../../repl/interactive_repl_session.dart';
import '../../repl/repl_history.dart';
import '../../repl/repl_line_reader.dart';
import '../../workspace/workspace_cli_service.dart';
import '../sanad_command.dart';

/// Command to launch the interactive CLI reasoning assistant (Chat REPL).
class ChatCommand extends SanadCommand {
  final FutureOr<int> Function(List<String> args)? onChat;
  final InteractiveReplSession? sessionOverride;
  final LocalGatewayCliClient? clientOverride;
  final ClientFactory? clientFactory;
  final ReplLineReader? lineReader;
  final ReplHistory? history;
  final WorkspaceCliService? workspaceService;

  ChatCommand({
    this.onChat,
    super.customAction,
    this.sessionOverride,
    this.clientOverride,
    this.clientFactory,
    this.lineReader,
    this.history,
    this.workspaceService,
  }) {
    addCommonOptions(argParser);
  }

  @override
  String get name => 'chat';

  @override
  List<String> get aliases => const ['cli'];

  @override
  String get description =>
      'Launch the interactive CLI reasoning assistant (Default)';

  @override
  String get invocation => 'sanad chat [session-id] [options]';

  @override
  Future<int> execute() async {
    final remaining = argResults?.rest ?? const [];
    if (onChat != null) {
      return await onChat!(remaining);
    }

    final sessionArg = remaining.isNotEmpty ? remaining.first.trim() : null;
    final effectiveSession = (sessionArg != null && sessionArg.isNotEmpty)
        ? sessionArg
        : session;

    final replSession =
        sessionOverride ??
        InteractiveReplSession(
          clientOverride: clientOverride,
          clientFactory: clientFactory,
          lineReaderOverride: lineReader,
          historyOverride: history,
          workspace: workspace,
          session: effectiveSession,
          model: model,
          provider: provider,
          thinking: thinking,
          standalone: standalone,
          gatewayUrl: gatewayUrl,
          sanadHome: sanadHome,
          stdoutSink: stdoutSink,
          stderrSink: stderrSink,
        );

    return await replSession.run();
  }
}
