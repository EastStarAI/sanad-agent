import 'dart:async';
import 'dart:convert' hide json;
import 'dart:io';

import 'package:uuid/uuid.dart';

import '../../../client/local_gateway_cli_client.dart';
import 'session_subcommand_base.dart';

/// Non-interactive live steering (`sanad session steer`).
///
/// A steer never discards progress: the daemon registers the text as a pending
/// steer for the run that currently owns the session and delivers it at the
/// next execution boundary. The command therefore reports only what it can
/// prove — that the gateway acknowledged the message as a pending steer for the
/// active turn — and never that the instruction has already been applied.
///
/// Every dispatch carries `steer_only: true`, so the daemon itself refuses a
/// steer that has no live owner (typed `no_active_turn`) instead of admitting
/// the text as a new turn or queuing it. The ownership pre-check stays as a
/// fast path: it answers without a round trip and keeps the local message
/// precise, but it is no longer the only guard, so a race between the read and
/// the dispatch cannot create a turn.
class SessionSteerCommand extends SessionSubcommandBase {
  /// Accepted as a pending steer for the active turn.
  static const int exitAccepted = 0;

  /// Transport, connection, or unexpected gateway failure.
  static const int exitFailed = 1;

  /// Invalid invocation (missing session id, message shape, or a bad file).
  static const int exitUsage = 2;

  /// No run owns the session, so there is nothing to steer.
  static const int exitNoActiveTurn = 3;

  /// The gateway answered without registering the text as a steer.
  static const int exitNotSteerable = 4;

  /// Dispatched but not acknowledged within the bounded wait.
  static const int exitUnacknowledged = 5;

  /// The daemon admitted the text as a new turn (`classification: think`).
  static const int exitAdmittedAsTurn = 6;

  /// The daemon queued the text as a later turn (`classification: queue`).
  static const int exitQueuedAsTurn = 7;

  /// The session projection could not be read, so no steer was dispatched.
  static const int exitStateUnreadable = 8;

  SessionSteerCommand({
    super.clientFactory,
    super.clientOverride,
    super.customAction,
  }) {
    argParser
      ..addOption(
        'message',
        help:
            'Steer text delivered to the active turn at the next execution boundary',
      )
      ..addOption(
        'message-file',
        abbr: 'f',
        help: 'Path to a file whose trimmed content is the steer text',
      );
  }

  @override
  String get name => 'steer';

  @override
  String get description =>
      'Steer an active turn mid-flight at its next execution boundary';

  @override
  String get invocation =>
      'sanad session steer <session-id> (--message <text> | --message-file <path>)';

