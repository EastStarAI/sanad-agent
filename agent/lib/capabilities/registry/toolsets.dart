import '../tools/base_tool.dart';
// ⛔ [TEMPORARILY DISABLED] delegate_task has been paused until it is fixed.
// import '../tools/delegate_task_tool.dart';
import '../tools/schedule_task_tool.dart';

class Toolsets {
  static List<BaseTool> get coreTools => [
    /// todo: ⛔ [TEMPORARILY DISABLED] delegate_task has been paused until it is fixed.
    // DelegateTaskTool(),
    ScheduleTaskTool(),
  ];
}
