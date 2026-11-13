import 'package:equatable/equatable.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_kind.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_permission_status.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_preferences.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_urgency.dart';
import 'package:sanad_client/features/notifications/domain/models/web_push_capability.dart';

/// What the last explicit test notification proved about this device.
///
/// The result is a closed set because it is the only honest answer to "did my
/// settings work": a test that always claims success would be worse than no
/// test at all.
enum NotificationTestOutcome {
  /// The pipeline ran and the operating system accepted the notification.
  shown,

  /// The user turned this kind, or notifications globally, off.
  kindDisabled,

  /// The OS has not allowed notifications for this app.
  permissionDenied,

  /// This system has no notification surface to drive.
  unsupported,

  /// The probe could not be built or presented, or no pipeline is attached to
  /// run it. Never reported as a notification that was shown.
  failed,
}

/// The Settings projection of notification permission and preferences.
class NotificationSettingsState extends Equatable {
  const NotificationSettingsState({
    this.loading = true,
    this.platformSupported = false,
    this.canOpenSystemSettings = false,
    this.permission = NotificationPermissionStatus.unknown,
    this.permissionRequested = false,
    this.preferences = const NotificationPreferences(),
    this.requestingPermission = false,
    this.webPush = const WebPushSettings(),
    this.sendingTest = false,
    this.testSenderAttached = false,
    this.testOutcome,
    this.testSequence = 0,
  });

  final bool loading;

  /// Whether this platform has an OS notification surface.
  final bool platformSupported;

  /// Whether this platform can open its own notification pane for the app.
  /// Where it cannot, Settings explains the refusal instead of offering a button
  /// that would do nothing.
  final bool canOpenSystemSettings;

  final NotificationPermissionStatus permission;

  /// Whether this Client has ever asked the OS for permission.
  final bool permissionRequested;

  final NotificationPreferences preferences;

  /// A permission request is in flight; the button must not be pressed twice.
  final bool requestingPermission;

  /// The browser push projection. It resolves
  /// [WebPushAvailability.unsupported] and is never rendered on a native build.
  final WebPushSettings webPush;

  /// A test notification is in flight.
  final bool sendingTest;

  /// Whether the running pipeline attached a test action.
  ///
  /// Settings cannot raise a notification itself, so a probe without this
  /// pipeline could only report a failure it did not cause.
  final bool testSenderAttached;

  /// The outcome of the last test notification, for the result line.
  final NotificationTestOutcome? testOutcome;

  /// Bumped on every test attempt, so pressing the button twice with the same
  /// result still re-renders the answer instead of looking ignored.
  final int testSequence;

  /// The OS has not been asked yet, so Settings offers the ask instead of
  /// claiming a refusal.
  bool get needsPermissionRequest =>
      platformSupported && !permissionRequested && permission == NotificationPermissionStatus.unknown;

  /// The ask was made and the OS refused; Settings explains it and offers the
  /// system pane instead of prompting again.
  bool get permissionDenied => permission == NotificationPermissionStatus.denied;

  /// The in-app switch is on while the OS refuses: the real state is reported
  /// rather than the toggle being forced off behind the user's back.
  bool get permissionDeniedWhileEnabled => permissionDenied && preferences.enabled;

  /// Notifications cannot work on this machine right now (no permission
  /// surface, or no notification service reachable).
  bool get unavailable => !platformSupported || permission == NotificationPermissionStatus.unavailable;

  /// Whether the permission action on a browser should run the subscription
  /// lifecycle instead of a bare prompt.
  bool get usesWebPushLifecycle => webPush.isWebPlatform && webPush.canSubscribe;

  /// The test action needs a platform to raise something and a sender attached
  /// by the running pipeline.
  bool get canSendTest =>
      platformSupported && testSenderAttached && !sendingTest && !unavailable;

  bool isKindEnabled(NotificationKind kind) => preferences.isKindEnabled(kind);

  NotificationUrgency ceilingFor(NotificationKind kind) => preferences.ceilingFor(kind);

  NotificationSettingsState copyWith({
    bool? loading,
    bool? platformSupported,
    bool? canOpenSystemSettings,
    NotificationPermissionStatus? permission,
    bool? permissionRequested,
    NotificationPreferences? preferences,
    bool? requestingPermission,
    WebPushSettings? webPush,
    bool? sendingTest,
    bool? testSenderAttached,
    NotificationTestOutcome? testOutcome,
    bool clearTestOutcome = false,
    int? testSequence,
  }) {
    return NotificationSettingsState(
      loading: loading ?? this.loading,
      platformSupported: platformSupported ?? this.platformSupported,
      canOpenSystemSettings: canOpenSystemSettings ?? this.canOpenSystemSettings,
      permission: permission ?? this.permission,
      permissionRequested: permissionRequested ?? this.permissionRequested,
      preferences: preferences ?? this.preferences,
      requestingPermission: requestingPermission ?? this.requestingPermission,
      webPush: webPush ?? this.webPush,
      sendingTest: sendingTest ?? this.sendingTest,
      testSenderAttached: testSenderAttached ?? this.testSenderAttached,
      testOutcome: clearTestOutcome ? null : (testOutcome ?? this.testOutcome),
      testSequence: testSequence ?? this.testSequence,
    );
  }

  @override
  List<Object?> get props => [
    loading,
    platformSupported,
    canOpenSystemSettings,
    permission,
    permissionRequested,
    preferences,
    requestingPermission,
    webPush,
    sendingTest,
    testSenderAttached,
    testOutcome,
    testSequence,
  ];
}
