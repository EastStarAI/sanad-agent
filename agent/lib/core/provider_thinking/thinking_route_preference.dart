/// Persisted thinking-selection binding for a session route (Task 43 Gate D).
library;

class ThinkingRoutePreference {
  final String? selectionId;
  final String providerInstanceId;
  final String modelId;
  final String capabilityRevision;

  const ThinkingRoutePreference({
    required this.selectionId,
    required this.providerInstanceId,
    required this.modelId,
    required this.capabilityRevision,
  });

  Map<String, dynamic> toMap() => {
    if (selectionId != null) 'selection_id': selectionId,
    'provider_instance_id': providerInstanceId,
    'model_id': modelId,
    'capability_revision': capabilityRevision,
  };

  factory ThinkingRoutePreference.fromMap(Map<String, dynamic> map) {
    return ThinkingRoutePreference(
      selectionId: map['selection_id'] as String?,
      providerInstanceId: map['provider_instance_id'] as String,
      modelId: map['model_id'] as String,
      capabilityRevision: map['capability_revision'] as String? ?? 'unknown',
    );
  }
}

class ThinkingRouteCorrection {
  final String reason;
  final String? previousSelectionId;
  final DateTime correctedAt;

  const ThinkingRouteCorrection({
    required this.reason,
    this.previousSelectionId,
    required this.correctedAt,
  });

  Map<String, dynamic> toMap() => {
    'reason': reason,
    if (previousSelectionId != null) 'previous_selection_id': previousSelectionId,
    'corrected_at': correctedAt.toUtc().toIso8601String(),
  };

  factory ThinkingRouteCorrection.fromMap(Map<String, dynamic> map) {
    return ThinkingRouteCorrection(
      reason: map['reason'] as String? ?? 'thinking_option_unavailable_for_route',
      previousSelectionId: map['previous_selection_id'] as String?,
      correctedAt: DateTime.parse(
        map['corrected_at'] as String? ?? DateTime.now().toUtc().toIso8601String(),
      ),
    );
  }
}
