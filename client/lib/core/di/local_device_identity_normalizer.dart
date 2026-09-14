import 'package:shared_preferences/shared_preferences.dart';
import 'package:sanad_client/features/conversations/data/persistence/shared_preferences_conversation_cache_persistence.dart';
import 'package:sanad_client/features/devices/data/device_manager.dart';
import 'package:sanad_client/features/devices/data/device_preferences_repository_impl.dart';

/// Removes the former synthetic desktop row id from Client-owned state.
///
/// This compatibility boundary is idempotent and never touches Agent or
/// Backend persistence. Runtime code must not consume [legacyDeviceId].
class LocalDeviceIdentityNormalizer {
  static const legacyDeviceId = 'local-agent';

  const LocalDeviceIdentityNormalizer._();

  static Future<void> normalize(
    SharedPreferences preferences,
    String hardwareId,
  ) async {
    if (hardwareId.isEmpty || hardwareId == legacyDeviceId) return;

    final conversationPersistence = SharedPreferencesConversationCachePersistence(preferences);
    await conversationPersistence.normalizeDeviceId(
      legacyDeviceId,
      hardwareId,
    );
    await DevicePreferencesRepositoryImpl(
      preferences,
    ).normalizeDeviceId(legacyDeviceId, hardwareId);
    await DeviceManager.normalizeActiveDeviceId(
      preferences,
      legacyDeviceId,
      hardwareId,
    );
  }
}
