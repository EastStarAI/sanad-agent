import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:logging/logging.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_action.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_permission_status.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_platform_adapter.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_urgency.dart';
import 'package:sanad_client/features/notifications/infrastructure/darwin_action_categories.dart';
import 'package:sanad_client/features/notifications/infrastructure/notification_action_labels.dart';
import 'package:sanad_client/utils/app_platform.dart';

/// The macOS, Windows, and Linux implementation of the local notification path.
///
/// This is the only library that imports `flutter_local_notifications`; every
/// consumer talks to [NotificationPlatformAdapter]. Two platform facts shape the
/// implementation and are recorded in
/// `docs/technical/desktop_background_and_system_tray.md`:
///
/// - macOS is the only desktop target with an OS notification permission, so it
///   is the only one that can report [NotificationPermissionStatus.unknown] and
///   that can be refused. Initialization deliberately requests nothing: a first
///   prompt may only follow an explicit user action in Settings.
/// - Windows reports the payload as the pressed action id and never exposes the
///   pressed button, so this adapter advertises no approval actions there
///   instead of presenting buttons whose decision it cannot read. An unpackaged
///   (NSIS) build also cannot cancel a presented toast, because Windows only
///   lets an app with package identity query its own notifications.
/// - macOS and Linux fix button copy when the platform initializes, so the
///   localized labels arrive once with [initialize]; the English fallback in
///   [NotificationActionLabels] is used only when that map is empty.
class FlutterLocalNotificationsAdapter implements NotificationPlatformAdapter {
  FlutterLocalNotificationsAdapter({FlutterLocalNotificationsPlugin? plugin})
      : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;

  static final Logger _logger = Logger('notifications.platform');

  /// Identity used by Windows to associate a toast with this application.
  /// Stable across releases: a changing AUMID orphans every previously
  /// delivered notification.
  static const String appUserModelId = 'com.eaststarai.sanad';
  static const String appDisplayName = 'Sanad';

  /// The activation-callback GUID registered with Windows. Stable on purpose.
  static const String windowsCallbackGuid = '9d0c1e46-5b0a-4f5a-9a4e-1d6f3c2b7a10';

  /// Freedesktop icon used when the session has no themed icon of its own.
  static const String linuxIconName = 'dialog-information';

  NotificationPlatformResponseCallback? _onResponse;
  String? _lastFailure;

  bool _initialized = false;

  /// The last platform failure, for diagnostics only. Never user-facing copy.
  String? get lastFailure => _lastFailure;

  @override
  bool get isSupported => AppPlatform.isDesktop;

  @override
  bool get supportsApprovalActions => AppPlatform.isMacOS || AppPlatform.isLinux;

  @override
  Future<void> initialize({
    NotificationPlatformResponseCallback? onResponse,
    Map<NotificationActionIntent, String> approvalActionLabels =
        const <NotificationActionIntent, String>{},
  }) async {
    if (!isSupported) return;
    _onResponse = onResponse;
    if (_initialized) return;

    final settings = buildSettings(approvalActionLabels: approvalActionLabels);

    try {
      await _plugin.initialize(
        settings: settings,
        onDidReceiveNotificationResponse: _handleResponse,
      );
      _initialized = true;
    } catch (error, stack) {
      _lastFailure = error.toString();
      _logger.warning('notification platform initialize failed', error, stack);
    }
  }

