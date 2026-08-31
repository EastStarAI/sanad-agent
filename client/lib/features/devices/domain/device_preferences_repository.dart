abstract class IDevicePreferencesRepository {
  Future<void> setLastProvider(String deviceId, String providerId);
  String? getLastProvider(String deviceId);

  Future<void> setLastModel(String deviceId, String model);
  String? getLastModel(String deviceId);

  Future<void> setLastThinkingMode(String deviceId, String thinkingMode);
  String? getLastThinkingMode(String deviceId);
  Future<void> clearLastThinkingMode(String deviceId);

  Future<void> clearPreferences(String deviceId);
}
