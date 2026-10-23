import 'package:sanad_agent/capabilities/models/tool_schema.dart';
import 'package:sanad_agent/capabilities/tools/base_tool.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/models/tool_execution_result.dart';
import 'package:sanad_agent/evolution/cron_scheduler.dart';
import 'package:sanad_agent/evolution/db/scheduled_task_repository.dart'
    show ScheduledTaskRepository;
import 'package:sanad_agent/evolution/scheduling/schedule_model.dart';

/// Performs one schedule-control action and returns its outcome.
///
/// Named so the shared control prelude stays readable: every control action has
/// the same shape and differs only in which control-layer method it calls.
typedef _ScheduleControlAction<T> = T Function(
  CronScheduler scheduler,
  String id,
  ScheduleCaller caller,
);

class ScheduleTaskTool extends BaseTool {
  static const int defaultListCap = 50;

  /// Stable message prefix for resuming a `once` schedule whose instant has
  /// passed (Task 139 D6).
  ///
  /// [ToolResultErrorCode] is transport-wide and carries no schedule-specific
  /// member, so the two state conditions the control layer distinguishes travel
  /// as stable prefixes of the message instead of widening that taxonomy.
  static const String scheduleExpiredCode = 'schedule_expired';

  /// Stable message prefix for a model-owned schedule whose owning
  /// conversation no longer exists (Task 139 S23, D10).
  static const String scheduleOrphanedCode = 'schedule_orphaned';

  @override
  ToolSchema get schema => ToolSchema(
    name: 'schedule_task',
    description:
        'Create, list, pause, resume, run now, cancel, or update scheduled tasks for this agent. Supports one-shot and recurring schedules. '
        'The task text must be self-contained: a run executes it verbatim, with no earlier conversation to draw context from. '
        'For update, send only the fields to change; the existing schedule shape is kept unless "kind" is supplied, '
        'in which case the schedule fields replace the whole definition. '
        'A model turn can control only schedules its own conversation created; '
        'run_now dispatches immediately and leaves the next run and the paused state unchanged.',
    parameters: {
      'type': 'object',
      'required': ['action'],
      'properties': {
        'action': {
          'type': 'string',
          'enum': ['create', 'list', 'cancel', 'update', 'pause', 'resume', 'run_now'],
          'description':
              'Action to perform: create, list, cancel, update, pause, resume, or run_now a scheduled task.',
        },
        'task': {
          'type': 'string',
          'description':
              'Task description / prompt to execute when the schedule triggers.',
        },
        'name': {
          'type': 'string',
          'description':
              'Optional short display name for the schedule, on create and update. '
              'Omitted or blank keeps the existing name.',
        },
        'id': {
          'type': 'string',
          'description':
              'Schedule ID (required for cancel, update, pause, resume, and run_now).',
        },
        'kind': {
          'type': 'string',
          'enum': ['once', 'interval', 'daily', 'weekly', 'monthly'],
          'description':
              'Recurrence kind: once, interval, daily, weekly, or monthly.',
        },
        'time': {
          'type': 'string',
          'description':
              'Wall-clock time HH:MM for daily/weekly/monthly, or ISO-8601 / relative for once.',
        },
        'at': {
          'type': 'string',
          'description': 'Absolute ISO-8601 timestamp for once schedule.',
        },
        'in': {
          'type': 'string',
          'description':
              'Relative delay like "5 minutes", "2 hours", "1 days" for once schedule.',
        },
        'every': {
          'type': 'string',
          'description':
              'Elapsed interval like "every 15 minutes", "every 2 hours", "every 1 days".',
        },
        'interval_minutes': {
          'type': 'integer',
          'description': 'Elapsed interval in minutes.',
        },
        'weekdays': {
          'type': 'array',
          'items': {'type': 'string'},
          'description':
              'One or more weekdays for weekly schedule: mon, tue, wed, thu, fri, sat, sun.',
        },
        'day_of_month': {
          'type': 'integer',
          'description': 'Day of month (1..31) for monthly schedule.',
        },
        'zone': {
          'type': 'string',
          'description':
              'Timezone for the schedule: "local" (default) or fixed UTC offset ("Z", "+HH:MM", "-HH:MM").',
        },
      },
    },
  );

  @override
  Future<String> execute(
    Map<String, dynamic> args, {
    ToolContext? context,
  }) async => (await executeResult(args, context: context)).displayText;

