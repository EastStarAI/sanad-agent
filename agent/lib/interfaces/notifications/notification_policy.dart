/// Plan 174 — origin-first delivery policy.
///
/// Delivery begins at the Client instance that originated the turn. The timer
/// exists only to escalate an ask nobody answered; it never replaces a dispatch
/// that could have happened now. When the origin cannot be named, cannot raise
/// a notification, or is not attached by any route, the policy skips the timer
/// and dispatches to the whole account immediately.
library;

import '../models/delivery/models.dart';
import 'notification_payload.dart';
import 'notification_presence.dart';

/// What the Agent knows about the surface that originated the ask.
final class NotificationOrigin {
  const NotificationOrigin({
    required this.platformFamily,
    required this.clientInstanceId,
    this.canNotify = true,
  });

  /// The platform family of the origin, resolved from the delivery envelope.
  final PlatformFamily? platformFamily;

  /// The authenticated Client instance id of the origin, when the envelope
  /// carried one. The standalone CLI, a scheduled run, and a restored
  /// checkpoint have none.
  final String? clientInstanceId;

  /// Whether the origin declared that it can raise a notification at all.
  final bool canNotify;

  /// A non-notifiable surface: external families (CLI, Telegram, WhatsApp),
  /// scheduled runs, and restored checkpoints that name no origin.
  bool get isNotifiableSurface =>
      platformFamily != null &&
      platformFamily!.isSanadClient &&
      (clientInstanceId?.isNotEmpty ?? false) &&
      canNotify;
}

/// The one dispatch step a plan allows.
final class NotificationDeliveryPlan {
  const NotificationDeliveryPlan({
    required this.step,
    required this.target,
    required this.armEscalation,
  });

  final NotificationDispatchStep step;
  final NotificationTarget target;

  /// Whether the dispatcher arms the escalation timer for this ask.
  final bool armEscalation;
}

/// Decides the first dispatch step of one ask.
class NotificationDispatchPolicy {
  const NotificationDispatchPolicy(this._presence);

  final NotificationTargetPresence _presence;

  /// Origin-first when the originating instance is provably attached and can
  /// notify; immediate account-wide dispatch otherwise.
  NotificationDeliveryPlan plan(NotificationOrigin? origin) {
    final instanceId = origin?.clientInstanceId;
    if (origin == null ||
        !origin.isNotifiableSurface ||
        !_presence.isInstanceAttached(instanceId!)) {
      return const NotificationDeliveryPlan(
        step: NotificationDispatchStep.immediate,
        target: NotificationTarget.account,
        armEscalation: false,
      );
    }
    return NotificationDeliveryPlan(
      step: NotificationDispatchStep.origin,
      target: NotificationTarget.clientInstance(instanceId),
      armEscalation: true,
    );
  }
}
