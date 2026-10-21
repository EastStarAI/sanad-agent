/// Session metadata persistence for thinking route preferences (Task 43 Gate D).
library;

import 'package:sanad_agent/evolution/session_manager.dart';

import 'thinking_route_preference.dart';
import 'thinking_selection_errors.dart';

class ThinkingRoutePreferenceStore {
  static const preferenceKey = 'thinking_route';
  static const routePreferencesKey = 'thinking_route_preferences';
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

  ThinkingRoutePreference? readForRoute(
    String sessionId, {
    required String providerInstanceId,
    required String modelId,
  }) {
    final routes = _readRoutePreferencesMap(sessionId);
    final raw = routes['$providerInstanceId::$modelId'];
    if (raw is Map) {
      return ThinkingRoutePreference.fromMap(Map<String, dynamic>.from(raw));
    }
    final active = read(sessionId);
    if (active != null &&
        active.providerInstanceId == providerInstanceId &&
        active.modelId == modelId) {
      return active;
    }
    return null;
  }

  Map<String, dynamic> _readRoutePreferencesMap(String sessionId) {
    final metadata = _sessions.getSessionMetadata(sessionId);
    final raw = metadata?[routePreferencesKey];
    if (raw is Map) {
      return Map<String, dynamic>.from(raw);
    }
    final active = read(sessionId);
    if (active != null) {
      return {
        '${active.providerInstanceId}::${active.modelId}': active.toMap(),
      };
    }
    return {};
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
    final routes = _readRoutePreferencesMap(sessionId);
    routes['${preference.providerInstanceId}::${preference.modelId}'] =
        preference.toMap();
    _mergeMetadata(sessionId, {
      preferenceKey: preference.toMap(),
      routePreferencesKey: routes,
      correctionKey: null,
    });
  }

  void recordCorrection({
    required String sessionId,
    required String reason,
    String? previousSelectionId,
    String? providerInstanceId,
    String? modelId,
  }) {
    final routes = _readRoutePreferencesMap(sessionId);
    final active = read(sessionId);
    if (providerInstanceId != null && modelId != null) {
      routes.remove('$providerInstanceId::$modelId');
    } else if (active != null) {
      routes.remove('${active.providerInstanceId}::${active.modelId}');
    }
    final shouldClearActive = providerInstanceId == null ||
        modelId == null ||
        (active != null &&
            active.providerInstanceId == providerInstanceId &&
            active.modelId == modelId);

    _mergeMetadata(sessionId, {
      if (shouldClearActive) preferenceKey: null,
      routePreferencesKey: routes,
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
