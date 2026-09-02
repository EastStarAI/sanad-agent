import '../../core/models/message.dart';
import 'agent_turn_request.dart';
import 'delivery/models.dart';

/// Represents a message or event coming from an external platform.
class GatewayEvent {
  final String sessionId;
  final String platformId;
  final String type;
  final Message message;
  final Map<String, dynamic> metadata;
  final String? runId;
  final AgentTurnRequest? turnRequest;

  /// Immutable platform origin captured when the command enters the runtime.
  /// It survives delayed tool suspensions so delivery never depends on the
  /// most recently registered socket for the session.
  final OriginContext? origin;

  GatewayEvent({
    required this.sessionId,
    required this.platformId,
    this.type = 'message',
    required this.message,
    this.metadata = const {},
    this.runId,
    this.turnRequest,
    this.origin,
  });

  GatewayEvent copyWithOrigin(OriginContext origin) => GatewayEvent(
    sessionId: sessionId,
    platformId: platformId,
    type: type,
    message: message,
    metadata: metadata,
    runId: runId,
    turnRequest: turnRequest,
    origin: origin,
  );
}

/// Represents a response from the agent to be sent back to the platform.
class GatewayResponse {
  final String sessionId;
  final String? platformId;
  final Message message;
  final bool isComplete;
  final String? runId;
  final String? modelStepId;
  final String? toolCallId;

  // New canonical fields
  final Map<String, dynamic>? usage;
  final Map<String, dynamic>? contextUsage;
  final int? runtimeMs;
  final String? model;
  final String? modelDisplay;
  final String? provider;
  final int? contextTokens;

  // Tool execution fields
  final String? toolName;
  final bool isToolUse;
  final bool isToolResult;
  final bool isToolError;
  final bool isToolCancelled;
  final bool isSessionCreated;
  final bool isSessionUpdated;
  final Map<String, dynamic>? sessionPayload;

  /// Phase 27 — canonical event id. Minted once at response creation and
  /// preserved across all local/cloud copies for client-side deduplication.
  final String eventId;

  /// Phase 27 — declarative delivery policy. The runtime owns the semantic
  /// meaning of the event; `GatewayManager` routes by this scope.
  final DeliveryPolicy delivery;

  /// Phase 27 — origin context of the triggering request, when available.
  /// Populated by `GatewayManager` from the originating platform descriptor.
  final OriginContext? origin;

  GatewayResponse({
    required this.sessionId,
    this.platformId,
    required this.message,
    this.isComplete = true,
    this.runId,
    this.modelStepId,
    this.toolCallId,
    this.usage,
    this.contextUsage,
    this.runtimeMs,
    this.model,
    this.modelDisplay,
    this.provider,
    this.contextTokens,
    this.toolName,
    this.isToolUse = false,
    this.isToolResult = false,
    this.isToolError = false,
    this.isToolCancelled = false,
    this.isSessionCreated = false,
    this.isSessionUpdated = false,
    this.sessionPayload,
    String? eventId,
    DeliveryPolicy? delivery,
    this.origin,
  }) : eventId = eventId ?? EventId.generate(),
       delivery =
           delivery ??
           DeliveryPolicy.platformFamily(PlatformFamily.sanadClient);

  /// Copy with a new delivery policy / origin context (used by `GatewayManager`
  /// during routing decisions and by translators when attaching scope).
  GatewayResponse copyWithDelivery({
    DeliveryPolicy? delivery,
    OriginContext? origin,
    String? eventId,
  }) => GatewayResponse(
    sessionId: sessionId,
    platformId: platformId,
    message: message,
    isComplete: isComplete,
    runId: runId,
    modelStepId: modelStepId,
    toolCallId: toolCallId,
    usage: usage,
    contextUsage: contextUsage,
    runtimeMs: runtimeMs,
    model: model,
    modelDisplay: modelDisplay,
    provider: provider,
    contextTokens: contextTokens,
    toolName: toolName,
    isToolUse: isToolUse,
    isToolResult: isToolResult,
    isToolError: isToolError,
    isToolCancelled: isToolCancelled,
    isSessionCreated: isSessionCreated,
    isSessionUpdated: isSessionUpdated,
    sessionPayload: sessionPayload,
    eventId: eventId ?? this.eventId,
    delivery: delivery ?? this.delivery,
    origin: origin ?? this.origin,
  );
}
