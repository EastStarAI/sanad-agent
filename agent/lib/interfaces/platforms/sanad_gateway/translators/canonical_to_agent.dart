import 'package:uuid/uuid.dart';
import '../../../../core/models/message.dart';
import '../../../models/gateway_event.dart';
import '../../../models/agent_turn_request.dart';

/// Translates raw gateway data (Canonical Protocol) to Sanad Agent GatewayEvents.
class CanonicalToAgent {
  static GatewayEvent? translate(Map<String, dynamic> data, String platformId) {
    final command = data['command'] as String?;
    final rawPayload = data['payload'];
    final payload = rawPayload is Map<String, dynamic>
        ? rawPayload
        : rawPayload is Map
        ? Map<String, dynamic>.from(rawPayload)
        : <String, dynamic>{};

    // Default session_id logic
    var sessionId = payload['session_id'] as String?;
    if (sessionId == null || sessionId.isEmpty) {
      if (command == 'create_session') {
        sessionId = const Uuid().v4();
      } else {
        sessionId = 'default';
      }
    }
    final runId =
        payload['run_id'] as String? ??
        data['run_id'] as String? ??
        (command == 'create_session' ? payload['request_id'] as String? : null);

    final mode = payload['mode'] as String?;
    final providerInstanceId = payload['provider_instance_id'] as String?;
    final providerId = payload['provider_id'] as String?;
    final deliveryIntent = payload['delivery_intent'] == 'queue'
        ? MessageDeliveryIntent.queue
        : MessageDeliveryIntent.auto;
    if (command == 'steer' || (command == 'think' && mode == 'steer')) {
      final text = payload['message'] as String? ?? '';
      final turnRequest = AgentTurnRequest(
        sessionId: sessionId,
        message: text,
        workspaceId: payload['workspace_id'] as String?,
        providerInstanceId: providerInstanceId,
        providerId: providerId,
        model: payload['model'] as String?,
        thinkingMode: payload['thinking_mode'] as String?,
        requestId: payload['request_id'] as String?,
        deliveryIntent: deliveryIntent,
        metadata: {
          if (payload['session_metadata'] is Map<String, dynamic>)
            'session_metadata': payload['session_metadata'],
          if (payload['platform_tools'] != null)
            'platform_tools': payload['platform_tools'],
        },
      );
      return GatewayEvent(
        sessionId: sessionId,
        platformId: platformId,
        type: 'steer',
        message: Message(role: MessageRole.user, content: text),
        metadata: data,
        runId: runId,
        turnRequest: turnRequest,
      );
    }

    if (command == 'think') {
      final text = payload['message'] as String? ?? '';
      final turnRequest = AgentTurnRequest(
        sessionId: sessionId,
        message: text,
        workspaceId: payload['workspace_id'] as String?,
        providerInstanceId: providerInstanceId,
        providerId: providerId,
        model: payload['model'] as String?,
        thinkingMode: payload['thinking_mode'] as String?,
        requestId: payload['request_id'] as String?,
        deliveryIntent: deliveryIntent,
        metadata: {
          if (payload['session_metadata'] is Map<String, dynamic>)
            'session_metadata': payload['session_metadata'],
          if (payload['platform_tools'] != null)
            'platform_tools': payload['platform_tools'],
        },
      );
      return GatewayEvent(
        sessionId: sessionId,
        platformId: platformId,
        message: Message(role: MessageRole.user, content: text),
        metadata: data,
        runId: runId,
        turnRequest: turnRequest,
      );
    }

    if (command == 'stop') {
      return GatewayEvent(
        sessionId: sessionId,
        platformId: platformId,
        type: 'stop',
        message: Message(role: MessageRole.user, content: ''),
        metadata: data,
        runId: runId,
      );
    }

    if (command == 'create_session') {
      final turnRequest = AgentTurnRequest(
        sessionId: sessionId,
        message: '',
        workspaceId: payload['workspace_id'] as String?,
        providerInstanceId: providerInstanceId,
        providerId: providerId,
        model: payload['model'] as String?,
        thinkingMode: payload['thinking_mode'] as String?,
        requestId: runId,
      );
      return GatewayEvent(
        sessionId: sessionId,
        platformId: platformId,
        type: command ?? 'create_session',
        message: Message(role: MessageRole.user, content: ''),
        metadata: data,
        runId: runId,
        turnRequest: turnRequest,
      );
    }

    // Reject unknown commands instead of translating them to a fallback message
    return null;
  }
}
