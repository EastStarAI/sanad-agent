import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:sanad_agent/capabilities/secrets/user_secret_catalog.dart';
import 'package:sanad_agent/capabilities/secrets/user_secret_vault.dart';
import 'package:sanad_agent/core/auth/secret_vault.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/sanad_home/sanad_home_bootstrap.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/user_secret_metadata_repository.dart';
import 'package:test/test.dart';

import '../../support/memory_agent_secret_store.dart';

/// Task 140 A2: `UserSecretCatalog` is the single read model behind the
/// Settings → Privacy & Security page. It joins vault names with non-secret
/// metadata, repairs and prunes rows on read, and never returns, logs, or
/// derives anything from a stored value.
void main() {
  /// A distinctive canary no other fixture contains.
  const canary = 'canary-9f3c1d7a-2b64-4e58-secret-value';

  late Directory root;
  late MemoryAgentSecretStore store;
  late SecretVaults vaults;
  late UserSecretVault userSecrets;
  late AgentStateDatabase state;
  late UserSecretMetadataRepository metadata;
  late UserSecretCatalog catalog;
  late List<String> logged;

  setUp(() async {
    root = Directory(
      Directory.systemTemp
          .createTempSync('sanad-secret-catalog-')
          .resolveSymbolicLinksSync(),
    );
    final home = Directory('${root.path}/home')..createSync();
    setSanadHomeOverride(home.resolveSymbolicLinksSync());
    setSanadStateHomeOverride(home.resolveSymbolicLinksSync());
    await SanadHomeBootstrap.identity().prepare();
    store = MemoryAgentSecretStore();
    vaults = await SecretVaults.open(store: store);
    userSecrets = UserSecretVault(vaults: () => vaults);
    state = AgentStateDatabase.inMemory();
    metadata = UserSecretMetadataRepository(state);
    catalog = UserSecretCatalog(vault: userSecrets, metadata: metadata);
    logged = [];
  });

  tearDown(() async {
    await SecretVaults.closeAll();
    setSanadHomeOverride(null);
    setSanadStateHomeOverride(null);
    state.dispose();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  /// Captures every log record emitted while [body] runs.
  Future<void> captureLogs(Future<void> Function() body) async {
    final previous = Logger.root.level;
    Logger.root.level = Level.ALL;
    final subscription = Logger.root.onRecord.listen(
      (record) => logged.add('${record.level.name} ${record.message}'),
    );
    try {
      await body();
      await Future<void>.delayed(Duration.zero);
    } finally {
      await subscription.cancel();
      Logger.root.level = previous;
    }
  }

  Future<void> seedVaultValue(String name, String value) async {
    // A legitimate vault write through the vault's own API, exactly what the
    // Task 84 acquisition path does once the user answers a card. It records no
    // metadata, which is the state a pre-Task-140 secret is in.
    await vaults.put(vaults.custom, {name: value});
  }

  /// Rebuilds the vault on an unavailable store, as it is when the platform
  /// backend refused to open for this Home.
  Future<void> useUnavailableVault() async {
    final unavailable = MemoryAgentSecretStore()..available = false;
    vaults = await SecretVaults.openDetached(store: unavailable);
    userSecrets = UserSecretVault(vaults: () => vaults);
    catalog = UserSecretCatalog(vault: userSecrets, metadata: metadata);
  }

  group('list joins vault names with metadata (A2)', () {
    test('returns one entry per vault name with its metadata', () async {
      await catalog.set(
        name: 'DATABASE_PASSWORD',
        value: canary,
        description: 'Staging database password',
      );

      final outcome = catalog.list();
      expect(outcome.isSuccess, isTrue);
      final entries = outcome.requireValue;
      expect(entries, hasLength(1));
      expect(entries.single.name, 'DATABASE_PASSWORD');
      expect(entries.single.description, 'Staging database password');
      expect(entries.single.source, UserSecretSource.user);
      expect(entries.single.createdAt, isNotNull);
      expect(entries.single.updatedAt, isNotNull);
    });

    test('a name with no metadata row is repaired on read', () async {
      // A secret the Task 84 path stored before metadata existed.
      await seedVaultValue('LEGACY_TOKEN', 'value-that-is-not-inspected');
      expect(metadata.find('LEGACY_TOKEN'), isNull);

      final entries = catalog.list().requireValue;

      final entry = entries.singleWhere((e) => e.name == 'LEGACY_TOKEN');
      expect(entry.description, isNull);
      expect(
        entry.source,
        UserSecretSource.agentRequest,
        reason: 'a repaired row never claims the user typed the value in',
      );
      expect(
        entry.updatedAt,
        isNotNull,
        reason: 'a repaired row carries both timestamps',
      );
      expect(
        metadata.find('LEGACY_TOKEN'),
        isNotNull,
        reason: 'the repair is persisted, not projected once',
      );
    });

    test('an orphaned metadata row is pruned on read', () async {
      await catalog.set(name: 'DELETED_ELSEWHERE', value: 'stored-once');
      // The vault entry disappears behind this owner's back, as it does when
      // the model's `system_delete_secret` removes a name.
      await vaults.remove(vaults.custom, ['DELETED_ELSEWHERE']);
      expect(metadata.find('DELETED_ELSEWHERE'), isNotNull);

      final entries = catalog.list().requireValue;

      expect(entries, isEmpty);
      expect(
        metadata.find('DELETED_ELSEWHERE'),
        isNull,
        reason: 'a metadata row cannot outlive its vault entry',
      );
    });

    test('an unavailable vault is a typed failure, never an empty list', () async {
      await catalog.set(name: 'DATABASE_PASSWORD', value: canary);
      await useUnavailableVault();

      final outcome = catalog.list();

      expect(outcome.isSuccess, isFalse);
      expect(outcome.failure!.code, UserSecretFailureCode.vaultUnavailable);
    });

    test('list returns no value and no value-derived field', () async {
      await catalog.set(name: 'DATABASE_PASSWORD', value: canary);

      final projected = jsonEncode([
        for (final entry in catalog.list().requireValue) entry.toJson(),
      ]);

      expect(projected, isNot(contains(canary)));
      expect(projected, isNot(contains(canary.substring(0, 8))));
      final decoded =
          (jsonDecode(projected) as List).single as Map<String, dynamic>;
      expect(decoded.keys.toSet(), {
        'name',
        'description',
        'source',
        'created_at',
        'updated_at',
      });
    });
  });

  group('set validates before it mutates (A2, M6)', () {
    test('a valid value is stored and described with source=user', () async {
      final outcome = await catalog.set(
        name: 'DATABASE_PASSWORD',
        value: canary,
        description: '  Staging password  ',
      );

      expect(outcome.isSuccess, isTrue);
      expect(outcome.requireValue.description, 'Staging password');
      expect(outcome.requireValue.source, UserSecretSource.user);
      expect(store.values['custom:DATABASE_PASSWORD'], canary);
    });

    test('an invalid or reserved name mutates nothing', () async {
      for (final entry in {
        '1ABC': UserSecretFailureCode.invalidSecretName,
        'A-B': UserSecretFailureCode.invalidSecretName,
        '': UserSecretFailureCode.invalidSecretName,
        'PATH': UserSecretFailureCode.reservedSecretName,
        'OPENAI_API_KEY': UserSecretFailureCode.reservedSecretName,
      }.entries) {
        final outcome = await catalog.set(name: entry.key, value: canary);
        expect(outcome.isSuccess, isFalse, reason: entry.key);
        expect(outcome.failure!.code, entry.value, reason: entry.key);
      }
      expect(metadata.list(), isEmpty);
      expect(
        store.values.keys.where((key) => key.startsWith('custom:') && key != 'custom:index'),
        isEmpty,
      );
    });

    test('an empty, oversized, or sentinel value mutates nothing', () async {
      for (final value in [
        '',
        'x' * (UserSecretVault.maxValueLength + 1),
        '[REDACTED:DATABASE_PASSWORD]',
        'prefix-[REDACTED:TOKEN]-suffix',
      ]) {
        final outcome = await catalog.set(
          name: 'DATABASE_PASSWORD',
          value: value,
        );
        expect(outcome.isSuccess, isFalse, reason: value.length.toString());
        expect(
          outcome.failure!.code,
          UserSecretFailureCode.invalidSecretValue,
          reason: value.length.toString(),
        );
        if (value.isNotEmpty) {
          expect(
            outcome.failure!.message,
            isNot(contains(value)),
            reason: 'a refusal never echoes the submitted value',
          );
        }
        expect(
          outcome.failure!.message.length,
          lessThan(400),
          reason: 'the wording is bounded prose, not the submitted value',
        );
      }
      expect(metadata.list(), isEmpty);
      expect(store.values.containsKey('custom:DATABASE_PASSWORD'), isFalse);
    });

    test('a value exactly at the bound is accepted', () async {
      final outcome = await catalog.set(
        name: 'DATABASE_PASSWORD',
        value: 'y' * UserSecretVault.maxValueLength,
      );
      expect(outcome.isSuccess, isTrue);
    });

    test('an oversized description mutates nothing', () async {
      final outcome = await catalog.set(
        name: 'DATABASE_PASSWORD',
        value: canary,
        description: 'd' * (UserSecretMetadataRepository.maxDescriptionLength + 1),
      );

      expect(outcome.isSuccess, isFalse);
      expect(outcome.failure!.code, UserSecretFailureCode.descriptionTooLong);
      expect(store.values.containsKey('custom:DATABASE_PASSWORD'), isFalse);
      expect(metadata.list(), isEmpty);
    });

    test('an unavailable vault refuses before any vault or metadata write', () async {
      await useUnavailableVault();

      final outcome = await catalog.set(
        name: 'DATABASE_PASSWORD',
        value: canary,
      );

      expect(outcome.isSuccess, isFalse);
      expect(outcome.failure!.code, UserSecretFailureCode.vaultUnavailable);
      expect(store.values.containsKey('custom:DATABASE_PASSWORD'), isFalse);
      expect(metadata.list(), isEmpty);
    });

    test('a refused vault write leaves no metadata row (M3)', () async {
      store.corruptWrites = true;

      final outcome = await catalog.set(
        name: 'DATABASE_PASSWORD',
        value: canary,
        description: 'Staging database password',
      );

      expect(
        outcome.isSuccess,
        isFalse,
        reason: 'a vault write that fails read-back is not a saved secret',
      );
      expect(outcome.failure!.code, UserSecretFailureCode.vaultUnavailable);
      expect(
        metadata.list(),
        isEmpty,
        reason: 'metadata is never written for a value the vault refused',
      );
    });

    test('a verified vault write survives a metadata failure (M3)', () async {
      // The repository is pointed at a database that has no table, which is
      // what a Home mid-migration looks like.
      final detached = AgentStateDatabase.inMemory();
      addTearDown(detached.dispose);
      detached.db.execute('DROP TABLE user_secret_metadata');
      final failing = UserSecretMetadataRepository(detached);
      final degraded = UserSecretCatalog(
        vault: userSecrets,
        metadata: failing,
      );

      final outcome = await degraded.set(
        name: 'DATABASE_PASSWORD',
        value: canary,
        description: 'Staging database password',
      );

      expect(
        outcome.isSuccess,
        isTrue,
        reason: 'a verified vault write is never reported as a failure',
      );
      expect(outcome.requireValue.source, UserSecretSource.user);
      expect(store.values['custom:DATABASE_PASSWORD'], canary);
      expect(
        () => metadata.find('DATABASE_PASSWORD'),
        returnsNormally,
        reason: 'nothing was written to the real table either way',
      );
    });

    test('the next read repairs a row a failed metadata write skipped', () async {
      // Simulate the degraded write by storing the value and no row.
      await seedVaultValue('DATABASE_PASSWORD', canary);
      expect(metadata.find('DATABASE_PASSWORD'), isNull);

      final entry = catalog
          .list()
          .requireValue
          .singleWhere((e) => e.name == 'DATABASE_PASSWORD');

      expect(entry.description, isNull);
      expect(entry.updatedAt, isNotNull);
      expect(metadata.find('DATABASE_PASSWORD'), isNotNull);
    });
  });

  group('replace and delete (A2)', () {
    test('replace advances updated_at and sets source=user', () async {
      final first = await catalog.set(
        name: 'DATABASE_PASSWORD',
        value: 'first-value',
        description: 'Staging database password',
      );
      final second = await catalog.set(
        name: 'DATABASE_PASSWORD',
        value: canary,
        description: 'Staging database password',
      );

      expect(second.isSuccess, isTrue);
      expect(
        second.requireValue.updatedAt.isAfter(first.requireValue.updatedAt),
        isTrue,
        reason: 'a replacement advances updated_at',
      );
      expect(
        second.requireValue.createdAt,
        first.requireValue.createdAt,
        reason: 'created_at is written once',
      );
      expect(second.requireValue.source, UserSecretSource.user);
      expect(store.values['custom:DATABASE_PASSWORD'], canary);
    });

    test('an acquisition-recorded row becomes user-sourced when replaced', () async {
      metadata.recordValue(
        name: 'DATABASE_PASSWORD',
        description: null,
        source: UserSecretSource.agentRequest,
        at: DateTime.utc(2026, 10, 20),
      );
      await seedVaultValue('DATABASE_PASSWORD', 'value-from-the-card');
      expect(catalog.list().requireValue.single.source, UserSecretSource.agentRequest);

      await catalog.set(
        name: 'DATABASE_PASSWORD',
        value: canary,
        description: 'Rotated in Settings',
      );

      final entry = catalog.list().requireValue.single;
      expect(entry.source, UserSecretSource.user);
      expect(entry.description, 'Rotated in Settings');
    });

    test('a null description clears the stored one', () async {
      await catalog.set(
        name: 'DATABASE_PASSWORD',
        value: canary,
        description: 'Staging database password',
      );

      await catalog.set(name: 'DATABASE_PASSWORD', value: canary);

      expect(metadata.find('DATABASE_PASSWORD')!.description, isNull);
    });

    test('a whitespace-only description is stored as absent', () async {
      await catalog.set(
        name: 'DATABASE_PASSWORD',
        value: canary,
        description: '   ',
      );
      expect(metadata.find('DATABASE_PASSWORD')!.description, isNull);
    });

    test('delete removes both the vault entry and the row', () async {
      await catalog.set(name: 'DATABASE_PASSWORD', value: canary);

      final outcome = await catalog.delete('DATABASE_PASSWORD');

      expect(outcome.requireValue, isTrue);
      expect(store.values.containsKey('custom:DATABASE_PASSWORD'), isFalse);
      expect(metadata.find('DATABASE_PASSWORD'), isNull);
      expect(catalog.list().requireValue, isEmpty);
    });

    test('delete reports not_found for an unknown name', () async {
      final outcome = await catalog.delete('NEVER_STORED');

      expect(outcome.isSuccess, isTrue);
      expect(outcome.requireValue, isFalse);
      expect(metadata.list(), isEmpty);
    });

    test('delete refuses a reserved name without touching the vault', () async {
      final outcome = await catalog.delete('PATH');

      expect(outcome.isSuccess, isFalse);
      expect(outcome.failure!.code, UserSecretFailureCode.reservedSecretName);
    });
  });

  group('no value reaches a log or an error (Security)', () {
    test('a successful set logs the name and never the value', () async {
      await captureLogs(() async {
        await catalog.set(
          name: 'DATABASE_PASSWORD',
          value: canary,
          description: 'Staging database password',
        );
      });

      final transcript = logged.join('\n');
      expect(transcript, contains('DATABASE_PASSWORD'));
      expect(transcript, isNot(contains(canary)));
      expect(transcript, isNot(contains(canary.substring(0, 8))));
    });

    test('every failing path logs and returns no fragment of the value', () async {
      await captureLogs(() async {
        // Refused by a corrupting store: the closest a value gets to an error.
        store.corruptWrites = true;
        await catalog.set(name: 'DATABASE_PASSWORD', value: canary);

        // Refused before the vault, on the sentinel rule.
        await catalog.set(
          name: 'DATABASE_PASSWORD',
          value: '[REDACTED:DATABASE_PASSWORD]',
        );
        await catalog.set(name: 'PATH', value: canary);
        await catalog.set(name: '1ABC', value: canary);
        await catalog.set(name: 'DATABASE_PASSWORD', value: '');
        await catalog.set(
          name: 'DATABASE_PASSWORD',
          value: 'z' * (UserSecretVault.maxValueLength + 5),
        );
        await catalog.set(
          name: 'DATABASE_PASSWORD',
          value: canary,
          description: 'd' * 500,
        );
        await catalog.delete('PATH');
      });

      final transcript = logged.join('\n');
      expect(transcript, isNot(contains(canary)));
      expect(transcript, isNot(contains(canary.substring(0, 8))));
      expect(
        transcript,
        isNot(contains('z' * (UserSecretVault.maxValueLength + 5))),
      );
    });

    test('a value never reaches request_dumps or a stored row', () async {
      await catalog.set(name: 'DATABASE_PASSWORD', value: canary);

      // The dumps directory is the one place a model request could have
      // carried the value into. `secret.set` is a device command, never a tool
      // argument or a tool result, so nothing there can name it; this asserts
      // the boundary rather than assuming it.
      final dumps = Directory('${root.path}/request_dumps');
      if (dumps.existsSync()) {
        for (final entity in dumps.listSync(recursive: true)) {
          if (entity is! File) continue;
          expect(
            entity.readAsStringSync(),
            isNot(contains(canary)),
            reason: '${entity.path} must not carry a stored value',
          );
        }
      }

      // The metadata table is the other place a value could land. Read the
      // real rows rather than the source.
      final stored = state.db
          .select('SELECT * FROM user_secret_metadata')
          .map((row) => Map<String, dynamic>.from(row).values.join('|'))
          .join('\n');
      expect(stored, isNot(contains(canary)));
      expect(stored, isNot(contains(canary.substring(0, 8))));
    });

    test('list logs no value while repairing and pruning', () async {
      await seedVaultValue('LEGACY_TOKEN', canary);
      metadata.recordValue(
        name: 'ORPHANED',
        description: null,
        source: UserSecretSource.agentRequest,
      );

      await captureLogs(() async {
        final entries = catalog.list().requireValue;
        expect(entries.single.name, 'LEGACY_TOKEN');
      });

      final transcript = logged.join('\n');
      expect(transcript, isNot(contains(canary)));
      expect(transcript, isNot(contains(canary.substring(0, 8))));
    });
  });

  group('a metadata failure is typed as internal_error (M4)', () {
    test('a list whose metadata read fails is not a vault problem', () {
      final detached = AgentStateDatabase.inMemory();
      addTearDown(detached.dispose);
      detached.db.execute('DROP TABLE user_secret_metadata');
      final degraded = UserSecretCatalog(
        vault: userSecrets,
        metadata: UserSecretMetadataRepository(detached),
      );

      final outcome = degraded.list();

      expect(outcome.isSuccess, isFalse);
      expect(
        outcome.failure!.code,
        UserSecretFailureCode.internalError,
        reason:
            'a repository failure is internal_error, so the Client never tells '
            'the user to fix a vault that is fine',
      );
    });
  });
}
