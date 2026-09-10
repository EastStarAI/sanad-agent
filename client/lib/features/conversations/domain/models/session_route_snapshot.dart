import 'package:equatable/equatable.dart';

enum SessionRouteSource {
  user,
  recovery,
  autoFailover;

  static SessionRouteSource fromWireValue(Object? value) => switch (value?.toString()) {
    'user' => SessionRouteSource.user,
    'recovery' => SessionRouteSource.recovery,
    'auto_failover' => SessionRouteSource.autoFailover,
    final value => throw FormatException('Unknown session route source: $value'),
  };
}

class SessionRouteSnapshot extends Equatable {
  final String sessionId;
  final SessionRouteSource source;
  final String? previousProviderInstanceId;
  final String providerInstanceId;
  final String model;
  final String? reason;
  final String? requestId;
  final int routeRevision;
  final DateTime? updatedAt;
  final String? eventId;
  final String? previousProviderDisplayName;
  final String? providerDisplayName;

  const SessionRouteSnapshot({
    required this.sessionId,
    required this.source,
    required this.previousProviderInstanceId,
    required this.providerInstanceId,
    required this.model,
    required this.reason,
    required this.requestId,
    required this.routeRevision,
    required this.updatedAt,
    required this.eventId,
    required this.previousProviderDisplayName,
    required this.providerDisplayName,
  });

  factory SessionRouteSnapshot.fromJson(
    Map<String, dynamic> json, {
    String? expectedSessionId,
  }) {
    final sessionId = _requiredString(json['session_id'], 'session_id');
    if (expectedSessionId != null && sessionId != expectedSessionId) {
      throw FormatException(
        'Route snapshot session_id $sessionId does not match $expectedSessionId.',
      );
    }
    final revision = json['route_revision'];
    if (revision is! num || revision.toInt() != revision || revision.isNegative) {
      throw FormatException(
        'Route snapshot route_revision must be a non-negative integer: $revision',
      );
    }
    final updatedAtValue = json['route_updated_at'] ?? json['updated_at'];
    final updatedAt = updatedAtValue == null ? null : DateTime.tryParse(updatedAtValue.toString());
    if (updatedAtValue != null && updatedAt == null) {
      throw FormatException('Invalid route snapshot updated_at: $updatedAtValue');
    }
    return SessionRouteSnapshot(
      sessionId: sessionId,
      source: SessionRouteSource.fromWireValue(json['source'] ?? 'user'),
      previousProviderInstanceId: _nullableString(
        json['previous_provider_instance_id'],
      ),
      providerInstanceId: _requiredString(
        json['provider_instance_id'],
        'provider_instance_id',
      ),
      model: _requiredString(json['model'], 'model'),
      reason: _nullableString(json['reason']),
      requestId: _nullableString(json['request_id']),
      routeRevision: revision.toInt(),
      updatedAt: updatedAt,
      eventId: _nullableString(json['event_id']),
      previousProviderDisplayName: _nullableString(
        json['previous_provider_display_name'],
      ),
      providerDisplayName: _nullableString(
        json['provider_display_name'],
      ),
    );
  }

  String get logicalEventId => 'route_${sessionId}_$routeRevision';

  int get transitionMetadataRichness => [
    if (source != SessionRouteSource.user) 1,
    if (previousProviderInstanceId != null) 1,
    if (reason != null) 1,
    if (requestId != null) 1,
    if (eventId != null) 1,
    if (previousProviderDisplayName != null) 1,
    if (providerDisplayName != null) 1,
  ].length;

  bool hasSameAuthoritativeRoute(SessionRouteSnapshot other) =>
      sessionId == other.sessionId &&
      providerInstanceId == other.providerInstanceId &&
      model == other.model &&
      routeRevision == other.routeRevision &&
      (updatedAt == null || other.updatedAt == null || updatedAt == other.updatedAt);

  String get informationalText {
    final previous = previousProviderDisplayName ?? previousProviderInstanceId ?? 'the previous provider';
    final next = providerDisplayName ?? providerInstanceId;
    final reasonText = _humanizeReason(reason);
    return 'Switched automatically from $previous to $next${reasonText == null ? '' : ' because $reasonText'}. Continuing with $model.';
  }

  static String _requiredString(Object? value, String field) {
    final normalized = _nullableString(value);
    if (normalized == null) throw FormatException('$field is required for a route snapshot.');
    return normalized;
  }

  static String? _nullableString(Object? value) {
    final normalized = value?.toString().trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }

  static String? _humanizeReason(String? value) {
    final normalized = _nullableString(value);
    if (normalized == null) return null;
    return normalized.replaceAll('_', ' ');
  }

  @override
  List<Object?> get props => [
    sessionId,
    source,
    previousProviderInstanceId,
    providerInstanceId,
    model,
    reason,
    requestId,
    routeRevision,
    updatedAt,
    eventId,
    previousProviderDisplayName,
    providerDisplayName,
  ];
}
