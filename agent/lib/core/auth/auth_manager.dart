import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:sanad_auth_lock/sanad_auth_lock.dart';
import 'package:uuid/uuid.dart';

import '../sanad_home/sanad_home_bootstrap.dart';
import 'agent_secret_store.dart';

class AuthManager {
  AuthManager({NativeAuthFileLock? authFileLock, AgentSecretStore? secretStore})
    : _authFileLock = authFileLock,
      _secretStore = secretStore ?? createAgentSecretStore();

  static const deviceCredentialKey = 'device_credential';
  static const pendingDeviceCredentialKey = 'pending_device_credential';

  final _logger = Logger('AuthManager');
  final NativeAuthFileLock? _authFileLock;
  final AgentSecretStore _secretStore;
  String? _accessToken;
  String? _refreshToken;
  String? _hardwareId;
  String? _deviceToken;
  String? _pairingToken;
  String? _pendingDeviceToken;
  final _changesController = StreamController<void>.broadcast();

  Stream<void> get changes => _changesController.stream;
  String? get accessToken => _accessToken;
  String? get hardwareId => _hardwareId;
  String? get refreshToken => _refreshToken;
  String? get deviceToken => _deviceToken;
  String? get pairingToken => _pairingToken;
  String? get pendingDeviceToken => _pendingDeviceToken;
  bool get hasPendingDevicePairing =>
      _pairingToken != null && _pendingDeviceToken != null;

  Future<void> initialize() async {
    await _withAuthFileLock(() async {
      await _reloadUnlocked();
      if (_hardwareId == null || _hardwareId!.isEmpty) {
        _hardwareId = const Uuid().v4();
        await _saveAuthUnlocked(notify: false);
      }
    });
  }

  /// Reloads the shared auth document. When [notifyIfChanged] is true, a
  /// credential-free change signal is emitted only after memory differs from
  /// the last loaded state.
  Future<bool> reload({bool notifyIfChanged = false}) {
    return _withAuthFileLock(
      () => _reloadUnlocked(notifyIfChanged: notifyIfChanged),
    );
  }

  Future<bool> _reloadUnlocked({bool notifyIfChanged = false}) async {
    final before = _fingerprint;
    final boundary = SanadHomeBootstrap.identity();

    Map<String, dynamic>? data;
    if (boundary.fileExists('auth.json')) {
      try {
        final content = utf8.decode(boundary.readSecretBytes('auth.json'));
        if (content.trim().isNotEmpty) {
          data = jsonDecode(content) as Map<String, dynamic>;
          _accessToken = data['access_token'];
          _refreshToken = data['refresh_token'];
          _hardwareId = data['hardware_id'];
          _pairingToken = data['pairing_token'];
        }
      } catch (_) {
        // A malformed or temporarily unavailable file cannot authorize a
        // state transition. Keep the last valid in-memory snapshot.
      }
    }

    var storedCredential = await _secretStore.read(deviceCredentialKey);
    final legacyCredential = data?['device_token'] as String?;
    if (storedCredential == null && legacyCredential != null) {
      await _secretStore.write(deviceCredentialKey, legacyCredential);
      storedCredential = await _secretStore.read(deviceCredentialKey);
      if (storedCredential != legacyCredential) {
        throw const AgentSecretStoreUnavailable(
          'Device Credential migration verification failed.',
        );
      }
    }
    _deviceToken = storedCredential;

    var pendingCredential = await _secretStore.read(pendingDeviceCredentialKey);
    final legacyPendingCredential = data?['pending_device_token'] as String?;
    if (pendingCredential == null && legacyPendingCredential != null) {
      await _secretStore.write(
        pendingDeviceCredentialKey,
        legacyPendingCredential,
      );
      pendingCredential = await _secretStore.read(pendingDeviceCredentialKey);
      if (pendingCredential != legacyPendingCredential) {
        throw const AgentSecretStoreUnavailable(
          'Pending Device Credential migration verification failed.',
        );
      }
    }
    _pendingDeviceToken = pendingCredential;

    if (data != null &&
        (data.containsKey('device_token') ||
            data.containsKey('pending_device_token'))) {
      data.remove('device_token');
      data.remove('pending_device_token');
      await boundary.writeSecretBytes(
        'auth.json',
        utf8.encode(jsonEncode(data)),
      );
    }

    final changed = before != _fingerprint;
    if (changed && notifyIfChanged) _notifyChanged();
    return changed;
  }

