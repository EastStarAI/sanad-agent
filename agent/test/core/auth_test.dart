import 'dart:convert';
import 'dart:io';
import 'package:sanad_auth_lock/sanad_auth_lock.dart';
import 'package:test/test.dart';
import 'package:sanad_agent/core/auth/auth_manager.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:path/path.dart' as p;

import '../support/memory_agent_secret_store.dart';

class _BeforeAcquireAuthLock extends NativeAuthFileLock {
  _BeforeAcquireAuthLock(super.sanadHomePath);

  Future<void> Function()? beforeNextLock;

  @override
  Future<T> runExclusive<T>(Future<T> Function() operation) async {
    final beforeLock = beforeNextLock;
    beforeNextLock = null;
    await beforeLock?.call();
    return super.runExclusive(operation);
  }
}

void main() {
  late Directory tempDir;
  late AuthManager authManager;
  late MemoryAgentSecretStore secrets;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sanadagent_auth_test');
    setSanadHomeOverride(tempDir.path);
    secrets = MemoryAgentSecretStore();
    authManager = AuthManager(secretStore: secrets);
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
    setSanadHomeOverride(null);
  });

  group('AuthManager Tests', () {
    test('reads tokens from auth.json when initialized', () async {
      final authFile = File(p.join(tempDir.path, 'auth.json'));
      await authFile.writeAsString(
        jsonEncode({
          'access_token': 'test_access',
          'refresh_token': 'test_refresh',
          'hardware_id': 'test_hardware',
        }),
      );

      await authManager.initialize();

      expect(authManager.isAuthenticated, isTrue);
      expect(authManager.canAuthenticateCloudAgent, isFalse);
      expect(authManager.accessToken, equals('test_access'));
      expect(authManager.refreshToken, equals('test_refresh'));
      expect(authManager.hardwareId, equals('test_hardware'));
    });

    test(
      'migrates a legacy Device Credential only after vault verification',
      () async {
        final authFile = File(p.join(tempDir.path, 'auth.json'));
        await authFile.writeAsString(
          jsonEncode({
            'device_token': 'legacy-device-credential',
            'hardware_id': 'test_hardware',
          }),
        );

        await authManager.initialize();

        expect(authManager.deviceToken, 'legacy-device-credential');
        expect(authManager.canAuthenticateCloudAgent, isTrue);
        expect(
          secrets.values[AuthManager.deviceCredentialKey],
          'legacy-device-credential',
        );
        expect(
          await authFile.readAsString(),
          isNot(contains('legacy-device-credential')),
        );
      },
    );

    test(
      'starts fail-closed and keeps legacy credential when vault is unavailable',
      () async {
        final authFile = File(p.join(tempDir.path, 'auth.json'));
        await authFile.writeAsString(
          jsonEncode({
            'device_token': 'legacy-device-credential',
            'hardware_id': 'stable-hardware',
          }),
        );
        secrets.available = false;

        await authManager.initialize();

        expect(
          await authFile.readAsString(),
          contains('legacy-device-credential'),
        );
        expect(authManager.deviceToken, isNull);
        expect(authManager.canAuthenticateCloudAgent, isFalse);
      },
    );

    test('handles missing auth.json gracefully', () async {
      await authManager.initialize();
      expect(authManager.isAuthenticated, isFalse);
      expect(authManager.accessToken, isNull);
    });

    test('handles malformed JSON in auth.json', () async {
      final authFile = File(p.join(tempDir.path, 'auth.json'));
      await authFile.writeAsString('not-json');

      await authManager.initialize();
      expect(authManager.isAuthenticated, isFalse);
    });

    test(
      'pairing replaces the visible token with an agent-owned token',
      () async {
        await authManager.initialize();
        await authManager.prepareDevicePairing('sanad_visible_pairing_token');

        expect(authManager.hasPendingDevicePairing, isTrue);
        expect(authManager.pairingToken, equals('sanad_visible_pairing_token'));
        expect(authManager.pendingDeviceToken, startsWith('sanad_'));
        expect(
          authManager.pendingDeviceToken,
          isNot(equals(authManager.pairingToken)),
        );
        expect(authManager.deviceToken, isNull);

        final proposed = authManager.pendingDeviceToken;
        expect(await authManager.completeDevicePairing(), isTrue);
        expect(authManager.hasPendingDevicePairing, isFalse);
        expect(authManager.deviceToken, equals(proposed));

        final authFile = File(p.join(tempDir.path, 'auth.json'));
        final data =
            jsonDecode(await authFile.readAsString()) as Map<String, dynamic>;
        expect(data.containsKey('device_token'), isFalse);
        expect(
          secrets.values[AuthManager.deviceCredentialKey],
          equals(proposed),
        );
        expect(data.containsKey('pairing_token'), isFalse);
        expect(data.containsKey('pending_device_token'), isFalse);
      },
    );

    test(
      'cancelled pairing atomically restores the prior Device Credential',
      () async {
        await authManager.initialize();
        await authManager.saveDeviceToken('prior-device-credential');
        await authManager.prepareDevicePairing('replacement-pairing-authority');

        expect(authManager.deviceToken, isNull);
        expect(
          secrets.values[AuthManager.previousDeviceCredentialKey],
          'prior-device-credential',
        );
        expect(await authManager.cancelPreparedDevicePairing(), isTrue);
        expect(authManager.deviceToken, 'prior-device-credential');
        expect(authManager.hasPendingDevicePairing, isFalse);
        expect(
          secrets.values[AuthManager.deviceCredentialKey],
          'prior-device-credential',
        );
        expect(secrets.values[AuthManager.pendingDeviceCredentialKey], isNull);
        expect(secrets.values[AuthManager.pairingTokenKey], isNull);
        expect(secrets.values[AuthManager.previousDeviceCredentialKey], isNull);
      },
    );

    test(
      'pending pairing survives restart for retry after a lost response',
      () async {
        await authManager.initialize();
        await authManager.prepareDevicePairing('sanad_retry_pairing_token');
        final proposed = authManager.pendingDeviceToken;

        final authFile = File(p.join(tempDir.path, 'auth.json'));
        final persistedAuth = await authFile.readAsString();
        expect(persistedAuth, isNot(contains('sanad_retry_pairing_token')));
        expect(persistedAuth, isNot(contains(proposed!)));
        expect(
          secrets.values[AuthManager.pairingTokenKey],
          'sanad_retry_pairing_token',
        );

        final restored = AuthManager(secretStore: secrets);
        await restored.initialize();

        expect(restored.pairingToken, equals('sanad_retry_pairing_token'));
        expect(restored.pendingDeviceToken, equals(proposed));
        expect(restored.hasPendingDevicePairing, isTrue);
      },
    );

    test('external reload emits a credential-free change signal', () async {
      await authManager.initialize();
      final hardwareId = authManager.hardwareId;
      final authFile = File(p.join(tempDir.path, 'auth.json'));
      await authFile.writeAsString(
        jsonEncode({
          'access_token': 'external_access',
          'refresh_token': 'external_refresh',
          'hardware_id': hardwareId,
        }),
      );
      final changed = authManager.changes.first;

      expect(await authManager.reload(notifyIfChanged: true), isTrue);
      await changed;

      expect(authManager.accessToken, 'external_access');
      expect(authManager.refreshToken, 'external_refresh');
    });

    test(
      'adopts credentials rotated while waiting for the process lock',
      () async {
        final authFile = File(p.join(tempDir.path, 'auth.json'));
        await authFile.writeAsString(
          jsonEncode({
            'access_token': 'old_access',
            'refresh_token': 'old_refresh',
            'hardware_id': 'test_hardware',
          }),
        );
        final lock = _BeforeAcquireAuthLock(tempDir.path);
        authManager = AuthManager(authFileLock: lock, secretStore: secrets);
        await authManager.initialize();
        lock.beforeNextLock = () async {
          await authFile.writeAsString(
            jsonEncode({
              'access_token': 'peer_access',
              'refresh_token': 'peer_refresh',
              'hardware_id': 'test_hardware',
            }),
            flush: true,
          );
        };

        final refreshed = await authManager.refreshAccessToken(
          'http://127.0.0.1:1',
        );

        expect(refreshed, isTrue);
        expect(authManager.accessToken, 'peer_access');
        expect(authManager.refreshToken, 'peer_refresh');
      },
    );

    test('logout clears tokens but preserves hardware_id', () async {
      final authFile = File(p.join(tempDir.path, 'auth.json'));
      await authFile.writeAsString(
        jsonEncode({
          'access_token': 'test',
          'refresh_token': 'test_refresh',
          'device_token': 'test_device',
          'pairing_token': 'test_pairing',
          'pending_device_token': 'test_pending',
          'hardware_id': 'test_hardware',
        }),
      );

      await authManager.initialize();
      expect(authManager.isAuthenticated, isTrue);

      await authManager.logout();
      expect(authManager.isAuthenticated, isFalse);
      expect(authManager.accessToken, isNull);
      expect(authManager.refreshToken, isNull);
      expect(authManager.deviceToken, isNull);
      expect(authManager.pairingToken, isNull);
      expect(authManager.pendingDeviceToken, isNull);

      expect(await authFile.exists(), isTrue);
      final content = await authFile.readAsString();
      final data = jsonDecode(content) as Map<String, dynamic>;
      expect(data['access_token'], isNull);
      expect(data['refresh_token'], isNull);
      expect(data['device_token'], isNull);
      expect(data['pairing_token'], isNull);
      expect(data['pending_device_token'], isNull);
      expect(data['hardware_id'], equals('test_hardware'));
      expect(data[AuthManager.pendingAgentLogoutKey], isNull);
      expect(secrets.values[AuthManager.deviceCredentialKey], isNull);
      expect(secrets.values[AuthManager.pendingDeviceCredentialKey], isNull);
    });

    test(
      'startup defers pending Agent logout while vault is unavailable',
      () async {
        final authFile = File(p.join(tempDir.path, 'auth.json'));
        await authFile.writeAsString(
          jsonEncode({
            'access_token': 'new-account-access',
            'hardware_id': 'stable-hardware',
            AuthManager.pendingAgentLogoutKey: true,
            'pairing_token': 'stale-pairing',
          }),
        );
        secrets.available = false;

        await authManager.initialize();

        final persisted =
            jsonDecode(await authFile.readAsString()) as Map<String, dynamic>;
        expect(persisted[AuthManager.pendingAgentLogoutKey], isTrue);
        expect(persisted['pairing_token'], 'stale-pairing');
        expect(authManager.accessToken, 'new-account-access');
        expect(authManager.pairingToken, isNull);
        expect(authManager.canAuthenticateCloudAgent, isFalse);

        secrets.available = true;
        await authManager.reload();
        final reconciled =
            jsonDecode(await authFile.readAsString()) as Map<String, dynamic>;
        expect(reconciled[AuthManager.pendingAgentLogoutKey], isNull);
        expect(reconciled['pairing_token'], isNull);
      },
    );

    test(
      'startup consumes pending Agent logout without erasing newer Client login',
      () async {
        final authFile = File(p.join(tempDir.path, 'auth.json'));
        await authFile.writeAsString(
          jsonEncode({
            'access_token': 'new-account-access',
            'refresh_token': 'new-account-refresh',
            'hardware_id': 'stable-hardware',
            AuthManager.pendingAgentLogoutKey: true,
            'pairing_token': 'stale-pairing',
          }),
        );
        secrets.values[AuthManager.deviceCredentialKey] =
            'old-account-device-credential';
        secrets.values[AuthManager.pendingDeviceCredentialKey] =
            'old-account-pending-credential';

        await authManager.initialize();

        expect(authManager.accessToken, 'new-account-access');
        expect(authManager.refreshToken, 'new-account-refresh');
        expect(authManager.hardwareId, 'stable-hardware');
        expect(authManager.deviceToken, isNull);
        expect(authManager.pairingToken, isNull);
        expect(authManager.pendingDeviceToken, isNull);
        expect(authManager.canAuthenticateCloudAgent, isFalse);
        expect(secrets.values, isEmpty);

        final persisted =
            jsonDecode(await authFile.readAsString()) as Map<String, dynamic>;
        expect(persisted['access_token'], isNull);
        expect(persisted['refresh_token'], isNull);
        expect(persisted['hardware_id'], 'stable-hardware');
        expect(persisted[AuthManager.pendingAgentLogoutKey], isNull);
        expect(persisted['pairing_token'], isNull);
      },
    );

    test(
      'writes auth.json with owner-only permissions on Unix-like systems',
      () async {
        await authManager.saveUserTokens('test_access', 'test_refresh');

        final authFile = File(p.join(tempDir.path, 'auth.json'));
        expect(await authFile.exists(), isTrue);

        if (!Platform.isWindows) {
          final mode = (await authFile.stat()).mode & 0x1ff;
          expect(mode, equals(0x180)); // 0600
        }
      },
    );
  });
}
