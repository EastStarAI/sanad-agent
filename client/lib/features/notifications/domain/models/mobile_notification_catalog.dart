import 'package:equatable/equatable.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_kind.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_payload.dart';

/// One Android notification channel owned by the Client.
///
/// Android fixes a channel's importance when the channel is created: it can be
/// lowered by the user afterwards and can never be raised again. The product
/// makes every kind high urgency, so every channel is created high the first
/// time it is seen, and no code path ever creates a channel at a lower
/// importance.
class MobileNotificationChannel extends Equatable {
  const MobileNotificationChannel({required this.id, required this.kind});

  final String id;
  final NotificationKind kind;

  /// Every channel this Client creates is high importance.
  bool get isHighImportance => true;

  @override
  List<Object?> get props => [id, kind];
}

/// One iOS notification category owned by the Client.
///
/// The category fixes the buttons iOS shows for a notification, including a
/// notification that arrives while the app is terminated, so it is registered
/// at startup with the actions the payload contract defines.
class MobileNotificationCategory extends Equatable {
  const MobileNotificationCategory({
    required this.id,
    required this.kind,
    required this.offersApprovalActions,
  });

  final String id;
  final NotificationKind kind;
  final bool offersApprovalActions;

  @override
  List<Object?> get props => [id, kind, offersApprovalActions];
}

/// The Client-owned mobile notification inventory.
///
/// The Agent decides that a notification exists, its kind, its urgency, and its
/// copy. The channel and category identities are the Client's own surface, so
/// they are derived here from the kind and never invented per delivery. The
/// derivation matches the payload contract's `platform_hints`
/// (`sanad_<kind>_<urgency>` and `SANAD_<KIND>`), and a hint that disagrees is
/// ignored exactly like a disagreeing collapse key: replacement and muting
/// behavior must stay deterministic even if a producer changes its own
/// derivation.
class MobileNotificationCatalog {
  MobileNotificationCatalog._();

  /// The channel id for [kind] when the Agent names no usable hint.
  ///
  /// Urgency does not select a second channel: every kind owns one high
  /// importance channel so that muting one kind cannot mute the rest, and a
  /// lower urgency only changes sound and presentation on the arriving
  /// notification.
  static String channelId(NotificationKind kind) => 'sanad_${kind.wire}_high';

  /// The iOS category id for [kind].
  static String categoryId(NotificationKind kind) => 'SANAD_${kind.wire.toUpperCase()}';

  /// The channel id to deliver [payload] on.
  ///
  /// An Agent hint is honoured only when it names a channel this Client owns;
  /// anything else falls back to the derived identity instead of creating a
  /// channel the user never had a chance to configure.
  static String channelIdFor(NotificationPayload payload) {
    final hint = payload.androidChannelId;
    if (hint != null && hint == channelId(payload.kind)) return hint;
    return channelId(payload.kind);
  }

  /// The iOS category id to deliver [payload] on.
  static String categoryIdFor(NotificationPayload payload) {
    final hint = payload.iosCategory;
    if (hint != null && hint == categoryId(payload.kind)) return hint;
    return categoryId(payload.kind);
  }

  /// Every channel this Client owns, in taxonomy order.
  static List<MobileNotificationChannel> get channels => <MobileNotificationChannel>[
        for (final kind in NotificationKind.values)
          MobileNotificationChannel(id: channelId(kind), kind: kind),
      ];

  /// Every iOS category this Client owns, in taxonomy order.
  static List<MobileNotificationCategory> get categories => <MobileNotificationCategory>[
        for (final kind in NotificationKind.values)
          MobileNotificationCategory(
            id: categoryId(kind),
            kind: kind,
            offersApprovalActions: kind.supportsApprovalActions,
          ),
      ];
}
