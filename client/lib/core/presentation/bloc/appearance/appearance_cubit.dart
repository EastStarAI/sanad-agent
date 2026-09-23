import 'dart:async';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:sanad_client/features/devices/data/device_connection_coordinator.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'appearance_state.dart';

class AppearanceCubit extends Cubit<AppearanceState> {
  static const String _themeStyleKey = 'appearance_theme_style';
  static const String _primaryColorKey = 'appearance_primary_color';
  static const String _fontFamilyKey = 'appearance_font_family';
  static const String _fontSizeScaleKey = 'appearance_font_size_scale';
  static const String _backgroundOptionKey = 'appearance_background_option';

  String? _activeDeviceId;
  DeviceConfig? _activeAgent;
  DeviceConnectionCoordinator? _connectionCoordinator;
  StreamSubscription? _socketEventSubscription;

  AppearanceCubit(super.initialState, {DeviceConnectionCoordinator? connectionCoordinator})
      : _connectionCoordinator = connectionCoordinator;

  String? get activeDeviceId => _activeDeviceId;
  DeviceConfig? get activeAgent => _activeAgent;

  void bindConnectionCoordinator(DeviceConnectionCoordinator coordinator) {
    _connectionCoordinator = coordinator;
  }

  static String _key(String prefix, String? deviceId) =>
      deviceId != null && deviceId.isNotEmpty ? '${prefix}_$deviceId' : prefix;

  Future<void> setActiveAgent(DeviceConfig agent, {Map<String, dynamic>? remoteAppearance}) async {
    _activeDeviceId = agent.id;
    _activeAgent = agent;

    if (remoteAppearance != null && remoteAppearance.isNotEmpty) {
      final remoteState = AppearanceState.fromJson(remoteAppearance);
      await _persistStateLocally(remoteState, deviceId: agent.id);
      emit(remoteState);
      return;
    }

    // Load from device-scoped local cache, falling back to default appearance
    final cached = await getSavedAppearance(deviceId: agent.id);
    emit(cached);

    // In background, fetch fresh appearance from agent
    unawaited(_fetchAppearanceFromAgent(agent));
  }

  Future<void> onCapabilitiesReceived(String deviceId, Map<String, dynamic>? remoteAppearance) async {
    if (remoteAppearance == null || remoteAppearance.isEmpty) return;
    if (_activeDeviceId != deviceId) return;

    final remoteState = AppearanceState.fromJson(remoteAppearance);
    if (remoteState != state) {
      await _persistStateLocally(remoteState, deviceId: deviceId);
      emit(remoteState);
    }
  }

  Future<void> updateThemeStyle(AppThemeStyle style) async {
    final updated = state.copyWith(themeStyle: style);
    await _applyAndSync(updated);
  }

  Future<void> updatePrimaryColor(AppPrimaryColor color) async {
    final updated = state.copyWith(primaryColor: color);
    await _applyAndSync(updated);
  }

  Future<void> updateFontFamily(AppFontFamily family) async {
    final updated = state.copyWith(fontFamily: family);
    await _applyAndSync(updated);
  }

  Future<void> updateFontSizeScale(AppFontSizeScale scale) async {
    final updated = state.copyWith(fontSizeScale: scale);
    await _applyAndSync(updated);
  }

  Future<void> updateBackgroundOption(AppBackgroundOption option) async {
    final updated = state.copyWith(backgroundOption: option);
    await _applyAndSync(updated);
  }

  Future<void> importAppearance(Map<String, dynamic> json) async {
    final imported = AppearanceState.fromJson(json);
    await _applyAndSync(imported);
  }

  Future<void> _applyAndSync(AppearanceState nextState) async {
    await _persistStateLocally(nextState, deviceId: _activeDeviceId);
    emit(nextState);
    final agent = _activeAgent;
    if (agent != null) {
      unawaited(_syncAppearanceToAgent(agent, nextState));
    }
  }

