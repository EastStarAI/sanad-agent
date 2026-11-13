import 'package:shared_preferences/shared_preferences.dart';

import 'package:sanad_client/features/notifications/domain/models/notification_preferences.dart';

/// Persists the user's notification choices.
///
/// Only deliberate choices are stored: a missing global key means enabled, and
/// only kinds the user turned off appear in the disabled list, so a newly added
/// Agent kind is enabled the first time it is seen instead of arriving silent.
class NotificationPreferencesStore {
  NotificationPreferencesStore(this._preferences);

  final SharedPreferences _preferences;

  static const String enabledKey = 'notifications_enabled';
  static const String disabledKindsKey = 'notifications_kinds_disabled';
  static const String permissionRequestedKey = 'notifications_permission_requested';

  NotificationPreferences read() {
    final disabled = _preferences.getStringList(disabledKindsKey) ?? const <String>[];
    return NotificationPreferences.fromStored(
      enabled: _preferences.getBool(enabledKey) ?? true,
      kindTokens: <String, bool>{for (final token in disabled) token: false},
    );
  }

  Future<void> write(NotificationPreferences preferences) async {
    await _preferences.setBool(enabledKey, preferences.enabled);
    await _preferences.setStringList(
      disabledKindsKey,
      preferences.kindOverrides.entries
          .where((entry) => !entry.value)
          .map((entry) => entry.key.wire)
          .toList(growable: false),
    );
  }

  /// Whether this Client has ever asked the OS for permission.
  ///
  /// macOS reports "not enabled" both before the first prompt and after a
  /// refusal, so the ask is recorded locally to let Settings explain the
  /// difference without prompting again.
  bool get wasPermissionRequested => _preferences.getBool(permissionRequestedKey) ?? false;

  Future<void> markPermissionRequested() => _preferences.setBool(permissionRequestedKey, true);
}
