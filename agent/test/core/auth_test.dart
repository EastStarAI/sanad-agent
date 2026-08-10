import 'dart:convert';
import 'dart:io';
import 'package:sanad_auth_lock/sanad_auth_lock.dart';
import 'package:test/test.dart';
import 'package:sanad_agent/core/auth/auth_manager.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:path/path.dart' as p;

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

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sanadagent_auth_test');
    setSanadHomeOverride(tempDir.path);
    authManager = AuthManager();
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
      expect(authManager.accessToken, equals('test_access'));
      expect(authManager.refreshToken, equals('test_refresh'));
      expect(authManager.hardwareId, equals('test_hardware'));
    });

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
        expect(data['device_token'], equals(proposed));
        expect(data.containsKey('pairing_token'), isFalse);
        expect(data.containsKey('pending_device_token'), isFalse);
      },
    );

    test(
      'pending pairing survives restart for retry after a lost response',
      () async {
        await authManager.initialize();
        await authManager.prepareDevicePairing('sanad_retry_pairing_token');
        final proposed = authManager.pendingDeviceToken;

        final restored = AuthManager();
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
        authManager = AuthManager(authFileLock: lock);
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
    });

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
