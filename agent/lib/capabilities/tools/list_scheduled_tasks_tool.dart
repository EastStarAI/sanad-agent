import 'package:sanad_agent/capabilities/models/tool_schema.dart';
import 'package:sanad_agent/capabilities/tools/base_tool.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/models/tool_execution_result.dart';
import 'package:sanad_agent/evolution/cron_scheduler.dart';

class ListScheduledTasksTool extends BaseTool {
  @override
  ToolSchema get schema => ToolSchema(
    name: 'list_scheduled_tasks',
    description: 'List all currently scheduled tasks.',
    parameters: {'type': 'object', 'properties': {}},
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
    final scheduler = getIt<CronScheduler>();
    final tasks = scheduler.activeTasks;

    if (tasks.isEmpty) {
      return ToolExecutionResult.text('No tasks are currently scheduled.');
    }

    final buffer = StringBuffer('Scheduled Tasks:\n');
    for (var i = 0; i < tasks.length; i++) {
      final task = tasks[i];
      buffer.writeln(
        '${i + 1}. Task: "${task.task}" at ${task.time} (Session: ${task.sessionId})',
      );
    }

    return ToolExecutionResult.text(buffer.toString());
  }
}
