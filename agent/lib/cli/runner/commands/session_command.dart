import 'dart:async';

import '../../client/local_gateway_cli_client.dart';
import '../../oneshot/oneshot_runner.dart';
import '../sanad_command.dart';
import 'session/answer_command.dart';
import 'session/compact_command.dart';
import 'session/delete_command.dart';
import 'session/list_command.dart';
import 'session/new_command.dart';
import 'session/permission_command.dart';
import 'session/retry_command.dart';
import 'session/show_command.dart';
import 'session/steer_command.dart';
import 'session/stop_command.dart';

export 'session/answer_command.dart';
export 'session/compact_command.dart';
export 'session/delete_command.dart';
export 'session/list_command.dart';
export 'session/new_command.dart';
export 'session/permission_command.dart';
export 'session/retry_command.dart';
export 'session/session_subcommand_base.dart';
export 'session/show_command.dart';
export 'session/steer_command.dart';
export 'session/stop_command.dart';

/// Command to manage and inspect conversation sessions.
class SessionCommand extends SanadCommand {
  final ClientFactory? clientFactory;
  final LocalGatewayCliClient? clientOverride;

  SessionCommand({
    this.clientFactory,
    this.clientOverride,
    super.customAction,
  }) {
    addCommonOptions(argParser);
    addSubcommand(
      SessionListCommand(
        clientFactory: clientFactory,
        clientOverride: clientOverride,
        customAction: customAction != null ? (cmd) => customAction!(cmd) : null,
      ),
    );
    addSubcommand(
      SessionShowCommand(
        clientFactory: clientFactory,
        clientOverride: clientOverride,
        customAction: customAction != null ? (cmd) => customAction!(cmd) : null,
      ),
    );
    addSubcommand(
      SessionStopCommand(
        clientFactory: clientFactory,
        clientOverride: clientOverride,
        customAction: customAction != null ? (cmd) => customAction!(cmd) : null,
      ),
    );
    addSubcommand(
      SessionCompactCommand(
        clientFactory: clientFactory,
        clientOverride: clientOverride,
        customAction: customAction != null ? (cmd) => customAction!(cmd) : null,
      ),
    );
    addSubcommand(
      SessionAnswerCommand(
        clientFactory: clientFactory,
        clientOverride: clientOverride,
        customAction: customAction != null ? (cmd) => customAction!(cmd) : null,
      ),
    );
    addSubcommand(
      SessionPermissionCommand(
        clientFactory: clientFactory,
        clientOverride: clientOverride,
        customAction: customAction != null ? (cmd) => customAction!(cmd) : null,
      ),
    );
    addSubcommand(
      SessionSteerCommand(
        clientFactory: clientFactory,
        clientOverride: clientOverride,
        customAction: customAction != null ? (cmd) => customAction!(cmd) : null,
      ),
    );
    addSubcommand(
      SessionRetryCommand(
        clientFactory: clientFactory,
        clientOverride: clientOverride,
        customAction: customAction != null ? (cmd) => customAction!(cmd) : null,
      ),
    );
    addSubcommand(
      SessionNewCommand(
        customAction: customAction != null ? (cmd) => customAction!(cmd) : null,
      ),
    );
    addSubcommand(
      SessionDeleteCommand(
        clientFactory: clientFactory,
        clientOverride: clientOverride,
        customAction: customAction != null ? (cmd) => customAction!(cmd) : null,
      ),
    );
  }

  @override
  String get name => 'session';

  @override
  String get description => 'Manage and inspect conversation sessions';

  @override
  String get invocation => 'sanad session <subcommand> [options]';

  @override
  Future<int> execute() async {
    final listCmd = subcommands['list'] as SessionListCommand?;
    if (listCmd != null) {
      listCmd.overrideGlobalResults = overrideGlobalResults ?? globalResults;
      return await listCmd.execute();
    }
    printUsage();
    return 0;
  }
}
