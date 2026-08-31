import 'package:sanad_client/features/devices/domain/device_preferences_repository.dart';

class FakeDevicePreferencesRepository implements IDevicePreferencesRepository {
  final Map<String, String> _providers = {};
  final Map<String, String> _models = {};
  final Map<String, String> _thinkingModes = {};

  @override
  Future<void> setLastProvider(String deviceId, String providerId) async {
    _providers[deviceId] = providerId;
  }

  @override
  String? getLastProvider(String deviceId) {
    return _providers[deviceId];
  }

  @override
  Future<void> setLastModel(String deviceId, String model) async {
    _models[deviceId] = model;
  }

  @override
  String? getLastModel(String deviceId) {
    return _models[deviceId];
  }

  @override
  Future<void> setLastThinkingMode(String deviceId, String thinkingMode) async {
    _thinkingModes[deviceId] = thinkingMode;
  }

  @override
  String? getLastThinkingMode(String deviceId) {
    return _thinkingModes[deviceId];
  }

  @override
  Future<void> clearLastThinkingMode(String deviceId) async {
    _thinkingModes.remove(deviceId);
  }

  @override
  Future<void> clearPreferences(String deviceId) async {
    _providers.remove(deviceId);
    _models.remove(deviceId);
    _thinkingModes.remove(deviceId);
  }
}
