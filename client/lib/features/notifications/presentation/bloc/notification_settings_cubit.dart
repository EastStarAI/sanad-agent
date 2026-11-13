import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:sanad_client/features/notifications/application/web_push_subscription_service.dart';
import 'package:sanad_client/features/notifications/data/notification_preferences_store.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_kind.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_permission_status.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_platform_adapter.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_preferences.dart';
import 'package:sanad_client/features/notifications/domain/models/web_push_capability.dart';
import 'package:sanad_client/features/notifications/domain/models/web_push_display_policy.dart';
import 'package:sanad_client/features/notifications/presentation/bloc/notification_settings_state.dart';

/// The single owner of notification permission state and preferences.
///
/// The display pipeline reads the same instance the Settings surface edits, so
/// turning a kind off takes effect on the next event instead of after a
/// restart, and an OS revocation seen on resume is honoured by the next
/// notification.
///
/// On a browser it also owns the push projection: the permission action runs the
/// whole subscription lifecycle, because a browser permission without a
/// registered endpoint cannot deliver anything while the tab is closed.
class NotificationSettingsCubit extends Cubit<NotificationSettingsState> {
  NotificationSettingsCubit({
    required NotificationPreferencesStore store,
    required NotificationPlatformAdapter adapter,
    WebPushSubscriptionService? webPush,
  })  : _store = store,
        _adapter = adapter,
        _webPush = webPush,
        super(
          NotificationSettingsState(
            platformSupported: adapter.isSupported,
            canOpenSystemSettings: adapter.canOpenSystemSettings,
            preferences: store.read(),
            permissionRequested: store.wasPermissionRequested,
            webPush: webPush?.settings ?? const WebPushSettings(),
          ),
        ) {
    final service = _webPush;
    if (service != null) {
      _webPushSubscription = service.changes.listen((settings) {
        if (isClosed) return;
        emit(state.copyWith(webPush: settings));
      });
    }
  }

  final NotificationPreferencesStore _store;
  final NotificationPlatformAdapter _adapter;
  final WebPushSubscriptionService? _webPush;
  StreamSubscription<WebPushSettings>? _webPushSubscription;

  bool _loaded = false;

  /// Reads the stored choices and the current OS permission.
  ///
  /// Safe to call again: an explicit refusal must be reflected without an app
  /// restart, so the Settings surface refreshes on open, on resume, and after a
  /// request.
  Future<void> load() async {
    final preferences = _store.read();
    final permission = await _readPermission();
    final webPush = await _readWebPush();
    _loaded = true;
    if (isClosed) return;
    emit(
      state.copyWith(
        loading: false,
        platformSupported: _adapter.isSupported,
        canOpenSystemSettings: _adapter.canOpenSystemSettings,
        preferences: preferences,
        permission: permission,
        permissionRequested: _store.wasPermissionRequested,
        webPush: webPush,
      ),
    );
    await _publishDisplayPolicy(preferences);
  }

  /// Re-reads only the OS permission and the browser subscription, leaving
  /// preferences untouched.
  Future<void> refreshPermission() async {
    final permission = await _readPermission();
    final webPush = await _readWebPush();
    if (isClosed) return;
    emit(
      state.copyWith(
        permission: permission,
        permissionRequested: _store.wasPermissionRequested,
        webPush: webPush,
      ),
    );
  }

  Future<void> setEnabled(bool enabled) async {
    final preferences = state.preferences.withEnabled(enabled);
    await _store.write(preferences);
    await _publishDisplayPolicy(preferences);
    if (isClosed) return;
    emit(state.copyWith(preferences: preferences));
  }

  Future<void> setKindEnabled(NotificationKind kind, bool enabled) async {
    final preferences = state.preferences.withKind(kind, enabled);
    await _store.write(preferences);
    await _publishDisplayPolicy(preferences);
    if (isClosed) return;
    emit(state.copyWith(preferences: preferences));
  }

  /// Asks the user's platform, and only ever because the user pressed the
  /// Settings action.
  ///
  /// A browser runs the full lifecycle: permission, subscription, and account
  /// registration. A native platform keeps the OS-only ask.
  Future<void> requestPermission() async {
    if (!_adapter.isSupported || state.requestingPermission) return;
    final service = _webPush;
    if (service != null && state.usesWebPushLifecycle) {
      emit(state.copyWith(requestingPermission: true));
      WebPushSettings settings;
      try {
        settings = await service.enable();
      } catch (_) {
        settings = service.settings.copyWith(failure: WebPushFailure.registrationFailed);
      }
      final permission = await _readPermission();
      await _store.markPermissionRequested();
      if (isClosed) return;
      emit(
        state.copyWith(
          requestingPermission: false,
          permission: permission,
          permissionRequested: true,
          webPush: settings,
        ),
      );
      return;
    }

    emit(state.copyWith(requestingPermission: true));
    NotificationPermissionStatus status;
    try {
      status = await _adapter.requestPermission();
    } catch (_) {
      status = NotificationPermissionStatus.unavailable;
    }
    await _store.markPermissionRequested();
    if (isClosed) return;
    emit(
      state.copyWith(
        requestingPermission: false,
        permission: status,
        permissionRequested: true,
      ),
    );
  }

  /// Withdraws this browser from the account. A native build has nothing to
  /// withdraw.
  Future<void> disableWebPush() async {
    final service = _webPush;
    if (service == null || state.requestingPermission) return;
    emit(state.copyWith(requestingPermission: true));
    WebPushSettings settings;
    try {
      settings = await service.disable();
    } catch (_) {
      settings = service.settings;
    }
    if (isClosed) return;
    emit(state.copyWith(requestingPermission: false, webPush: settings));
  }

  /// Opens the system notification pane after a refusal. No second prompt
  /// exists on macOS, so this is the only way back.
  Future<bool> openSystemSettings() => _adapter.openSystemSettings();

  Future<NotificationPermissionStatus> _readPermission() async {
    if (!_adapter.isSupported) return NotificationPermissionStatus.unsupported;
    try {
      return await _adapter.checkPermission();
    } catch (_) {
      return NotificationPermissionStatus.unavailable;
    }
  }

  Future<WebPushSettings> _readWebPush() async {
    final service = _webPush;
    if (service == null) return const WebPushSettings();
    try {
      return await service.refresh();
    } catch (_) {
      return service.settings;
    }
  }

  Future<void> _publishDisplayPolicy(NotificationPreferences preferences) async {
    final service = _webPush;
    if (service == null) return;
    await service.publishDisplayPolicy(
      WebPushDisplayPolicy(enabled: preferences.enabled, mutedKinds: preferences.mutedKinds),
    );
  }

  /// Whether [load] has completed at least once.
  bool get isLoaded => _loaded;

  @override
  Future<void> close() async {
    await _webPushSubscription?.cancel();
    return super.close();
  }
}