  Future<void> _persistStateLocally(AppearanceState appearance, {String? deviceId}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key(_themeStyleKey, deviceId), appearance.themeStyle.id);
    await prefs.setString(_key(_primaryColorKey, deviceId), appearance.primaryColor.id);
    await prefs.setString(_key(_fontFamilyKey, deviceId), appearance.fontFamily.id);
    await prefs.setString(_key(_fontSizeScaleKey, deviceId), appearance.fontSizeScale.id);
    await prefs.setString(_key(_backgroundOptionKey, deviceId), appearance.backgroundOption.id);
    await prefs.setInt('theme_mode', appearance.themeStyle.themeMode.index);

    // Also persist to global keys for backward compatibility
    if (deviceId != null) {
      await prefs.setString(_themeStyleKey, appearance.themeStyle.id);
      await prefs.setString(_primaryColorKey, appearance.primaryColor.id);
      await prefs.setString(_fontFamilyKey, appearance.fontFamily.id);
      await prefs.setString(_fontSizeScaleKey, appearance.fontSizeScale.id);
      await prefs.setString(_backgroundOptionKey, appearance.backgroundOption.id);
    }
  }

  Future<void> _syncAppearanceToAgent(DeviceConfig agent, AppearanceState appearance) async {
    final coordinator = _connectionCoordinator;
    if (coordinator == null) return;
    try {
      final endpoint = await coordinator.ensureConnectedEndpointForAgent(agent);
      if (endpoint.socketService.isConnected) {
        endpoint.socketService.emit('execute_command', {
          'command': 'update_appearance',
          'device_id': endpoint.protocolDeviceId,
          'payload': {
            'appearance': appearance.toJson(),
          },
        });
      }
    } catch (_) {
      // Best-effort remote synchronization
    }
  }

  Future<void> _fetchAppearanceFromAgent(DeviceConfig agent) async {
    final coordinator = _connectionCoordinator;
    if (coordinator == null) return;
    try {
      final endpoint = await coordinator.ensureConnectedEndpointForAgent(agent);
      if (endpoint.socketService.isConnected) {
        endpoint.socketService.emit('execute_command', {
          'command': 'get_appearance',
          'device_id': endpoint.protocolDeviceId,
          'payload': {},
        });
      }
    } catch (_) {
      // Best-effort remote fetch
    }
  }

  static Future<AppearanceState> getSavedAppearance({String? deviceId}) async {
    final prefs = await SharedPreferences.getInstance();
    final themeStyleId = prefs.getString(_key(_themeStyleKey, deviceId)) ??
        (deviceId != null ? prefs.getString(_themeStyleKey) : null);
    final primaryColorId = prefs.getString(_key(_primaryColorKey, deviceId)) ??
        (deviceId != null ? prefs.getString(_primaryColorKey) : null);
    final fontFamilyId = prefs.getString(_key(_fontFamilyKey, deviceId)) ??
        (deviceId != null ? prefs.getString(_fontFamilyKey) : null);
    final fontSizeScaleId = prefs.getString(_key(_fontSizeScaleKey, deviceId)) ??
        (deviceId != null ? prefs.getString(_fontSizeScaleKey) : null);
    final backgroundOptionId = prefs.getString(_key(_backgroundOptionKey, deviceId)) ??
        (deviceId != null ? prefs.getString(_backgroundOptionKey) : null);

    AppThemeStyle style;
    if (themeStyleId != null) {
      style = AppThemeStyle.fromId(themeStyleId);
    } else {
      final legacyThemeIndex = prefs.getInt('theme_mode');
      if (legacyThemeIndex == 1) {
        style = AppThemeStyle.light;
      } else {
        style = AppThemeStyle.dark;
      }
    }

    return AppearanceState(
      themeStyle: style,
      primaryColor: AppPrimaryColor.fromId(primaryColorId),
      fontFamily: AppFontFamily.fromId(fontFamilyId),
      fontSizeScale: AppFontSizeScale.fromId(fontSizeScaleId),
      backgroundOption: AppBackgroundOption.fromId(backgroundOptionId),
    );
  }

  @override
  Future<void> close() async {
    await _socketEventSubscription?.cancel();
    return super.close();
  }
}
