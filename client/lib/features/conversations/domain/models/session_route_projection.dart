import 'package:sanad_client/features/conversations/domain/models/session.dart';
import 'package:sanad_client/features/conversations/domain/models/session_route_snapshot.dart';

/// Applies a device's route snapshot to one session's own projection.
///
/// A route snapshot is the Agent's last known provider/model/route revision for
/// the session; it never carries permission or workspace authority, so it can
/// only refine the route fields the composer shows. A snapshot older than the
/// session's own confirmed revision is ignored, and applying one clears a
/// thinking control that belonged to the replaced route.
Session applySessionRouteSnapshot(Session session, SessionRouteSnapshot? route) {
  if (route == null ||
      (session.routeRevision != null &&
          session.routeRevision! > route.routeRevision)) {
    return session;
  }
  return session.copyWith(
    model: route.model,
    modelProvider: route.providerInstanceId,
    routeRevision: route.routeRevision,
    clearThinkingControl: true,
    metadata: {
      ...?session.metadata,
      'model': route.model,
      'model_provider': route.providerInstanceId,
      'route_revision': route.routeRevision,
      if (route.providerDisplayName != null)
        'provider_display_name': route.providerDisplayName,
    },
  );
}
