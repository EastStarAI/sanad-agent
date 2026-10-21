enum SessionRouteSource { user, recovery, autoFailover }

extension SessionRouteSourceStorage on SessionRouteSource {
  String get storageValue => switch (this) {
    SessionRouteSource.user => 'user',
    SessionRouteSource.recovery => 'recovery',
    SessionRouteSource.autoFailover => 'auto_failover',
  };

  static SessionRouteSource fromStorage(String value) => switch (value) {
    'user' => SessionRouteSource.user,
    'recovery' => SessionRouteSource.recovery,
    'auto_failover' => SessionRouteSource.autoFailover,
    _ => throw FormatException('Unknown session route source: $value'),
  };
}

class SessionRouteTransition {
  final String sessionId;
  final int routeRevision;
  final String eventId;
  final SessionRouteSource source;
  final String? previousProviderInstanceId;
  final String providerInstanceId;

  /// Display names snapshotted at write time so history stays correct even if
  /// an instance is later renamed or deleted.
  final String? previousProviderDisplayName;
  final String? providerDisplayName;
  final String model;
  final String? reason;
  final String? requestId;

  /// `message_id` of the newest active row when the transition committed;
  /// history places the notice right after it. Null for legacy rows and for
  /// route changes made outside a running turn.
  final String? anchorMessageId;
  final DateTime createdAt;

  const SessionRouteTransition({
    required this.sessionId,
    required this.routeRevision,
    required this.eventId,
    required this.source,
    required this.previousProviderInstanceId,
    required this.providerInstanceId,
    this.previousProviderDisplayName,
    this.providerDisplayName,
    required this.model,
    required this.reason,
    required this.requestId,
    this.anchorMessageId,
    required this.createdAt,
  });

  factory SessionRouteTransition.fromRow(Map<String, Object?> row) {
    return SessionRouteTransition(
      sessionId: row['session_id']! as String,
      routeRevision: row['route_revision']! as int,
      eventId: row['event_id']! as String,
      source: SessionRouteSourceStorage.fromStorage(row['source']! as String),
      previousProviderInstanceId:
          row['previous_provider_instance_id'] as String?,
      providerInstanceId: row['provider_instance_id']! as String,
      previousProviderDisplayName:
          row['previous_provider_display_name'] as String?,
      providerDisplayName: row['provider_display_name'] as String?,
      model: row['model']! as String,
      reason: row['reason'] as String?,
      requestId: row['request_id'] as String?,
      anchorMessageId: row['anchor_message_id'] as String?,
      createdAt: DateTime.parse(row['created_at']! as String).toUtc(),
    );
  }

  Map<String, dynamic> toPayload() => {
    'session_id': sessionId,
    'source': source.storageValue,
    'previous_provider_instance_id': previousProviderInstanceId,
    'provider_instance_id': providerInstanceId,
    if (previousProviderDisplayName != null)
      'previous_provider_display_name': previousProviderDisplayName,
    if (providerDisplayName != null)
      'provider_display_name': providerDisplayName,
    'model': model,
    'reason': reason,
    'request_id': requestId,
    'route_revision': routeRevision,
    'updated_at': createdAt.toUtc().toIso8601String(),
  };
}
