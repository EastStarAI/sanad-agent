/// Plan 174f — one device's own notification choices, as that device declared
/// them.
///
/// Scope is the device, not the account (plan 174, 174f G0): a phone and a
/// desktop tolerate a different number of interruptions, so each Client keeps
/// its own answer and the Agent applies the answer of the device it is
/// dispatching to.
///
/// The declaration reaches the Agent inside the Client's authenticated
/// registration envelope — the local `client.hello`, or the client identity the
/// hosted service already relays for a cloud connection — so the relay forwards
/// one opaque field and never reads a choice. The Agent stores nothing on disk:
/// a reconnecting Client re-declares, and an unregistered device is treated as
/// the product default.
///
/// Two invariants hold here rather than in the Client's UI:
/// - a kind can only be lowered, so a declaration can never raise a
///   notification above the product default;
/// - an unknown kind or urgency token is ignored rather than stored, so an
///   older Agent never invents meaning for a newer Client's choice.
library;

import 'notification_kind.dart';

/// The choices one Client instance declared for itself.
final class ClientNotificationPreferences {
  const ClientNotificationPreferences({
    this.enabled = true,
    this.mutedKinds = const <String>{},
    this.urgencyCeilings = const <String, NotificationUrgency>{},
  });

  /// The product default, which is what an unregistered device gets.
  static const ClientNotificationPreferences productDefault =
      ClientNotificationPreferences();

  /// The declaration token a Client sends for a kind it turned off.
  static const String offToken = 'off';

  /// The global switch.
  final bool enabled;

  /// Kind values the device turned off.
  final Set<String> mutedKinds;

  /// Kind value to the loudest urgency that device accepts. Only values below
  /// [NotificationUrgency.high] are ever stored.
  final Map<String, NotificationUrgency> urgencyCeilings;

  /// True when the device declared nothing that changes the product default.
  bool get isProductDefault =>
      enabled && mutedKinds.isEmpty && urgencyCeilings.isEmpty;

  /// Whether this device accepts a notification of [kind] at all.
  bool allowsKind(NotificationKind kind) =>
      enabled && !mutedKinds.contains(kind.value);

  /// The loudest urgency this device accepts for [kind].
  NotificationUrgency ceilingFor(NotificationKind kind) =>
      urgencyCeilings[kind.value] ?? NotificationUrgency.high;

  /// The urgency to dispatch [kind] with, given the Agent's own decision.
  ///
  /// Lowering is one-way: the result is never louder than either input.
  NotificationUrgency urgencyFor(
    NotificationKind kind,
    NotificationUrgency fromAgent,
  ) =>
      NotificationUrgency.lowerOf(fromAgent, ceilingFor(kind));

  /// Reads a Client declaration.
  ///
  /// Returns `null` when [raw] is absent or not a declaration at all, which
  /// tells the caller to keep what it already knew for that instance. An empty
  /// but well-formed declaration is a deliberate reset and yields the product
  /// default.
  static ClientNotificationPreferences? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final enabled = _readEnabled(raw['enabled']) ?? true;
    final muted = <String>{};
    final ceilings = <String, NotificationUrgency>{};
    final kinds = raw['kinds'];
    if (kinds is Map) {
      for (final entry in kinds.entries) {
        final kind = NotificationKind.tryParse(entry.key);
        if (kind == null) continue;
        final token = entry.value;
        if (token == false || _isOffToken(token)) {
          muted.add(kind.value);
          continue;
        }
        final urgency = _readUrgency(token);
        // `high` is the product default, so declaring it is the same as saying
        // nothing; a louder token is not a user choice and is ignored.
        if (urgency == null || urgency == NotificationUrgency.high) continue;
        ceilings[kind.value] = urgency;
      }
    }
    return ClientNotificationPreferences(
      enabled: enabled,
      mutedKinds: Set<String>.unmodifiable(muted),
      urgencyCeilings: Map<String, NotificationUrgency>.unmodifiable(ceilings),
    );
  }

  /// The wire shape this model round-trips, used by tests and diagnostics.
  Map<String, dynamic> toJson() => <String, dynamic>{
        'enabled': enabled,
        'kinds': <String, String>{
          for (final kind in mutedKinds) kind: offToken,
          for (final entry in urgencyCeilings.entries)
            entry.key: entry.value.wireName,
        },
      };

  static bool? _readEnabled(Object? value) {
    if (value is bool) return value;
    if (value is String) {
      final normalized = value.trim().toLowerCase();
      if (normalized == 'true') return true;
      if (normalized == 'false') return false;
    }
    return null;
  }

  static bool _isOffToken(Object? value) {
    if (value is! String) return false;
    return value.trim().toLowerCase() == offToken;
  }

  static NotificationUrgency? _readUrgency(Object? value) {
    if (value is! String) return null;
    final normalized = value.trim().toLowerCase();
    for (final urgency in NotificationUrgency.values) {
      if (urgency.wireName == normalized) return urgency;
    }
    return null;
  }
}
