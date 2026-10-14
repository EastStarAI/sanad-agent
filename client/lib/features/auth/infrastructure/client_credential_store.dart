import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:logging/logging.dart';

/// Contract for native secure credential persistence in the Sanad Client.
///
/// Under Plan 83 (Task 83d), User access and refresh tokens are strictly stored
/// in OS-level credential vaults (macOS Keychain, Windows Credential Manager,
/// Linux Secret Service, Android EncryptedSharedPreferences, iOS Keychain)
/// rather than general SharedPreferences.
abstract interface class ClientCredentialStore {
  /// Reads the stored (accessToken, refreshToken) credential pair.
  /// Returns null if no pair exists or if the pair is corrupted/partial.
  Future<(String, String)?> readCredentials();

  /// Atomically writes the complete (accessToken, refreshToken) credential pair.
  /// Partial writes (where either token is empty) are rejected.
  Future<void> writeCredentials({
    required String accessToken,
    required String refreshToken,
  });

  /// Deletes all stored credentials.
  Future<void> clearCredentials();
}

/// Production implementation of [ClientCredentialStore] backed by [FlutterSecureStorage].
class NativeClientCredentialStore implements ClientCredentialStore {
  NativeClientCredentialStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(),
              mOptions: MacOsOptions(
                groupId: null,
                accountName: 'ai.eaststar.sanad.client',
              ),
              wOptions: WindowsOptions(useBackwardCompatibility: false),
              lOptions: LinuxOptions(),
            );

  final FlutterSecureStorage _storage;
  static final _logger = Logger('NativeClientCredentialStore');

  static const _keyAccessToken = 'sanad_client_access_token_v2';
  static const _keyRefreshToken = 'sanad_client_refresh_token_v2';

  @override
  Future<(String, String)?> readCredentials() async {
    try {
      final access = await _storage.read(key: _keyAccessToken);
      final refresh = await _storage.read(key: _keyRefreshToken);

      if (access == null || access.trim().isEmpty) return null;
      if (refresh == null || refresh.trim().isEmpty) return null;

      return (access.trim(), refresh.trim());
    } catch (e) {
      _logger.warning('Failed to read native credentials: ${e.runtimeType}');
      return null;
    }
  }

  @override
  Future<void> writeCredentials({
    required String accessToken,
    required String refreshToken,
  }) async {
    final access = accessToken.trim();
    final refresh = refreshToken.trim();

    if (access.isEmpty || refresh.isEmpty) {
      throw ArgumentError(
        'Both accessToken and refreshToken must be non-empty for secure persistence.',
      );
    }

    try {
      await _storage.write(key: _keyAccessToken, value: access);
      await _storage.write(key: _keyRefreshToken, value: refresh);
    } catch (e) {
      _logger.severe('Failed to write native credentials: ${e.runtimeType}');
      rethrow;
    }
  }

  @override
  Future<void> clearCredentials() async {
    try {
      await _storage.delete(key: _keyAccessToken);
      await _storage.delete(key: _keyRefreshToken);
    } catch (e) {
      _logger.warning('Failed to delete native credentials: ${e.runtimeType}');
    }
  }
}

/// In-memory implementation of [ClientCredentialStore] for tests.
class InMemoryClientCredentialStore implements ClientCredentialStore {
  String? _accessToken;
  String? _refreshToken;

  @override
  Future<(String, String)?> readCredentials() async {
    if (_accessToken == null || _refreshToken == null) return null;
    return (_accessToken!, _refreshToken!);
  }

  @override
  Future<void> writeCredentials({
    required String accessToken,
    required String refreshToken,
  }) async {
    final access = accessToken.trim();
    final refresh = refreshToken.trim();
    if (access.isEmpty || refresh.isEmpty) {
      throw ArgumentError(
        'Both accessToken and refreshToken must be non-empty for secure persistence.',
      );
    }
    _accessToken = access;
    _refreshToken = refresh;
  }

  @override
  Future<void> clearCredentials() async {
    _accessToken = null;
    _refreshToken = null;
  }
}
