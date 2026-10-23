import 'dart:async';
import 'dart:convert' hide json;

import '../../../../core/config.dart';
import '../../../client/local_gateway_cli_client.dart';
import 'session_subcommand_base.dart';

class SessionCompactCommand extends SessionSubcommandBase {
  SessionCompactCommand({
    super.clientFactory,
    super.clientOverride,
    super.customAction,
  });

  @override
  String get name => 'compact';

  @override
  String get description =>
      'Request context compaction admission for a specific session';

  @override
  String get invocation => 'sanad session compact <session-id>';

  @override
  Future<int> execute() async {
    final id = resolveSessionId();
    if (id == null) {
      stderrSink.writeln('Error: Session ID is required.');
      stderrSink.writeln('Usage: $invocation');
      if (json) {
        stdoutSink.writeln(
          jsonEncode({'exit_code': 1, 'error': 'Session ID is required.'}),
        );
      }
      return 1;
    }

    // The daemon replies only when its compaction operation ends, so the
    // wait is bounded by the runtime's own compaction pass timeout unless
    // the caller sets --timeout (Task 125).
    final configuredBound =
        ModelAwareRuntimePolicy.compactionPassTimeoutForHome(sanadHome);
    final explicitSeconds = timeoutSeconds == null
        ? null
        : int.tryParse(timeoutSeconds!);
    final timeout = explicitSeconds != null && explicitSeconds > 0
        ? Duration(seconds: explicitSeconds)
        : configuredBound;

    try {
      return await withClient((client) async {
        final result = await client.compactSession(
          sessionId: id,
          timeout: timeout,
          resendOnTimeout: false,
        );

        final unwrapped = (result['payload'] is Map<String, dynamic>)
            ? Map<String, dynamic>.from(result['payload'] as Map)
            : result;
        final rawOutcome =
            unwrapped['outcome']?.toString() ?? result['outcome']?.toString();

        final isMalformed = rawOutcome == null || rawOutcome.trim().isEmpty;
        final outcome = isMalformed ? 'failed' : rawOutcome.trim();

        final payload = <String, dynamic>{
          'session_id': id,
          ...result,
          if (unwrapped != result) ...unwrapped,
          'outcome': outcome,
        };

        if (isMalformed && !payload.containsKey('failure_reason')) {
          payload['failure_reason'] = 'missing_outcome';
        }

        final isSuccess =
            outcome == 'accepted' ||
            outcome == 'dispatched' ||
            outcome == 'no_op';

        if (!isSuccess && !payload.containsKey('exit_code')) {
          payload['exit_code'] = 1;
        }

        if (json) {
          stdoutSink.writeln(jsonEncode(payload));
        } else {
          final compactionId = payload['compaction_id']?.toString();
          if (outcome == 'accepted' || outcome == 'dispatched') {
            stdoutSink.writeln(
              'Compaction request $outcome for session $id'
              '${compactionId != null ? ' (compaction_id: $compactionId)' : ''}.',
            );
          } else if (outcome == 'no_op') {
            stdoutSink.writeln('No compaction needed for session $id.');
          } else {
            final reason = payload['failure_reason']?.toString();
            stdoutSink.writeln(
              'Compaction request for session $id finished with outcome "$outcome"'
              '${reason != null ? ': $reason' : ''}.',
            );
          }
        }
        return isSuccess ? 0 : 1;
      });
    } on CliClientException catch (e) {
      if (e.code != 'query_timeout') return _reportCompactError(id, e);
      // No result within the bound is not a failure: the single dispatch is
      // never resent and the daemon may still be compacting.
      final poll = 'sanad session show $id';
      const exitCode = 124;
      final message =
          'Compaction for session $id is unconfirmed after '
          '${timeout.inSeconds}s; the daemon may still be compacting. '
          'Check with: $poll';
      if (json) {
        stdoutSink.writeln(
          jsonEncode({
            'session_id': id,
            'outcome': 'unconfirmed',
            'poll': poll,
            'exit_code': exitCode,
          }),
        );
      }
      stderrSink.writeln('Notice: $message');
      return exitCode;
    } catch (e) {
      rethrowEndpointFailure(e);
      return _reportCompactError(id, e);
    }
  }

  int _reportCompactError(String id, Object e) {
    stderrSink.writeln('Error: Failed to compact session: $e');
    if (json) {
      stdoutSink.writeln(
        jsonEncode({'session_id': id, 'exit_code': 1, 'error': e.toString()}),
      );
    }
    return 1;
  }
}
