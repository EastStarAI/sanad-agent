import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:logging/logging.dart';
import 'package:sanad_client/features/notifications/domain/models/mobile_notification_catalog.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_action.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_kind.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_permission_status.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_platform_adapter.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_urgency.dart';
import 'package:sanad_client/utils/app_platform.dart';
import 'package:url_launcher/url_launcher.dart';

/// The macOS, Windows, Linux, Android, and iOS implementation of the local
/// notification path.
///
/// This is the only library that imports `flutter_local_notifications`; every
/// consumer talks to [NotificationPlatformAdapter]. The platform facts that
/// shape the implementation are recorded in
/// `docs/technical/desktop_background_and_system_tray.md` and
/// `docs/technical/mobile_push_delivery.md`:
///
/// - macOS is the only desktop target with an OS notification permission, so it
///   is the only desktop platform that can report
///   [NotificationPermissionStatus.unknown] and that can be refused.
///   Initialization deliberately requests nothing on any platform: a first
///   prompt may only follow an explicit user action in Settings.
/// - Windows reports the payload as the pressed action id and never exposes the
///   pressed button, so this adapter advertises no approval actions there
///   instead of presenting buttons whose decision it cannot read. An unpackaged
///   (NSIS) build also cannot cancel a presented toast, because Windows only
///   lets an app with package identity query its own notifications.
/// - Android fixes a channel's importance when the channel is created, so every
///   kind's channel is created high at initialization and is never recreated at
///   a lower importance. Channels are created before any notification can
///   arrive, because a channel created implicitly by a delivery would take the
///   delivery's importance instead of the product default.
/// - iOS fixes the buttons of a notification in the registered category, which
///   includes a notification that arrives while the app is terminated, so the
///   categories are registered here with the same action set the payload
///   contract defines.
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

  /// The macOS notification category that carries approval buttons.
  static const String approvalCategoryId = 'sanad_ask';

  /// Freedesktop icon used when the session has no themed icon of its own.
  static const String linuxIconName = 'dialog-information';

  /// The launcher icon Android uses for a notification this Client raises.
  static const String androidIconName = '@mipmap/ic_launcher';

  NotificationPlatformResponseCallback? _onResponse;
  String? _lastFailure;

  /// Localized channel names, keyed by channel id, captured when the channels
  /// are created. Android shows the name in the system settings, so it is read
  /// from the same copy the rest of the surface uses.
  Map<String, String> _channelLabels = const <String, String>{};

  bool _initialized = false;

  /// The last platform failure, for diagnostics only. Never user-facing copy.
  String? get lastFailure => _lastFailure;

  @override
  bool get isSupported => AppPlatform.isDesktop || AppPlatform.isMobile;

  @override
  bool get supportsApprovalActions =>
      AppPlatform.isMacOS || AppPlatform.isLinux || AppPlatform.isAndroid || AppPlatform.isIOS;

  @override
  bool get canOpenSystemSettings => AppPlatform.isMacOS || AppPlatform.isIOS;

  @override
  Future<void> initialize({
    NotificationPlatformResponseCallback? onResponse,
    Map<NotificationActionIntent, String> approvalActionLabels =
        const <NotificationActionIntent, String>{},
    Map<NotificationKind, String> kindLabels = const <NotificationKind, String>{},
  }) async {
    if (!isSupported) return;
    _onResponse = onResponse;
    _channelLabels = <String, String>{
      for (final channel in MobileNotificationCatalog.channels)
        if (kindLabels[channel.kind] != null) channel.id: kindLabels[channel.kind]!,
    };
    if (_initialized) return;

    final darwinCategories = <DarwinNotificationCategory>[
      DarwinNotificationCategory(approvalCategoryId, actions: _approvalActions(approvalActionLabels)),
      for (final category in MobileNotificationCatalog.categories)
        DarwinNotificationCategory(
          category.id,
          actions: category.offersApprovalActions ? _approvalActions(approvalActionLabels) : const <DarwinNotificationAction>[],
        ),
    ];

    final settings = InitializationSettings(
      macOS: DarwinInitializationSettings(
        // Nothing is requested at startup: the OS prompt may only follow a
        // click in Settings.
        requestAlertPermission: false,
        requestSoundPermission: false,
        requestBadgePermission: false,
        notificationCategories: darwinCategories,
      ),
      iOS: DarwinInitializationSettings(
        // The same rule on iOS: the push permission prompt is a Settings
        // action, never a startup side effect.
        requestAlertPermission: false,
        requestSoundPermission: false,
        requestBadgePermission: false,
        notificationCategories: darwinCategories,
      ),
      android: const AndroidInitializationSettings(androidIconName),
      linux: LinuxInitializationSettings(
        defaultActionName: 'Open',
        defaultIcon: ThemeLinuxIcon(linuxIconName),
      ),
      windows: const WindowsInitializationSettings(
        appName: appDisplayName,
        appUserModelId: appUserModelId,
        guid: windowsCallbackGuid,
      ),
    );

    try {
      await _plugin.initialize(
        settings: settings,
        onDidReceiveNotificationResponse: _handleResponse,
      );
      _initialized = true;
      await _createAndroidChannels();
    } catch (error, stack) {
      _lastFailure = error.toString();
      _logger.warning('notification platform initialize failed', error, stack);
    }
  }

  /// The approval actions iOS and macOS fix when the category is registered.
  List<DarwinNotificationAction> _approvalActions(
    Map<NotificationActionIntent, String> labels,
  ) {
    return <DarwinNotificationAction>[
      DarwinNotificationAction.plain(
        NotificationAction.allowOnceId,
        _label(labels, NotificationActionIntent.allowOnce),
      ),
      DarwinNotificationAction.plain(
        NotificationAction.allowSessionId,
        _label(labels, NotificationActionIntent.allowSession),
      ),
      DarwinNotificationAction.plain(
        NotificationAction.denyId,
        _label(labels, NotificationActionIntent.deny),
      ),
    ];
  }

  /// Creates every channel this Client owns, before any delivery can reach the
  /// device.
  ///
  /// Android fixes a channel's importance at creation and never raises it again,
  /// so a channel created implicitly by a notification would adopt whatever
  /// that delivery asked for. Creating all of them here at maximum importance is
  /// what makes "every kind is high" true for the life of the installation; the
  /// user may still lower a kind in the system settings, which is their
  /// decision and is never overridden.
  Future<void> _createAndroidChannels() async {
    if (!AppPlatform.isAndroid) return;
    final implementation =
        _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    if (implementation == null) return;
    for (final channel in MobileNotificationCatalog.channels) {
      final label = _channelLabels[channel.id];
      if (label == null) continue;
      try {
        await implementation.createNotificationChannel(
          AndroidNotificationChannel(
            channel.id,
            label,
            importance: Importance.max,
            playSound: true,
            enableVibration: true,
            showBadge: true,
          ),
        );
      } catch (error) {
        _lastFailure = error.toString();
        _logger.warning('could not create the ${channel.kind.wire} notification channel', error);
      }
    }
  }

  static String _label(
    Map<NotificationActionIntent, String> labels,
    NotificationActionIntent intent,
  ) {
    final label = labels[intent];
    if (label == null || label.trim().isEmpty) return intent.name;
    return label.trim();
  }

  void _handleResponse(NotificationResponse response) {
    _onResponse?.call(
      NotificationPlatformResponse(
        payload: response.payload ?? '',
        actionId: response.actionId,
        data: <String, String>{
          for (final entry in response.data.entries) entry.key: entry.value?.toString() ?? '',
        },
      ),
    );
  }

  @override
  Future<NotificationPermissionStatus> checkPermission() async {
    if (!isSupported) return NotificationPermissionStatus.unsupported;
    if (AppPlatform.isAndroid) {
      final implementation =
          _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      if (implementation == null) return NotificationPermissionStatus.unsupported;
      try {
        final enabled = await implementation.areNotificationsEnabled();
        if (enabled == null) return NotificationPermissionStatus.unknown;
        return enabled
            ? NotificationPermissionStatus.granted
            : NotificationPermissionStatus.denied;
      } catch (error) {
        _lastFailure = error.toString();
        return NotificationPermissionStatus.unavailable;
      }
    }
    if (AppPlatform.isIOS) {
      final implementation =
          _plugin.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>();
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
    if (AppPlatform.isAndroid) {
      final implementation =
          _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      if (implementation == null) return NotificationPermissionStatus.unsupported;
      try {
        // Android 13 and later ask at runtime; earlier releases answer here
        // without a prompt, which is why the result is re-read afterwards.
        await implementation.requestNotificationsPermission();
        return await checkPermission();
      } catch (error) {
        _lastFailure = error.toString();
        return NotificationPermissionStatus.unavailable;
      }
    }
    if (AppPlatform.isIOS) {
      final implementation =
          _plugin.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>();
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
        android: _androidDetails(request),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBanner: true,
          presentList: true,
          presentSound: request.urgency.isInterruptive,
          threadIdentifier: request.threadId,
          categoryIdentifier: request.iosCategoryId,
        ),
        macOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBanner: true,
          presentList: true,
          presentSound: request.urgency.isInterruptive,
          threadIdentifier: request.threadId,
          categoryIdentifier: request.offersApprovalActions && supportsApprovalActions
              ? approvalCategoryId
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

  /// The Android presentation of one notification.
  ///
  /// The channel is the Client-owned one for the kind, which already exists at
  /// high importance; the delivery repeats the same identity and importance so a
  /// build that somehow reaches `show` before the channel exists still cannot
  /// create a quieter channel than the product default.
  AndroidNotificationDetails _androidDetails(NotificationPresentationRequest request) {
    final channelId = request.androidChannelId;
    final channelName = channelId == null ? null : _channelLabels[channelId];
    return AndroidNotificationDetails(
      channelId ?? request.threadId ?? 'sanad_default_high',
      channelName ?? appDisplayName,
      importance: Importance.max,
      priority: Priority.high,
      playSound: request.urgency.isInterruptive,
      enableVibration: request.urgency.isInterruptive,
      autoCancel: true,
      category: AndroidNotificationCategory.message,
      groupKey: request.threadId,
      actions: <AndroidNotificationAction>[
        for (final action in request.actions)
          AndroidNotificationAction(
            action.id,
            action.label,
            showsUserInterface: true,
            cancelNotification: true,
          ),
      ],
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
    if (AppPlatform.isIOS) {
      try {
        // iOS exposes the per-app notification pane through the settings URL
        // its own framework publishes, and offers no second permission prompt.
        return await launchUrl(Uri.parse('app-settings:'));
      } catch (error) {
        _lastFailure = error.toString();
        return false;
      }
    }
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
