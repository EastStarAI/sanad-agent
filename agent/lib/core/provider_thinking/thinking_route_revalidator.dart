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

  /// Side-effect-free check: whether the route currently offers [selectionId].
  bool offersSelection({
    required String providerInstanceId,
    required String modelId,
    required String selectionId,
  }) {
    try {
      _resolver.resolve(
        providerInstanceId: providerInstanceId,
        modelId: modelId,
        selectionId: selectionId,
      );
      return true;
    } on ThinkingSelectionException {
      return false;
    }
  }

  ThinkingRouteRevalidationResult revalidateForRoute({
    required String sessionId,
    required String providerInstanceId,
    required String modelId,
    required String? selectionId,
    bool restorePreserved = false,
  }) {
    final trimmed = selectionId?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      if (restorePreserved) {
        final preserved = _store.readForRoute(
          sessionId,
          providerInstanceId: providerInstanceId,
          modelId: modelId,
        );
        if (preserved != null &&
            preserved.selectionId != null &&
            preserved.selectionId!.isNotEmpty) {
          try {
            final resolution = _resolver.resolve(
              providerInstanceId: providerInstanceId,
              modelId: modelId,
              selectionId: preserved.selectionId,
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
              previousSelectionId: preserved.selectionId,
              providerInstanceId: providerInstanceId,
              modelId: modelId,
            );
            return ThinkingRouteRevalidationResult(
              selectionId: null,
              corrected: true,
              correction: _store.readCorrection(sessionId),
            );
          }
        }
      }

      _store.savePreference(
        sessionId: sessionId,
        preference: ThinkingRoutePreference(
          selectionId: null,
          providerInstanceId: providerInstanceId,
          modelId: modelId,
          capabilityRevision: 'provider-default',
        ),
      );
      _store.clearCorrection(sessionId);
      return const ThinkingRouteRevalidationResult(selectionId: null);
    }

    final activeStored = _store.read(sessionId);
    final isInheritedFromOtherRoute = activeStored != null &&
        (activeStored.providerInstanceId != providerInstanceId ||
            activeStored.modelId != modelId);

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
      if (isInheritedFromOtherRoute) {
        _store.savePreference(
          sessionId: sessionId,
          preference: ThinkingRoutePreference(
            selectionId: null,
            providerInstanceId: providerInstanceId,
            modelId: modelId,
            capabilityRevision: 'provider-default',
          ),
        );
        return const ThinkingRouteRevalidationResult(
          selectionId: null,
          corrected: false,
        );
      }
      _store.recordCorrection(
        sessionId: sessionId,
        reason: error.code,
        previousSelectionId: trimmed,
        providerInstanceId: providerInstanceId,
        modelId: modelId,
      );
      return ThinkingRouteRevalidationResult(
        selectionId: null,
        corrected: true,
        correction: _store.readCorrection(sessionId),
      );
    }
  }
}