  @override
  Future<int> execute() async {
    final id = resolveSessionId();
    if (id == null) {
      return reportUsage(id: null, message: 'Session ID is required.');
    }

    final rawMessage = getOption('message');
    final rawMessageFile = getOption('message-file');

    // Presence, not content, decides the shape: `--message "" --message-file f`
    // is an ambiguous invocation even though one of them is blank.
    if (rawMessage != null && rawMessageFile != null) {
      return reportUsage(
        id: id,
        message: '--message cannot be combined with --message-file.',
      );
    }
    if (rawMessage == null && rawMessageFile == null) {
      return reportUsage(
        id: id,
        message: 'One of --message or --message-file is required.',
      );
    }

    // `--timeout` is the acknowledgement bound and reuses the shared option's
    // documented range; a value outside it is a usage error, never a silent
    // fall-back to the default.
    final Duration? ackTimeout;
    try {
      ackTimeout = sessionAcknowledgementTimeout(timeoutSeconds);
    } on FormatException catch (e) {
      return reportUsage(id: id, message: e.message);
    }

    final String text;
    if (rawMessageFile != null) {
      // The path is used verbatim: a caller that quotes a path keeps exactly
      // the bytes it passed.
      final path = rawMessageFile;
      if (path.trim().isEmpty) {
        return reportUsage(id: id, message: 'Message file path is required.');
      }
      final type = FileSystemEntity.typeSync(path);
      if (type == FileSystemEntityType.directory) {
        return reportUsage(
          id: id,
          message: 'Message file "$path" is a directory; pass a file path.',
        );
      }
      if (type == FileSystemEntityType.notFound) {
        return reportUsage(
          id: id,
          message: 'Message file does not exist: $path',
        );
      }
      final String content;
      try {
        content = File(path).readAsStringSync().trim();
      } on FileSystemException catch (e) {
        return reportUsage(
          id: id,
          message: 'Failed to read message file "$path": ${e.message}',
        );
      }
      if (content.isEmpty) {
        return reportUsage(id: id, message: 'Message file "$path" is empty.');
      }
      text = content;
    } else {
      final content = rawMessage!.trim();
      if (content.isEmpty) {
        return reportUsage(id: id, message: 'Message cannot be empty.');
      }
      text = content;
    }

    // Allocated here so the same identity travels with the dispatch, the
    // acknowledgement wait, and every reported outcome — including a timeout,
    // where the caller needs it to correlate a late acknowledgement.
    final requestId = const Uuid().v4();

    try {
      return await withClient((client) async {
        // Fast-path ownership pre-check. The dispatch below is `steer_only`, so
        // the daemon is the authoritative guard; this read only saves a round
        // trip and lets the local message name the reason precisely.
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
                  'Failed to read the state of session $id before steering, '
                  'so no steer was sent: $e',
              exitCode: exitFailed,
            );
          }
          return reportFailure(
            sessionId: id,
            requestId: requestId,
            errorCode: 'session_state_unreadable',
            message:
                'Could not read the state of session $id, so no steer was '
                'sent (gateway code ${e.code}): ${e.message}',
            exitCode: exitStateUnreadable,
          );
        } catch (e) {
          return reportFailure(
            sessionId: id,
            requestId: requestId,
            errorCode: 'session_state_unreadable',
            message:
                'Could not read the state of session $id, so no steer was '
                'sent: $e',
            exitCode: exitStateUnreadable,
          );
        }
        if (!_hasActiveTurn(projection)) {
          return reportFailure(
            sessionId: id,
            requestId: requestId,
            errorCode: 'no_active_turn',
            message:
                'No run currently owns session $id, so there is nothing to '
                'steer and nothing was sent. Retry while the turn is running, '
                'or inspect it with: sanad session show $id',
            exitCode: exitNoActiveTurn,
          );
        }

        final ack = await client.steerAndAwaitAck(
          sessionId: id,
          message: text,
          requestId: requestId,
          steerOnly: true,
          timeout: ackTimeout,
        );
        final ackRequestId = ack['request_id']?.toString() ?? requestId;
        final classification = ack['classification']?.toString();
        final ackEvent = ack['event']?.toString() ?? 'gateway response';
        final ackState = ack['state']?.toString();

        if (classification == 'steer') {
          if (json) {
            stdoutSink.writeln(
              jsonEncode({
                'session_id': id,
                'request_id': ackRequestId,
                'status': 'steer_sent',
              }),
            );
          } else {
            stdoutSink.writeln(
              'Steer sent to session $id (request $ackRequestId).',
            );
          }
          return exitAccepted;
        }

        if (classification == 'think') {
          return reportFailure(
            sessionId: id,
            requestId: ackRequestId,
            errorCode: 'admitted_as_turn',
            message:
                'The daemon admitted the steer text as a NEW TURN: a turn is '
                'now running for session $id instead of being steered. The '
                'daemon did not honour `steer_only` (an older daemon), so the '
                'text was not applied to the previous turn.',
            exitCode: exitAdmittedAsTurn,
          );
        }

        if (classification == 'queue') {
          return reportFailure(
            sessionId: id,
            requestId: ackRequestId,
            errorCode: 'queued_as_turn',
            message:
                'The daemon queued the steer text as a LATER TURN for session '
                '$id: a turn is now queued instead of the text being applied '
                'to the active turn. The daemon did not honour `steer_only` '
                '(an older daemon).',
            exitCode: exitQueuedAsTurn,
          );
        }

        return reportFailure(
          sessionId: id,
          requestId: ackRequestId,
          errorCode: 'steer_not_applied',
          message:
              'The gateway acknowledged the message for session $id as '
              '"$ackEvent"${ackState == null ? '' : ' (state $ackState)'} '
              'without registering it as a pending steer.',
          exitCode: exitNotSteerable,
        );
      });
    } on CliClientException catch (e) {
      if (e.code == 'steer_unacknowledged') {
        return reportFailure(
          sessionId: id,
          requestId: requestId,
          errorCode: e.code,
          message:
              'Steer dispatched to session $id but not acknowledged in time; '
              'it may still be applied. Confirm with: sanad session show $id',
          exitCode: exitUnacknowledged,
        );
      }
      if (sessionTransportErrorCodes.contains(e.code)) {
        return reportFailure(
          sessionId: id,
          requestId: requestId,
          errorCode: e.code,
          message: 'Failed to steer session: $e',
          exitCode: exitFailed,
        );
      }
      if (e.code == 'no_active_turn') {
        // The daemon's own `steer_only` rejection: nothing was started and
        // nothing was queued, so this is the same condition as the local
        // pre-check, reported the same way.
        return reportFailure(
          sessionId: id,
          requestId: requestId,
          errorCode: 'no_active_turn',
          message:
              'No run currently owns session $id, so the daemon rejected the '
              'steer: no turn was started and the text was not queued. Retry '
              'while the turn is running, or inspect it with: '
              'sanad session show $id',
          exitCode: exitNoActiveTurn,
        );
      }
      // A typed gateway verdict (for example a rejected or invalid request).
      return reportFailure(
        sessionId: id,
        requestId: requestId,
        errorCode: e.code,
        message: 'Gateway rejected the steer: ${e.message}',
        exitCode: exitNotSteerable,
      );
    } catch (e) {
      return reportFailure(
        sessionId: id,
        requestId: requestId,
        errorCode: 'steer_failed',
        message: 'Failed to steer session: $e',
        exitCode: exitFailed,
      );
    }
  }

  /// Whether the session projection proves a run is currently steerable.
  ///
  /// The durable execution snapshot is authoritative: only `running`/`resuming`
  /// work can hold pending steers, and an in-memory partial-stream (`in_flight`)
  /// left behind by a stopped, blocked, or waiting run must not be read as an
  /// active turn (Task 134). A projection without a snapshot falls back to
  /// `in_flight`.
  ///
  /// Two further signals prove the run is past steering even while it still
  /// reads `running`:
  ///
  /// * the durable `stopping` state, which the stop path writes before it
  ///   cancels the run (the projection carries no in-memory stop flag, and the
  ///   daemon's own `steer_only` guard owns that distinction);
  /// * an active runtime recovery notice whose status is not `resuming` — a
  ///   `waiting` or `blocked` run is not executing, so a steer would have no
  ///   execution boundary to reach.
  ///
  /// A controlled-restart drain is not projected through the session query at
  /// all, so the daemon's own `steer_only` guard decides it; the pre-check only
  /// avoids a round trip when it already knows the answer.
  static bool _hasActiveTurn(Map<String, dynamic> projection) {
    final snapshot = projection['execution_snapshot'];
    final state = snapshot is Map ? snapshot['state']?.toString() : null;
    if (state == null) return projection['in_flight'] is Map;
    if (state != 'running' && state != 'resuming') return false;
    final notice = projection['runtime_notice'];
    final noticeStatus = notice is Map ? notice['status']?.toString() : null;
    if (noticeStatus != null && noticeStatus != 'resuming') return false;
    return true;
  }
}
