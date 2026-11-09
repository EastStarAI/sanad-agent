import 'dart:async';
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

/// Failure deadline for the first credential-store read an open performs.
///
/// The fake store signals that read itself, so this is never a wait: an open
/// that crosses a real file-lock round trip before reaching the store simply
/// takes as many event-loop turns as it takes.
const _firstReadDeadline = Duration(seconds: 30);

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
    Future<List<String>> drainLogged() =>
        _captureVaultLog(SecretVaults.drainStartupEvents);

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

    test('recorded attempts are replayed as deduplicated history at INFO', () async {
      // Two processes recorded the same failed verification; a start must show
      // it once, as history, and never as the level that describes this start.
      final event = jsonEncode({
        'at': '2026-11-08T20:06:59Z',
        'level': 'warning',
        'message': 'Secret migration for providers: did not verify (StateError)',
      });
      await SanadHomeBootstrap.identity().writeSecretBytes(
        'secret_vault_events.jsonl',
        utf8.encode('$event\n$event\n'),
      );

      final logged = await drainLogged();

      expect(logged, hasLength(1), reason: 'identical events collapse');
      expect(logged.single, startsWith('INFO'));
      expect(logged.single, contains('did not verify'));
      expect(logged.single, contains('recorded 2026-11-08T20:06:59Z'));
      expect(logged.single, contains('repeated 2 times'));
      expect(await drainLogged(), isEmpty, reason: 'the file is cleared');
    });

    test(
      'a closed vault is current state, so it is never replayed as history',
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
             (line) =>
                 line.startsWith('INFO') &&
                 line.contains('Secret migration for providers: did not verify'),
           ),
           hasLength(1),
           reason: 'a failed migration is history and is replayed once',
         );
        expect(
          logged.where((line) => line.contains('vault unavailable')),
          isEmpty,
          reason:
              'the closed vault is reported by this start\'s own state line, '
              'not by a recorded event',
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

        // Exactly one line describes this start, and it is the actionable
        // WARNING an operator needs.
        final state = await _captureVaultLog(vaults.logStartupState);
        expect(state, hasLength(1));
        expect(state.single, startsWith('WARNING'));
        expect(
          state.single,
          contains(AgentSecretStoreUnavailableReason.interactionForbidden),
          reason: 'the daemon log must name the reason code',
        );
        expect(state.single, contains('sanad vault authorize'));
        expect(
          await _captureVaultLog(vaults.logStartupState),
          isEmpty,
          reason: 'a start logs its state once, never twice',
        );
        expect(
          await drainLogged(),
          isEmpty,
          reason: 'a closed vault is current state, not recorded history',
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

  group('deferred open', () {
    test('a vault opens without waiting for the operating-system store', () async {
      final store = _NeverAnsweringStore();
      final vaults = SecretVaults.beginOpen(store: store);

      // The listener, the banner, and `/health` exist before the store answers.
      expect(vaults.status, SecretVaultStatus.opening);
      expect(vaults.statusLabel, 'opening');
      expect(vaults.available, isFalse);
      expect(vaults.isReady, isFalse);
      // The store signals the read instead of the test guessing how many event
      // loop turns the open needs to cross its file-lock round trip, so a loaded
      // machine can delay the turn without failing the assertion.
      await store.firstRead.future.timeout(
        _firstReadDeadline,
        onTimeout: () => fail('the open never reached the credential store'),
      );
      expect(store.reads, greaterThan(0), reason: 'the open did start');
      expect(
        await vaults.readyWithin(const Duration(milliseconds: 50)),
        isFalse,
        reason: 'a store that never answers must not become an unbounded wait',
      );

      // The one state line for a start that is still opening is INFO: nothing
      // is known yet, so nothing may be reported as closed.
      final state = await _captureVaultLog(vaults.logStartupState);
      expect(state, hasLength(1));
      expect(state.single, startsWith('INFO'));
      expect(state.single, contains('still opening'));

      // Settle the open so the test owns its whole lifetime.
      store.refuse();
      await vaults.ready;
      expect(vaults.status, SecretVaultStatus.unavailable);
    }, timeout: const Timeout(Duration(minutes: 1)));

    test('a secret written while the vault is opening fails as not ready', () async {
      final store = _NeverAnsweringStore();
      final vaults = SecretVaults.beginOpen(store: store);

      await expectLater(
        VaultSecretStore(vaults).write(
          'inst-1',
          SecureFileSecretStore.apiKeyRecord('inst-1', 'sk-opening-0001'),
        ),
        throwsA(
          isA<AgentSecretStoreUnavailable>().having(
            (error) => error.reasonCode,
            'reasonCode',
            AgentSecretStoreUnavailableReason.vaultNotReady,
          ),
        ),
      );

      store.refuse();
      await vaults.ready;
    });

    test('a vault that answers becomes available with its cached values', () async {
      final store = _AnsweringStore();
      final vaults = SecretVaults.beginOpen(store: store);
      await vaults.ready;

      expect(vaults.status, SecretVaultStatus.available);
      expect(vaults.statusLabel, 'available');
      expect(vaults.available, isTrue);
      expect(await vaults.readyWithin(Duration.zero), isTrue);
      expect(
        store.readKeys,
        contains(AgentSecretNamespaces.providerIndexKey),
        reason: 'a settled open has read every namespace index',
      );

      final state = await _captureVaultLog(vaults.logStartupState);
      expect(state, hasLength(1));
      expect(state.single, startsWith('INFO'));
      expect(state.single, contains('available'));
    });

    test('a store that refuses closes the vault without waiting', () async {
      final vaults = SecretVaults.beginOpen(
        store: _ReasonCodedUnavailableStore(),
      );
      await vaults.ready;

      expect(vaults.status, SecretVaultStatus.unavailable);
      expect(
        vaults.unavailableReason,
        AgentSecretStoreUnavailableReason.interactionForbidden,
      );
      expect(
        vaults.unavailableStateMessage,
        contains('sanad vault authorize'),
        reason: 'the recovery route must not require Keychain Access',
      );
    });

    test('open and beginOpen agree on one instance per Home', () async {
      final first = SecretVaults.beginOpen(store: _AnsweringStore());
      final second = await SecretVaults.open(store: _AnsweringStore());
      expect(identical(first, second), isTrue);
      expect(identical(SecretVaults.current, first), isTrue);
    });
  });
}

/// Collects every `SecretVaults` log line [action] produces.
Future<List<String>> _captureVaultLog(FutureOr<void> Function() action) async {
  final logged = <String>[];
  final previous = Logger.root.level;
  Logger.root.level = Level.ALL;
  final sub = Logger.root.onRecord
      .where((record) => record.loggerName == 'SecretVaults')
      .listen((record) => logged.add('${record.level.name} ${record.message}'));
  await action();
  await Future<void>.delayed(Duration.zero);
  await sub.cancel();
  Logger.root.level = previous;
  return logged;
}

/// A store whose reads never complete on their own, standing in for an
/// operating-system credential store that is showing a dialog, waiting on a
/// locked keyring, or blocked behind a competing lock holder.
///
/// [refuse] settles every pending read, so a test owns the open's whole lifetime
/// instead of leaving asynchronous work behind.
final class _NeverAnsweringStore implements AgentSecretStore {
  static const _refusedError = AgentSecretStoreUnavailable(
    'The operating-system credential store did not answer.',
    reasonCode: AgentSecretStoreUnavailableReason.interactionForbidden,
  );

  final List<Completer<String?>> _pending = [];
  bool _refused = false;

  /// Completed by the first read the open performs, so a test waits for the
  /// state it asserts instead of for one event-loop turn.
  final Completer<void> firstRead = Completer<void>();

  int get reads => _pending.length;

  /// Refuses every pending and future read, so a test owns the open's whole
  /// lifetime instead of leaving asynchronous work behind.
  void refuse() {
    _refused = true;
    for (final completer in _pending) {
      if (!completer.isCompleted) completer.completeError(_refusedError);
    }
  }

  @override
  Future<String?> read(String key) {
    if (!firstRead.isCompleted) firstRead.complete();
    if (_refused) return Future<String?>.error(_refusedError);
    final completer = Completer<String?>();
    _pending.add(completer);
    return completer.future;
  }

  @override
  Future<void> write(String key, String value) => Completer<void>().future;

  @override
  Future<void> delete(String key) => Completer<void>().future;
}

/// A store that answers every read with "absent", so an open settles.
final class _AnsweringStore implements AgentSecretStore {
  final Map<String, String> values = {};
  final List<String> readKeys = [];

  @override
  Future<String?> read(String key) async {
    readKeys.add(key);
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
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
