/// Revalidates stored thinking selections when the active route changes.
library;

import 'package:sanad_agent/core/provider_thinking/thinking_route_preference.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_route_preference_store.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_selection_errors.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_selection_resolver.dart';

class ThinkingRouteRevalidationResult {
  final String? selectionId;
  final bool corrected;
  final ThinkingRouteCorrection? correction;

  const ThinkingRouteRevalidationResult({
    required this.selectionId,
    this.corrected = false,
    this.correction,
  });
}

class ThinkingRouteRevalidator {
  final ThinkingSelectionResolver _resolver;
  final ThinkingRoutePreferenceStore _store;

  ThinkingRouteRevalidator({
    required ThinkingSelectionResolver resolver,
    required ThinkingRoutePreferenceStore store,
  }) : _resolver = resolver,
       _store = store;

  ThinkingRouteRevalidationResult revalidateForRoute({
    required String sessionId,
    required String providerInstanceId,
    required String modelId,
    required String? selectionId,
  }) {
    final trimmed = selectionId?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      _store.savePreference(
        sessionId: sessionId,
        preference: ThinkingRoutePreference(
          selectionId: null,
          providerInstanceId: providerInstanceId,
          modelId: modelId,
          capabilityRevision: 'provider-default',
        ),
      );
      return const ThinkingRouteRevalidationResult(selectionId: null);
    }

    try {
      final resolution = _resolver.resolve(
        providerInstanceId: providerInstanceId,
        modelId: modelId,
        selectionId: trimmed,
      );
      _store.savePreference(
        sessionId: sessionId,
        preference: ThinkingRoutePreference(
          selectionId: resolution.selectionId,
          providerInstanceId: providerInstanceId,
          modelId: modelId,
          capabilityRevision: resolution.descriptor.capabilityRevision,
        ),
      );
      _store.clearCorrection(sessionId);
      return ThinkingRouteRevalidationResult(
        selectionId: resolution.selectionId,
      );
    } on ThinkingSelectionException catch (error) {
      _store.recordCorrection(
        sessionId: sessionId,
        reason: error.code,
        previousSelectionId: trimmed,
      );
      return ThinkingRouteRevalidationResult(
        selectionId: null,
        corrected: true,
        correction: _store.readCorrection(sessionId),
      );
    }
  }
}
