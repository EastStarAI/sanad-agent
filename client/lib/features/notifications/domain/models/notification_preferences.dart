import 'package:equatable/equatable.dart';

import 'notification_kind.dart';

/// The user's notification choices.
///
/// Two levels exist because they answer different questions: the global switch
/// answers "does Sanad interrupt me at all", and a per-kind switch answers
/// "which asks matter". Every kind is enabled by default — the product never
/// ships a silent kind — and a stored value only ever records a deliberate
/// change, so a newly added Agent kind starts enabled instead of silently off.
class NotificationPreferences extends Equatable {
  const NotificationPreferences({
    this.enabled = true,
    this.kindOverrides = const <NotificationKind, bool>{},
  });

  /// The global switch.
  final bool enabled;

  /// Explicit per-kind choices. A missing entry means "enabled".
  final Map<NotificationKind, bool> kindOverrides;

  NotificationPreferences get defaults => const NotificationPreferences();

  bool isKindEnabled(NotificationKind kind) => kindOverrides[kind] ?? true;

  /// The kinds the user deliberately muted. Mirrored to the web service worker
  /// so a closed tab honours the same choices the page made.
  Set<NotificationKind> get mutedKinds => <NotificationKind>{
        for (final entry in kindOverrides.entries)
          if (!entry.value) entry.key,
      };

  /// Whether a notification of [kind] may be raised at all.
  bool allows(NotificationKind kind) => enabled && isKindEnabled(kind);

  NotificationPreferences withEnabled(bool value) =>
      NotificationPreferences(enabled: value, kindOverrides: kindOverrides);

  NotificationPreferences withKind(NotificationKind kind, bool value) {
    final next = Map<NotificationKind, bool>.from(kindOverrides);
    if (value) {
      next.remove(kind);
    } else {
      next[kind] = false;
    }
    return NotificationPreferences(enabled: enabled, kindOverrides: Map.unmodifiable(next));
  }

  /// Serializes only deliberate choices, so the store holds the smallest state
  /// that can reconstruct these preferences.
  Map<String, bool> toKindTokenMap() => <String, bool>{
        for (final entry in kindOverrides.entries) entry.key.wire: entry.value,
      };

  /// Rebuilds preferences from stored tokens, ignoring kinds this build does
  /// not know so an older Client never drops a newer Client's choice.
  static NotificationPreferences fromStored({
    required bool enabled,
    required Map<String, bool> kindTokens,
  }) {
    final overrides = <NotificationKind, bool>{};
    for (final entry in kindTokens.entries) {
      final kind = NotificationKind.fromWire(entry.key);
      if (kind == null) continue;
      if (entry.value) continue;
      overrides[kind] = false;
    }
    return NotificationPreferences(
      enabled: enabled,
      kindOverrides: Map.unmodifiable(overrides),
    );
  }

  @override
  List<Object?> get props => [enabled, kindOverrides];
}
