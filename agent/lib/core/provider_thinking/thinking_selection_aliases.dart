/// Legacy thinking-mode alias migration helpers (Task 43 §7.3).
library;

import 'thinking_control_models.dart';

const _legacyFastAliases = {'fast', 'light', 'minimal'};
const _legacyBalancedAliases = {'balanced', 'normal'};
const _legacyDeepAliases = {'deep'};
const _legacyXHighAliases = {'extra-high', 'extra_high', 'extrahigh', 'x-high'};
const _legacyMaxAliases = {'ultra', 'maximum'};

const legacyThinkingSelectionAliases = {
  'fast': 'low',
  'light': 'low',
  'minimal': 'low',
  'balanced': 'medium',
  'normal': 'medium',
  'deep': 'high',
  'extra-high': 'xhigh',
  'extra_high': 'xhigh',
  'extrahigh': 'xhigh',
  'x-high': 'xhigh',
  'maximum': 'max',
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
  if (lowered == 'ultra') {
    if (descriptor.containsOptionId('max')) return 'max';
    if (descriptor.containsOptionId('xhigh')) return 'xhigh';
    return null;
  }
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
      _legacyDeepAliases.contains(lowered) ||
      _legacyXHighAliases.contains(lowered) ||
      _legacyMaxAliases.contains(lowered);
}
