import 'package:equatable/equatable.dart';

import 'notification_kind.dart';
import 'notification_urgency.dart';

/// The notification choices that belong to **this device**.
///
/// Scope is the device, not the account: a phone and a desktop tolerate a
/// different number of interruptions, so each Client stores its own answer and
/// the Agent applies the preference of the device it dispatches to. The store
/// is the platform's own preferences file (`SharedPreferences`, which is
/// `NSUserDefaults` on macOS/iOS, a registry-backed file on Windows, a file under
/// `~/.local/share` on Linux, `SharedPreferences` on Android, and `localStorage`
/// on the web), so a device keeps its choice without an account round trip.
///
/// Two levels exist because they answer different questions: the global switch
/// answers "does Sanad interrupt me at all", and a per-kind choice answers
/// "which asks matter, and how loudly". Every kind starts enabled at the product
/// default — the product never ships a silent kind — and a stored value only
/// ever records a deliberate change, so a newly added Agent kind starts enabled
/// instead of silently off.
///
/// A kind can only be **lowered**. The product default is
/// [NotificationUrgency.defaultUrgency] (banner and sound); a stored ceiling is
/// honoured only when it is strictly below that default, so neither a corrupt
/// file nor a future build can raise a notification above what the product
/// decided.
///
/// A kind is **off or quietened, never both**. The two choices are stored
/// separately because switching a kind back on should restore the ceiling the
/// user had chosen, but the declaration that leaves this device states one
/// answer per kind and therefore has to name a winner: `off` does.
class NotificationPreferences extends Equatable {
  const NotificationPreferences({
    this.enabled = true,
    this.kindOverrides = const <NotificationKind, bool>{},
    this.kindUrgencyOverrides = const <NotificationKind, NotificationUrgency>{},
  });

  /// The global switch.
  final bool enabled;

  /// Per-kind off choices. A missing entry means "enabled".
  final Map<NotificationKind, bool> kindOverrides;

  /// Per-kind lowered urgency ceilings. A missing entry means the product
  /// default; only values below [NotificationUrgency.defaultUrgency] are kept.
  ///
  /// A muted kind may still hold a ceiling so that switching it back on restores
  /// what the user chose, but the ceiling is never declared or displayed while
  /// the kind is off: see [toAgentDeclaration] and [ceilingFor].
  final Map<NotificationKind, NotificationUrgency> kindUrgencyOverrides;

  /// The urgency the user accepts for [kind], before the Agent's decision.
  ///
  /// A muted kind has no ceiling: it is off, so no urgency describes it and a
  /// stale ceiling must not be presented as if this device would accept it.
  NotificationUrgency ceilingFor(NotificationKind kind) =>
      isKindEnabled(kind)
          ? kindUrgencyOverrides[kind] ?? NotificationUrgency.defaultUrgency
          : NotificationUrgency.defaultUrgency;

  bool isKindEnabled(NotificationKind kind) => kindOverrides[kind] ?? true;

  /// Whether a notification of [kind] may be raised at all.
  bool allows(NotificationKind kind) => enabled && isKindEnabled(kind);

  /// The urgency this device accepts for a notification the Agent decided to
  /// send at [agentUrgency].
  ///
  /// Lowering is one-way: the result is never louder than either input.
  NotificationUrgency urgencyFor(
    NotificationKind kind,
    NotificationUrgency agentUrgency,
  ) =>
      NotificationUrgency.lowerOf(agentUrgency, ceilingFor(kind));

  /// True when the user has not changed anything, which is the state every
  /// device starts in and the one the Agent assumes before a registration.
  bool get isProductDefault => enabled && kindOverrides.isEmpty && kindUrgencyOverrides.isEmpty;

  NotificationPreferences withEnabled(bool value) => NotificationPreferences(
        enabled: value,
        kindOverrides: kindOverrides,
        kindUrgencyOverrides: kindUrgencyOverrides,
      );

