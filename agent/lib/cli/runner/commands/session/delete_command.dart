import 'dart:async';
import 'dart:convert' hide json;

import 'session_subcommand_base.dart';

class SessionDeleteCommand extends SessionSubcommandBase {
  SessionDeleteCommand({
    super.clientFactory,
    super.clientOverride,
    super.customAction,
  });

  @override
  String get name => 'delete';

  @override
  String get description => 'Delete a session and its cached turns';

  @override
  String get invocation => 'sanad session delete <session-id>';

  @override
  Future<int> execute() async {
    final id = resolveSessionId();
    if (id == null) {
      stderrSink.writeln('Error: Session ID is required.');
      stderrSink.writeln('Usage: $invocation');
      return 1;
    }

    try {
      return await withClient((client) async {
        await client.query(
          command: 'delete_session',
          payload: {'session_id': id},
        );
        if (json) {
          stdoutSink.writeln(
            jsonEncode({'session_id': id, 'status': 'deleted'}),
          );
        } else {
          stdoutSink.writeln('Session $id deleted.');
        }
        return 0;
      });
    } catch (e) {
      rethrowEndpointFailure(e);
      stderrSink.writeln('Error: Failed to delete session: $e');
      if (json) {
        stdoutSink.writeln(jsonEncode({'exit_code': 1, 'error': e.toString()}));
      }
      return 1;
    }
  }
}
