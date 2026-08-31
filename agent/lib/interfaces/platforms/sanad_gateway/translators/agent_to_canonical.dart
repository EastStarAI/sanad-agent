import '../../../../core/models/message.dart';
import '../../../../evolution/db/message_history_identity.dart';
import '../../../models/gateway_event.dart';
import '../protocol/canonical_events.dart';

/// Translates Sanad Agent GatewayResponses to Canonical Protocol events.
class AgentToCanonical {
  static CanonicalEvent translate(GatewayResponse response) {
    final String type;
    final Map<String, dynamic> payload;

    if (response.isSessionCreated) {
      type = 'session_created';
      payload = {
        'id': response.sessionId,
        'session_id': response.sessionId,
        'title': response.message.content ?? 'New Chat',
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
        ...?response.sessionPayload,
        if (response.runId != null) 'run_id': response.runId,
        if (response.runId != null) 'request_id': response.runId,
      };
    } else if (response.isSessionUpdated) {
      type = 'session_updated';
      payload = {
        'id': response.sessionId,
        'session_id': response.sessionId,
        'title': response.message.content ?? '',
        'updated_at': DateTime.now().toIso8601String(),
        ...?response.sessionPayload,
        if (response.runId != null) 'run_id': response.runId,
      };
    } else if (response.message.role == MessageRole.user) {
      type = 'user_message';
      payload = {
        'id': 'msg_${DateTime.now().millisecondsSinceEpoch}',
        'content': response.message.content ?? '',
        'status': 'done',
        'timestamp':
            response.message.metadata?['received_at'] ??
            DateTime.now().toIso8601String(),
        if (response.runId != null) 'run_id': response.runId,
        if (response.message.metadata != null)
          'metadata': response.message.metadata,
        if (response.message.metadata?['request_id'] != null)
          'request_id': response.message.metadata?['request_id'],
        ...MessageHistoryIdentity.wireFields(response.message),
      };
    } else if (response.isToolUse) {
      type = 'tool_use';
      payload = {
        'tool': response.toolName,
        'input': response.message.content,
        'status': 'running',
        if (response.runId != null) 'run_id': response.runId,
        if (response.modelStepId != null) 'model_step_id': response.modelStepId,
        if (response.toolCallId != null) 'tool_call_id': response.toolCallId,
        if (response.contextUsage != null)
          'context_usage': response.contextUsage,
      };
    } else if (response.isToolResult) {
      type = 'tool_result';
      final terminalMetadata = response.message.metadata;
      payload = {
        'tool': response.toolName,
        'output': response.message.content,
        'isError': response.isToolError,
        'status': response.isToolCancelled
            ? 'cancelled'
            : (response.isToolError ? 'error' : 'done'),
        if (response.runId != null) 'run_id': response.runId,
        if (response.modelStepId != null) 'model_step_id': response.modelStepId,
        if (response.toolCallId != null) 'tool_call_id': response.toolCallId,
        if (terminalMetadata?['generation'] != null)
          'generation': terminalMetadata!['generation'],
        if (terminalMetadata?['revision'] != null)
          'revision': terminalMetadata!['revision'],
        if (terminalMetadata?['reason'] != null)
          'reason': terminalMetadata!['reason'],
        if (terminalMetadata?['started_at'] != null)
          'started_at': terminalMetadata!['started_at'],
        if (terminalMetadata?['terminal_at'] != null)
          'terminal_at': terminalMetadata!['terminal_at'],
        if (terminalMetadata?['cleanup_outcome'] != null)
          'cleanup_outcome': terminalMetadata!['cleanup_outcome'],
      };
    } else if (response.isComplete) {
      type = CanonicalEventTypes.finalAnswer;
      payload = {
        'id': 'msg_${DateTime.now().millisecondsSinceEpoch}',
        'content': response.message.content,
        'status': 'done',
        'timestamp': DateTime.now().toIso8601String(),
        if (response.runId != null) 'run_id': response.runId,
        if (response.modelStepId != null) 'model_step_id': response.modelStepId,
        if (response.model != null) 'model': response.model,
        if (response.modelDisplay != null)
          'model_display': response.modelDisplay,
        if (response.provider != null) 'provider': response.provider,
        if (response.usage != null) 'usage': response.usage,
        if (response.contextUsage != null)
          'context_usage': response.contextUsage,
        if (response.runtimeMs != null) 'runtime_ms': response.runtimeMs,
        if (response.contextTokens != null)
          'context_tokens': response.contextTokens,
        ...MessageHistoryIdentity.wireFields(response.message),
      };
    } else {
      // Distinguish reasoning content from intermediate thought text.
      // When the adapter populated [Message.reasoning], the stream carries
      // provider chain-of-thought tokens that must be rendered separately
      // from the final answer in the UI.
      final isReasoning =
          response.message.reasoning?.trim().isNotEmpty ?? false;
      type = isReasoning
          ? CanonicalEventTypes.reasoningStream
          : CanonicalEventTypes.thoughtStream;
      payload = {
        'content': isReasoning
            ? response.message.reasoning
            : response.message.thought ?? response.message.content,
        'status': 'running',
        if (response.runId != null) 'run_id': response.runId,
        if (response.modelStepId != null) 'model_step_id': response.modelStepId,
      };
    }

    return CanonicalEvent(
      type: type,
      payload: payload,
      sessionId: response.sessionId,
      runId: response.runId,
      eventId: response.eventId,
      delivery: response.delivery,
    );
  }
}