  NotificationPreferences withKind(NotificationKind kind, bool value) {
    final next = Map<NotificationKind, bool>.from(kindOverrides);
    if (value) {
      next.remove(kind);
    } else {
      next[kind] = false;
    }
    return NotificationPreferences(
      enabled: enabled,
      kindOverrides: Map.unmodifiable(next),
      kindUrgencyOverrides: kindUrgencyOverrides,
    );
  }

  /// Sets the urgency ceiling of [kind].
  ///
  /// A `null` ceiling, or one at or above the product default, clears the
  /// override: the Agent's own urgency is used again. Values below the default
  /// are stored as given.
  NotificationPreferences withKindUrgency(
    NotificationKind kind,
    NotificationUrgency? ceiling,
  ) {
    final next = Map<NotificationKind, NotificationUrgency>.from(kindUrgencyOverrides);
    if (ceiling == null || ceiling.index >= NotificationUrgency.defaultUrgency.index) {
      next.remove(kind);
    } else {
      next[kind] = ceiling;
    }
    return NotificationPreferences(
      enabled: enabled,
      kindOverrides: kindOverrides,
      kindUrgencyOverrides: Map.unmodifiable(next),
    );
  }

  /// The per-device declaration the Agent registers for this Client.
  ///
  /// It carries only the name of this device's decision: no account identity, no
  /// token, and nothing the relay is expected to read. A muted kind is `off`;
  /// a lowered kind carries its ceiling token; an untouched kind is absent and
  /// therefore means the product default.
  ///
  /// Exactly one token is emitted per kind, and `off` wins. The Agent treats the
  /// declaration as a ceiling, so a kind that is both muted and quietened must
  /// never reach the wire as a quietened kind: that would tell the Agent to
  /// deliver it. The order the user made the two choices in cannot matter, which
  /// is why precedence is decided here instead of by map insertion order.
  Map<String, dynamic> toAgentDeclaration() => <String, dynamic>{
        'enabled': enabled,
        'kinds': <String, String>{
          for (final kind in NotificationKind.values)
            if (!isKindEnabled(kind))
              kind.wire: _offToken
            else if (kindUrgencyOverrides[kind] case final urgency?)
              kind.wire: urgency.wire,
        },
      };

  /// The token a declaration uses for a kind the user turned off.
  static const String _offToken = 'off';

  /// Serializes only deliberate choices, so the store holds the smallest state
  /// that can reconstruct these preferences.
  Map<String, bool> toKindTokenMap() => <String, bool>{
        for (final entry in kindOverrides.entries) entry.key.wire: entry.value,
      };

  /// Rebuilds preferences from stored tokens, ignoring kinds this build does
  /// not know so an older Client never drops a newer Client's choice, and
  /// ignoring an urgency that would raise a kind above the product default.
  static NotificationPreferences fromStored({
    required bool enabled,
    required Map<String, bool> kindTokens,
    Map<String, String> urgencyTokens = const <String, String>{},
  }) {
    final overrides = <NotificationKind, bool>{};
    for (final entry in kindTokens.entries) {
      final kind = NotificationKind.fromWire(entry.key);
      if (kind == null) continue;
      if (entry.value) continue;
      overrides[kind] = false;
    }
    final urgencies = <NotificationKind, NotificationUrgency>{};
    for (final entry in urgencyTokens.entries) {
      final kind = NotificationKind.fromWire(entry.key);
      if (kind == null) continue;
      final urgency = _urgencyForWire(entry.value);
      if (urgency == null) continue;
      if (urgency.index >= NotificationUrgency.defaultUrgency.index) continue;
      urgencies[kind] = urgency;
    }
    return NotificationPreferences(
      enabled: enabled,
      kindOverrides: Map.unmodifiable(overrides),
      kindUrgencyOverrides: Map.unmodifiable(urgencies),
    );
  }

  static NotificationUrgency? _urgencyForWire(String token) {
    final normalized = token.trim().toLowerCase();
    for (final urgency in NotificationUrgency.values) {
      if (urgency.wire == normalized) return urgency;
    }
    return null;
  }

  @override
  List<Object?> get props => [enabled, kindOverrides, kindUrgencyOverrides];
}
