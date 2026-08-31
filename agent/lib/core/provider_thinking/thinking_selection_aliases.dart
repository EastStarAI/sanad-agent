/// Legacy thinking-mode alias migration helpers (Task 43 §7.3).
library;

import 'thinking_control_models.dart';

const _legacyFastAliases = {'fast'};
const _legacyBalancedAliases = {'balanced', 'normal'};
const _legacyDeepAliases = {'deep'};

const legacyThinkingSelectionAliases = {
  'fast': 'low',
  'balanced': 'medium',
  'normal': 'medium',
  'deep': 'high',
};

/// Maps a legacy stored selection to a modern option id when available.
///
/// Returns null when [selectionId] is absent, already modern, or when the
/// mapped option is not present in [descriptor].
String? migrateLegacyThinkingSelectionId({
  required String? selectionId,
  required ThinkingControlDescriptor descriptor,
}) {
  final trimmed = selectionId?.trim();
  if (trimmed == null || trimmed.isEmpty) {
    return null;
  }
  final lowered = trimmed.toLowerCase();
  final mapped = legacyThinkingSelectionAliases[lowered] ?? lowered;
  if (descriptor.containsOptionId(mapped)) {
    return mapped;
  }
  return null;
}

bool isLegacyThinkingSelectionId(String? selectionId) {
  final lowered = selectionId?.trim().toLowerCase();
  if (lowered == null || lowered.isEmpty) {
    return false;
  }
  return _legacyFastAliases.contains(lowered) ||
      _legacyBalancedAliases.contains(lowered) ||
      _legacyDeepAliases.contains(lowered);
}
