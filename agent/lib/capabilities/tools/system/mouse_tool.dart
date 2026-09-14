import 'dart:async';
import '../../../core/models/tool_execution_result.dart';
import '../../../infrastructure/platform/automation_service_factory.dart';
import '../../models/local_tool_spec.dart';
import '../base_tool.dart';
import '../runtime/spec_backed_tool.dart';

class MouseTool extends SpecBackedTool {
  @override
  LocalToolSpec get toolSpec => const LocalToolSpec(
    name: 'system_mouse',
    displayName: 'Mouse Control',
    description: 'Control the mouse cursor, click, or scroll.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'action': {
          'type': 'string',
          'enum': ['click', 'double_click', 'right_click', 'move', 'scroll'],
        },
        'x': {'type': 'integer'},
        'y': {'type': 'integer'},
        'dx': {'type': 'integer'},
        'dy': {'type': 'integer'},
      },
      'required': ['action'],
      'additionalProperties': false,
    },
    source: {'type': 'builtin_local', 'id': 'sanad-agent.system'},
    category: 'system_control',
    workspaceRequired: false,
    approval: {'mode': 'default', 'sensitive': true},
    execution: {'target': 'local_runtime', 'timeout_ms': 10000},
    serverName: 'system',
  );

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
    final action = args['action'] as String;
    final x = args['x'] is int
        ? args['x'] as int
        : int.tryParse(args['x']?.toString() ?? '');
    final y = args['y'] is int
        ? args['y'] as int
        : int.tryParse(args['y']?.toString() ?? '');
    final dx = args['dx'] is int
        ? args['dx'] as int
        : int.tryParse(args['dx']?.toString() ?? '');
    final dy = args['dy'] is int
        ? args['dy'] as int
        : int.tryParse(args['dy']?.toString() ?? '');

    final service = AutomationServiceFactory.instance;
    final hasPerm = await service.checkPermissions();
    if (!hasPerm) {
      throw Exception(
        'System.mouse failed: Missing Accessibility permissions on the daemon.',
      );
    }

    await service.simulateMouse(action: action, x: x, y: y, dx: dx, dy: dy);

    return ToolExecutionResult.text(
      'Mouse action "$action" executed successfully.',
    );
  }
}
