import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:sanad_client/features/notifications/data/notification_preferences_store.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_kind.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_permission_status.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_platform_adapter.dart';
import 'package:sanad_client/features/notifications/presentation/bloc/notification_settings_state.dart';

/// The single owner of notification permission state and preferences.
///
/// The display pipeline reads the same instance the Settings surface edits, so
/// turning a kind off takes effect on the next event instead of after a
/// restart, and an OS revocation seen on resume is honoured by the next
/// notification.
class NotificationSettingsCubit extends Cubit<NotificationSettingsState> {
  NotificationSettingsCubit({
    required NotificationPreferencesStore store,
    required NotificationPlatformAdapter adapter,
  })  : _store = store,
        _adapter = adapter,
        super(NotificationSettingsState(
          platformSupported: adapter.isSupported,
          canOpenSystemSettings: adapter.canOpenSystemSettings,
          preferences: store.read(),
          permissionRequested: store.wasPermissionRequested,
        ));

  final NotificationPreferencesStore _store;
  final NotificationPlatformAdapter _adapter;

  bool _loaded = false;

  /// Reads the stored choices and the current OS permission.
  ///
  /// Safe to call again: an explicit refusal must be reflected without an app
  /// restart, so the Settings surface refreshes on open, on resume, and after a
  /// request.
  Future<void> load() async {
    final preferences = _store.read();
    final permission = await _readPermission();
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
      ),
    );
  }

  /// Re-reads only the OS permission, leaving preferences untouched.
  Future<void> refreshPermission() async {
    final permission = await _readPermission();
    if (isClosed) return;
    emit(state.copyWith(permission: permission, permissionRequested: _store.wasPermissionRequested));
  }

  Future<void> setEnabled(bool enabled) async {
    final preferences = state.preferences.withEnabled(enabled);
    await _store.write(preferences);
    if (isClosed) return;
    emit(state.copyWith(preferences: preferences));
  }

  Future<void> setKindEnabled(NotificationKind kind, bool enabled) async {
    final preferences = state.preferences.withKind(kind, enabled);
    await _store.write(preferences);
    if (isClosed) return;
    emit(state.copyWith(preferences: preferences));
  }

  /// Asks the OS, and only ever because the user pressed the Settings action.
  Future<void> requestPermission() async {
    if (!_adapter.isSupported || state.requestingPermission) return;
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

  /// Whether [load] has completed at least once.
  bool get isLoaded => _loaded;
}
