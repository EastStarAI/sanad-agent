import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:sanad_agent/capabilities/permissions/permission_manager.dart';
import 'package:sanad_agent/capabilities/models/tool_schema.dart';
import 'package:sanad_agent/capabilities/registry/tools_registry.dart';
import 'package:sanad_agent/capabilities/tools/base_tool.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/models/tool_call.dart';
import 'package:sanad_agent/core/models/tool_execution_result.dart';
import 'package:sanad_agent/core/models/view_image_media_metadata.dart';
import 'package:sanad_agent/core/provider_runtime/route_capability_resolver.dart';
import 'package:sanad_agent/engine/runtime/continuation_checkpoint_coordinator.dart';
import 'package:sanad_agent/engine/runtime/deferred_tool_result.dart';
import 'package:sanad_agent/engine/runtime/tool_execution_coordinator.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/persisted_runtime_state_repository.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/plugins/plugin_manager.dart';
import 'package:test/test.dart';

/// Task 114e regression suite: media-bearing tool events must be published only
/// after the durable tool result is recorded.
///
/// A client that receives a media event immediately fetches the bytes from the
/// Local Gateway or the hosted relay, and both resolve the payload from the
/// session's stored tool result. Publishing the event before that write makes
/// the live `system_screenshot` thumbnail racy, so `system_screenshot` follows
/// the same deferred publication contract as `view_image`.
Uint8List _pngBytes({int width = 12, int height = 6}) {
  final image = img.Image(width: width, height: height, numChannels: 3);
  img.fill(image, color: img.ColorRgb8(5, 10, 15));
  return Uint8List.fromList(img.encodePng(image));
}

class _MediaResultTool extends BaseTool {
  _MediaResultTool(this.toolName, this._bytes);

  final String toolName;
  final Uint8List _bytes;

  @override
  ToolSchema get schema => ToolSchema(
    name: toolName,
    description: 'Test media tool.',
    parameters: const {'type': 'object'},
  );

  @override
  Future<ToolExecutionResult> executeResult(
    Map<String, dynamic> args, {
    ToolContext? context,
  }) async => ToolExecutionResult(
    blocks: [
      ToolTextBlock(text: 'Screenshot taken successfully from monitor 1'),
      ToolImageBlock(
        dataBase64: base64.encode(_bytes),
        mimeType: 'image/png',
        width: 12,
        height: 6,
        detail: ToolImageDetail.auto,
      ),
    ],
  );

  @override
  Future<String> execute(
    Map<String, dynamic> args, {
    ToolContext? context,
  }) async => (await executeResult(args, context: context)).displayText;
}

class _DenyingTool extends BaseTool {
  @override
  ToolSchema get schema => ToolSchema(
    name: 'shell_execute',
    description: 'denied',
    parameters: const {'type': 'object'},
  );

  @override
  Future<ToolExecutionResult> executeResult(
    Map<String, dynamic> args, {
    ToolContext? context,
  }) async => throw const ToolPermissionDeniedException(
    'User denied permission for tool shell_execute.',
  );

  @override
  Future<String> execute(
    Map<String, dynamic> args, {
    ToolContext? context,
  }) async => (await executeResult(args, context: context)).displayText;
}

class _RecordingCallbacks extends ToolExecutionCallbacks {
  final Map<String, String> results = {};
  int historySaveCount = 0;

  @override
  Future<void> addToolMessage(
    ToolCall toolCall,
    String result, {
    required bool isError,
    DateTime? startedAt,
    DateTime? terminalAt,
    int? runtimeMs,
    String? errorCode,
  }) async {
    results[toolCall.id] = result;
  }

  @override
  void applyPendingSteerToToolResults(int numToolCalls) {}

  @override
  int currentHistoryLength() => results.length;

  @override
  RouteImageSupport currentImageSupport() => RouteImageSupport.supported;

  @override
  bool isToolMessagePresent(String toolCallId) =>
      results.containsKey(toolCallId);

  @override
  void saveHistory() {
    historySaveCount++;
  }
}

typedef _Observation = ({
  String toolName,
  bool isStart,
  bool hasMedia,
  bool toolMessagePresent,
  String? mediaId,
  CanonicalMediaAvailability? availability,
});

