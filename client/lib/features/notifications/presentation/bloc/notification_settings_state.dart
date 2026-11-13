import 'package:equatable/equatable.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_kind.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_permission_status.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_preferences.dart';
import 'package:sanad_client/features/notifications/domain/models/web_push_capability.dart';

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

  /// The OS has not been asked yet, so Settings offers the ask instead of
  /// claiming a refusal.
  bool get needsPermissionRequest =>
      platformSupported && !permissionRequested && permission == NotificationPermissionStatus.unknown;

  /// The ask was made and the OS refused; Settings explains it and offers the
  /// system pane instead of prompting again.
  bool get permissionDenied => permission == NotificationPermissionStatus.denied;

  /// Notifications cannot work on this machine right now (no permission
  /// surface, or no notification service reachable).
  bool get unavailable => !platformSupported || permission == NotificationPermissionStatus.unavailable;

  /// Whether the permission action on a browser should run the subscription
  /// lifecycle instead of a bare prompt.
  bool get usesWebPushLifecycle => webPush.isWebPlatform && webPush.canSubscribe;

  bool isKindEnabled(NotificationKind kind) => preferences.isKindEnabled(kind);

  NotificationSettingsState copyWith({
    bool? loading,
    bool? platformSupported,
    bool? canOpenSystemSettings,
    NotificationPermissionStatus? permission,
    bool? permissionRequested,
    NotificationPreferences? preferences,
    bool? requestingPermission,
    WebPushSettings? webPush,
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
  ];
}
