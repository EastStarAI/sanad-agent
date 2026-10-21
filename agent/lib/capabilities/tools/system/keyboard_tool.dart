import 'dart:async';
import '../../../core/models/tool_execution_result.dart';
import '../../../infrastructure/platform/automation_service_factory.dart';
import '../../models/local_tool_spec.dart';
import '../base_tool.dart';
import '../runtime/spec_backed_tool.dart';

class KeyboardTool extends SpecBackedTool {
  @override
  LocalToolSpec get toolSpec => const LocalToolSpec(
    name: 'system_keyboard',
    displayName: 'Keyboard Control',
    description: 'Type text or press keyboard shortcuts.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'action': {
          'type': 'string',
          'enum': ['type', 'hotkey'],
        },
        'text': {'type': 'string'},
        'keys': {
          'type': 'array',
          'items': {'type': 'string'},
        },
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
    final text = args['text']?.toString();
    final keys = (args['keys'] as List?)?.map((e) => e.toString()).toList();

    final service = AutomationServiceFactory.instance;
    final hasPerm = await service.checkPermissions();
    if (!hasPerm) {
      throw Exception(
        'System.keyboard failed: Missing Accessibility permissions on the daemon.',
      );
    }

    await service.simulateKeyboard(action: action, text: text, keys: keys);

    return ToolExecutionResult.text(
      'Keyboard action "$action" executed successfully.',
    );
  }
}
