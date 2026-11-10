// Project built-in policy defaults: the documented, code-tracked values a
// policy section ships with when the user's `config.yaml` says nothing.
//
// This is the single mechanism for every section that needs one (today
// `context.modelLimits`; a future `compaction.models` uses the same types), so
// a built-in default never becomes a model-name branch inside runtime logic.

/// One project built-in policy default: the value plus why and when it was set.
///
/// `reason` is one line of evidence for the exact number, and `date` is the day
/// the owner adopted it. Both are required so a shipped default is reviewable
/// without archaeology.
class BuiltinPolicyDefault<T extends Object> {
  final T value;

  /// Why this exact value is the shipped default.
  final String reason;

  /// `yyyy-mm-dd` the value was adopted.
  final String date;

  const BuiltinPolicyDefault({
    required this.value,
    required this.reason,
    required this.date,
  });
}

/// A code-tracked default table for one `config.yaml` policy section.
///
/// Entries are keyed by the normalized model id, exactly like the user's own
/// keys. A lookup also accepts the model id's segment after the last `/`, so a
/// vendor-prefixed spelling of the same model (`deepseek/deepseek-v4.1-flash`)
/// shares the shipped default. User-written keys stay exact: only built-in
/// tables have this leniency.
class BuiltinModelPolicyDefaults<T extends Object> {
  /// The `config.yaml` section these defaults belong to, for diagnostics.
  final String section;

  final Map<String, BuiltinPolicyDefault<T>> entries;

  const BuiltinModelPolicyDefaults({
    required this.section,
    required this.entries,
  });

  /// The built-in entry for [normalizedModelId], if one applies.
  BuiltinPolicyDefault<T>? entryFor(String normalizedModelId) {
    final exact = entries[normalizedModelId];
    if (exact != null) return exact;
    final slash = normalizedModelId.lastIndexOf('/');
    if (slash < 0 || slash == normalizedModelId.length - 1) return null;
    return entries[normalizedModelId.substring(slash + 1)];
  }

  /// The built-in value for [normalizedModelId], if one applies.
  T? valueFor(String normalizedModelId) => entryFor(normalizedModelId)?.value;

  /// Key-by-key merge over [user]: a user entry wins for its own key and every
  /// other built-in default stays effective.
  ///
  /// This is the documented merge semantic for sections without an extra cap
  /// dimension. A resolver that must know which layer answered (for example
  /// capping shipped values but never user values) looks up [valueFor] instead
  /// of flattening the layers.
  Map<String, T> mergedOver(Map<String, T> user) => {
    for (final entry in entries.entries) entry.key: entry.value.value,
    ...user,
  };
}
