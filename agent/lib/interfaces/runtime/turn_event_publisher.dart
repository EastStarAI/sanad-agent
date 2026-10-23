import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/models/view_image_media_metadata.dart';
import 'package:sanad_agent/engine/agent_runner.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/interfaces/models/gateway_event.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';
import 'package:sanad_agent/interfaces/runtime/session_turn_executor.dart';

/// Run-ownership predicate supplied by the executor that owns the active-run
/// maps: only the current, non-invalidated owner of a run may publish.
typedef ActiveRunOwnershipCheck = bool Function(ActiveRun run);

/// Context-usage capture supplied by the executor, which owns the session
/// metadata projection the snapshot is written to.
typedef TurnContextUsageCapture =
    Future<Map<String, dynamic>?> Function({
      required String sessionId,
      required AgentRunner agentRunner,
    });

/// Publishes one turn's live events: tool lifecycle, thought and reasoning
/// deltas, the in-flight snapshot projection, and the completed pre-steer
/// segment.
///
/// Every publication stays owner-gated through [ownsRun] and the run's
/// cancellation scope, so this owner never decides admission, ownership, or
/// terminal commit — `SessionTurnExecutor` keeps the active-run maps, the
/// stream subscription, and the durable steer delivery commit.
class TurnEventPublisher {
  final void Function(GatewayResponse) emitResponse;
  final ActiveRunOwnershipCheck ownsRun;
  final TurnContextUsageCapture captureContextUsage;

  const TurnEventPublisher({
    required this.emitResponse,
    required this.ownsRun,
    required this.captureContextUsage,
  });

  Future<void> emitToolEvent({
    required ActiveRun owner,
    required GatewayEvent event,
    required String runId,
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
    required void Function() onResetFullContent,
  }) async {
    if (!ownsRun(owner) || !owner.cancellationScope.isPublicationOpen) {
      return;
    }
    final sessionManager = getIt<SessionManager>();
    if (isStart) {
      onResetFullContent();
      sessionManager.clearInFlightSnapshot(event.sessionId);
      final contextUsage = await captureContextUsage(
        sessionId: event.sessionId,
        agentRunner: owner.agentRunner,
      );
      emitResponse(
        GatewayResponse(
          sessionId: event.sessionId,
          platformId: event.platformId,
          message: Message(
            role: MessageRole.tool,
            content: input,
            metadata: {
              if (startedAt != null) 'started_at': startedAt.toIso8601String(),
            },
          ),
          isComplete: false,
          runId: owner.runId,
          turnId: owner.turnId,
          modelStepId: owner.agentRunner.currentModelStepId,
          toolCallId: toolRunId,
          usage: owner.agentRunner.lastUsage,
          contextUsage: contextUsage,
          toolName: toolName,
          isToolUse: true,
        ),
      );
      return;
    }
    emitResponse(
      GatewayResponse(
        sessionId: event.sessionId,
        platformId: event.platformId,
        message: Message(
          role: MessageRole.tool,
          content: output,
          metadata: {
            'media': ?media?.toPublicJson(),
            'started_at': ?startedAt?.toIso8601String(),
            'terminal_at': ?terminalAt?.toIso8601String(),
            'runtime_ms': ?runtimeMs,
            'error_code': ?errorCode,
          },
        ),
        isComplete: false,
        runId: owner.runId,
        turnId: owner.turnId,
        modelStepId: owner.agentRunner.currentModelStepId,
        toolCallId: toolRunId,
        toolName: toolName,
        isToolResult: true,
        isToolError: isError,
      ),
    );
  }

  void emitThoughtDelta({
    required ActiveRun owner,
    required GatewayEvent event,
    required AgentRunner agentRunner,
    required String thought,
  }) {
    if (thought.isEmpty ||
        !ownsRun(owner) ||
        !owner.cancellationScope.isPublicationOpen) {
      return;
    }
    appendInFlightSnapshot(
      sessionId: event.sessionId,
      runId: owner.runId,
      turnId: owner.turnId,
      modelStepId: agentRunner.currentModelStepId,
      type: CanonicalEventTypes.thoughtStream,
      delta: thought,
    );
    emitResponse(
      GatewayResponse(
        sessionId: event.sessionId,
        platformId: event.platformId,
        message: Message(role: MessageRole.assistant, thought: thought),
        isComplete: false,
        runId: owner.runId,
        turnId: owner.turnId,
        modelStepId: agentRunner.currentModelStepId,
      ),
    );
  }

  void emitReasoningDelta({
    required ActiveRun owner,
    required GatewayEvent event,
    required AgentRunner agentRunner,
    required String fallbackRunId,
    required String reasoning,
  }) {
    if (reasoning.isEmpty ||
        !ownsRun(owner) ||
        !owner.cancellationScope.isPublicationOpen) {
      return;
    }
    appendInFlightSnapshot(
      sessionId: event.sessionId,
      runId: owner.runId,
      turnId: owner.turnId,
      modelStepId: agentRunner.currentModelStepId,
      type: CanonicalEventTypes.reasoningStream,
      delta: reasoning,
    );
    emitResponse(
      GatewayResponse(
        sessionId: event.sessionId,
        platformId: event.platformId,
        message: Message(role: MessageRole.assistant, reasoning: reasoning),
        isComplete: false,
        runId: owner.runId,
        turnId: owner.turnId,
        modelStepId: agentRunner.currentModelStepId,
      ),
    );
  }

  void appendInFlightSnapshot({
    required String sessionId,
    required String runId,
    required String? turnId,
    required String? modelStepId,
    required String type,
    required String delta,
  }) {
    if (delta.isEmpty) return;
    final sessionManager = getIt<SessionManager>();
    final existing = sessionManager.getInFlightSnapshot(sessionId);
    final sameStream =
        existing != null &&
        existing['type'] == type &&
        existing['run_id'] == runId &&
        existing['turn_id'] == turnId &&
        existing['model_step_id'] == modelStepId &&
        existing['content'] is String;
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    sessionManager.saveInFlightSnapshot(sessionId, {
      'type': type,
      'status': 'running',
      'session_id': sessionId,
      'run_id': runId,
      'turn_id': ?turnId,
      'model_step_id': modelStepId,
      'content': sameStream ? '${existing['content']}$delta' : delta,
      'timestamp': timestamp,
      'updated_at': timestamp,
    });
  }

  void emitCompletedSteerSegment({
    required ActiveRun owner,
    required GatewayEvent event,
    required String content,
  }) {
    if (content.isEmpty ||
        !ownsRun(owner) ||
        !owner.cancellationScope.isPublicationOpen) {
      return;
    }
    final modelStepId = owner.agentRunner.currentModelStepId;
    emitResponse(
      GatewayResponse(
        sessionId: event.sessionId,
        platformId: event.platformId,
        message: Message(
          role: MessageRole.assistant,
          content: content,
          metadata: {
            'canonical_event_type': CanonicalEventTypes.thought,
            'canonical_payload': {
              'content': content,
              'status': 'done',
              'session_id': event.sessionId,
              'run_id': owner.runId,
              if (owner.turnId != null) 'turn_id': owner.turnId,
              'model_step_id': ?modelStepId,
            },
          },
        ),
        isComplete: false,
        runId: owner.runId,
        turnId: owner.turnId,
        modelStepId: modelStepId,
      ),
    );
  }
}
