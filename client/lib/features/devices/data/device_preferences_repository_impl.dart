import 'package:shared_preferences/shared_preferences.dart';
import '../domain/device_preferences_repository.dart';

class DevicePreferencesRepositoryImpl implements IDevicePreferencesRepository {
  final SharedPreferences _prefs;

  DevicePreferencesRepositoryImpl(this._prefs);

  static String _providerKey(String deviceId) => 'agent_route_${deviceId}_provider';
  static String _modelKey(String deviceId) => 'agent_route_${deviceId}_model';
  static String _thinkingKey(String deviceId) => 'agent_pref_aasd11sdfsdf${deviceId}_thinking';

  @override
  Future<void> setLastProvider(String deviceId, String providerId) async {
    await _prefs.setString(_providerKey(deviceId), providerId);
  }

  @override
  String? getLastProvider(String deviceId) {
    return _prefs.getString(_providerKey(deviceId));
  }

  @override
  Future<void> setLastModel(String deviceId, String model) async {
    await _prefs.setString(_modelKey(deviceId), model);
  }

  @override
  String? getLastModel(String deviceId) {
    return _prefs.getString(_modelKey(deviceId));
  }

  @override
  Future<void> setLastThinkingMode(String deviceId, String thinkingMode) async {
    await _prefs.setString(_thinkingKey(deviceId), thinkingMode);
  }

  @override
  String? getLastThinkingMode(String deviceId) {
    return _prefs.getString(_thinkingKey(deviceId));
  }

  @override
  Future<void> clearLastThinkingMode(String deviceId) async {
    await _prefs.remove(_thinkingKey(deviceId));
  }

  @override
  Future<void> clearPreferences(String deviceId) async {
    await _prefs.remove(_providerKey(deviceId));
    await _prefs.remove(_modelKey(deviceId));
    await _prefs.remove(_thinkingKey(deviceId));
  }
}
