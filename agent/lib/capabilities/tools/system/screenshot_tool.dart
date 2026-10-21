import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:logging/logging.dart';

import '../../../core/models/tool_execution_result.dart';
import '../../../core/provider_runtime/route_capability_resolver.dart';
import '../../../infrastructure/platform/automation_service_factory.dart';
import '../../../infrastructure/platform/automation_service_interface.dart';
import '../../image/image_policy.dart';
import '../../image/image_worker.dart';
import '../../models/local_tool_spec.dart';
import '../base_tool.dart';
import '../runtime/spec_backed_tool.dart';

class ScreenshotTool extends SpecBackedTool {
  ScreenshotTool({
    AutomationServiceInterface? automationService,
    ImageWorker? imageWorker,
    Directory? screenshotDirectory,
  }) : _automationService = automationService,
       _imageWorker = imageWorker ?? ImageWorker(),
       _screenshotDirectory = screenshotDirectory;

  static final _logger = Logger('ScreenshotTool');
  final AutomationServiceInterface? _automationService;
  final ImageWorker _imageWorker;

  /// Optional override for the `Downloads/AgentScreenshots` destination so
  /// automated tests never write capture files into a real user profile.
  final Directory? _screenshotDirectory;

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
    final service = _automationService ?? AutomationServiceFactory.instance;

    // Check permission
    final hasPerm = await service.checkPermissions();
    if (!hasPerm) {
      throw Exception(
        'System.screenshot failed: Missing Accessibility or Screen Recording permissions on the daemon.',
      );
    }

    final rawBytes = await service.takeScreenshot();
    final bytes = rawBytes is Uint8List
        ? rawBytes
        : Uint8List.fromList(rawBytes);

    // The user-facing backup copy is independent of model attachment: capture
    // and save must never be lost because the image cannot reach the model.
    final filePath = await _saveBackupCopy(bytes);
    final media = await _projectMedia(bytes, context);

    final description = filePath != null
        ? 'Screenshot taken successfully from monitor $monitorNumber , imagePaht: $filePath '
        : 'Screenshot taken successfully from monitor $monitorNumber';

    return ToolExecutionResult(
      blocks: [
        ToolTextBlock(text: '$description${media.note}'),
        if (media.image != null) media.image!,
      ],
    );
  }

  /// Saves the raw capture into `Downloads/AgentScreenshots` (replicating the
  /// client behavior) and returns the saved path, or null when unavailable.
  Future<String?> _saveBackupCopy(Uint8List bytes) async {
    try {
      final home = Platform.isWindows
          ? Platform.environment['USERPROFILE']
          : Platform.environment['HOME'];
      final agentDir =
          _screenshotDirectory ??
          (home == null
              ? null
              : Directory(p.join(home, 'Downloads', 'AgentScreenshots')));
      if (agentDir == null) return null;
      if (!agentDir.existsSync()) {
        agentDir.createSync(recursive: true);
      }
      final timestamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
      final filePath = p.join(agentDir.path, 'screenshot_$timestamp.jpg');
      await File(filePath).writeAsBytes(bytes);
      _logger.info('Saved screenshot to: $filePath');
      return filePath;
    } catch (e) {
      _logger.warning(
        'Failed to save a backup copy of the screenshot to Downloads/AgentScreenshots: $e',
      );
      return null;
    }
  }

  /// Projects the captured bytes into a bounded image block through the shared
  /// image policy, or returns a text-only explanation.
  ///
  /// The capture is never attached when the frozen route capability cannot
  /// accept image input: a pixel-bearing history entry makes every later
  /// request on that route fail closed. Policy failures (unsupported format,
  /// oversized or corrupt data, timeout) degrade to the text summary instead of
  /// failing the tool.
  Future<({ToolImageBlock? image, String note})> _projectMedia(
    Uint8List bytes,
    ToolContext? context,
  ) async {
    if (context?.imageSupport != RouteImageSupport.supported) {
      return (
        image: null,
        note:
            ' The screenshot image was not attached because the active model route does not accept image input.',
      );
    }
    final processed = await _imageWorker.process(
      bytes,
      detail: ToolImageDetail.auto,
    );
    if (processed is ImagePolicyFailure) {
      _logger.warning(
        'Screenshot image was not attached to the model: ${processed.message}',
      );
      return (
        image: null,
        note: ' The screenshot image was not attached: ${processed.message}',
      );
    }
    final success = processed as ImagePolicySuccess;
    return (
      image: ToolImageBlock(
        dataBase64: base64.encode(success.bytes),
        mimeType: success.mimeType,
        width: success.width,
        height: success.height,
        detail: ToolImageDetail.auto,
      ),
      note: '',
    );
  }
}