  bool get isAuthenticated =>
      _accessToken != null || _deviceToken != null || hasPendingDevicePairing;

  Future<void> saveDeviceToken(String token) {
    return _withAuthFileLock(() async {
      await _reloadUnlocked();
      await _secretStore.write(deviceCredentialKey, token);
      if (await _secretStore.read(deviceCredentialKey) != token) {
        throw const AgentSecretStoreUnavailable(
          'Device Credential write verification failed.',
        );
      }
      await _secretStore.delete(pendingDeviceCredentialKey);
      _deviceToken = token;
      _pairingToken = null;
      _pendingDeviceToken = null;
      await _saveAuthUnlocked();
    });
  }

  Future<void> prepareDevicePairing(String pairingToken) {
    if (pairingToken.isEmpty) {
      throw ArgumentError.value(
        pairingToken,
        'pairingToken',
        'must not be empty',
      );
    }
    return _withAuthFileLock(() async {
      await _reloadUnlocked();
      final pendingCredential = _generateDeviceToken();
      await _secretStore.write(pendingDeviceCredentialKey, pendingCredential);
      if (await _secretStore.read(pendingDeviceCredentialKey) !=
          pendingCredential) {
        throw const AgentSecretStoreUnavailable(
          'Pending Device Credential write verification failed.',
        );
      }
      _pairingToken = pairingToken;
      _pendingDeviceToken = pendingCredential;
      _deviceToken = null;
      await _secretStore.delete(deviceCredentialKey);
      await _saveAuthUnlocked();
    });
  }

  Future<bool> completeDevicePairing() {
    return _withAuthFileLock(() async {
      await _reloadUnlocked();
      final pendingToken = _pendingDeviceToken;
      if (pendingToken == null || _pairingToken == null) return false;
      await _secretStore.write(deviceCredentialKey, pendingToken);
      if (await _secretStore.read(deviceCredentialKey) != pendingToken) {
        throw const AgentSecretStoreUnavailable(
          'Paired Device Credential write verification failed.',
        );
      }
      await _secretStore.delete(pendingDeviceCredentialKey);
      _deviceToken = pendingToken;
      _pairingToken = null;
      _pendingDeviceToken = null;
      await _saveAuthUnlocked();
      return true;
    });
  }

  Future<void> saveUserTokens(String accessToken, String refreshToken) {
    return _withAuthFileLock(() async {
      await _reloadUnlocked();
      _accessToken = accessToken;
      _refreshToken = refreshToken;
      await _saveAuthUnlocked();
    });
  }

  Future<bool> refreshAccessToken(String portalUrl) async {
    final accessBeforeLock = _accessToken;
    final refreshBeforeLock = _refreshToken;
    try {
      return await _withAuthFileLock(() async {
        await _reloadUnlocked(notifyIfChanged: true);
        final pairChangedWhileWaiting =
            _accessToken != accessBeforeLock ||
            _refreshToken != refreshBeforeLock;
        if (pairChangedWhileWaiting) {
          if (_accessToken != null && _refreshToken != null) {
            _logger.info(
              'Adopted credentials refreshed by another local process.',
            );
            return true;
          }
          _logger.warning('Authentication changed while waiting to refresh.');
          return false;
        }
        if (_refreshToken == null || _refreshToken!.isEmpty) {
          _logger.warning('Refresh token is null or empty');
          return false;
        }

        try {
          // Refresh goes through the portal only. The CLI/daemon must never
          // call backend auth endpoints directly.
          final url = Uri.parse('$portalUrl/auth/refresh');
          _logger.info('Calling portal refresh endpoint...');
          final response = await http
              .post(
                url,
                headers: {'Content-Type': 'application/json'},
                body: jsonEncode({'refresh_token': _refreshToken}),
              )
              .timeout(const Duration(seconds: 10));

          if (response.statusCode == 200) {
            final data = jsonDecode(response.body) as Map<String, dynamic>;
            _accessToken = data['access_token'];
            if (data.containsKey('refresh_token')) {
              _refreshToken = data['refresh_token'];
            }
            await _saveAuthUnlocked();
            _logger.info('Token refreshed and saved successfully.');
            return true;
          }
          _logger.warning('Refresh failed with status ${response.statusCode}.');
        } catch (error) {
          _logger.warning('Portal refresh unavailable: ${error.runtimeType}');
        }
        return false;
      });
    } on AuthFileLockTimeout {
      _logger.warning('Timed out waiting for another authentication mutation.');
      return false;
    } catch (error) {
      _logger.warning('Authentication lock unavailable: ${error.runtimeType}');
      return false;
    }
  }

