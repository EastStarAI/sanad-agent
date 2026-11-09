import 'dart:io';

import 'package:sanad_agent/core/auth/agent_secret_store.dart';
import 'package:sanad_agent/core/auth/secret_vault.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../support/memory_agent_secret_store.dart';

/// Backend and namespace are two separate decisions, and the safety refusals
/// must survive every combination of them.
///
/// A Dart test can never reach the real operating-system store — the test
/// runtime takes the owner-only file store by law — so the macOS and Secret
/// Service item names are asserted on [SecretStoreKind] itself, and the live
/// check (see the PR body) covers the OS store end to end.
void main() {
  late Directory home;

  setUp(() {
    home = Directory(
      Directory.systemTemp
          .createTempSync('sanad-secret-namespace')
          .resolveSymbolicLinksSync(),
    );
    setSanadHomeOverride(home.path);
  });

  tearDown(() async {
    await SecretVaults.closeAll();
    setSanadHomeOverride(null);
    if (home.existsSync()) home.deleteSync(recursive: true);
  });

  File homeFile(String name) => File(p.join(home.path, name));

  group('backend selection', () {
    test('a plaintext file is refused for the production namespace', () async {
      // The production Home keeps its secrets in the OS vault; a development
      // override must not downgrade them where an upgrade would hide them.
      await expectLater(
        () => createAgentSecretStore(
          environment: const {'SANAD_SECRET_STORE': 'file'},
          isTestRuntime: false,
        ),
        throwsA(
          isA<AgentSecretStoreUnavailable>().having(
            (error) => error.reasonCode,
            'reasonCode',
            AgentSecretStoreUnavailableReason.fileStoreRefusedForApp,
          ),
        ),
      );
    });

    test('the OS store is refused inside a test runtime', () async {
      await expectLater(
        () => createAgentSecretStore(
          environment: const {'SANAD_SECRET_STORE': 'os'},
          isTestRuntime: true,
        ),
        throwsA(
          isA<AgentSecretStoreUnavailable>().having(
            (error) => error.reasonCode,
            'reasonCode',
            AgentSecretStoreUnavailableReason.osStoreRefusedForTest,
          ),
        ),
      );
    });

    test('an invalid override fails closed before a backend exists', () async {
      await expectLater(
        () => createAgentSecretStore(
          environment: const {'SANAD_SECRET_STORE': 'plaintext'},
          isTestRuntime: false,
        ),
        throwsA(
          isA<AgentSecretStoreUnavailable>().having(
            (error) => error.reasonCode,
            'reasonCode',
            AgentSecretStoreUnavailableReason.invalidStoreSelection,
          ),
        ),
      );
    });

    test('a declared dev runtime takes the file store it asked for', () async {
      final store = createAgentSecretStore(
        environment: const {
          'SANAD_SECRET_STORE': 'file',
          'SANAD_RUNTIME_KIND': 'dev',
        },
        isTestRuntime: false,
      );

      expect(store, isA<LinuxOwnerFileAgentSecretStore>());
      expect(
        (store as LinuxOwnerFileAgentSecretStore).kind,
        SecretStoreKind.dev,
      );
    });

    test('a test runtime takes the file store by law', () async {
      final store = createAgentSecretStore(
        environment: const {},
        isTestRuntime: true,
      );

      expect(store, isA<LinuxOwnerFileAgentSecretStore>());
      expect(
        (store as LinuxOwnerFileAgentSecretStore).kind,
        SecretStoreKind.test,
      );
    });
  });

  group('file namespace isolation', () {
    Future<LinuxOwnerFileAgentSecretStore> fileStore(
      SecretStoreKind kind,
    ) async =>
        createAgentSecretStore(
              environment: {
                'SANAD_SECRET_STORE': 'file',
                'SANAD_RUNTIME_KIND': kind.wireName,
              },
              isTestRuntime: false,
            )
            as LinuxOwnerFileAgentSecretStore;

    test('two namespaces on one Home never share a file or a value', () async {
      final dev = await fileStore(SecretStoreKind.dev);
      final test = await fileStore(SecretStoreKind.test);

      await dev.write(AgentSecretNamespaces.deviceCredentialKey, 'dev-token');
      await test.write(AgentSecretNamespaces.deviceCredentialKey, 'test-token');

      expect(homeFile(dev.kind.credentialDataFileName).existsSync(), isTrue);
      expect(homeFile(test.kind.credentialDataFileName).existsSync(), isTrue);
      // The production file is never created by a development runtime.
      expect(
        homeFile(SecretStoreKind.app.credentialDataFileName).existsSync(),
        isFalse,
      );

      expect(
        await dev.read(AgentSecretNamespaces.deviceCredentialKey),
        'dev-token',
      );
      expect(
        await test.read(AgentSecretNamespaces.deviceCredentialKey),
        'test-token',
      );

      // Deleting in one namespace leaves the other untouched.
      await dev.delete(AgentSecretNamespaces.deviceCredentialKey);
      expect(await dev.read(AgentSecretNamespaces.deviceCredentialKey), isNull);
      expect(
        await test.read(AgentSecretNamespaces.deviceCredentialKey),
        'test-token',
      );
    });

    test('a new store instance reads what its namespace wrote', () async {
      final first = await fileStore(SecretStoreKind.dev);
      await first.write(AgentSecretNamespaces.pairingTokenKey, 'pairing-token');

      // A restart binds a fresh store to the same Home and namespace.
      final second = await fileStore(SecretStoreKind.dev);
      expect(
        await second.read(AgentSecretNamespaces.pairingTokenKey),
        'pairing-token',
      );
    });
  });

  group('vault reports its namespace', () {
    test('an injected store plus a kind is reported verbatim', () async {
      final vaults = await SecretVaults.openDetached(
        store: MemoryAgentSecretStore(),
        kind: SecretStoreKind.dev,
      );

      expect(vaults.available, isTrue);
      expect(vaults.kind, SecretStoreKind.dev);
      expect(vaults.secretStoreService, SecretStoreKind.dev.service);
      expect(vaults.statusLabel, 'available');
    });

    test('a test namespace reports the test service', () async {
      final vaults = await SecretVaults.openDetached(
        store: MemoryAgentSecretStore(),
        kind: SecretStoreKind.test,
      );

      expect(vaults.kind, SecretStoreKind.test);
      expect(vaults.secretStoreService, SecretStoreKind.test.service);
    });

    test('no kind keeps the production namespace unchanged', () async {
      final vaults = await SecretVaults.openDetached(
        store: MemoryAgentSecretStore(),
      );

      expect(vaults.kind, SecretStoreKind.app);
      expect(vaults.secretStoreService, agentVaultKeychainService);
    });
  });
}
