import '../../interfaces/models/agent_turn_request.dart';
import '../models/cli_events.dart';

enum CliConnectionState {
  disconnected,
  connecting,
  connected,
  reconnecting,
  closed,
}

/// Minimal turn transport consumed by the one-shot CLI runner.
///
/// Implementations may connect to the Local Gateway or execute through the
/// canonical in-process runtime. Keeping this boundary transport-neutral makes
/// attached and standalone behavior share the same runner and renderers.
abstract interface class CliTurnClient {
  Stream<CliEvent> get eventStream;
  Stream<CliConnectionState> get stateStream;

  Stream<CliAssistantChunkEvent> get assistantStream => eventStream
      .where((event) => event is CliAssistantChunkEvent)
      .cast<CliAssistantChunkEvent>();

  Stream<CliReasoningDeltaEvent> get reasoningStream => eventStream
      .where((event) => event is CliReasoningDeltaEvent)
      .cast<CliReasoningDeltaEvent>();

  Stream<CliToolCallEvent> get toolCallStream => eventStream
      .where((event) => event is CliToolCallEvent)
      .cast<CliToolCallEvent>();

  Stream<CliToolResultEvent> get toolResultStream => eventStream
      .where((event) => event is CliToolResultEvent)
      .cast<CliToolResultEvent>();

  Stream<CliPermissionRequestEvent> get permissionStream => eventStream
      .where((event) => event is CliPermissionRequestEvent)
      .cast<CliPermissionRequestEvent>();

  Stream<CliTurnCompleteEvent> get turnCompleteStream => eventStream
      .where((event) => event is CliTurnCompleteEvent)
      .cast<CliTurnCompleteEvent>();

  Future<String> dispatchTurnRequest(AgentTurnRequest request);

  Future<void> stop({required String sessionId, String? runId});

  Future<void> respondPermission({
    required String requestId,
    required bool allowed,
    String scope = 'once',
    String? decision,
    String? answer,
    String? comment,
  });

  Future<void> dispose();
}

/// Convenience base for in-process and test transports.
abstract class CliTurnClientBase implements CliTurnClient {
  @override
  Stream<CliAssistantChunkEvent> get assistantStream => eventStream
      .where((event) => event is CliAssistantChunkEvent)
      .cast<CliAssistantChunkEvent>();

  @override
  Stream<CliReasoningDeltaEvent> get reasoningStream => eventStream
      .where((event) => event is CliReasoningDeltaEvent)
      .cast<CliReasoningDeltaEvent>();

  @override
  Stream<CliToolCallEvent> get toolCallStream => eventStream
      .where((event) => event is CliToolCallEvent)
      .cast<CliToolCallEvent>();

  @override
  Stream<CliToolResultEvent> get toolResultStream => eventStream
      .where((event) => event is CliToolResultEvent)
      .cast<CliToolResultEvent>();

  @override
  Stream<CliPermissionRequestEvent> get permissionStream => eventStream
      .where((event) => event is CliPermissionRequestEvent)
      .cast<CliPermissionRequestEvent>();

  @override
  Stream<CliTurnCompleteEvent> get turnCompleteStream => eventStream
      .where((event) => event is CliTurnCompleteEvent)
      .cast<CliTurnCompleteEvent>();
}
