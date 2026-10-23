import 'dart:async';
import 'dart:convert' hide json;

import 'session_subcommand_base.dart';

class SessionPermissionCommand extends SessionSubcommandBase {
  SessionPermissionCommand({
    super.clientFactory,
    super.clientOverride,
    super.customAction,
  }) {
    argParser
      ..addOption(
        'request-id',
        abbr: 'r',
        help: 'Request ID of the pending tool permission',
      )
      ..addFlag(
        'allow',
        help: 'Grant permission for the tool execution',
        negatable: false,
      )
      ..addFlag(
        'deny',
        help: 'Deny permission for the tool execution',
        negatable: false,
      )
      ..addOption('decision', abbr: 'd', help: 'Decision: "allow" or "deny"')
      ..addOption(
        'scope',
        help: 'Permission scope: once, session, workspace',
        defaultsTo: 'once',
      )
      ..addOption(
        'comment',
        abbr: 'c',
        help: 'Optional comment explaining the decision',
      )
      ..addOption(
        'file',
        abbr: 'f',
        help: 'Path to a JSON file containing the permission decision',
      );
  }

  @override
  String get name => 'permission';

  @override
  List<String> get aliases => const ['permit', 'decide'];

  @override
  String get description =>
      'Submit an explicit permission decision (allow/deny) for a gated tool request';

  @override
  String get invocation =>
      'sanad session permission <session-id> --request-id <req-id> --allow / --deny';

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

    bool? allowed;
    String? decision;
    String scope = getOption('scope') ?? 'once';
    String? comment = getOption('comment');

    final filePath = getOption('file');
    if (filePath != null && filePath.isNotEmpty) {
      final decoded = readPermissionFile(filePath);
      if (decoded == null) return 1;
      if (decoded.containsKey('allowed')) {
        allowed = decoded['allowed'] == true;
      }
      if (decoded.containsKey('decision')) {
        decision = decoded['decision']?.toString();
        if (decision == 'allow') allowed = true;
        if (decision == 'deny') allowed = false;
      }
      if (decoded.containsKey('scope')) {
        scope = decoded['scope']?.toString() ?? scope;
      }
      if (decoded.containsKey('comment')) {
        comment = decoded['comment']?.toString();
      }
    }

    if (allowed == null) {
      final allowFlag = getFlag('allow');
      final denyFlag = getFlag('deny');
      final decisionOpt = getOption('decision')?.toLowerCase();

      if (allowFlag && !denyFlag) {
        allowed = true;
        decision = 'allow';
      } else if (denyFlag && !allowFlag) {
        allowed = false;
        decision = 'deny';
      } else if (decisionOpt == 'allow') {
        allowed = true;
        decision = 'allow';
      } else if (decisionOpt == 'deny') {
        allowed = false;
        decision = 'deny';
      }
    }

    if (allowed == null) {
      stderrSink.writeln(
        'Error: Decision must specify either --allow, --deny, or --decision allow|deny.',
      );
      stderrSink.writeln('Usage: $invocation');
      return 1;
    }

    decision ??= allowed ? 'allow' : 'deny';

    try {
      return await withClient((client) async {
        final result = await client.respondToolPermission(
          sessionId: id,
          requestId: reqId,
          allowed: allowed!,
          scope: scope,
          decision: decision,
          comment: comment,
        );

        final payload = result['payload'] is Map
            ? Map<String, dynamic>.from(result['payload'] as Map)
            : result;
        final outcome = payload['outcome']?.toString() ?? 'resolved';

        if (json) {
          stdoutSink.writeln(
            jsonEncode({
              'session_id': id,
              'request_id': reqId,
              'status': 'resolved',
              'outcome': outcome,
              'decision': decision,
              'scope': scope,
            }),
          );
        } else {
          stdoutSink.writeln(
            'Permission $decision submitted for session $id (request $reqId).',
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
