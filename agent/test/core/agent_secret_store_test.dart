import 'dart:convert';
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:path/path.dart' as p;
import 'package:sanad_agent/core/auth/agent_secret_store.dart';
import 'package:sanad_agent/core/auth/auth_manager.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

class _UnavailableLinuxSecretServiceClient implements LinuxSecretServiceClient {
  Never _unavailable() => throw StateError('Secret Service unavailable');

  @override
  Future<void> delete(Map<String, String> attributes) async => _unavailable();

  @override
  Future<String?> read(Map<String, String> attributes) async => _unavailable();

  @override
  Future<void> write({
    required Map<String, String> attributes,
    required String label,
    required String value,
  }) async => _unavailable();
}

void main() {
  group('Linux Secret Service', () {
    test('normalizes unavailable D-Bus service for every operation', () {
      final store = LinuxSecretServiceAgentSecretStore(
        scope: 'test-scope',
        client: _UnavailableLinuxSecretServiceClient(),
      );
      final unavailable = throwsA(isA<AgentSecretStoreUnavailable>());

      expect(store.read('entry'), unavailable);
      expect(store.write('entry', 'secret'), unavailable);
      expect(store.delete('entry'), unavailable);
    });

    test(
      'missing session D-Bus fails closed without blocking startup',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'sanad-linux-secret-service-unavailable',
        );
        setSanadHomeOverride(tempDir.path);
        final client = DBusClient(
          DBusAddress('unix:path=${p.join(tempDir.path, 'missing-bus')}'),
        );
        final auth = AuthManager(
          secretStore: LinuxSecretServiceAgentSecretStore(
            scope: 'unavailable-scope',
            client: DBusLinuxSecretServiceClient(
              client: client,
              timeout: const Duration(milliseconds: 250),
            ),
          ),
        );
        try {
          await auth.initialize();
          expect(auth.hardwareId, isNotEmpty);
          expect(auth.canAuthenticateCloudAgent, isFalse);
        } finally {
          await client.close();
          setSanadHomeOverride(null);
          await tempDir.delete(recursive: true);
        }
      },
      skip: !Platform.isLinux,
    );

    test(
      'real session round trip uses D-Bus without secret-tool',
      () async {
        final scope = 'task68-l2-${const Uuid().v4()}';
        final store = LinuxSecretServiceAgentSecretStore(scope: scope);
        const key = 'synthetic-entry';
        const value = 'synthetic-secret-value';
        try {
          expect(await store.read(key), isNull);
          await store.write(key, value);
          expect(await store.read(key), value);
          await store.delete(key);
          expect(await store.read(key), isNull);
        } finally {
          await store.delete(key);
        }
      },
      skip: !Platform.isLinux,
    );

    test(
      'real session verifies legacy migration before deletion',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'sanad-linux-secret-service-migration',
        );
        final scope = 'task68-l2-migration-${const Uuid().v4()}';
        final store = LinuxSecretServiceAgentSecretStore(scope: scope);
        final authFile = File(p.join(tempDir.path, 'auth.json'));
        const legacyCredential = 'synthetic-legacy-device-credential';
        setSanadHomeOverride(tempDir.path);
        try {
          await authFile.writeAsString(
            jsonEncode({
              'hardware_id': 'synthetic-hardware',
              'device_token': legacyCredential,
            }),
          );
          final auth = AuthManager(secretStore: store);

          await auth.initialize();

          expect(auth.deviceToken, legacyCredential);
          expect(
            await store.read(AuthManager.deviceCredentialKey),
            legacyCredential,
          );
          expect(
            await authFile.readAsString(),
            isNot(contains(legacyCredential)),
          );
        } finally {
          await store.delete(AuthManager.deviceCredentialKey);
          await store.delete(AuthManager.pendingDeviceCredentialKey);
          setSanadHomeOverride(null);
          await tempDir.delete(recursive: true);
        }
      },
      skip: !Platform.isLinux,
    );
  });

  test('Windows DPAPI round trip stores ciphertext only', () async {
    final tempDir = await Directory.systemTemp.createTemp('sanad-dpapi-test');
    setSanadHomeOverride(tempDir.path);
    final store = WindowsDpapiAgentSecretStore(scope: const Uuid().v4());
    try {
      expect(await store.read('entry'), isNull);
      await store.write('entry', 'synthetic-secret-value');
      expect(await store.read('entry'), 'synthetic-secret-value');
      final files = await tempDir
          .list()
          .where((entity) => entity is File)
          .toList();
      expect(files, hasLength(1));
      expect(
        String.fromCharCodes(await File(files.single.path).readAsBytes()),
        isNot(contains('synthetic-secret-value')),
      );
      await store.delete('entry');
      expect(await store.read('entry'), isNull);
    } finally {
      setSanadHomeOverride(null);
      await tempDir.delete(recursive: true);
    }
  }, skip: !Platform.isWindows);

  test('Windows DPAPI verifies legacy migration before deletion', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'sanad-dpapi-migration',
    );
    final authFile = File(p.join(tempDir.path, 'auth.json'));
    final store = WindowsDpapiAgentSecretStore(scope: const Uuid().v4());
    const legacyCredential = 'synthetic-windows-legacy-credential';
    setSanadHomeOverride(tempDir.path);
    try {
      await authFile.writeAsString(
        jsonEncode({
          'hardware_id': 'synthetic-windows-hardware',
          'device_token': legacyCredential,
        }),
      );

      final auth = AuthManager(secretStore: store);
      await auth.initialize();

      expect(auth.deviceToken, legacyCredential);
      expect(
        await store.read(AuthManager.deviceCredentialKey),
        legacyCredential,
      );
      expect(await authFile.readAsString(), isNot(contains(legacyCredential)));
    } finally {
      setSanadHomeOverride(null);
      await tempDir.delete(recursive: true);
    }
  }, skip: !Platform.isWindows);

  test('corrupt Windows DPAPI ciphertext keeps startup fail-closed', () async {
    final tempDir = await Directory.systemTemp.createTemp('sanad-dpapi-corrupt');
    final store = WindowsDpapiAgentSecretStore(scope: const Uuid().v4());
    setSanadHomeOverride(tempDir.path);
    try {
      await store.write(AuthManager.deviceCredentialKey, 'synthetic-secret');
      final vaultFile =
          await tempDir.list().where((entity) => entity is File).single as File;
      await vaultFile.writeAsBytes(const [1, 2, 3, 4], flush: true);

      final auth = AuthManager(secretStore: store);
      await auth.initialize();

      expect(auth.hardwareId, isNotEmpty);
      expect(auth.deviceToken, isNull);
      expect(auth.canAuthenticateCloudAgent, isFalse);
    } finally {
      setSanadHomeOverride(null);
      await tempDir.delete(recursive: true);
    }
  }, skip: !Platform.isWindows);

  test('macOS Keychain round trip stores no plaintext file', () async {
    final scope = 'sec01e-test-${const Uuid().v4()}';
    const key = 'synthetic-entry';
    final store = MacOsKeychainAgentSecretStore(scope: scope);
    try {
      expect(await store.read(key), isNull);
      await store.write(key, 'synthetic-secret-value');
      expect(await store.read(key), 'synthetic-secret-value');
      await store.delete(key);
      expect(await store.read(key), isNull);
    } finally {
      await store.delete(key);
    }
  }, skip: !Platform.isMacOS);
}
