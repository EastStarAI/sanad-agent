import 'dart:convert';
import 'dart:io';

import 'package:sanad_agent/capabilities/mcp/mcp_secret_store.dart';
import 'package:sanad_agent/core/auth/agent_secret_namespaces.dart';
import 'package:sanad_agent/core/auth/agent_secret_store.dart';
import 'package:sanad_agent/core/auth/secret_vault.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/provider_runtime/secure_file_secret_store.dart';
import 'package:sanad_agent/core/provider_runtime/vault_secret_store.dart';
import 'package:sanad_agent/core/sanad_home/sanad_home_bootstrap.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

import '../../support/memory_agent_secret_store.dart';

void main() {
  late Directory home;
  late MemoryAgentSecretStore vault;

  setUp(() async {
    home = Directory(
      Directory.systemTemp
          .createTempSync('sanad-vault')
          .resolveSymbolicLinksSync(),
    );
    setSanadHomeOverride(home.path);
    await SanadHomeBootstrap.identity().prepare();
    vault = MemoryAgentSecretStore();
  });

  tearDown(() async {
    await SecretVaults.closeAll();
    setSanadHomeOverride(null);
    home.deleteSync(recursive: true);
  });

  File legacyProviders() => File('${home.path}/provider_secrets.json');
  File legacyMcp() => File('${home.path}/mcp_secrets.json');

  Future<void> seedLegacy() async {
    await SecureFileSecretStore().write(
      'inst-1',
      SecureFileSecretStore.apiKeyRecord('inst-1', 'sk-legacy-provider-0001'),
    );
    await SanadHomeBootstrap.identity().writeSecretBytes(
      'mcp_secrets.json',
      utf8.encode(jsonEncode({'mcp-secret://ref-1': 'mcp-legacy-token'})),
    );
  }

  Future<SecretVaults> open() => SecretVaults.open(store: vault);

  test(
    'startup migration moves every legacy secret into the vault, then deletes the files',
    () async {
      await seedLegacy();
      final vaults = await open();
      expect(
        vault.values[AgentSecretNamespaces.providerKey('inst-1')],
        contains('sk-legacy-provider-0001'),
      );
      expect(
        vault.values[AgentSecretNamespaces.mcpKey('mcp-secret://ref-1')],
        'mcp-legacy-token',
      );
      expect(legacyProviders().existsSync(), isFalse);
      expect(legacyMcp().existsSync(), isFalse);
      expect(
        VaultSecretStore(vaults).read('inst-1')?.apiKey,
        'sk-legacy-provider-0001',
      );
      expect(
        McpSecretStore().resolve('mcp-secret://ref-1'),
        'mcp-legacy-token',
      );
    },
  );

  test(
    'a failed verification keeps the legacy files and their values',
    () async {
      await seedLegacy();
      vault.corruptWrites = true;
      final vaults = await open();
      expect(legacyProviders().existsSync(), isTrue);
      expect(legacyMcp().existsSync(), isTrue);
      expect(vault.values[AgentSecretNamespaces.providerIndexKey], isNull);
      expect(
        VaultSecretStore(vaults).read('inst-1')?.apiKey,
        'sk-legacy-provider-0001',
      );
      expect(
        McpSecretStore().resolve('mcp-secret://ref-1'),
        'mcp-legacy-token',
      );

      // The next start retries and succeeds.
      await SecretVaults.closeAll();
      vault.corruptWrites = false;
      await open();
      expect(legacyProviders().existsSync(), isFalse);
      expect(legacyMcp().existsSync(), isFalse);
    },
  );

  test('secrets written through the vault survive a restart', () async {
    var store = VaultSecretStore(await open());
    await store.write(
      'inst-2',
      SecureFileSecretStore.apiKeyRecord('inst-2', 'sk-after-restart-0002'),
    );
    final ref = await McpSecretStore().put('mcp-after-restart');
    expect(legacyProviders().existsSync(), isFalse);
    expect(legacyMcp().existsSync(), isFalse);

    await SecretVaults.closeAll();
    store = VaultSecretStore(await open());
    expect(store.read('inst-2')?.apiKey, 'sk-after-restart-0002');
    expect(store.listIds(), ['inst-2']);
    expect(McpSecretStore().resolve(ref), 'mcp-after-restart');

    await store.remove('inst-2');
    await SecretVaults.closeAll();
    store = VaultSecretStore(await open());
    expect(store.read('inst-2'), isNull);
  });

  test(
    'migration is idempotent and never overwrites a newer vault value',
    () async {
      final store = VaultSecretStore(await open());
      await store.write(
        'inst-1',
        SecureFileSecretStore.apiKeyRecord('inst-1', 'test-vault-value'),
      );
      await SecretVaults.closeAll();
      await seedLegacy();
      final reopened = VaultSecretStore(await open());
      expect(reopened.read('inst-1')?.apiKey, 'test-vault-value');
      expect(legacyProviders().existsSync(), isFalse);
    },
  );

  test('another process sees a write after refresh', () async {
    final first = await open();
    final second = await SecretVaults.openDetached(store: vault);
    await VaultSecretStore(first).write(
      'inst-3',
      SecureFileSecretStore.apiKeyRecord('inst-3', 'sk-cross-process-0003'),
    );
    expect(VaultSecretStore(second).read('inst-3'), isNull);
    await second.refreshIfStale();
    expect(
      VaultSecretStore(second).read('inst-3')?.apiKey,
      'sk-cross-process-0003',
    );
  });

  group('lifecycle events reach the agent log', () {
    Future<List<String>> drainLogged() async {
      final logged = <String>[];
      final previous = Logger.root.level;
      Logger.root.level = Level.ALL;
      final sub = Logger.root.onRecord
          .where((record) => record.loggerName == 'SecretVaults')
          .listen(
            (record) => logged.add('${record.level.name} ${record.message}'),
          );
      SecretVaults.drainStartupEvents();
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      Logger.root.level = previous;
      return logged;
    }

    test('a migration done without a log listener is replayed once', () async {
      await seedLegacy();
      await open();
      final logged = await drainLogged();
      expect(
        logged.where((l) => l.contains('Migrated 1 providers:')),
        hasLength(1),
      );
      expect(logged.where((l) => l.contains('Migrated 1 mcp:')), hasLength(1));
      expect(logged.join('\n'), isNot(contains('sk-legacy')));
      expect(await drainLogged(), isEmpty);
    });

    test(
      'a failed verification and an unavailable vault are replayed as warnings',
      () async {
        await seedLegacy();
        vault.corruptWrites = true;
        await open();
        await SecretVaults.closeAll();
        vault
          ..corruptWrites = false
          ..available = false;
        await open();
        final logged = await drainLogged();
        expect(
          logged.where(
            (l) => l.startsWith('WARNING') && l.contains('did not verify'),
          ),
          isNotEmpty,
        );
        expect(
          logged.where(
            (l) => l.startsWith('WARNING') && l.contains('unavailable'),
          ),
          isNotEmpty,
        );
      },
    );

    test(
      'an unavailable vault reports its reason code for doctor and /health',
      () async {
        await SecretVaults.closeAll();
        final vaults = await SecretVaults.open(
          store: _ReasonCodedUnavailableStore(),
        );
        expect(vaults.available, isFalse);
        expect(
          vaults.unavailableReason,
          AgentSecretStoreUnavailableReason.interactionForbidden,
        );
        expect(vaults.statusLabel, 'unavailable');
        expect(vaults.unavailableMessage, contains('no human'));
        final logged = await drainLogged();
        expect(
          logged.where(
            (line) => line.contains(
              AgentSecretStoreUnavailableReason.interactionForbidden,
            ),
          ),
          isNotEmpty,
          reason: 'the daemon log must name the reason code',
        );
        // A closed vault still rejects writes instead of degrading to a file.
        expect(
          () => VaultSecretStore(vaults).write(
            'inst-9',
            SecureFileSecretStore.apiKeyRecord('inst-9', 'sk-blocked-0009'),
          ),
          throwsA(isA<AgentSecretStoreUnavailable>()),
        );
      },
    );
  });
}

/// A store whose every read refuses the way macOS does when the item demands an
/// interactive authorization in a process that has nobody to answer it.
final class _ReasonCodedUnavailableStore implements AgentSecretStore {
  static const _error = AgentSecretStoreUnavailable(
    'The Agent vault item demands an interactive authorization and this '
    'process has no human to answer it.',
    reasonCode: AgentSecretStoreUnavailableReason.interactionForbidden,
  );

  @override
  Future<String?> read(String key) async => throw _error;

  @override
  Future<void> write(String key, String value) async => throw _error;

  @override
  Future<void> delete(String key) async => throw _error;
}
