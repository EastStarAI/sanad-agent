import 'package:sanad_agent/capabilities/models/tool_schema.dart';
import 'package:sanad_agent/capabilities/tools/base_tool.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/models/tool_execution_result.dart';
import 'package:sanad_agent/evolution/cron_scheduler.dart';
import 'package:sanad_agent/evolution/scheduling/schedule_model.dart';

class ScheduleTaskTool extends BaseTool {
  static const int defaultListCap = 50;

  @override
  ToolSchema get schema => ToolSchema(
    name: 'schedule_task',
    description:
        'Create, list, cancel, or update scheduled tasks for this agent. Supports one-shot and recurring schedules. '
        'For update, send only the fields to change; the existing schedule shape is kept unless "kind" is supplied, '
        'in which case the schedule fields replace the whole definition.',
    parameters: {
      'type': 'object',
      'required': ['action'],
      'properties': {
        'action': {
          'type': 'string',
          'enum': ['create', 'list', 'cancel', 'update'],
          'description':
              'Action to perform: create, list, cancel, or update a scheduled task.',
        },
        'task': {
          'type': 'string',
          'description':
              'Task description / prompt to execute when the schedule triggers.',
        },
        'id': {
          'type': 'string',
          'description': 'Schedule ID (required for cancel and update).',
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
      default:
        return ToolExecutionResult.text(
          'Error: Unknown action "$action". Accepted actions are: create, list, cancel, update.',
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
      final record = scheduler.createSchedule(
        task: taskVal,
        sessionId: sessionId,
        definition: definition,
      );

      final zone = ScheduleZone.parse(record.zone);
      final formattedNext = zone.formatInstant(record.nextRunAt);

      return ToolExecutionResult.text(
        'Scheduled task "${record.id}" created successfully:\n'
        '- Task: "${record.task}"\n'
        '- Recurrence: ${definition.humanRecurrenceSummary}\n'
        '- Next run: $formattedNext\n'
        '- Status: ${record.lastStatus ?? 'pending'}',
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

        buffer.writeln(
          '${i + 1}. [${record.id}] "${record.task}"\n'
          '   - Recurrence: ${def.humanRecurrenceSummary}\n'
          '   - Next run: $formattedNext\n'
          '   - Status: ${record.lastStatus ?? 'pending'}\n'
          '   - Owning session: ${record.sessionId}',
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
        '- Owning session: ${record.sessionId}',
      );
    } on ScheduleNotFoundException catch (e) {
      return ToolExecutionResult.text(
        'Error: ${e.message}',
        isError: true,
        errorCode: ToolResultErrorCode.notFound,
      );
    } on SchedulePermissionException catch (e) {
      return ToolExecutionResult.text(
        'Error: ${e.message}',
        isError: true,
        errorCode: ToolResultErrorCode.permissionDenied,
      );
    } catch (error) {
      return ToolExecutionResult.text(
        'Error: Failed to cancel schedule: $error',
        isError: true,
        errorCode: ToolResultErrorCode.executionFailed,
      );
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

    final hasRecurrence = args.keys.any(
      ScheduleDefinition.definitionKeys.contains,
    );

    if (!hasTask && !hasRecurrence) {
      return ToolExecutionResult.text(
        'Error: update action requires "task" and/or schedule recurrence parameters.',
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
      );

      final zone = ScheduleZone.parse(updated.zone);
      final formattedNext = zone.formatInstant(updated.nextRunAt);

      return ToolExecutionResult.text(
        'Scheduled task "${updated.id}" updated successfully:\n'
        '- Task: "${updated.task}"\n'
        '- Recurrence: ${updated.toDefinition().humanRecurrenceSummary}\n'
        '- Next run: $formattedNext\n'
        '- Status: ${updated.lastStatus ?? 'pending'}\n'
        '- Owning session: ${updated.sessionId}',
      );
    } on ScheduleNotFoundException catch (e) {
      return ToolExecutionResult.text(
        'Error: ${e.message}',
        isError: true,
        errorCode: ToolResultErrorCode.notFound,
      );
    } on SchedulePermissionException catch (e) {
      return ToolExecutionResult.text(
        'Error: ${e.message}',
        isError: true,
        errorCode: ToolResultErrorCode.permissionDenied,
      );
    } catch (error) {
      return ToolExecutionResult.text(
        'Error: Failed to update schedule: $error',
        isError: true,
        errorCode: ToolResultErrorCode.executionFailed,
      );
    }
  }

  String _resolveDefaultZone() {
    if (getIt.isRegistered<Config>()) {
      return getIt<Config>().scheduleTimezone;
    }
    return 'local';
  }
}