  @override
  Future<ToolExecutionResult> executeResult(
    Map<String, dynamic> args, {
    ToolContext? context,
  }) async {
    // Unused optional parameters sent as null or blank are absent (D2).
    args = ScheduleDefinition.withoutAbsentValues(args);
    final action = _resolveAction(args);

    switch (action) {
      case 'create':
        return _handleCreate(args, context);
      case 'list':
        return _handleList(args, context);
      case 'cancel':
        return _handleCancel(args, context);
      case 'update':
        return _handleUpdate(args, context);
      case 'pause':
        return _handlePause(args, context);
      case 'resume':
        return _handleResume(args, context);
      case 'run_now':
        return _handleRunNow(args, context);
      default:
        return ToolExecutionResult.text(
          'Error: Unknown action "$action". Accepted actions are: create, list, cancel, update, pause, resume, run_now.',
          isError: true,
          errorCode: ToolResultErrorCode.invalidInput,
        );
    }
  }

  String _resolveAction(Map<String, dynamic> args) {
    final raw = args['action']?.toString().trim().toLowerCase();
    if (raw != null && raw.isNotEmpty) return raw;

    // Graceful inference for backwards compatibility and replayed checkpoints
    if (args.containsKey('task') ||
        args.containsKey('time') ||
        args.containsKey('at') ||
        args.containsKey('in') ||
        args.containsKey('every') ||
        args.containsKey('interval_minutes') ||
        args.containsKey('weekdays') ||
        args.containsKey('day_of_month') ||
        args.containsKey('month_day') ||
        args.containsKey('kind')) {
      if (args.containsKey('id') && !args.containsKey('task')) {
        return 'update';
      }
      return 'create';
    }
    if (args.containsKey('id')) return 'cancel';
    return 'list';
  }

  Future<ToolExecutionResult> _handleCreate(
    Map<String, dynamic> args,
    ToolContext? context,
  ) async {
    final sessionId = context?.sessionId;
    if (sessionId == null || sessionId.trim().isEmpty) {
      return ToolExecutionResult.text(
        'Error: Cannot create a scheduled task without a session context.',
        isError: true,
        errorCode: ToolResultErrorCode.invalidInput,
      );
    }

    final taskVal = args['task']?.toString().trim();
    if (taskVal == null || taskVal.isEmpty) {
      return ToolExecutionResult.text(
        'Error: "task" parameter is required and must be a non-empty string.',
        isError: true,
        errorCode: ToolResultErrorCode.invalidInput,
      );
    }

    ScheduleDefinition definition;
    try {
      definition = ScheduleDefinition.parse(args, defaultZone: _resolveDefaultZone());
    } on ScheduleValidationException catch (e) {
      return ToolExecutionResult.text(
        'Error: ${e.message}',
        isError: true,
        errorCode: ToolResultErrorCode.invalidInput,
      );
    }

    try {
      final scheduler = getIt<CronScheduler>();
      // Task 139 D5: the model family fixes the owner kind at `model`, so a
      // forged `owner_kind` in the arguments has no reader and no effect.
      final record = scheduler.createSchedule(
        task: taskVal,
        sessionId: sessionId,
        definition: definition,
        name: _optionalName(args),
      );

      final zone = ScheduleZone.parse(record.zone);
      final formattedNext = zone.formatInstant(record.nextRunAt);

      return ToolExecutionResult.text(
        'Scheduled task "${record.id}" created successfully:\n'
        '- Task: "${record.task}"\n'
        '${_nameLine(record)}'
        '- Recurrence: ${definition.humanRecurrenceSummary}\n'
        '- Next run: $formattedNext\n'
        '- Status: ${record.lastStatus ?? 'pending'}\n'
        '- Owner: ${_describeOwner(record)}',
      );
    } catch (error) {
      return ToolExecutionResult.text(
        'Error: CronScheduler failed to create schedule: $error',
        isError: true,
        errorCode: ToolResultErrorCode.executionFailed,
      );
    }
  }

