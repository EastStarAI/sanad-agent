/// Session metadata persistence for thinking route preferences (Task 43 Gate D).
library;

import 'package:sanad_agent/evolution/session_manager.dart';

import 'thinking_route_preference.dart';
import 'thinking_selection_errors.dart';

class ThinkingRoutePreferenceStore {
  static const preferenceKey = 'thinking_route';
  static const correctionKey = 'thinking_correction';

  final SessionManager _sessions;

  ThinkingRoutePreferenceStore(this._sessions);

  ThinkingRoutePreference? read(String sessionId) {
    final metadata = _sessions.getSessionMetadata(sessionId);
    final raw = metadata?[preferenceKey];
    if (raw is! Map) {
      return null;
    }
    return ThinkingRoutePreference.fromMap(Map<String, dynamic>.from(raw));
  }

  ThinkingRouteCorrection? readCorrection(String sessionId) {
    final metadata = _sessions.getSessionMetadata(sessionId);
    final raw = metadata?[correctionKey];
    if (raw is! Map) {
      return null;
    }
    return ThinkingRouteCorrection.fromMap(Map<String, dynamic>.from(raw));
  }

  void savePreference({
    required String sessionId,
    required ThinkingRoutePreference preference,
  }) {
    _mergeMetadata(sessionId, {
      preferenceKey: preference.toMap(),
      correctionKey: null,
    });
  }

  void recordCorrection({
    required String sessionId,
    required String reason,
    String? previousSelectionId,
  }) {
    _mergeMetadata(sessionId, {
      preferenceKey: null,
      correctionKey: ThinkingRouteCorrection(
        reason: reason,
        previousSelectionId: previousSelectionId,
        correctedAt: DateTime.now().toUtc(),
      ).toMap(),
    });
  }

  void clearCorrection(String sessionId) {
    _mergeMetadata(sessionId, {correctionKey: null});
  }

  void recordUnavailableRouteCorrection({
    required String sessionId,
    required String? previousSelectionId,
  }) {
    recordCorrection(
      sessionId: sessionId,
      reason: ThinkingSelectionErrorCode.optionUnavailable,
      previousSelectionId: previousSelectionId,
    );
  }

  void _mergeMetadata(
    String sessionId,
    Map<String, Object?> updates,
  ) {
    final existing = Map<String, dynamic>.from(
      _sessions.getSessionMetadata(sessionId) ?? const {},
    );
    for (final entry in updates.entries) {
      if (entry.value == null) {
        existing.remove(entry.key);
      } else {
        existing[entry.key] = entry.value;
      }
    }
    _sessions.saveSessionMetadata(sessionId, existing);
  }
}
