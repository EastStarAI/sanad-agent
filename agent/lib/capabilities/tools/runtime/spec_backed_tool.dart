import '../../../core/models/tool_execution_result.dart';
import '../../models/local_tool_spec.dart';
import '../../models/tool_schema.dart';
import '../base_tool.dart';

abstract class ToolSpecProvider {
  LocalToolSpec get toolSpec;
}

abstract class SpecBackedTool extends BaseTool implements ToolSpecProvider {
  @override
  ToolSchema get schema => ToolSchema(
    name: toolSpec.name,
    description: toolSpec.description,
    parameters: toolSpec.inputSchema,
  );

  @override
  bool get restartReplaySafe =>
      toolSpec.execution['restart_replay_safe'] == true;
}

typedef ToolExecutionCallback =
    Future<String> Function(Map<String, dynamic> args, {ToolContext? context});

class CallbackTool extends SpecBackedTool {
  CallbackTool({
    required this.toolSpec,
    required ToolExecutionCallback onExecute,
  }) : _onExecute = onExecute;

  final ToolExecutionCallback _onExecute;

  @override
  final LocalToolSpec toolSpec;

  @override
  Future<String> execute(
    Map<String, dynamic> args, {
    ToolContext? context,
  }) async {
    final result = await executeResult(args, context: context);
    return result.displayText;
  }

  @override
  Future<ToolExecutionResult> executeResult(
    Map<String, dynamic> args, {
    ToolContext? context,
  }) async {
    final text = await _onExecute(args, context: context);
    return ToolExecutionResult.text(text);
  }
}
