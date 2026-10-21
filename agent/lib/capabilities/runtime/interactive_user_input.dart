import 'package:sanad_agent/capabilities/tools/base_tool.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/evolution/models/suspended_checkpoint.dart';
import 'package:sanad_agent/interfaces/runtime/platform_runtime_bridge.dart';
import 'package:sanad_agent/interfaces/runtime/suspended_checkpoint_store.dart';

/// Suspends a tool call on one interactive user-input request
/// (`system_ask_user`, `system_request_secret`): persists the durable
/// checkpoint first, waits for the client decision through the runtime
/// bridge, and removes the checkpoint once the live call has its answer.
class InteractiveUserInput {
  InteractiveUserInput({
    required PlatformRuntimeBridge bridge,
    SuspendedCheckpointStore Function()? checkpointStore,
  }) : _bridge = bridge,
       _checkpointStore =
           checkpointStore ?? (() => getIt<SuspendedCheckpointStore>());

  final PlatformRuntimeBridge _bridge;
  final SuspendedCheckpointStore Function() _checkpointStore;

  static const timeout = Duration(hours: 24);

  /// Requests input for [toolName]. [fields] become the request payload next
  /// to the identity fields; [args] are the original tool arguments kept in
  /// the checkpoint for redisplay and resume.
  Future<Map<String, dynamic>> request({
    required String toolName,
    required String checkpointPrefix,
    required ToolContext? context,
    required Map<String, dynamic> args,
    required Map<String, dynamic> fields,
  }) async {
    final requestId = DateTime.now().microsecondsSinceEpoch.toString();
    final toolContext =
        context ??
        ToolContext(
          sessionId: 'default',
          toolCallId: '$checkpointPrefix-call-$requestId',
        );
    final toolCallId =
        toolContext.toolCallId ?? '$checkpointPrefix-call-$requestId';
    final payload = <String, dynamic>{
      'request_id': requestId,
      'tool_name': toolName,
      'session_id': toolContext.sessionId,
      'tool_call_id': toolCallId,
      ...fields,
      'workspace_id': toolContext.metadata['workspace_id'],
    };

    final checkpointStore = _checkpointStore();
    final now = DateTime.now();
    await checkpointStore.save(
      SuspendedCheckpoint(
        checkpointId: '$checkpointPrefix-$requestId',
        sessionId: toolContext.sessionId,
        requestId: requestId,
        toolCallId: toolCallId,
        toolName: toolName,
        status: 'awaiting_permission',
        toolArguments: Map<String, dynamic>.from(args),
        permissionPayload: payload,
        createdAt: now,
        updatedAt: now,
      ),
    );
    try {
      return await _bridge.requestToolPermission(
        sessionId: toolContext.sessionId,
        payload: payload,
        timeout: timeout,
      );
    } finally {
      await checkpointStore.deleteByRequestId(requestId);
    }
  }
}