  Future<ToolExecutionResult> _handleList(
    Map<String, dynamic> args,
    ToolContext? context,
  ) async {
    try {
      final scheduler = getIt<CronScheduler>();
      final allSchedules = scheduler.listSchedules();

      if (allSchedules.isEmpty) {
        return ToolExecutionResult.text('No tasks are currently scheduled.');
      }

      final total = allSchedules.length;
      final displayed = allSchedules.take(defaultListCap).toList();

      final buffer = StringBuffer('Scheduled Tasks ($total total):\n');
      for (var i = 0; i < displayed.length; i++) {
        final record = displayed[i];
        final zone = ScheduleZone.parse(record.zone);
        final def = record.toDefinition();
        final formattedNext = zone.formatInstant(record.nextRunAt);
        final nameSuffix = record.name == null ? '' : ' (name: "${record.name}")';

        buffer.writeln(
          '${i + 1}. [${record.id}] "${record.task}"$nameSuffix\n'
          '   - Recurrence: ${def.humanRecurrenceSummary}\n'
          '   - Next run: $formattedNext\n'
          '   - Status: ${record.lastStatus ?? 'pending'}\n'
          '   - Enabled: ${record.enabled ? 'yes' : 'no'}\n'
          '   - Owner: ${_describeOwner(record)}\n'
          '   - Consecutive failures: ${scheduler.consecutiveFailures(record.id)}',
        );
      }

      if (total > defaultListCap) {
        buffer.writeln(
          'Note: Output truncated at $defaultListCap schedules ($total total).',
        );
      }

      return ToolExecutionResult.text(buffer.toString().trimRight());
    } catch (error) {
      return ToolExecutionResult.text(
        'Error: Failed to list scheduled tasks: $error',
        isError: true,
        errorCode: ToolResultErrorCode.executionFailed,
      );
    }
  }

  Future<ToolExecutionResult> _handleCancel(
    Map<String, dynamic> args,
    ToolContext? context,
  ) async {
    final sessionId = context?.sessionId;
    if (sessionId == null || sessionId.trim().isEmpty) {
      return ToolExecutionResult.text(
        'Error: Cannot cancel a scheduled task without a session context.',
        isError: true,
        errorCode: ToolResultErrorCode.invalidInput,
      );
    }

    final id = args['id']?.toString().trim();
    if (id == null || id.isEmpty) {
      return ToolExecutionResult.text(
        'Error: "id" parameter is required for cancel action.',
        isError: true,
        errorCode: ToolResultErrorCode.invalidInput,
      );
    }

    try {
      final scheduler = getIt<CronScheduler>();
      final record = scheduler.cancelSchedule(id, callerSessionId: sessionId);

      return ToolExecutionResult.text(
        'Scheduled task "${record.id}" cancelled successfully.\n'
        '- Task: "${record.task}"\n'
        '- Owner: ${_describeOwner(record)}',
      );
    } catch (error) {
      return _controlFailure(error, 'cancel schedule');
    }
  }

  Future<ToolExecutionResult> _handleUpdate(
    Map<String, dynamic> args,
    ToolContext? context,
  ) async {
    final sessionId = context?.sessionId;
    if (sessionId == null || sessionId.trim().isEmpty) {
      return ToolExecutionResult.text(
        'Error: Cannot update a scheduled task without a session context.',
        isError: true,
        errorCode: ToolResultErrorCode.invalidInput,
      );
    }

    final id = args['id']?.toString().trim();
    if (id == null || id.isEmpty) {
      return ToolExecutionResult.text(
        'Error: "id" parameter is required for update action.',
        isError: true,
        errorCode: ToolResultErrorCode.invalidInput,
      );
    }

    final taskVal = args['task']?.toString().trim();
    final hasTask = taskVal != null && taskVal.isNotEmpty;
    final nameVal = _optionalName(args);
    final hasName = nameVal != null;

    final hasRecurrence = args.keys.any(
      ScheduleDefinition.definitionKeys.contains,
    );

    if (!hasTask && !hasRecurrence && !hasName) {
      return ToolExecutionResult.text(
        'Error: update action requires "task", "name", and/or schedule recurrence parameters.',
        isError: true,
        errorCode: ToolResultErrorCode.invalidInput,
      );
    }

    ScheduleDefinition? definition;
    if (hasRecurrence) {
      final existing = getIt<CronScheduler>().getSchedule(id);
      if (existing == null) {
        return ToolExecutionResult.text(
          'Error: Schedule "$id" not found.',
          isError: true,
          errorCode: ToolResultErrorCode.notFound,
        );
      }
      try {
        definition = ScheduleDefinition.parse(
          ScheduleDefinition.mergeUpdateArgs(existing.toDefinition(), args),
          defaultZone: existing.zone,
        );
      } on ScheduleValidationException catch (e) {
        return ToolExecutionResult.text(
          'Error: ${e.message}',
          isError: true,
          errorCode: ToolResultErrorCode.invalidInput,
        );
      }
    }

    try {
      final scheduler = getIt<CronScheduler>();
      final updated = scheduler.updateSchedule(
        id: id,
        callerSessionId: sessionId,
        task: hasTask ? taskVal : null,
        definition: definition,
        // The settings columns have one edit path (`updateScheduleSettings`),
        // so an absent `name` must stay the repository's own omission sentinel
        // rather than a `null`, which would clear the stored value (D1).
        name: hasName ? nameVal : ScheduledTaskRepository.unset,
      );

      final zone = ScheduleZone.parse(updated.zone);
      final formattedNext = zone.formatInstant(updated.nextRunAt);

      return ToolExecutionResult.text(
        'Scheduled task "${updated.id}" updated successfully:\n'
        '- Task: "${updated.task}"\n'
        '${_nameLine(updated)}'
        '- Recurrence: ${updated.toDefinition().humanRecurrenceSummary}\n'
        '- Next run: $formattedNext\n'
        '- Status: ${updated.lastStatus ?? 'pending'}\n'
        '- Owner: ${_describeOwner(updated)}',
      );
    } catch (error) {
      return _controlFailure(error, 'update schedule');
    }
  }

