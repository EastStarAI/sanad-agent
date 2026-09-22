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

  /// Optional temporary filesystem context for tool and prompt execution.
  ///
  /// A registered workspace is authoritative. The execution root is used only
  /// when the request has no workspace association.
  String? get executionRoot {
    if (effectiveWorkspaceId != null) return null;
    final raw = metadata['execution_root'];
    if (raw is String && raw.trim().isNotEmpty) {
      return raw.trim();
    }
    return null;
  }

  String? get effectiveWorkspaceId {
    final raw = workspaceId ?? metadata['workspace_id'];
    if (raw is String && raw.trim().isNotEmpty) return raw.trim();
    return null;
  }

  Map<String, dynamic> get effectiveMetadata {
    final result = Map<String, dynamic>.from(metadata);
    final authoritativeWorkspaceId = effectiveWorkspaceId;
    if (authoritativeWorkspaceId != null) {
      result['workspace_id'] = authoritativeWorkspaceId;
      result.remove('execution_root');
    }
    return result;
  }

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

  Map<String, dynamic> toMetadata() {
    final result = <String, dynamic>{
      if (effectiveWorkspaceId != null) 'workspace_id': effectiveWorkspaceId,
      if (providerInstanceId != null)
        'provider_instance_id': providerInstanceId,
      if (providerId != null) 'provider_id': providerId,
      if (model != null) 'model': model,
      if (thinkingMode != null) 'thinking_mode': thinkingMode,
      if (requestId != null) 'request_id': requestId,
      'delivery_intent': deliveryIntent.name,
      ...effectiveMetadata,
    };
    return result;
  }

  AgentTurnRequest copyWith({
    String? sessionId,
    String? message,
    String? workspaceId,
    String? providerInstanceId,
    String? providerId,
    Object? model = _unset,
    String? thinkingMode,
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
      thinkingMode: thinkingMode ?? this.thinkingMode,
      requestId: requestId ?? this.requestId,
      deliveryIntent: deliveryIntent ?? this.deliveryIntent,
      metadata: metadata ?? this.metadata,
    );
  }
}
