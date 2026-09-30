import 'dart:convert';
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:path/path.dart' as p;
import 'package:sanad_agent/core/auth/agent_secret_store.dart';
import 'package:sanad_agent/core/auth/auth_manager.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

class _MemoryLinuxSecretServiceClient implements LinuxSecretServiceClient {
  bool available;
  final values = <String, String>{};
  int writes = 0;
  String? unverifiableEntry;

  _MemoryLinuxSecretServiceClient({this.available = true});

  String _key(Map<String, String> attributes) => attributes['entry']!;

  void _check() {
    if (!available) throw StateError('Secret Service unavailable');
  }

  @override
  Future<void> delete(Map<String, String> attributes) async {
    _check();
    values.remove(_key(attributes));
  }

  @override
  Future<String?> read(Map<String, String> attributes) async {
    _check();
    return values[_key(attributes)];
  }

  @override
  Future<void> write({
    required Map<String, String> attributes,
    required String label,
    required String value,
  }) async {
    _check();
    writes++;
    final key = _key(attributes);
    if (key != unverifiableEntry) values[key] = value;
  }
}

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
  final runRealLinuxSecretService =
      Platform.isLinux &&
      Platform.environment['SANAD_TEST_LINUX_SECRET_SERVICE_REAL'] == '1';

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

    test('real session round trip uses D-Bus without secret-tool', () async {
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
    }, skip: !runRealLinuxSecretService);

    test('real session verifies legacy migration before deletion', () async {
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
    }, skip: !runRealLinuxSecretService);
  });

  group('Linux owner-file backend selection', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('sanad-linux-owner-file');
      setSanadHomeOverride(tempDir.path);
    });

    tearDown(() async {
      setSanadHomeOverride(null);
      await tempDir.delete(recursive: true);
    });

    test('round trip is atomic and owner-only', () async {
      final store = LinuxOwnerFileAgentSecretStore();

      await store.write('entry', 'synthetic-secret');

      expect(await store.read('entry'), 'synthetic-secret');
      final dataFile = File(
        p.join(tempDir.path, LinuxOwnerFileAgentSecretStore.dataFileName),
      );
      final lockFile = File(
        p.join(tempDir.path, LinuxOwnerFileAgentSecretStore.lockFileName),
      );
      expect(await dataFile.exists(), isTrue);
      expect(await lockFile.exists(), isTrue);
      if (!Platform.isWindows) {
        expect((await dataFile.stat()).mode & 0x1ff, 0x180);
        expect((await lockFile.stat()).mode & 0x1ff, 0x180);
        expect((await tempDir.stat()).mode & 0x1ff, 0x1c0);
      }

      await store.delete('entry');
      expect(await store.read('entry'), isNull);
      expect(await dataFile.exists(), isFalse);
    });

    test('serializes concurrent record updates without lost keys', () async {
      final store = LinuxOwnerFileAgentSecretStore();

      await Future.wait(
        List.generate(
          12,
          (index) => store.write('entry-$index', 'value-$index'),
        ),
      );

      for (var index = 0; index < 12; index++) {
        expect(await store.read('entry-$index'), 'value-$index');
      }
    });

    test('rejects corrupt data without replacing it', () async {
      final dataFile = File(
        p.join(tempDir.path, LinuxOwnerFileAgentSecretStore.dataFileName),
      );
      await dataFile.writeAsString('{corrupt');
      final store = LinuxOwnerFileAgentSecretStore();

      await expectLater(
        store.write('entry', 'replacement'),
        throwsA(isA<AgentSecretStoreUnavailable>()),
      );
      expect(await dataFile.readAsString(), '{corrupt');
    });

    test('rejects a symlink credential target', () async {
      if (Platform.isWindows) return;
      final outside = File(p.join(tempDir.parent.path, 'sanad-outside-secret'));
      await outside.writeAsString('outside');
      final link = Link(
        p.join(tempDir.path, LinuxOwnerFileAgentSecretStore.dataFileName),
      );
      await link.create(outside.path);
      final store = LinuxOwnerFileAgentSecretStore();
      try {
        await expectLater(
          store.read('entry'),
          throwsA(isA<AgentSecretStoreUnavailable>()),
        );
        expect(await outside.readAsString(), 'outside');
      } finally {
        await link.delete();
        await outside.delete();
      }
    });

    test('falls back once and persists owner-file backend identity', () async {
      final client = _MemoryLinuxSecretServiceClient(available: false);
      final auto = LinuxAutoAgentSecretStore(
        scope: 'fallback-scope',
        secretService: LinuxSecretServiceAgentSecretStore(
          scope: 'fallback-scope',
          client: client,
        ),
      );

      await auto.write('entry', 'synthetic-secret');

      expect(await auto.backend, LinuxAgentSecretBackend.ownerFile);
      expect(await auto.read('entry'), 'synthetic-secret');
      final metadata = await File(
        p.join(tempDir.path, LinuxAutoAgentSecretStore.metadataFileName),
      ).readAsString();
      expect(metadata, contains('linux_owner_file'));
      expect(metadata, isNot(contains('synthetic-secret')));
    });

    test(
      'does not fall back from a persisted Secret Service selection',
      () async {
        final client = _MemoryLinuxSecretServiceClient();
        final secretService = LinuxSecretServiceAgentSecretStore(
          scope: 'sticky-scope',
          client: client,
        );
        final first = LinuxAutoAgentSecretStore(
          scope: 'sticky-scope',
          secretService: secretService,
        );
        await first.write('entry', 'synthetic-secret');
        expect(await first.backend, LinuxAgentSecretBackend.secretService);

        client.available = false;
        final restored = LinuxAutoAgentSecretStore(
          scope: 'sticky-scope',
          secretService: secretService,
        );
        await expectLater(
          restored.read('entry'),
          throwsA(isA<AgentSecretStoreUnavailable>()),
        );
        expect(
          File(
            p.join(tempDir.path, LinuxOwnerFileAgentSecretStore.dataFileName),
          ).existsSync(),
          isFalse,
        );
      },
    );

    test('fails closed when persisted backend metadata is corrupt', () async {
      await File(
        p.join(tempDir.path, LinuxAutoAgentSecretStore.metadataFileName),
      ).writeAsString('{corrupt');
      final auto = LinuxAutoAgentSecretStore(scope: 'corrupt-scope');

      await expectLater(
        auto.read('entry'),
        throwsA(isA<AgentSecretStoreUnavailable>()),
      );
      expect(
        File(
          p.join(tempDir.path, LinuxOwnerFileAgentSecretStore.dataFileName),
        ).existsSync(),
        isFalse,
      );
    });

    test(
      'migrates owner-file records only after verified Secret Service writes',
      () async {
        final unavailable = _MemoryLinuxSecretServiceClient(available: false);
        final first = LinuxAutoAgentSecretStore(
          scope: 'migration-scope',
          secretService: LinuxSecretServiceAgentSecretStore(
            scope: 'migration-scope',
            client: unavailable,
          ),
        );
        await first.write('entry', 'synthetic-secret');

        final available = _MemoryLinuxSecretServiceClient();
        final restored = LinuxAutoAgentSecretStore(
          scope: 'migration-scope',
          secretService: LinuxSecretServiceAgentSecretStore(
            scope: 'migration-scope',
            client: available,
          ),
        );

        expect(await restored.read('entry'), 'synthetic-secret');
        expect(await restored.backend, LinuxAgentSecretBackend.secretService);
        expect(available.values['entry'], 'synthetic-secret');
        expect(
          File(
            p.join(tempDir.path, LinuxOwnerFileAgentSecretStore.dataFileName),
          ).existsSync(),
          isFalse,
        );
      },
    );

    test(
      'retains owner-file records when migration verification fails',
      () async {
        final unavailable = _MemoryLinuxSecretServiceClient(available: false);
        final first = LinuxAutoAgentSecretStore(
          scope: 'failed-migration-scope',
          secretService: LinuxSecretServiceAgentSecretStore(
            scope: 'failed-migration-scope',
            client: unavailable,
          ),
        );
        await first.write('entry', 'synthetic-secret');

        final unverifiable = _MemoryLinuxSecretServiceClient()
          ..unverifiableEntry = 'entry';
        final restored = LinuxAutoAgentSecretStore(
          scope: 'failed-migration-scope',
          secretService: LinuxSecretServiceAgentSecretStore(
            scope: 'failed-migration-scope',
            client: unverifiable,
          ),
        );

        expect(await restored.read('entry'), 'synthetic-secret');
        expect(await restored.backend, LinuxAgentSecretBackend.ownerFile);
        expect(
          File(
            p.join(tempDir.path, LinuxOwnerFileAgentSecretStore.dataFileName),
          ).existsSync(),
          isTrue,
        );
      },
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
    final tempDir = await Directory.systemTemp.createTemp(
      'sanad-dpapi-corrupt',
    );
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
      // Overwrite/update existing key
      await store.write(key, 'updated-secret-value-12345');
      expect(await store.read(key), 'updated-secret-value-12345');
      await store.delete(key);
      expect(await store.read(key), isNull);
    } finally {
      await store.delete(key);
    }
  }, skip: !Platform.isMacOS);

  test('macOS Keychain handles multiple keys and special characters', () async {
    final scope = 'sec01e-multi-${const Uuid().v4()}';
    final store = MacOsKeychainAgentSecretStore(scope: scope);
    const key1 = 'device_credential';
    const key2 = 'provider:openai_api_key';
    const value1 = 'token_abc123!@#\$%^&*()_+~`|}{[]:;?><,./';
    const value2 = '{"type":"json_secret","nested":{"field":123}}';

    try {
      await store.write(key1, value1);
      await store.write(key2, value2);

      expect(await store.read(key1), value1);
      expect(await store.read(key2), value2);

      await store.delete(key1);
      expect(await store.read(key1), isNull);
      expect(await store.read(key2), value2);

      await store.delete(key2);
      expect(await store.read(key2), isNull);
    } finally {
      await store.delete(key1);
      await store.delete(key2);
    }
  }, skip: !Platform.isMacOS);
}