void main() {
  late AgentStateDatabase state;
  late PersistedRuntimeStateRepository persisted;
  late ToolsRegistry registry;
  late ToolExecutionCoordinator coordinator;
  late Uint8List pngBytes;

  setUp(() {
    getIt.allowReassignment = true;
    state = AgentStateDatabase.inMemory();
    persisted = PersistedRuntimeStateRepository.fromState(state);
    getIt.registerSingleton<AgentStateDatabase>(state);
    getIt.registerSingleton<PersistedRuntimeStateRepository>(persisted);

    state.db.execute('''
      INSERT INTO sessions (session_id, model, created_at, updated_at)
      VALUES ('test-session-114e', 'model-vision', '2026-10-18', '2026-10-18')
    ''');

    persisted.executionState.enqueueWorkItem(
      workItemId: 'test-work-114e',
      sessionId: 'test-session-114e',
      state: SessionWorkState.running,
      continuationMetadata: const {
        // Rich (typed) durability is enabled only for run-owned work items,
        // matching the live engine path that stores resolvable media.
        'owner_run_id': 'run-114e',
        'owner_generation': 1,
      },
    );

    pngBytes = _pngBytes();
    registry = ToolsRegistry()
      ..registerTool(_MediaResultTool('system_screenshot', pngBytes));
    coordinator = ToolExecutionCoordinator(
      sessionId: 'test-session-114e',
      registry: registry,
      sessionManager: SessionManager(),
      pluginManager: PluginManager(),
      checkpointCoordinator: ContinuationCheckpointCoordinator(
        sessionId: 'test-session-114e',
      ),
      deferredToolResultResolver: DeferredToolResultResolver(
        environment: {'SANAD_HOME': Directory.systemTemp.path},
      ),
    );
  });

  tearDown(() async {
    SessionManager.resetForTesting();
    await getIt.reset();
    state.dispose();
  });

  test(
    'system_screenshot publishes its media event only after the tool result is in history',
    () async {
      final callbacks = _RecordingCallbacks();
      final observations = <_Observation>[];
      final call = ToolCall(
        id: 'shot_1',
        name: 'system_screenshot',
        arguments: const {'monitor_number': 1},
      );

      await coordinator.executeToolCalls(
        [call],
        parallel: false,
        callbacks: callbacks,
        ctx: (currentTurnStartIndex: 0, currentModelStepId: 'model-step-1'),
        onToolEvent:
            ({
              required String toolName,
              String? input,
              String? output,
              ViewImageMediaMetadata? media,
              required bool isError,
              required bool isStart,
              String? toolRunId,
              DateTime? startedAt,
              DateTime? terminalAt,
              int? runtimeMs,
              String? errorCode,
            }) async {
              observations.add((
                toolName: toolName,
                isStart: isStart,
                hasMedia: media != null,
                toolMessagePresent: callbacks.isToolMessagePresent(
                  toolRunId ?? '',
                ),
                mediaId: media?.mediaId,
                availability: media?.availability,
              ));
            },
      );

      expect(
        callbacks.results[call.id],
        contains('Screenshot taken successfully'),
      );

      final mediaEvents = observations
          .where((event) => event.hasMedia)
          .toList();
      expect(
        mediaEvents,
        hasLength(1),
        reason:
            'exactly one media-bearing completion event must be published, '
            'never an early one plus a deferred one',
      );
      expect(mediaEvents.single.isStart, isFalse);
      expect(
        mediaEvents.single.toolMessagePresent,
        isTrue,
        reason:
            'a client fetch triggered by this event must not race the durable '
            'tool-result write',
      );
      expect(
        mediaEvents.single.availability,
        CanonicalMediaAvailability.available,
      );
      expect(mediaEvents.single.mediaId, isNotNull);
      expect(mediaEvents.single.mediaId, hasLength(64));

      // The stored typed result is what the Local Gateway and hosted relay
      // resolve the published media id against: the id published on the event
      // must already be resolvable from durable session history.
      final storedToolMessages = SessionManager()
          .getMessages('test-session-114e')
          .where((message) => message.role == MessageRole.tool)
          .toList();
      expect(storedToolMessages, hasLength(1));
      final storedResult = storedToolMessages.single.toolResult;
      expect(storedResult, isNotNull);
      final storedImages = storedResult!.blocks
          .whereType<ToolImageBlock>()
          .toList();
      expect(storedImages, hasLength(1));
      expect(storedImages.single.dataBase64, base64.encode(pngBytes));

      final resolvable = ViewImageMediaMetadata.project(
        sessionId: 'test-session-114e',
        toolName: 'system_screenshot',
        toolCallId: call.id,
        result: storedResult,
      );
      expect(resolvable, isNotNull);
      expect(
        resolvable!.mediaId,
        mediaEvents.single.mediaId,
        reason:
            'the published media id must match the id derived from the durable '
            'tool result the client fetches',
      );
    },
  );

  test(
    'view_image keeps the same deferred media publication contract',
    () async {
      registry = ToolsRegistry()
        ..registerTool(_MediaResultTool('view_image', pngBytes));
      coordinator = ToolExecutionCoordinator(
        sessionId: 'test-session-114e',
        registry: registry,
        sessionManager: SessionManager(),
        pluginManager: PluginManager(),
        checkpointCoordinator: ContinuationCheckpointCoordinator(
          sessionId: 'test-session-114e',
        ),
        deferredToolResultResolver: DeferredToolResultResolver(
          environment: {'SANAD_HOME': Directory.systemTemp.path},
        ),
      );

      final callbacks = _RecordingCallbacks();
      final observations = <_Observation>[];
      final call = ToolCall(
        id: 'view_1',
        name: 'view_image',
        arguments: const {'path': 'sample.png'},
      );

      await coordinator.executeToolCalls(
        [call],
        parallel: false,
        callbacks: callbacks,
        ctx: (currentTurnStartIndex: 0, currentModelStepId: 'model-step-1'),
        onToolEvent:
            ({
              required String toolName,
              String? input,
              String? output,
              ViewImageMediaMetadata? media,
              required bool isError,
              required bool isStart,
              String? toolRunId,
              DateTime? startedAt,
              DateTime? terminalAt,
              int? runtimeMs,
              String? errorCode,
            }) async {
              observations.add((
                toolName: toolName,
                isStart: isStart,
                hasMedia: media != null,
                toolMessagePresent: callbacks.isToolMessagePresent(
                  toolRunId ?? '',
                ),
                mediaId: media?.mediaId,
                availability: media?.availability,
              ));
            },
      );

      final mediaEvents = observations
          .where((event) => event.hasMedia)
          .toList();
      expect(mediaEvents, hasLength(1));
      expect(mediaEvents.single.toolMessagePresent, isTrue);
    },
  );

  test('a denied call reports the typed code to the live tool event', () async {
    registry.registerTool(_DenyingTool());
    final codes = <String?>[];
    await coordinator.executeToolCalls(
      [
        ToolCall(
          id: 'deny_1',
          name: 'shell_execute',
          arguments: const {'command': 'rm -rf build'},
        ),
      ],
      parallel: false,
      callbacks: _RecordingCallbacks(),
      ctx: (currentTurnStartIndex: 0, currentModelStepId: 'model-step-deny'),
      onToolEvent:
          ({
            required String toolName,
            String? input,
            String? output,
            ViewImageMediaMetadata? media,
            required bool isError,
            required bool isStart,
            String? toolRunId,
            DateTime? startedAt,
            DateTime? terminalAt,
            int? runtimeMs,
            String? errorCode,
          }) async {
            if (!isStart) codes.add(errorCode);
          },
    );
    expect(codes, ['permission_denied']);
  });

  test('a resumed user denial records and reports permission_denied', () async {
    final codes = <String?>[];
    await coordinator.executeSingleToolCall(
      ToolCall(
        id: 'deny_resume_1',
        name: 'shell_execute',
        arguments: const {'command': 'ls'},
      ),
      callbacks: _RecordingCallbacks(),
      forcedOutput:
          'Error executing tool: Exception: User denied permission for tool shell_execute.',
      forcedIsError: true,
      forcedErrorCode: ToolResultErrorCode.permissionDenied,
      onToolEvent:
          ({
            required String toolName,
            String? input,
            String? output,
            ViewImageMediaMetadata? media,
            required bool isError,
            required bool isStart,
            String? toolRunId,
            DateTime? startedAt,
            DateTime? terminalAt,
            int? runtimeMs,
            String? errorCode,
          }) async {
            if (!isStart) codes.add(errorCode);
          },
    );
    expect(codes, ['permission_denied']);
  });
}
