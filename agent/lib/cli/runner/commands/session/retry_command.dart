import 'dart:async';
import 'dart:convert' hide json;

import 'package:uuid/uuid.dart';

import '../../../client/local_gateway_cli_client.dart';
import 'session_subcommand_base.dart';

/// Non-interactive runtime recovery retry (`sanad session retry`).
///
/// A blocked `sanad run` worker has no client attached, so nothing presses the
/// Sanad Client's Retry action and the session can stay blocked indefinitely.
/// This command dispatches the same `session.runtime_retry` command that action
/// sends and reports the daemon's own recovery transition.
///
/// It resumes the suspended request the session already owns, on the same route
/// unless `--provider`/`--model` override it. The dedicated "Change Provider"
/// action is a different command (`session.runtime_continue_with_provider`,
/// reason `provider_changed`, route-confirmation broadcast); this one is the
/// recovery Retry with an optional route override, reason `manual_retry`.
class SessionRetryCommand extends SessionSubcommandBase {
  /// The daemon accepted the retry and is resuming the suspended request.
  static const int exitAccepted = 0;

  /// Transport, connection, or unexpected gateway failure.
  static const int exitFailed = 1;

  /// Invalid invocation (missing session id or an unusable `--timeout`).
  static const int exitUsage = 2;

  /// The session is not in a retryable blocked or waiting recovery state.
  static const int exitNotBlocked = 3;

  /// The daemon rejected the retry with a typed recovery notice.
  static const int exitRejected = 4;

  /// Dispatched but not acknowledged within the bounded wait.
  static const int exitUnacknowledged = 5;

  /// The session projection could not be read, so no retry was dispatched.
  static const int exitStateUnreadable = 8;

  SessionRetryCommand({
    super.clientFactory,
    super.clientOverride,
    super.customAction,
  });

  @override
  String get name => 'retry';

  @override
  String get description =>
      'Retry a blocked or waiting session through the daemon recovery owner';

  @override
  String get invocation =>
      'sanad session retry <session-id> [--provider <instance-id>] '
      '[--model <model-id>]';

  @override
  Future<int> execute() async {
    final id = resolveSessionId();
    if (id == null) {
      return reportUsage(id: null, message: 'Session ID is required.');
    }

    final Duration? ackTimeout;
    try {
      ackTimeout = sessionAcknowledgementTimeout(timeoutSeconds);
    } on FormatException catch (e) {
      return reportUsage(id: id, message: e.message);
    }

    // The shared `--provider`/`--model` options map to the retry payload's
    // `provider_instance_id`/`model_id`. A blank value is treated as absent so
    // an empty shell variable never becomes a provider id.
    final providerInstanceId = _blankToNull(getOption('provider'));
    final modelId = _blankToNull(getOption('model'));

    // Allocated before dispatch so a timeout still names the identity a caller
    // can correlate a late acknowledgement with.
    final requestId = const Uuid().v4();

    try {
      return await withClient((client) async {
        // The pre-check answers without a dispatch and keeps "nothing was sent"
        // exact: a retry on a healthy session would be a silent no-op at best
        // (already resuming) and a second turn at worst.
        final Map<String, dynamic> projection;
        try {
          projection = unwrapSessionPayload(
            await client.getSessionHistory(sessionId: id),
          );
        } on CliClientException catch (e) {
          if (sessionTransportErrorCodes.contains(e.code)) {
            return reportFailure(
              sessionId: id,
              requestId: requestId,
              errorCode: e.code,
              message:
                  'Failed to read the state of session $id before retrying, '
                  'so nothing was sent: $e',
              exitCode: exitFailed,
            );
          }
          return reportFailure(
            sessionId: id,
            requestId: requestId,
            errorCode: 'session_state_unreadable',
            message:
                'Could not read the state of session $id, so nothing was sent '
                '(gateway code ${e.code}): ${e.message}',
            exitCode: exitStateUnreadable,
          );
        } catch (e) {
          return reportFailure(
            sessionId: id,
            requestId: requestId,
            errorCode: 'session_state_unreadable',
            message:
                'Could not read the state of session $id, so nothing was sent: '
                '$e',
            exitCode: exitStateUnreadable,
          );
        }

        if (!_isRetryable(projection)) {
          return reportFailure(
            sessionId: id,
            requestId: requestId,
            errorCode: 'not_blocked',
            message:
                'Session $id is not blocked or waiting for a retry, so nothing '
                'was sent. Inspect it with: sanad session show $id',
            exitCode: exitNotBlocked,
          );
        }

        final ack = await client.retryRuntimeAndAwaitAck(
          sessionId: id,
          requestId: requestId,
          providerInstanceId: providerInstanceId,
          modelId: modelId,
          timeout: ackTimeout,
        );
        final ackRequestId = ack['request_id']?.toString() ?? requestId;
        final noticeRequestId = ack['notice_request_id']?.toString();

        if (json) {
          stdoutSink.writeln(
            jsonEncode({
              'session_id': id,
              'request_id': ackRequestId,
              'status': 'retrying',
              'notice_request_id': ?noticeRequestId,
            }),
          );
        } else {
          stdoutSink.writeln(
            'Retry accepted for session $id (request $ackRequestId): the '
            'daemon is resuming the last request.',
          );
        }
        return exitAccepted;
      });
    } on CliClientException catch (e) {
      if (e.code == 'retry_unacknowledged') {
        return reportFailure(
          sessionId: id,
          requestId: requestId,
          errorCode: e.code,
          message:
              'Retry dispatched to session $id but not acknowledged in time; '
              'the daemon may still resume it. Confirm with: '
              'sanad session show $id',
          exitCode: exitUnacknowledged,
        );
      }
      if (sessionTransportErrorCodes.contains(e.code)) {
        return reportFailure(
          sessionId: id,
          requestId: requestId,
          errorCode: e.code,
          message: 'Failed to retry session: $e',
          exitCode: exitFailed,
        );
      }
      return reportFailure(
        sessionId: id,
        requestId: requestId,
        errorCode: e.code,
        message: 'Gateway rejected the retry: ${e.message}',
        exitCode: exitRejected,
      );
    } catch (e) {
      return reportFailure(
        sessionId: id,
        requestId: requestId,
        errorCode: 'retry_failed',
        message: 'Failed to retry session: $e',
        exitCode: exitFailed,
      );
    }
  }

  /// Whether the projection proves the session is waiting for a recovery.
  ///
  /// The daemon's own recovery notice is authoritative: `blocked` waits for an
  /// explicit Retry/Change Provider/Stop, and `waiting` waits on a resume timer
  /// a manual retry may shorten. The durable execution snapshot is the second
  /// signal, because restored blocked work can be projected before its notice is
  /// rehydrated. Anything else — idle, queued, running, resuming, stopping — is
  /// not a retry target, and this command sends nothing for it.
  static bool _isRetryable(Map<String, dynamic> projection) {
    final notice = projection['runtime_notice'];
    final noticeStatus = notice is Map ? notice['status']?.toString() : null;
    if (noticeStatus == 'blocked' || noticeStatus == 'waiting') return true;
    final snapshot = projection['execution_snapshot'];
    final state = snapshot is Map ? snapshot['state']?.toString() : null;
    return state == 'blocked' || state == 'waiting';
  }

  static String? _blankToNull(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }
}
