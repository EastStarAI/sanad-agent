import 'dart:async';
import 'dart:convert' hide json;

import 'session_subcommand_base.dart';

class SessionAnswerCommand extends SessionSubcommandBase {
  SessionAnswerCommand({
    super.clientFactory,
    super.clientOverride,
    super.customAction,
  }) {
    argParser
      ..addOption(
        'request-id',
        abbr: 'r',
        help: 'Request ID of the pending clarification',
      )
      ..addOption(
        'answer',
        abbr: 'a',
        help: 'Answer text for the clarification',
      )
      ..addOption(
        'file',
        abbr: 'f',
        help: 'Path to a file containing the answer text or JSON payload',
      );
  }

  @override
  String get name => 'answer';

  @override
  String get description =>
      'Submit an explicit answer for a pending user clarification (system_ask_user)';

  @override
  String get invocation =>
      'sanad session answer <session-id> --request-id <req-id> --answer <text>';

  @override
  Future<int> execute() async {
    final id = resolveSessionId();
    if (id == null) {
      stderrSink.writeln('Error: Session ID is required.');
      stderrSink.writeln('Usage: $invocation');
      return 1;
    }

    final reqId = resolveRequestId();
    if (reqId == null) {
      stderrSink.writeln('Error: Request ID is required.');
      stderrSink.writeln('Usage: $invocation');
      return 1;
    }

    String? answerText = getOption('answer');
    final filePath = getOption('file');

    if (filePath != null && filePath.isNotEmpty) {
      answerText = readAnswerFile(filePath);
      if (answerText == null) return 1;
    }

    if (answerText == null || answerText.trim().isEmpty) {
      stderrSink.writeln('Error: Answer cannot be empty.');
      stderrSink.writeln('Usage: $invocation');
      return 1;
    }

    try {
      return await withClient((client) async {
        final result = await client.respondAnswer(
          sessionId: id,
          requestId: reqId,
          answer: answerText!.trim(),
        );

        final payload = unwrapSessionPayload(result);
        final outcome = payload['outcome']?.toString() ?? 'resolved';

        if (json) {
          stdoutSink.writeln(
            jsonEncode({
              'session_id': id,
              'request_id': reqId,
              'status': 'resolved',
              'outcome': outcome,
            }),
          );
        } else {
          stdoutSink.writeln(
            'Answer submitted successfully for session $id (request $reqId).',
          );
        }
        return 0;
      });
    } catch (e) {
      rethrowEndpointFailure(e);
      stderrSink.writeln('Error: $e');
      if (json) {
        stdoutSink.writeln(
          jsonEncode({
            'session_id': id,
            'request_id': reqId,
            'status': 'error',
            'error': e.toString(),
          }),
        );
      }
      return 1;
    }
  }
}