  Future<void> _saveAuthUnlocked({bool notify = true}) async {
    final boundary = SanadHomeBootstrap.identity();
    final data = <String, dynamic>{};

    if (boundary.fileExists('auth.json')) {
      try {
        final content = utf8.decode(boundary.readSecretBytes('auth.json'));
        if (content.trim().isNotEmpty) {
          data.addAll(jsonDecode(content) as Map<String, dynamic>);
        }
      } catch (_) {}
    }

    data.remove('access_token');
    data.remove('refresh_token');
    data.remove('hardware_id');
    data.remove('device_token');
    data.remove('pairing_token');
    data.remove('pending_device_token');

    if (_accessToken != null) data['access_token'] = _accessToken;
    if (_refreshToken != null) data['refresh_token'] = _refreshToken;
    if (_hardwareId != null) data['hardware_id'] = _hardwareId;
    if (_pairingToken != null) data['pairing_token'] = _pairingToken;
    if (_pendingDeviceToken != null) {
      data['pending_device_token'] = _pendingDeviceToken;
    }

    await boundary.writeSecretBytes('auth.json', utf8.encode(jsonEncode(data)));
    if (notify) _notifyChanged();
  }

  /// Clears the shared native session under the cross-process auth lock.
  Future<void> logout() {
    return _withAuthFileLock(() async {
      await _reloadUnlocked();
      _accessToken = null;
      _refreshToken = null;
      _deviceToken = null;
      _pairingToken = null;
      _pendingDeviceToken = null;
      await _secretStore.delete(deviceCredentialKey);
      await _secretStore.delete(pendingDeviceCredentialKey);
      final boundary = SanadHomeBootstrap.identity();
      if (boundary.fileExists('auth.json')) {
        try {
          final content = utf8.decode(boundary.readSecretBytes('auth.json'));
          if (content.trim().isNotEmpty) {
            final data = jsonDecode(content) as Map<String, dynamic>;
            data.remove('access_token');
            data.remove('refresh_token');
            data.remove('device_token');
            data.remove('pairing_token');
            data.remove('pending_device_token');
            await boundary.writeSecretBytes(
              'auth.json',
              utf8.encode(jsonEncode(data)),
            );
          } else {
            await boundary.deleteFile('auth.json');
          }
        } catch (_) {
          await boundary.deleteFile('auth.json');
        }
      }
      _notifyChanged();
    });
  }

  Future<T> _withAuthFileLock<T>(Future<T> Function() operation) {
    final lock =
        _authFileLock ??
        NativeAuthFileLock(SanadHomeBootstrap.identity().canonicalRoot());
    return lock.runExclusive(operation);
  }

  String get _fingerprint => <String?>[
    _accessToken,
    _refreshToken,
    _hardwareId,
    _deviceToken,
    _pairingToken,
    _pendingDeviceToken,
  ].join('\u0000');

  void _notifyChanged() {
    if (!_changesController.isClosed) _changesController.add(null);
  }

  String _generateDeviceToken() {
    const alphabet =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
    final random = Random.secure();
    final value = List.generate(
      32,
      (_) => alphabet[random.nextInt(alphabet.length)],
    ).join();
    return 'sanad_$value';
  }
}
