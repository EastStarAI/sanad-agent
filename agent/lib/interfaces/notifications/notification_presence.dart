/// Plan 174 — the reachability question the delivery policy asks.
///
/// Origin-first delivery only means anything if the Agent can tell whether the
/// originating Client instance is still attached. Both transports already own
/// that answer: the local route holds in-memory membership for its sockets, and
/// the cloud route holds a bounded, revisioned, lease-based recipient set
/// published by the Gateway. This port keeps the notification module free of
/// either transport.
library;

import '../platforms/sanad_gateway/delivery_presence_controller.dart';

/// Whether a named Client instance is reachable by any route right now.
abstract interface class NotificationTargetPresence {
  /// True only when the instance is provably attached: it holds local
  /// membership, or it appears in a fresh cloud recipient set.
  ///
  /// Unknown is reported as `false`. A stale or absent cloud signal therefore
  /// escalates immediately instead of delaying the first notification, because
  /// a missed notification is worse than an early fan-out.
  bool isInstanceAttached(String clientInstanceId);
}

/// [DeliveryPresenceController] as the notification policy sees it.
class DeliveryPresenceTargetPresence implements NotificationTargetPresence {
  const DeliveryPresenceTargetPresence(this._presence);

  final DeliveryPresenceController _presence;

  @override
  bool isInstanceAttached(String clientInstanceId) =>
      _presence.isInstanceAttached(clientInstanceId);
}
