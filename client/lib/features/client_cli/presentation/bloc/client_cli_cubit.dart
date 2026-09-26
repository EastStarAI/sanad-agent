import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/client_cli_host.dart';
import '../../domain/models/client_cli_settings.dart';

class ClientCliCubit extends Cubit<ClientCliSettings> {
  final ClientCliHost _host;
  final SharedPreferences _prefs;

  static const String keyEnabled = 'client_cli_enabled';
  static const String keyPermissionMode = 'client_cli_permission_mode';

  ClientCliCubit({
    required ClientCliHost host,
    required SharedPreferences prefs,
  })  : _host = host,
        _prefs = prefs,
        super(const ClientCliSettings());

  Future<void> load() async {
    final enabled = _prefs.getBool(keyEnabled) ?? false;
    final mode = _prefs.getString(keyPermissionMode) ?? ClientCliSettings.defaultMode;
    emit(ClientCliSettings(enabled: enabled, permissionMode: mode));
    await _host.updateSettings(enabled: enabled, permissionMode: mode);
  }

  Future<void> setEnabled(bool enabled) async {
    await _prefs.setBool(keyEnabled, enabled);
    emit(state.copyWith(enabled: enabled));
    await _host.updateSettings(
      enabled: enabled,
      permissionMode: state.permissionMode,
    );
  }

  Future<void> setPermissionMode(String permissionMode) async {
    await _prefs.setString(keyPermissionMode, permissionMode);
    emit(state.copyWith(permissionMode: permissionMode));
    await _host.updateSettings(
      enabled: state.enabled,
      permissionMode: permissionMode,
    );
  }

  Future<void> onLogout() async {
    await _host.stop();
  }

  @override
  Future<void> close() async {
    await _host.stop();
    return super.close();
  }
}
