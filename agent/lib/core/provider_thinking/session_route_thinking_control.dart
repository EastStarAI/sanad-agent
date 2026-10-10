/// Resolves the active route thinking descriptor for session payloads (Task 43 Gate C).
library;

import 'package:sanad_agent/core/provider_thinking/thinking_selection_resolver.dart';
import 'package:sanad_agent/evolution/models/session_state.dart';

Map<String, dynamic>? resolveSessionRouteThinkingControl({
  required ThinkingSelectionResolver resolver,
  required SessionState session,
}) {
  final providerId = session.providerId?.trim();
  final modelId = session.model.trim();
  if (providerId == null || providerId.isEmpty || modelId.isEmpty) {
    return null;
  }

  try {
    final resolution = resolver.resolve(
      providerInstanceId: providerId,
      modelId: modelId,
      selectionId: null,
    );
    return resolution.descriptor.toMap();
  } catch (_) {
    return null;
  }
}
