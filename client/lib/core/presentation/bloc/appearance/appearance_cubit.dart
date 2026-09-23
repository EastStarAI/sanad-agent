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
  final List<StreamSubscription> _socketSubscriptions = [];

  AppearanceCubit(super.initialState, {DeviceConnectionCoordinator? connectionCoordinator})
      : _connectionCoordinator = connectionCoordinator {
    if (connectionCoordinator != null) {
      _listenToSocketEvents();
    }
  }

  String? get activeDeviceId => _activeDeviceId;
  DeviceConfig? get activeAgent => _activeAgent;

  void bindConnectionCoordinator(DeviceConnectionCoordinator coordinator) {
    _connectionCoordinator = coordinator;
    _listenToSocketEvents();
  }

  void _listenToSocketEvents() {
    for (final sub in _socketSubscriptions) {
      unawaited(sub.cancel());
    }
    _socketSubscriptions.clear();

    final coordinator = _connectionCoordinator;
    if (coordinator == null) return;

    for (final stream in coordinator.eventStreams) {
      _socketSubscriptions.add(stream.listen(_handleSocketEvent));
    }
  }

  void _handleSocketEvent(Map<String, dynamic> event) {
    final messageType = event['message_type'] ?? event['event'] ?? event['type'];
    if (messageType == 'appearance_snapshot' || messageType == 'appearance_updated') {
      final payload = event['payload'];
      if (payload is Map) {
        final rawAppearance = payload['appearance'] ?? payload;
        if (rawAppearance is Map) {
          final deviceId = event['device_id'] as String? ?? _activeDeviceId;
          if (deviceId != null && (_activeDeviceId == deviceId || _activeAgent?.representsDeviceId(deviceId) == true)) {
            final next = AppearanceState.fromJson(Map<String, dynamic>.from(rawAppearance));
            if (next != state) {
              unawaited(_persistStateLocally(next, deviceId: deviceId));
              emit(next);
            }
          }
        }
      }
    }
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
    final cached = await getSavedAppearance(
      deviceId: agent.id,
      fallbackDeviceId: agent.cloudDeviceId,
    );
    emit(cached);

    // In background, fetch fresh appearance from agent
    unawaited(_fetchAppearanceFromAgent(agent));
  }

  Future<void> onCapabilitiesReceived(String deviceId, Map<String, dynamic>? remoteAppearance) async {
    if (remoteAppearance == null || remoteAppearance.isEmpty) return;
    if (_activeDeviceId != deviceId && _activeAgent?.representsDeviceId(deviceId) != true) return;

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
    if (deviceId != null && deviceId.isNotEmpty) {
      await prefs.setString(_key(_themeStyleKey, deviceId), appearance.themeStyle.id);
      await prefs.setString(_key(_primaryColorKey, deviceId), appearance.primaryColor.id);
      await prefs.setString(_key(_fontFamilyKey, deviceId), appearance.fontFamily.id);
      await prefs.setString(_key(_fontSizeScaleKey, deviceId), appearance.fontSizeScale.id);
      await prefs.setString(_key(_backgroundOptionKey, deviceId), appearance.backgroundOption.id);

      final fallbackId = _activeAgent?.cloudDeviceId;
      if (fallbackId != null && fallbackId.isNotEmpty && fallbackId != deviceId) {
        await prefs.setString(_key(_themeStyleKey, fallbackId), appearance.themeStyle.id);
        await prefs.setString(_key(_primaryColorKey, fallbackId), appearance.primaryColor.id);
        await prefs.setString(_key(_fontFamilyKey, fallbackId), appearance.fontFamily.id);
        await prefs.setString(_key(_fontSizeScaleKey, fallbackId), appearance.fontSizeScale.id);
        await prefs.setString(_key(_backgroundOptionKey, fallbackId), appearance.backgroundOption.id);
      }
    } else {
      // Global fallback only (cold start before any device is selected)
      await prefs.setString(_themeStyleKey, appearance.themeStyle.id);
      await prefs.setString(_primaryColorKey, appearance.primaryColor.id);
      await prefs.setString(_fontFamilyKey, appearance.fontFamily.id);
      await prefs.setString(_fontSizeScaleKey, appearance.fontSizeScale.id);
      await prefs.setString(_backgroundOptionKey, appearance.backgroundOption.id);
      await prefs.setInt('theme_mode', appearance.themeStyle.themeMode.index);
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

  static Future<AppearanceState> getSavedAppearance({
    String? deviceId,
    String? fallbackDeviceId,
  }) async {
    final prefs = await SharedPreferences.getInstance();

    if (deviceId != null && deviceId.isNotEmpty) {
      String? themeStyleId = prefs.getString(_key(_themeStyleKey, deviceId));
      String? primaryColorId = prefs.getString(_key(_primaryColorKey, deviceId));
      String? fontFamilyId = prefs.getString(_key(_fontFamilyKey, deviceId));
      String? fontSizeScaleId = prefs.getString(_key(_fontSizeScaleKey, deviceId));
      String? backgroundOptionId = prefs.getString(_key(_backgroundOptionKey, deviceId));

      if (themeStyleId == null && fallbackDeviceId != null && fallbackDeviceId.isNotEmpty) {
        themeStyleId = prefs.getString(_key(_themeStyleKey, fallbackDeviceId));
        primaryColorId ??= prefs.getString(_key(_primaryColorKey, fallbackDeviceId));
        fontFamilyId ??= prefs.getString(_key(_fontFamilyKey, fallbackDeviceId));
        fontSizeScaleId ??= prefs.getString(_key(_fontSizeScaleKey, fallbackDeviceId));
        backgroundOptionId ??= prefs.getString(_key(_backgroundOptionKey, fallbackDeviceId));
      }

      // If this device has no saved preferences, strictly return initial defaults!
      // NEVER fall back to global keys or legacy theme_mode when querying a specific device.
      return AppearanceState(
        themeStyle: themeStyleId != null ? AppThemeStyle.fromId(themeStyleId) : AppThemeStyle.dark,
        primaryColor: AppPrimaryColor.fromId(primaryColorId),
        fontFamily: AppFontFamily.fromId(fontFamilyId),
        fontSizeScale: AppFontSizeScale.fromId(fontSizeScaleId),
        backgroundOption: AppBackgroundOption.fromId(backgroundOptionId),
      );
    }

    // Only if deviceId == null (app cold start before any device is selected)
    final themeStyleId = prefs.getString(_themeStyleKey);
    final primaryColorId = prefs.getString(_primaryColorKey);
    final fontFamilyId = prefs.getString(_fontFamilyKey);
    final fontSizeScaleId = prefs.getString(_fontSizeScaleKey);
    final backgroundOptionId = prefs.getString(_backgroundOptionKey);

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
    for (final sub in _socketSubscriptions) {
      await sub.cancel();
    }
    _socketSubscriptions.clear();
    return super.close();
  }
}