  /// The settings this adapter registers with the platform.
  ///
  /// Built once, because macOS registers its categories and Linux fixes its
  /// default action name at initialization: both take the localized labels here
  /// and cannot be corrected later. One macOS category is registered per
  /// non-empty subset of the approval actions, so a presented notification can
  /// only show the buttons its own payload offered.
  @visibleForTesting
  static InitializationSettings buildSettings({
    Map<NotificationActionIntent, String> approvalActionLabels =
        const <NotificationActionIntent, String>{},
  }) {
    return InitializationSettings(
      macOS: DarwinInitializationSettings(
        // Nothing is requested at startup: the OS prompt may only follow a
        // click in Settings.
        requestAlertPermission: false,
        requestSoundPermission: false,
        requestBadgePermission: false,
        notificationCategories: <DarwinNotificationCategory>[
          for (final actions in DarwinActionCategories.registeredActionSets)
            DarwinNotificationCategory(
              DarwinActionCategories.idFor(actions),
              actions: <DarwinNotificationAction>[
                for (final action in actions)
                  DarwinNotificationAction.plain(
                    action.id,
                    NotificationActionLabels.resolve(approvalActionLabels, action.intent),
                  ),
              ],
            ),
        ],
      ),
      linux: LinuxInitializationSettings(
        defaultActionName: NotificationActionLabels.linuxDefaultActionName(approvalActionLabels),
        defaultIcon: ThemeLinuxIcon(linuxIconName),
      ),
      windows: const WindowsInitializationSettings(
        appName: appDisplayName,
        appUserModelId: appUserModelId,
        guid: windowsCallbackGuid,
      ),
    );
  }

  /// The macOS category that presents exactly the actions [request] offers, or
  /// `null` when the request answers no approval.
  @visibleForTesting
  static String? approvalCategoryFor(NotificationPresentationRequest request) {
    if (!request.offersApprovalActions) return null;
    return DarwinActionCategories.categoryFor(request.actions.map((action) => action.id));
  }

  /// Maps a platform response to the Client's interaction shape.
  ///
  /// Pure, so a test can prove the mapping without a channel or a desktop host.
  @visibleForTesting
  static NotificationPlatformResponse responseFrom(NotificationResponse response) {
    return NotificationPlatformResponse(
      payload: response.payload ?? '',
      actionId: response.actionId,
      data: <String, String>{
        for (final entry in response.data.entries) entry.key: entry.value?.toString() ?? '',
      },
    );
  }

  /// Maps the platform's launch details to the Client's interaction shape, or
  /// `null` when this process was not started by a notification interaction.
  @visibleForTesting
  static NotificationPlatformResponse? launchResponseFrom(
    NotificationAppLaunchDetails? details,
  ) {
    if (details == null || !details.didNotificationLaunchApp) return null;
    final response = details.notificationResponse;
    if (response == null) return null;
    return responseFrom(response);
  }

  void _handleResponse(NotificationResponse response) {
    _onResponse?.call(responseFrom(response));
  }

  @override
  Future<NotificationPlatformResponse?> readLaunchResponse() async {
    // Only macOS and Windows can report the interaction that started the
    // process; Linux has no launch-time response at all. The caller must still
    // treat a returned interaction as unusable in-memory state.
    if (!_initialized || !(AppPlatform.isMacOS || AppPlatform.isWindows)) return null;
    try {
      return launchResponseFrom(await _plugin.getNotificationAppLaunchDetails());
    } catch (error, stack) {
      _lastFailure = error.toString();
      _logger.warning('could not read the notification launch details', error, stack);
      return null;
    }
  }

  @override
  Future<NotificationPermissionStatus> checkPermission() async {
    if (!isSupported) return NotificationPermissionStatus.unsupported;
    if (AppPlatform.isMacOS) {
      final implementation =
          _plugin.resolvePlatformSpecificImplementation<MacOSFlutterLocalNotificationsPlugin>();
      if (implementation == null) return NotificationPermissionStatus.unsupported;
      try {
        final options = await implementation.checkPermissions();
        if (options == null) return NotificationPermissionStatus.unknown;
        return options.isEnabled
            ? NotificationPermissionStatus.granted
            : NotificationPermissionStatus.denied;
      } catch (error) {
        _lastFailure = error.toString();
        return NotificationPermissionStatus.unavailable;
      }
    }
    if (AppPlatform.isLinux) {
      final implementation =
          _plugin.resolvePlatformSpecificImplementation<LinuxFlutterLocalNotificationsPlugin>();
      if (implementation == null) return NotificationPermissionStatus.unsupported;
      try {
        // A Linux session without a notification daemon cannot present
        // anything; the D-Bus capability call is the only way to find out.
        await implementation.getCapabilities();
        return NotificationPermissionStatus.granted;
      } catch (error) {
        _lastFailure = error.toString();
        return NotificationPermissionStatus.unavailable;
      }
    }
    // Windows exposes no notification permission; the toast either renders or
    // the user's Focus Assist policy suppresses it.
    return NotificationPermissionStatus.granted;
  }