  /// Pauses a schedule: `enabled=false`, the in-memory timer is cancelled, and
  /// `next_run_at` / `last_*` are kept (Task 139 A2, S13).
  Future<ToolExecutionResult> _handlePause(
    Map<String, dynamic> args,
    ToolContext? context,
  ) => _handleControlAction<ScheduledTaskRecord>(
    args,
    context,
    action: 'pause',
    failureLabel: 'pause schedule',
    perform: (scheduler, id, caller) => scheduler.pauseSchedule(id, caller),
    describe: (record, _) => _controlSummary(
      'paused',
      record,
      nextRunNote: 'kept as-is while paused',
    ),
  );

  /// Resumes a paused schedule and recomputes its next instant from now
  /// (Task 139 A2, S13, D6).
  Future<ToolExecutionResult> _handleResume(
    Map<String, dynamic> args,
    ToolContext? context,
  ) => _handleControlAction<ScheduledTaskRecord>(
    args,
    context,
    action: 'resume',
    failureLabel: 'resume schedule',
    perform: (scheduler, id, caller) => scheduler.resumeSchedule(id, caller),
    describe: (record, _) => _controlSummary(
      'resumed',
      record,
      nextRunNote: 'recomputed from now',
    ),
  );

  /// Dispatches a schedule immediately without changing when it next runs and
  /// without resuming it when it is paused (Task 139 A2, S14, S21).
  Future<ToolExecutionResult> _handleRunNow(
    Map<String, dynamic> args,
    ToolContext? context,
  ) => _handleControlAction<ScheduledRunNowResult>(
    args,
    context,
    action: 'run_now',
    verb: 'run',
    failureLabel: 'run schedule now',
    perform: (scheduler, id, caller) => scheduler.runNowSchedule(id, caller),
    describe: (result, id) {
      final record = getIt<CronScheduler>().getSchedule(id);
      return _runNowSummary(id, result, record);
    },
  );

  /// The shared prelude and error mapping of every control action.
  ///
  /// Control always runs with [ScheduleAuthority.model] inside the calling
  /// conversation, so the control layer applies D6 exactly: a model turn can
  /// only touch a `model`-owned row of its own conversation, and a row it does
  /// not own is denied before anything mutates (Task 139 A5, S15).
  Future<ToolExecutionResult> _handleControlAction<T>(
    Map<String, dynamic> args,
    ToolContext? context, {
    required String action,
    required String failureLabel,
    required _ScheduleControlAction<T> perform,
    required String Function(T outcome, String id) describe,
    String? verb,
  }) async {
    final sessionId = context?.sessionId;
    if (sessionId == null || sessionId.trim().isEmpty) {
      return ToolExecutionResult.text(
        'Error: Cannot ${verb ?? action} a scheduled task without a session context.',
        isError: true,
        errorCode: ToolResultErrorCode.invalidInput,
      );
    }

    final id = args['id']?.toString().trim();
    if (id == null || id.isEmpty) {
      return ToolExecutionResult.text(
        'Error: "id" parameter is required for the $action action.',
        isError: true,
        errorCode: ToolResultErrorCode.invalidInput,
      );
    }

    try {
      final outcome = perform(
        getIt<CronScheduler>(),
        id,
        ScheduleCaller.model(sessionId),
      );
      return ToolExecutionResult.text(describe(outcome, id));
    } catch (error) {
      return _controlFailure(error, failureLabel);
    }
  }

