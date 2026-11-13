/// The operating system's answer to "may this app post a notification?".
///
/// Only macOS has a real permission gate. Windows and Linux expose no
/// permission API, so their adapters report [granted] and let the OS decide at
/// delivery time; [unavailable] is the state where a Linux session has no
/// notification daemon at all.
enum NotificationPermissionStatus {
  /// The platform has no OS notification surface in this build.
  unsupported,

  /// Permission has not been decided yet; nothing may be shown until the user
  /// asks for it from Settings.
  unknown,

  /// The OS accepts notifications.
  granted,

  /// The user (or a policy) denied notifications for this app.
  denied,

  /// The platform supports notifications but no notification service is
  /// reachable, for example a Linux session without a notification daemon.
  unavailable;

  bool get canDisplay => this == NotificationPermissionStatus.granted;

  /// Whether asking again from Settings could change the answer.
  bool get isRequestable =>
      this == NotificationPermissionStatus.unknown ||
      this == NotificationPermissionStatus.denied;
}