  @override
  Future<NotificationPermissionStatus> requestPermission() async {
    if (!isSupported) return NotificationPermissionStatus.unsupported;
    if (!AppPlatform.isMacOS) return checkPermission();
    final implementation =
        _plugin.resolvePlatformSpecificImplementation<MacOSFlutterLocalNotificationsPlugin>();
    if (implementation == null) return NotificationPermissionStatus.unsupported;
    try {
      final granted = await implementation.requestPermissions(
        alert: true,
        sound: true,
        badge: false,
      );
      return granted == true
          ? NotificationPermissionStatus.granted
          : NotificationPermissionStatus.denied;
    } catch (error) {
      _lastFailure = error.toString();
      return NotificationPermissionStatus.unavailable;
    }
  }

  @override
  Future<void> show(NotificationPresentationRequest request) async {
    if (!isSupported || !_initialized) {
      throw StateError('notification platform is not initialized');
    }
    await _plugin.show(
      id: request.id,
      title: request.title,
      body: request.body,
      notificationDetails: NotificationDetails(
        macOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBanner: true,
          presentList: true,
          presentSound: request.urgency.isInterruptive,
          threadIdentifier: request.threadId,
          categoryIdentifier: request.offersApprovalActions && supportsApprovalActions
              ? approvalCategoryFor(request)
              : null,
        ),
        linux: LinuxNotificationDetails(
          urgency: _linuxUrgency(request.urgency),
          icon: ThemeLinuxIcon(linuxIconName),
          actions: <LinuxNotificationAction>[
            for (final action in request.actions)
              LinuxNotificationAction(key: action.id, label: action.label),
          ],
        ),
        windows: WindowsNotificationDetails(
          duration: request.urgency.isInterruptive
              ? WindowsNotificationDuration.long
              : WindowsNotificationDuration.short,
          actions: <WindowsAction>[
            // Windows is deliberately excluded from approval actions (see the
            // class comment); any action offered here would have to open the
            // session, so no button is presented at all.
            for (final action in request.actions)
              if (supportsApprovalActions)
                WindowsAction(content: action.label, arguments: action.id),
          ],
        ),
      ),
      payload: request.payload,
    );
  }

  static LinuxNotificationUrgency _linuxUrgency(NotificationUrgency urgency) {
    return switch (urgency) {
      NotificationUrgency.low => LinuxNotificationUrgency.low,
      NotificationUrgency.normal => LinuxNotificationUrgency.normal,
      NotificationUrgency.high ||
      NotificationUrgency.critical =>
        LinuxNotificationUrgency.critical,
    };
  }

  @override
  Future<bool> cancel(int notificationId) async {
    if (!isSupported || !_initialized) return false;
    try {
      await _plugin.cancel(id: notificationId);
      return true;
    } catch (error) {
      _lastFailure = error.toString();
      return false;
    }
  }

  @override
  Future<void> cancelAll() async {
    if (!isSupported || !_initialized) return;
    try {
      await _plugin.cancelAll();
    } catch (error) {
      _lastFailure = error.toString();
    }
  }

  @override
  Future<bool> openSystemSettings() async {
    if (!AppPlatform.isMacOS) return false;
    final implementation =
        _plugin.resolvePlatformSpecificImplementation<MacOSFlutterLocalNotificationsPlugin>();
    if (implementation == null) return false;
    try {
      return await implementation.openAppNotificationSettings() ?? false;
    } catch (error) {
      _lastFailure = error.toString();
      return false;
    }
  }

  @override
  Future<void> dispose() async {
    _onResponse = null;
    _initialized = false;
  }
}

NotificationPlatformAdapter createNotificationAdapter() => FlutterLocalNotificationsAdapter();
