import 'package:shared_preferences/shared_preferences.dart';

/// Persists application-level Home sidebar layout preferences.
class SidebarPreferences {
  static const String sidebarWidthKey = 'home_sidebar_width';

  final SharedPreferences _preferences;

  const SidebarPreferences(this._preferences);

  double? get sidebarWidth => _preferences.getDouble(sidebarWidthKey);

  Future<void> setSidebarWidth(double width) {
    return _preferences.setDouble(sidebarWidthKey, width);
  }
}