  /// Maps one schedule-control failure to a bounded tool result.
  ///
  /// Messages come from the control layer, so a denied request names the owner
  /// the caller may not touch (Task 139 S15). The two state conditions that
  /// taxonomy cannot express are prefixed with their stable code.
  static ToolExecutionResult _controlFailure(
    Object error,
    String failureLabel,
  ) {
    if (error is ScheduleNotFoundException) {
      return ToolExecutionResult.text(
        'Error: ${error.message}',
        isError: true,
        errorCode: ToolResultErrorCode.notFound,
      );
    }
    if (error is SchedulePermissionException) {
      return ToolExecutionResult.text(
        'Error: ${error.message}',
        isError: true,
        errorCode: ToolResultErrorCode.permissionDenied,
      );
    }
    if (error is ScheduleExpiredException) {
      return ToolExecutionResult.text(
        'Error: $scheduleExpiredCode: ${error.message}',
        isError: true,
        errorCode: ToolResultErrorCode.executionFailed,
      );
    }
    if (error is ScheduleOrphanedException) {
      return ToolExecutionResult.text(
        'Error: $scheduleOrphanedCode: ${error.message}',
        isError: true,
        errorCode: ToolResultErrorCode.executionFailed,
      );
    }
    return ToolExecutionResult.text(
      'Error: Failed to $failureLabel: $error',
      isError: true,
      errorCode: ToolResultErrorCode.executionFailed,
    );
  }

  /// The optional `name` a create or update supplied, or `null` when absent.
  ///
  /// A blank value is an omitted one, matching how every other optional
  /// schedule parameter is treated (D2).
  static String? _optionalName(Map<String, dynamic> args) {
    final name = args['name']?.toString().trim();
    return (name == null || name.isEmpty) ? null : name;
  }

  static String _nameLine(ScheduledTaskRecord record) =>
      record.name == null ? '' : '- Name: "${record.name}"\n';

  /// The owner kind plus the conversation label a listing must show (S15, D9).
  ///
  /// A user-owned schedule is owned by the device itself — it has no owning
  /// conversation until a run creates one — so its label never presents the
  /// empty `session_id` as an identity.
  static String _describeOwner(ScheduledTaskRecord record) {
    final kind = record.ownerKind.wireName;
    if (record.ownerKind == ScheduleOwnerKind.user) return '$kind (device)';
    final conversation = record.runSessionId ?? record.sessionId;
    return '$kind (conversation "$conversation")';
  }

  /// One paused/resumed schedule rendered for the model.
  static String _controlSummary(
    String verb,
    ScheduledTaskRecord record, {
    required String nextRunNote,
  }) {
    final zone = ScheduleZone.parse(record.zone);
    final buffer = StringBuffer()
      ..writeln('Scheduled task "${record.id}" $verb:')
      ..writeln('- Task: "${record.task}"');
    if (record.name != null) buffer.writeln('- Name: "${record.name}"');
    buffer
      ..writeln('- Recurrence: ${record.toDefinition().humanRecurrenceSummary}')
      ..writeln(
        '- Next run: ${zone.formatInstant(record.nextRunAt)} ($nextRunNote)',
      )
      ..writeln('- Enabled: ${record.enabled ? 'yes' : 'no'}')
      ..writeln('- Owner: ${_describeOwner(record)}');
    return buffer.toString().trimRight();
  }

  /// One accepted manual dispatch, including the state it deliberately left
  /// untouched (S14, S21).
  static String _runNowSummary(
    String id,
    ScheduledRunNowResult result,
    ScheduledTaskRecord? record,
  ) {
    final buffer = StringBuffer()
      ..writeln('Manual run accepted for scheduled task "$id":')
      ..writeln('- Run id: ${result.runId}')
      ..writeln('- Conversation: ${result.sessionId}');
    if (record != null) {
      final zone = ScheduleZone.parse(record.zone);
      buffer
        ..writeln('- Task: "${record.task}"')
        ..writeln(
          '- Next scheduled run: ${zone.formatInstant(record.nextRunAt)} (unchanged)',
        )
        ..writeln('- Enabled: ${record.enabled ? 'yes' : 'no'}');
      if (!record.enabled) {
        buffer.writeln('  A manual run never resumes a paused schedule.');
      }
    }
    return buffer.toString().trimRight();
  }

  String _resolveDefaultZone() {
    if (getIt.isRegistered<Config>()) {
      return getIt<Config>().scheduleTimezone;
    }
    return 'local';
  }
}
