enum MessageDeliveryIntent { auto, queue }

class AgentTurnRequest {
  static const Object _unset = Object();

  final String sessionId;
  final String message;
  final String? workspaceId;
  final String? providerInstanceId;
  final String? providerId;
  final String? model;
  final String? thinkingMode;
  final String? requestId;
  final MessageDeliveryIntent deliveryIntent;
  final Map<String, dynamic> metadata;

  const AgentTurnRequest({
    required this.sessionId,
    required this.message,
    this.workspaceId,
    this.providerInstanceId,
    this.providerId,
    this.model,
    this.thinkingMode,
    this.requestId,
    this.deliveryIntent = MessageDeliveryIntent.auto,
    this.metadata = const {},
  });

  /// The effective provider instance UUID (prefers [providerInstanceId], falls back to [providerId]).
  String? get effectiveProviderInstanceId => providerInstanceId ?? providerId;

  List<Map<String, dynamic>> get platformTools {
    final raw = metadata['platform_tools'];
    if (raw is! List) {
      return const [];
    }
    return raw
        .whereType<Map>()
        .map((entry) => Map<String, dynamic>.from(entry))
        .toList(growable: false);
  }

  Map<String, dynamic> toMetadata() => {
    if (workspaceId != null) 'workspace_id': workspaceId,
    if (providerInstanceId != null) 'provider_instance_id': providerInstanceId,
    if (providerId != null) 'provider_id': providerId,
    if (model != null) 'model': model,
    if (thinkingMode != null) 'thinking_mode': thinkingMode,
    if (requestId != null) 'request_id': requestId,
    'delivery_intent': deliveryIntent.name,
    ...metadata,
  };

  AgentTurnRequest copyWith({
    String? sessionId,
    String? message,
    String? workspaceId,
    String? providerInstanceId,
    String? providerId,
    Object? model = _unset,
    Object? thinkingMode = _unset,
    String? requestId,
    MessageDeliveryIntent? deliveryIntent,
    Map<String, dynamic>? metadata,
  }) {
    return AgentTurnRequest(
      sessionId: sessionId ?? this.sessionId,
      message: message ?? this.message,
      workspaceId: workspaceId ?? this.workspaceId,
      providerInstanceId: providerInstanceId ?? this.providerInstanceId,
      providerId: providerId ?? this.providerId,
      model: identical(model, _unset) ? this.model : model as String?,
      thinkingMode: identical(thinkingMode, _unset)
          ? this.thinkingMode
          : thinkingMode as String?,
      requestId: requestId ?? this.requestId,
      deliveryIntent: deliveryIntent ?? this.deliveryIntent,
      metadata: metadata ?? this.metadata,
    );
  }
}
