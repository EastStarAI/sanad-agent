import 'dart:async';
import 'dart:convert' hide json;

import '../../../client/local_gateway_cli_client.dart';
import 'session_subcommand_base.dart';

class SessionStopCommand extends SessionSubcommandBase {
  SessionStopCommand({
    super.clientFactory,
    super.clientOverride,
    super.customAction,
  });

  @override
  String get name => 'stop';

  @override
  String get description => 'Stop execution for a specific session';

  @override
  String get invocation => 'sanad session stop <session-id>';

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
        // Name the execution the operator observed. Resolution is best-effort:
        // the stop must still be dispatched when the session state cannot be
        // read, and the daemon's stop is session-scoped either way (Task 134).
        final runId = await _resolveInFlightRunId(client, id);
        await client.stop(sessionId: id, runId: runId);

        if (json) {
          stdoutSink.writeln(
            jsonEncode({'session_id': id, 'status': 'stopped'}),
          );
        } else {
          stdoutSink.writeln('Session $id stopped.');
        }
        return 0;
      });
    } catch (e) {
      rethrowEndpointFailure(e);
      stderrSink.writeln('Error: Failed to stop session: $e');
      if (json) {
        stdoutSink.writeln(jsonEncode({'exit_code': 1, 'error': e.toString()}));
      }
      return 1;
    }
  }

  /// Reads the session's authoritative `in_flight` run identity so the stop
  /// names the same execution the Client UI would stop.
  Future<String?> _resolveInFlightRunId(
    LocalGatewayCliClient client,
    String sessionId,
  ) async {
    try {
      final history = await client.getSessionHistory(sessionId: sessionId);
      final payload = unwrapSessionPayload(history);
      final inFlight = payload['in_flight'];
      if (inFlight is Map) {
        final runId = inFlight['run_id']?.toString();
        if (runId != null && runId.isNotEmpty) return runId;
      }
    } catch (_) {
      // Best-effort: the stop command does not depend on this read.
    }
    return null;
  }
}
