import 'dart:async';
import 'dart:convert' hide json;

import 'session_subcommand_base.dart';

class SessionListCommand extends SessionSubcommandBase {
  SessionListCommand({
    super.clientFactory,
    super.clientOverride,
    super.customAction,
  });

  @override
  String get name => 'list';

  @override
  String get description => 'List existing conversation sessions';

  @override
  String get invocation => 'sanad session list [options]';

  @override
  Future<int> execute() async {
    try {
      return await withClient((client) async {
        final sessions = await client.getSessions();

        if (json) {
          stdoutSink.writeln(jsonEncode(sessions));
          return 0;
        }

        if (sessions.isEmpty) {
          stdoutSink.writeln('Active sessions:');
          stdoutSink.writeln('  (No cached sessions found)');
          return 0;
        }

        stdoutSink.writeln('Active sessions:');
        for (final s in sessions) {
          final sId = s['session_id'] ?? s['id'] ?? 'unknown';
          final title = s['title'] != null && s['title'].toString().isNotEmpty
              ? ' (${s['title']})'
              : '';
          final m = s['model'] != null ? ' - ${s['model']}' : '';
          final isPending =
              s['has_pending_permission_request'] == true ||
              (s['metadata'] is Map &&
                  s['metadata']['has_pending_permission_request'] == true);
          final pending = isPending ? ' [Pending intervention]' : '';
          stdoutSink.writeln('  $sId$title$m$pending');
        }
        return 0;
      });
    } catch (e) {
      rethrowEndpointFailure(e);
      stderrSink.writeln('Error: Failed to list sessions: $e');
      if (json) {
        stdoutSink.writeln(jsonEncode({'exit_code': 1, 'error': e.toString()}));
      }
      return 1;
    }
  }
}
