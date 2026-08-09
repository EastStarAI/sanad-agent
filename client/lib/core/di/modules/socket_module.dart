import 'package:sanad_client/core/config/app_config.dart';
import 'package:sanad_client/infrastructure/local_tools/sanad_settings_store.dart';
import 'package:sanad_client/infrastructure/socket/sanad_socket_service.dart';
import 'package:sanad_client/utils/app_platform.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'package:sanad_client/infrastructure/local_gateway/local_gateway_credential_provider.dart';

class SocketModule {
  static const _hardwareIdKey = 'hardware_id';

  Future<String> hardwareId(SharedPreferences prefs) async {
    if (AppPlatform.isDesktop) {
      final settingsStore = const SanadSettingsStore();
      final authDoc = await settingsStore.readAuthDocument();
      final existing = authDoc[_hardwareIdKey]?.toString();

      if (existing != null && existing.isNotEmpty) {
        if (prefs.getString(_hardwareIdKey) != existing) {
          await prefs.setString(_hardwareIdKey, existing);
        }
        return existing;
      }

      final generated = const Uuid().v4();
      await _persistHardwareId(settingsStore, prefs, authDoc, generated);
      return generated;
    }

    final existing = prefs.getString(_hardwareIdKey);
    if (existing != null && existing.isNotEmpty) return existing;

    final generated = const Uuid().v4();
    await prefs.setString(_hardwareIdKey, generated);
    return generated;
  }

  Future<void> _persistHardwareId(
    SanadSettingsStore settingsStore,
    SharedPreferences prefs,
    Map<String, dynamic> authDoc,
    String hardwareId,
  ) async {
    final nextAuthDoc = Map<String, dynamic>.from(authDoc)..['hardware_id'] = hardwareId;

    await settingsStore.saveAuthDocument(nextAuthDoc);
    await prefs.setString(_hardwareIdKey, hardwareId);
  }

  SanadSocketService socketService({
    required String hardwareId,
    String? accessToken,
  }) {
    return SanadSocketService(
      url: AppConfig.backendUrl,
      hardwareId: hardwareId,
      startToken: accessToken,
    );
  }

  SanadSocketService localSocketService({
    required String hardwareId,
  }) {
    return SanadSocketService.local(
      url: AppConfig.localGatewayUrl,
      hardwareId: hardwareId,
      credentialProvider: const LocalGatewayCredentialProvider(),
      enabled: AppPlatform.isDesktop,
    );
  }
}
