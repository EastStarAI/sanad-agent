import 'dart:async';
import 'dart:convert' hide json;
import 'dart:io';

import 'package:uuid/uuid.dart';

import '../../client/local_gateway_cli_client.dart';
import '../../oneshot/oneshot_runner.dart';
import '../sanad_command.dart';

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

abstract class _BaseSessionSubcommand extends SanadCommand {
  final ClientFactory? clientFactory;
  final LocalGatewayCliClient? clientOverride;

  _BaseSessionSubcommand({
    this.clientFactory,
    this.clientOverride,
    super.customAction,
  }) {
    addCommonOptions(argParser);
  }

  Future<({LocalGatewayCliClient client, bool shouldDispose})>
  getClient() async {
    if (clientOverride != null) {
      return (client: clientOverride!, shouldDispose: false);
    }
    final parentCmd = parent;
    if (parentCmd is SessionCommand) {
      if (parentCmd.clientOverride != null) {
        return (client: parentCmd.clientOverride!, shouldDispose: false);
      }
      if (parentCmd.clientFactory != null) {
        final c = await parentCmd.clientFactory!(
          urlOverride: gatewayUrl,
          sanadHomeOverride: sanadHome,
        );
        return (client: c, shouldDispose: true);
      }
    }
    if (clientFactory != null) {
      final c = await clientFactory!(
        urlOverride: gatewayUrl,
        sanadHomeOverride: sanadHome,
      );
      return (client: c, shouldDispose: true);
    }
    final c = await LocalGatewayCliClient.discoverAndConnect(
      urlOverride: gatewayUrl,
      sanadHomeOverride: sanadHome,
    );
    return (client: c, shouldDispose: true);
  }

  Future<T> withClient<T>(
    Future<T> Function(LocalGatewayCliClient client) action,
  ) async {
    final handle = await getClient();
    try {
      return await action(handle.client);
    } finally {
      if (handle.shouldDispose) {
        try {
          await handle.client.dispose();
        } catch (_) {}
      }
    }
  }

  String? resolveSessionId() {
    final explicit = getOption('session');
    if (explicit != null && explicit.trim().isNotEmpty) {
      return explicit.trim();
    }
    final restId = argResults?.rest.firstOrNull;
    if (restId != null && restId.trim().isNotEmpty) {
      return restId.trim();
    }
    final fallback = session;
    if (fallback != null && fallback.trim().isNotEmpty) {
      return fallback.trim();
    }
    return null;
  }

  String? resolveRequestId() {
    final explicit = getOption('request-id');
    if (explicit != null && explicit.trim().isNotEmpty) {
      return explicit.trim();
    }
    if (argResults != null && argResults!.rest.length > 1) {
      final restId = argResults!.rest[1];
      if (restId.trim().isNotEmpty) {
        return restId.trim();
      }
    }
    return null;
  }

  String? readAnswerFile(String filePath) {
    final file = File(filePath);
    if (!file.existsSync()) {
      stderrSink.writeln('Error: Answer file does not exist: $filePath');
      return null;
    }
    final fileContent = file.readAsStringSync().trim();
    try {
      final decoded = jsonDecode(fileContent);
      if (decoded is Map) {
        return decoded['answer']?.toString() ??
            decoded['text']?.toString() ??
            fileContent;
      }
      return decoded.toString();
    } catch (_) {
      return fileContent;
    }
  }

  Map<String, dynamic>? readPermissionFile(String filePath) {
    final file = File(filePath);
    if (!file.existsSync()) {
      stderrSink.writeln('Error: Permission file does not exist: $filePath');
      return null;
    }
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
      return null;
    } catch (e) {
      stderrSink.writeln('Error: Failed to parse permission file JSON: $e');
      return null;
    }
  }
}

class SessionListCommand extends _BaseSessionSubcommand {
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
      stderrSink.writeln('Error: Failed to list sessions: $e');
      if (json) {
        stdoutSink.writeln(jsonEncode({'exit_code': 1, 'error': e.toString()}));
      }
      return 1;
    }
  }
}

class SessionShowCommand extends _BaseSessionSubcommand {
  SessionShowCommand({
    super.clientFactory,
    super.clientOverride,
    super.customAction,
  });

  @override
  String get name => 'show';

  @override
  String get description =>
      'Show authoritative state, in-flight execution, and pending intervention requests for a session';

  @override
  String get invocation => 'sanad session show <session-id>';

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
        final rawResult = await client.getSessionHistory(sessionId: id);
        final payload = rawResult['payload'] is Map
            ? Map<String, dynamic>.from(rawResult['payload'] as Map)
            : rawResult;

