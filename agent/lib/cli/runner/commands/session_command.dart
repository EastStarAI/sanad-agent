import 'dart:async';
import 'dart:convert' hide json;
import 'dart:io';

import 'package:uuid/uuid.dart';

import '../../../core/config.dart';
import '../../client/local_gateway_cli_client.dart';
import '../../oneshot/oneshot_runner.dart';
import '../sanad_command.dart';

/// Unwraps a correlated gateway response into its canonical payload map.
///
/// Query responses wrap the canonical payload under `payload`; an envelope that
/// is already canonical is returned unchanged.
Map<String, dynamic> _unwrapPayload(Map<String, dynamic> result) =>
    result['payload'] is Map
    ? Map<String, dynamic>.from(result['payload'] as Map)
    : result;

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
  }) {
    argParser.addFlag(
      'include-messages',
      negatable: false,
      help:
          'Explicit opt-in: embed the full conversation/messages payload in the output.',
    );
  }

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
        final payload = _unwrapPayload(rawResult);

        final inFlight = payload['in_flight'] is Map
            ? Map<String, dynamic>.from(payload['in_flight'] as Map)
            : null;
        final pending = payload['pending_permission_request'] is Map
            ? Map<String, dynamic>.from(
                payload['pending_permission_request'] as Map,
              )
            : null;
        final executionSnapshot = payload['execution_snapshot'] is Map
            ? Map<String, dynamic>.from(payload['execution_snapshot'] as Map)
            : null;

        final bool isAskUser =
            pending != null &&
            (pending['tool_name'] == 'system_ask_user' ||
                (pending['questions'] is List &&
                    (pending['questions'] as List).isNotEmpty));

        // The in-flight projection is an in-memory partial-stream snapshot.
        // A durable execution projection that is unowned (`idle`/`queued`)
        // proves no run is publishing, so a leftover snapshot must not be
        // reported as `running` (Task 134).
        final durableExecutionState = executionSnapshot?['state']?.toString();
        final durableIsIdle =
            durableExecutionState == 'idle' ||
            durableExecutionState == 'queued';
        final hasRunningExecution = inFlight != null && !durableIsIdle;

        final String status;
        if (pending != null) {
          status = isAskUser ? 'needs_input' : 'needs_permission';
        } else if (hasRunningExecution) {
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

        // Machine-review contract: by default this projection is bounded and
        // reviewer-focused. It surfaces owner identities, execution status,
        // pending intervention, the effective route, timestamps, and message /
        // tool summary counts WITHOUT embedding the complete conversation.
        // Full history is exposed only through the explicit --include-messages
        // opt-in flag.
        final summary = _summarizeMessages(messages);
        final compaction = _latestCompaction(messages);
        final identities = <String, dynamic>{
          'session_id': id,
          if (hasRunningExecution && inFlight['run_id'] != null)
            'run_id': inFlight['run_id'],
          if (executionSnapshot?['work_item_id'] != null)
            'work_item_id': executionSnapshot!['work_item_id'],
          if (executionSnapshot?['request_id'] != null)
            'request_id': executionSnapshot!['request_id'],
          if (pending?['request_id'] != null)
            'pending_request_id': pending!['request_id'],
          if (payload['history_revision'] != null)
            'history_revision': payload['history_revision'],
          if (payload['route_revision'] != null)
            'route_revision': payload['route_revision'],
        };

        final includeFullHistory = getFlag('include-messages');

        final showResult = <String, dynamic>{
          'session_id': id,
          'status': status,
          'identities': identities,
          'in_flight': inFlight,
          'pending_permission_request': pending,
          'execution_snapshot': ?executionSnapshot,
          if (payload['model'] != null) 'model': payload['model'],
          if (payload['model_display'] != null)
            'model_display': payload['model_display'],
          if (payload['provider_instance_id'] != null)
            'provider_instance_id': payload['provider_instance_id'],
          if (payload['model_provider'] != null)
            'model_provider': payload['model_provider'],
          if (payload['route_revision'] != null)
            'route_revision': payload['route_revision'],
          if (payload['route_updated_at'] != null)
            'route_updated_at': payload['route_updated_at'],
          if (payload['thinking_mode'] != null)
            'thinking_mode': payload['thinking_mode'],
          if (payload['title'] != null) 'title': payload['title'],
          if (payload['created_at'] != null)
            'created_at': payload['created_at'],
          if (payload['updated_at'] != null)
            'updated_at': payload['updated_at'],
          if (payload['last_user_message_at'] != null)
            'last_user_message_at': payload['last_user_message_at'],
          'message_count': messages.length,
          'summary': summary,
          'compaction': ?compaction,
          if (includeFullHistory) 'messages': messages,
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
        if (payload['provider_instance_id'] != null) {
          stdoutSink.writeln('Provider: ${payload['provider_instance_id']}');
        }
        if (payload['title'] != null) {
          stdoutSink.writeln('Title: ${payload['title']}');
        }

        stdoutSink.writeln(
          'Messages: ${messages.length} (${_describeSummary(summary)})',
        );
        if (compaction != null) {
          stdoutSink.writeln(
            'Latest compaction: ${compaction['compaction_id']} '
            '(${compaction['status']}, ${compaction['trigger']})',
          );
        }
        if (messages.isNotEmpty && !includeFullHistory) {
          stdoutSink.writeln(
            '  Full history is not shown by default. Add --include-messages to embed the complete messages payload.',
          );
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

  /// The latest compaction lifecycle row of hydrated history, so a caller can
  /// poll a compaction that outlived `sanad session compact` (Task 125).
  static Map<String, dynamic>? _latestCompaction(
    List<Map<String, dynamic>> messages,
  ) {
    for (final message in messages.reversed) {
      final type = message['type']?.toString() ?? '';
      if (!type.startsWith('context_compaction.')) continue;
      return {
        'compaction_id': message['compaction_id'],
        'status': message['status'],
        'trigger': message['trigger'],
      };
    }
    return null;
  }

  /// Builds a bounded, reviewer-focused message/tool count summary without
  /// copying any message/history content into the output.
  static Map<String, dynamic> _summarizeMessages(
    List<Map<String, dynamic>> messages,
  ) {
    var userMessages = 0;
    var finalAnswers = 0;
    var toolCalls = 0;
    var toolResults = 0;
    var reasoningRows = 0;
    var thoughtRows = 0;
    for (final message in messages) {
      switch (message['type']?.toString()) {
        case 'user_message':
          userMessages++;
          break;
        case 'final_answer':
          finalAnswers++;
          break;
        case 'tool_use':
          toolCalls++;
          break;
        case 'tool_result':
          toolResults++;
          break;
        case 'reasoning':
          reasoningRows++;
          break;
        case 'thought':
          thoughtRows++;
          break;
      }
    }
    return <String, dynamic>{
      'message_count': messages.length,
      'user_messages': userMessages,
      'final_answers': finalAnswers,
      'tool_calls': toolCalls,
      'tool_results': toolResults,
      'reasoning_rows': reasoningRows,
      'thought_rows': thoughtRows,
    };
  }

  /// One-line human-friendly rendering of the bounded [summary] map.
  static String _describeSummary(Map<String, dynamic> summary) {
    final parts = <String>[
      '${summary['user_messages']} user',
      '${summary['final_answers']} replies',
    ];
    if (summary['tool_calls'] != 0 || summary['tool_results'] != 0) {
      parts.add(
        '${summary['tool_calls']} tools / ${summary['tool_results']} results',
      );
    }
    return parts.join(', ');
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
      final payload = _unwrapPayload(history);
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

class SessionCompactCommand extends _BaseSessionSubcommand {
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
          jsonEncode({
            'exit_code': 1,
            'error': 'Session ID is required.',
          }),
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
            unwrapped['outcome']?.toString() ??
            result['outcome']?.toString();

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

        final payload = _unwrapPayload(result);
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
class SessionSteerCommand extends _BaseSessionSubcommand {
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

  /// Client-side failures that are transport problems, never gateway verdicts.
  static const Set<String> _transportErrorCodes = {
    'client_error',
    'connection_failed',
    'disposed',
    'not_connected',
    'disconnected',
    'send_error',
    'query_timeout',
  };

  /// Shared upper bound of `--timeout` (`addCommonOptions`), in seconds.
  static const int _maxTimeoutSeconds = 86400;

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
      return _reportUsage(id: null, message: 'Session ID is required.');
    }

    final rawMessage = getOption('message');
    final rawMessageFile = getOption('message-file');

    // Presence, not content, decides the shape: `--message "" --message-file f`
    // is an ambiguous invocation even though one of them is blank.
    if (rawMessage != null && rawMessageFile != null) {
      return _reportUsage(
        id: id,
        message: '--message cannot be combined with --message-file.',
      );
    }
    if (rawMessage == null && rawMessageFile == null) {
      return _reportUsage(
        id: id,
        message: 'One of --message or --message-file is required.',
      );
    }

    // `--timeout` is the acknowledgement bound and reuses the shared option's
    // documented range; a value outside it is a usage error, never a silent
    // fall-back to the default.
    final rawTimeout = timeoutSeconds;
    Duration? ackTimeout;
    if (rawTimeout != null) {
      final parsed = int.tryParse(rawTimeout.trim());
      if (parsed == null || parsed < 1 || parsed > _maxTimeoutSeconds) {
        return _reportUsage(
          id: id,
          message:
              '--timeout must be a whole number of seconds from 1 to '
              '$_maxTimeoutSeconds.',
        );
      }
      ackTimeout = Duration(seconds: parsed);
    }

    final String text;
    if (rawMessageFile != null) {
      // The path is used verbatim: a caller that quotes a path keeps exactly
      // the bytes it passed.
      final path = rawMessageFile;
      if (path.trim().isEmpty) {
        return _reportUsage(id: id, message: 'Message file path is required.');
      }
      final type = FileSystemEntity.typeSync(path);
      if (type == FileSystemEntityType.directory) {
        return _reportUsage(
          id: id,
          message: 'Message file "$path" is a directory; pass a file path.',
        );
      }
      if (type == FileSystemEntityType.notFound) {
        return _reportUsage(
          id: id,
          message: 'Message file does not exist: $path',
        );
      }
      final String content;
      try {
        content = File(path).readAsStringSync().trim();
      } on FileSystemException catch (e) {
        return _reportUsage(
          id: id,
          message: 'Failed to read message file "$path": ${e.message}',
        );
      }
      if (content.isEmpty) {
        return _reportUsage(id: id, message: 'Message file "$path" is empty.');
      }
      text = content;
    } else {
      final content = rawMessage!.trim();
      if (content.isEmpty) {
        return _reportUsage(id: id, message: 'Message cannot be empty.');
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
          projection = _unwrapPayload(
            await client.getSessionHistory(sessionId: id),
          );
        } on CliClientException catch (e) {
          if (_transportErrorCodes.contains(e.code)) {
            return _reportFailure(
              sessionId: id,
              requestId: requestId,
              errorCode: e.code,
              message:
                  'Failed to read the state of session $id before steering, '
                  'so no steer was sent: $e',
              exitCode: exitFailed,
            );
          }
          return _reportFailure(
            sessionId: id,
            requestId: requestId,
            errorCode: 'session_state_unreadable',
            message:
                'Could not read the state of session $id, so no steer was '
                'sent (gateway code ${e.code}): ${e.message}',
            exitCode: exitStateUnreadable,
          );
        } catch (e) {
          return _reportFailure(
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
          return _reportFailure(
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
          return _reportFailure(
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
          return _reportFailure(
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

        return _reportFailure(
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
        return _reportFailure(
          sessionId: id,
          requestId: requestId,
          errorCode: e.code,
          message:
              'Steer dispatched to session $id but not acknowledged in time; '
              'it may still be applied. Confirm with: sanad session show $id',
          exitCode: exitUnacknowledged,
        );
      }
      if (_transportErrorCodes.contains(e.code)) {
        return _reportFailure(
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
        return _reportFailure(
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
      return _reportFailure(
        sessionId: id,
        requestId: requestId,
        errorCode: e.code,
        message: 'Gateway rejected the steer: ${e.message}',
        exitCode: exitNotSteerable,
      );
    } catch (e) {
      return _reportFailure(
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
  /// * a stop request (`stop_requested` on the snapshot, or the durable
  ///   `stopping` state, which the stop path writes before it cancels the run);
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
    if (snapshot is Map && snapshot['stop_requested'] == true) return false;
    final notice = projection['runtime_notice'];
    final noticeStatus = notice is Map ? notice['status']?.toString() : null;
    if (noticeStatus != null && noticeStatus != 'resuming') return false;
    return true;
  }

  int _reportUsage({required String? id, String? message}) {
    if (message != null) {
      stderrSink.writeln('Error: $message');
      stderrSink.writeln('Usage: $invocation');
    }
    if (json) {
      stdoutSink.writeln(
        jsonEncode({
          'session_id': ?id,
          'status': 'error',
          'error_code': 'invalid_arguments',
          'error': message ?? 'Invalid invocation.',
          'exit_code': exitUsage,
        }),
      );
    }
    return exitUsage;
  }

  int _reportFailure({
    required String sessionId,
    required String errorCode,
    required String message,
    required int exitCode,
    String? requestId,
  }) {
    // Every outcome after a dispatch names its request id, so a caller can
    // correlate a late acknowledgement with the steer it already attempted.
    final trace = requestId == null ? '' : ' (request $requestId)';
    stderrSink.writeln('Error: $message$trace');
    if (json) {
      stdoutSink.writeln(
        jsonEncode({
          'session_id': sessionId,
          'request_id': ?requestId,
          'status': 'error',
          'error_code': errorCode,
          'error': message,
          'exit_code': exitCode,
        }),
      );
    }
    return exitCode;
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
