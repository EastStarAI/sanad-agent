import 'package:sanad_agent/core/provider_thinking/native_thinking_directive.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_selection_errors.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_selection_resolver.dart';
import 'package:test/test.dart';

/// Matches a selection closure that never puts a thinking field on the wire:
/// it is either rejected (a route that reports the set but does not offer the
/// value) or admitted with the provider default (no authority layer reports a
/// set, so the selection passes through unchanged and no field is sent).
final Matcher sendsNoThinkingField = predicate<Object? Function()>((resolve) {
  try {
    final resolution = resolve();
    return resolution is ThinkingSelectionResolution &&
        resolution.directive is UseProviderDefault;
  } on ThinkingSelectionException {
    return true;
  }
}, 'rejects the selection or admits it with no thinking field');