        final inFlight = payload['in_flight'] is Map
            ? Map<String, dynamic>.from(payload['in_flight'] as Map)
            : null;
        final pending = payload['pending_permission_request'] is Map
            ? Map<String, dynamic>.from(
                payload['pending_permission_request'] as Map,
              )
            : null;

        final bool isAskUser =
            pending != null &&
            (pending['tool_name'] == 'system_ask_user' ||
                (pending['questions'] is List &&
                    (pending['questions'] as List).isNotEmpty));

        final String status;
        if (pending != null) {
          status = isAskUser ? 'needs_input' : 'needs_permission';
        } else if (inFlight != null) {
          status = 'running';
        } else {
          status = 'idle';
        }

        final messages =
            (payload['messages'] as List?)
                ?.whereType<Map>()
                .map((m) => Map<String, dynamic>.from(m))
                .toList() ??
            const <Map<String, dynamic>>[];

        final showResult = <String, dynamic>{
          'session_id': id,
          'status': status,
          'in_flight': inFlight,
          'pending_permission_request': pending,
          if (payload['model'] != null) 'model': payload['model'],
          if (payload['title'] != null) 'title': payload['title'],
          if (payload['created_at'] != null)
            'created_at': payload['created_at'],
          if (payload['execution_snapshot'] != null)
            'execution_snapshot': payload['execution_snapshot'],
          'message_count': messages.length,
          'messages': messages,
        };

        if (json) {
          stdoutSink.writeln(jsonEncode(showResult));
          return 0;
        }

        stdoutSink.writeln('Session details for: $id');
        stdoutSink.writeln('Status: $status');
        if (payload['model'] != null) {
          stdoutSink.writeln('Model: ${payload['model']}');
        }
        if (payload['title'] != null) {
          stdoutSink.writeln('Title: ${payload['title']}');
        }

        if (inFlight != null) {
          stdoutSink.writeln('In-flight state:');
          stdoutSink.writeln('  Type: ${inFlight['type'] ?? 'active'}');
          if (inFlight['run_id'] != null) {
            stdoutSink.writeln('  Run ID: ${inFlight['run_id']}');
          }
        }

        if (pending != null) {
          stdoutSink.writeln('Pending request:');
          stdoutSink.writeln('  Request ID: ${pending['request_id']}');
          stdoutSink.writeln('  Tool Name: ${pending['tool_name']}');
          if (isAskUser) {
            final questions = pending['questions'];
            if (questions is List) {
              for (final q in questions) {
                if (q is Map) {
                  stdoutSink.writeln('  Question: ${q['question']}');
                  if (q['options'] is List &&
                      (q['options'] as List).isNotEmpty) {
                    stdoutSink.writeln(
                      '  Options: ${(q['options'] as List).join(', ')}',
                    );
                  }
                }
              }
            }
            stdoutSink.writeln(
              '  Intervention command: sanad session answer $id -r ${pending['request_id']} --answer "<answer>"',
            );
          } else {
            if (pending['tool_input'] != null) {
              stdoutSink.writeln(
                '  Tool Input: ${jsonEncode(pending['tool_input'])}',
              );
            }
            stdoutSink.writeln(
              '  Intervention command: sanad session permission $id -r ${pending['request_id']} --allow / --deny',
            );
          }
        }

        return 0;
      });
    } catch (e) {
      stderrSink.writeln('Error: Failed to show session: $e');
      if (json) {
        stdoutSink.writeln(jsonEncode({'exit_code': 1, 'error': e.toString()}));
      }
      return 1;
    }
  }
}

class SessionStopCommand extends _BaseSessionSubcommand {
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
        await client.stop(sessionId: id);

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
      stderrSink.writeln('Error: Failed to stop session: $e');
      if (json) {
        stdoutSink.writeln(jsonEncode({'exit_code': 1, 'error': e.toString()}));
      }
      return 1;
    }
  }
}

class SessionAnswerCommand extends _BaseSessionSubcommand {
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

class SessionPermissionCommand extends _BaseSessionSubcommand {
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

class SessionNewCommand extends SanadCommand {
  SessionNewCommand({super.customAction});

  @override
  String get name => 'new';

  @override
  String get description => 'Generate and initialize a new session ID';

  @override
  Future<int> execute() async {
    final newId = const Uuid().v4();
    stdoutSink.writeln(newId);
    return 0;
  }
}

class SessionDeleteCommand extends _BaseSessionSubcommand {
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
      stderrSink.writeln('Error: Failed to delete session: $e');
      if (json) {
        stdoutSink.writeln(jsonEncode({'exit_code': 1, 'error': e.toString()}));
      }
      return 1;
    }
  }
}
