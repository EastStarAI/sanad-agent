import 'package:shared_preferences/shared_preferences.dart';

import 'package:sanad_client/features/notifications/domain/models/notification_preferences.dart';

/// Persists the user's notification choices **for this device**.
///
/// The platform preferences file is the storage owner: `NSUserDefaults` on
/// macOS and iOS, the app's registry-backed file on Windows, a file under the
/// user's local share directory on Linux, `SharedPreferences` on Android, and
/// `localStorage` on the web. Nothing here is account-scoped and nothing is
/// uploaded, which is what makes the preference per-device: reinstalling or
/// signing in on another device does not carry it over.
///
/// Only deliberate choices are stored: a missing global key means enabled, only
/// kinds the user turned off appear in the disabled list, and only lowered
/// urgencies appear in the urgency list. A newly added Agent kind is therefore
/// enabled the first time it is seen instead of arriving silent.
class NotificationPreferencesStore {
  NotificationPreferencesStore(this._preferences);

  final SharedPreferences _preferences;

  static const String enabledKey = 'notifications_enabled';
  static const String disabledKindsKey = 'notifications_kinds_disabled';
  static const String kindUrgencyKey = 'notifications_kinds_urgency';
  static const String permissionRequestedKey = 'notifications_permission_requested';

  /// Separates the kind token from the urgency token in a stored entry.
  static const String kindUrgencySeparator = ':';

  NotificationPreferences read() {
    final disabled = _preferences.getStringList(disabledKindsKey) ?? const <String>[];
    return NotificationPreferences.fromStored(
      enabled: _preferences.getBool(enabledKey) ?? true,
      kindTokens: <String, bool>{for (final token in disabled) token: false},
      urgencyTokens: _readUrgencyTokens(),
    );
  }

  Future<void> write(NotificationPreferences preferences) async {
    await _preferences.setBool(enabledKey, preferences.enabled);
    await _preferences.setStringList(
      disabledKindsKey,
      [
        for (final entry in preferences.kindOverrides.entries)
          if (!entry.value) entry.key.wire,
      ],
    );
    await _preferences.setStringList(
      kindUrgencyKey,
      [
        for (final entry in preferences.kindUrgencyOverrides.entries)
          '${entry.key.wire}$kindUrgencySeparator${entry.value.wire}',
      ],
    );
  }

  /// Whether this Client has ever asked the OS for permission.
  ///
  /// macOS reports "not enabled" both before the first prompt and after a
  /// refusal, so the ask is recorded locally to let Settings explain the
  /// difference without prompting again.
  bool get wasPermissionRequested => _preferences.getBool(permissionRequestedKey) ?? false;

  Future<void> markPermissionRequested() => _preferences.setBool(permissionRequestedKey, true);

  /// Reads the stored `kind:urgency` entries, dropping a malformed one instead
  /// of failing the whole read: a corrupt file must not silence every kind.
  Map<String, String> _readUrgencyTokens() {
    final stored = _preferences.getStringList(kindUrgencyKey) ?? const <String>[];
    final tokens = <String, String>{};
    for (final entry in stored) {
      final separator = entry.indexOf(kindUrgencySeparator);
      if (separator <= 0 || separator == entry.length - 1) continue;
      tokens[entry.substring(0, separator)] = entry.substring(separator + 1);
    }
    return tokens;
  }
}
