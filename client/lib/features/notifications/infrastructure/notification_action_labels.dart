import 'package:sanad_client/features/notifications/domain/models/notification_action.dart';

/// Resolves the button copy a platform fixes when it registers its notification
/// categories.
///
/// The Client always passes the labels it resolves from `AppLocalizations`
/// (`NotificationCopySource.approvalActionLabels`), and those win. This class
/// exists for the one path where the map can be empty — a caller that
/// initializes the platform without labels — because macOS registers its
/// categories once at startup and Linux fixes its default action name at the
/// same moment: an absent entry would otherwise either leave an empty button or
/// leak a raw intent name (`allowOnce`), which is protocol vocabulary, not copy.
///
/// The English fallback is kept identical to the `notificationAction*` entries of
/// `client/lib/l10n/app_en.arb`; a unit test asserts that equality so the two
/// cannot drift.
abstract final class NotificationActionLabels {
  /// English copy, used only when no localized label is supplied.
  static const Map<NotificationActionIntent, String> english =
      <NotificationActionIntent, String>{
    NotificationActionIntent.allowOnce: 'Allow once',
    NotificationActionIntent.allowSession: 'Allow for this session',
    NotificationActionIntent.deny: 'Deny',
    NotificationActionIntent.open: 'Open',
  };

  /// The localized label for [intent], or its English fallback.
  static String resolve(
    Map<NotificationActionIntent, String> labels,
    NotificationActionIntent intent,
  ) {
    final label = labels[intent]?.trim();
    if (label != null && label.isNotEmpty) return label;
    return english[intent]!;
  }

  /// The freedesktop default action name, shown for the notification body.
  ///
  /// Linux fixes it when the plugin initializes, like the macOS category, so it
  /// uses the same localized label the adapter already receives.
  static String linuxDefaultActionName(Map<NotificationActionIntent, String> labels) =>
      resolve(labels, NotificationActionIntent.open);
}
