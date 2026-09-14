import 'dart:async';
import 'dart:io';

import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:logging/logging.dart';

import '../../../core/models/tool_execution_result.dart';
import '../../../infrastructure/platform/automation_service_factory.dart';
import '../../models/local_tool_spec.dart';
import '../base_tool.dart';
import '../runtime/spec_backed_tool.dart';

class ScreenshotTool extends SpecBackedTool {
  static final _logger = Logger('ScreenshotTool');

  @override
  LocalToolSpec get toolSpec => const LocalToolSpec(
    name: 'system_screenshot',
    displayName: 'Screenshot',
    description: 'Capture the current screen on the local device.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'monitor_number': {'type': 'integer', 'default': 1},
      },
      'additionalProperties': false,
    },
    source: {'type': 'builtin_local', 'id': 'sanad-agent.system'},
    category: 'system_control',
    workspaceRequired: false,
    approval: {'mode': 'default', 'sensitive': true},
    execution: {'target': 'local_runtime', 'timeout_ms': 30000},
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
    final monitorNumber = args['monitor_number'] ?? 1;
    final service = AutomationServiceFactory.instance;

    // Check permission
    final hasPerm = await service.checkPermissions();
    if (!hasPerm) {
      throw Exception(
        'System.screenshot failed: Missing Accessibility or Screen Recording permissions on the daemon.',
      );
    }

    final bytes = await service.takeScreenshot();

    // Save to AgentScreenshots folder in user's Downloads directory (replicate client behaviour)
    try {
      final home = Platform.isWindows
          ? Platform.environment['USERPROFILE']
          : Platform.environment['HOME'];
      if (home != null) {
        final agentDir = Directory(
          p.join(home, 'Downloads', 'AgentScreenshots'),
        );
        if (!agentDir.existsSync()) {
          agentDir.createSync(recursive: true);
        }
        final timestamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
        final filePath = p.join(agentDir.path, 'screenshot_$timestamp.jpg');
        await File(filePath).writeAsBytes(bytes);
        _logger.info('Saved screenshot to: $filePath');

        return ToolExecutionResult.text(
          'Screenshot taken successfully from monitor $monitorNumber , imagePaht: $filePath ',
        );
      }
    } catch (e) {
      _logger.warning(
        'Failed to save a backup copy of the screenshot to Downloads/AgentScreenshots: $e',
      );
    }

    return ToolExecutionResult.text(
      'Screenshot taken successfully from monitor $monitorNumber',
    );
  }
}
