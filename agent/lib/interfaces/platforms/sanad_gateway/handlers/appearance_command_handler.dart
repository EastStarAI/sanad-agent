import 'package:sanad_agent/core/appearance/appearance_store.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';

import '../sanad_protocol_bridge.dart';

class AppearanceCommandHandler {
  AppearanceCommandHandler({
    required AppearanceStore store,
    required SanadProtocolBridge bridge,
  }) : _store = store,
       _bridge = bridge;

  final AppearanceStore _store;
  final SanadProtocolBridge _bridge;

  Future<Map<String, dynamic>> buildSnapshotEnvelope(
    CanonicalEvent event,
  ) async {
    final appearance = await _store.readAppearance();
    return _bridge.buildAgentEventEnvelope(
      CanonicalEvent(
        type: CanonicalEventTypes.appearanceSnapshot,
        payload: {
          'request_id': event.payload['request_id'],
          'appearance': appearance,
          ...appearance,
        },
      ),
    );
  }

  Future<Map<String, dynamic>> buildUpdateEnvelope(
    CanonicalEvent event,
  ) async {
    final requestId = event.payload['request_id'];
    try {
      final rawAppearance = event.payload['appearance'] ?? event.payload['changes'] ?? event.payload;
      final appearanceMap = rawAppearance is Map ? Map<String, dynamic>.from(rawAppearance) : <String, dynamic>{};
      final updated = await _store.saveAppearance(appearanceMap);
      return _bridge.buildAgentEventEnvelope(
        CanonicalEvent(
          type: CanonicalEventTypes.appearanceUpdated,
          payload: {
            'request_id': requestId,
            'appearance': updated,
            ...updated,
          },
        ),
      );
    } on Object catch (error) {
      return _bridge.buildAgentEventEnvelope(
        CanonicalEvent(
          type: 'error',
          payload: {
            'request_id': requestId,
            'code': 'invalid_appearance_settings',
            'message': error.toString(),
          },
        ),
      );
    }
  }
}
