import 'dart:async';
import 'dart:convert' hide json;

import '../../../models/runtime_retry_state.dart';
import 'session_subcommand_base.dart';

class SessionShowCommand extends SessionSubcommandBase {
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
        final payload = unwrapSessionPayload(rawResult);

        // The daemon always projects a session's own identity when it knows the
        // session (`buildSessionPayload` sets `title` and `created_at`
        // unconditionally), and omits it entirely when it does not. Reporting
        // the omitted case as `idle` with exit 0 made an unknown id
        // indistinguishable from a stopped turn.
        final hasSessionIdentity =
            payload['title'] != null || payload['created_at'] != null;
        if (!hasSessionIdentity) {
          stderrSink.writeln(
            'Error: Session $id was not found. Check the id with: '
            'sanad session list',
          );
          if (json) {
            stdoutSink.writeln(
              jsonEncode({
                'session_id': id,
                'exit_code': 1,
                'error_code': 'session_not_found',
                'error': 'Session $id was not found on this daemon.',
              }),
            );
          }
          return 1;
        }

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
        final notice = payload['runtime_notice'] is Map
            ? Map<String, dynamic>.from(payload['runtime_notice'] as Map)
            : null;
        // The daemon owns recovery: its notice status, the failure's
        // retryability, and the remaining budget decide whether the turn is
        // being retried or is truly stopped. Prose never does.
        final retry = RuntimeRetryState.fromProjection(payload);

        final bool isAskUser =
            pending != null &&
            (pending['tool_name'] == 'system_ask_user' ||
                (pending['questions'] is List &&
                    (pending['questions'] as List).isNotEmpty));

        // The durable execution projection is the authoritative state: the
        // daemon that owns the turn writes it. `in_flight` is only the in-memory
        // partial-stream snapshot, and it is absent while a tool runs, which is
        // why this projection used to answer `idle` for a session that was
        // demonstrably executing.
        final durableExecutionState = executionSnapshot?['state']?.toString();
        final durableIsIdle =
            durableExecutionState == 'idle' ||
            durableExecutionState == 'queued';
        final hasRunningExecution = inFlight != null && !durableIsIdle;

        final String status;
        if (pending != null) {
          status = isAskUser ? 'needs_input' : 'needs_permission';
        } else if (retry.isAutoRetrying) {
          // A scheduled resume (or budget left) outranks both `blocked` and a
          // missing in-flight snapshot: the daemon will continue on its own.
          status = 'retrying';
        } else if (durableExecutionState != null && !durableIsIdle) {
          status = durableExecutionState;
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

        // The recovery facts an observer needs to classify the turn without
        // guessing: whether the daemon is retrying, the notice that says so, the
        // attempt counters, and the remaining resume delay.
        final Map<String, dynamic>? retryFacts =
            retry.isAutoRetrying || retry.isTrulyBlocked
            ? <String, dynamic>{
                'pending': retry.isAutoRetrying,
                'stopped': retry.isTrulyBlocked,
                if (retry.noticeStatus != null)
                  'notice_status': retry.noticeStatus,
                if (retry.reason != null) 'reason': retry.reason,
                if (retry.attempt != null) 'attempt': retry.attempt,
                if (retry.budget != null) 'budget': retry.budget,
                if (retry.retryAfterMs != null)
                  'resume_in_ms': retry.retryAfterMs,
                'label': retry.isAutoRetrying
                    ? retry.retryLabel
                    : 'needs_intervention',
              }
            : null;

        final showResult = <String, dynamic>{
          'session_id': id,
          'status': status,
          'execution_state': ?durableExecutionState,
          'identities': identities,
          'in_flight': inFlight,
          'pending_permission_request': pending,
          'runtime_notice': ?notice,
          'retry': ?retryFacts,
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
        if (durableExecutionState != null) {
          stdoutSink.writeln('Execution: $durableExecutionState');
        }
        if (retryFacts != null) {
          final reason = retry.reason == null ? '' : ' (${retry.reason})';
          final resume = retry.retryAfterMs == null || retry.retryAfterMs == 0
              ? ''
              : ' in ${(retry.retryAfterMs! / 1000).round()}s';
          stdoutSink.writeln(
            retry.isAutoRetrying
                ? 'Recovery: ${retry.retryLabel}$resume$reason — the daemon '
                      'continues this turn automatically'
                : 'Recovery: needs_intervention$reason — the daemon will not '
                      'continue without Retry, Change Provider or Stop',
          );
        }
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
      rethrowEndpointFailure(e);
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
