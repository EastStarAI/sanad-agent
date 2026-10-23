import 'dart:convert';
import 'dart:io';

import 'package:sanad_agent/capabilities/permissions/command_authority.dart';
import 'package:sanad_agent/capabilities/secrets/secret_acquisition.dart';
import 'package:sanad_agent/capabilities/secrets/user_secret_catalog.dart';
import 'package:sanad_agent/capabilities/secrets/user_secret_vault.dart';
import 'package:sanad_agent/core/auth/secret_vault.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/sanad_home/sanad_home_bootstrap.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/user_secret_metadata_repository.dart';
import 'package:test/test.dart';

import '../../support/memory_agent_secret_store.dart';

/// Task 140 A3: the Task 84 acquisition path records non-secret metadata for
/// the values it stores, so a secret entered through the composer card appears
/// in the Settings list with `source = agent_request`.
///
/// Nothing else about that path changes: no value leaves it, and the sanitized
/// decision stays value-free.
void main() {
  const canary = 'canary-4a8e2b90-6d13-4f27-acquired-value';
  const sessionId = 'acquisition-metadata-session';

  late Directory root;
  late MemoryAgentSecretStore store;
  late SecretVaults vaults;
  late UserSecretVault userSecrets;
  late AgentStateDatabase state;
  late UserSecretMetadataRepository metadata;

  setUp(() async {
    root = Directory(
      Directory.systemTemp
          .createTempSync('sanad-secret-acquisition-')
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
  });

  tearDown(() async {
    await SecretVaults.closeAll();
    setSanadHomeOverride(null);
    setSanadStateHomeOverride(null);
    state.dispose();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Map<String, dynamic> decision({
    required bool allowed,
    Map<String, String>? values,
  }) => {
    CommandAuthority.payloadKey: CommandAuthority.owner.value,
    'session_id': sessionId,
    'allowed': allowed,
    SecretAcquisition.valuesKey: ?values,
  };

  Map<String, dynamic> pendingRequest(List<String> names) => {
    'fields': [
      for (final name in names) {'name': name, 'label': 'Value for $name'},
    ],
  };

  group('a card-stored secret records agent_request metadata (A3)', () {
    test('the value is stored and described without being echoed', () async {
      final acquisition = SecretAcquisition(
        vault: userSecrets,
        metadata: metadata,
      );
      final body = decision(
        allowed: true,
        values: {'DEMO_DB_PASSWORD': canary},
      );
      expect(
        SecretAcquisition.validate(pendingRequest(['DEMO_DB_PASSWORD']), body),
        isNull,
      );

      final prepared = acquisition.prepare(body);
      await prepared.commit();

      expect(store.values['custom:DEMO_DB_PASSWORD'], canary);
      final row = metadata.find('DEMO_DB_PASSWORD');
      expect(row, isNotNull);
      expect(row!.source, UserSecretSource.agentRequest);
      expect(
        row.description,
        isNull,
        reason: 'the card collects no description',
      );
      expect(row.createdAt, row.updatedAt);

      // The sanitized decision stays value-free, as it did before A3.
      expect(jsonEncode(prepared.decision), isNot(contains(canary)));
      expect(prepared.decision[SecretAcquisition.outcomeKey], 'stored');
      expect(prepared.decision[SecretAcquisition.namesKey], [
        'DEMO_DB_PASSWORD',
      ]);
      expect(
        prepared.decision.containsKey(SecretAcquisition.valuesKey),
        isFalse,
      );
    });

    test('the stored secret appears in the Settings list as agent-arrived', () async {
      final acquisition = SecretAcquisition(
        vault: userSecrets,
        metadata: metadata,
      );
      await acquisition
          .prepare(
            decision(allowed: true, values: {'DEMO_DB_PASSWORD': canary}),
          )
          .commit();

      final catalog = UserSecretCatalog(
        vault: userSecrets,
        metadata: metadata,
      );
      final entry = catalog.list().requireValue.single;

      expect(entry.name, 'DEMO_DB_PASSWORD');
      expect(entry.source, UserSecretSource.agentRequest);
      expect(entry.updatedAt, isNotNull);
      expect(jsonEncode(entry.toJson()), isNot(contains(canary)));
    });

    test('several names from one card each get a row', () async {
      final acquisition = SecretAcquisition(
        vault: userSecrets,
        metadata: metadata,
      );
      await acquisition
          .prepare(
            decision(
              allowed: true,
              values: {'DEMO_A': canary, 'DEMO_B': '$canary-b'},
            ),
          )
          .commit();

      expect(metadata.list().map((row) => row.name), ['DEMO_A', 'DEMO_B']);
      for (final row in metadata.list()) {
        expect(row.source, UserSecretSource.agentRequest);
      }
    });
  });

  group('nothing else about the acquisition path changes (A3)', () {
    test('a skip stores no value and records no metadata', () async {
      final acquisition = SecretAcquisition(
        vault: userSecrets,
        metadata: metadata,
      );

      final prepared = acquisition.prepare(decision(allowed: false));
      await prepared.commit();

      expect(store.values.keys.where((k) => k.startsWith('custom:')), isEmpty);
      expect(metadata.list(), isEmpty);
      expect(prepared.decision[SecretAcquisition.outcomeKey], 'skipped');
    });

    test('a refused vault write records no metadata and reports failed', () async {
      store.corruptWrites = true;
      final acquisition = SecretAcquisition(
        vault: userSecrets,
        metadata: metadata,
      );

      final prepared = acquisition.prepare(
        decision(allowed: true, values: {'DEMO_DB_PASSWORD': canary}),
      );
      await prepared.commit();

      expect(
        prepared.decision[SecretAcquisition.outcomeKey],
        'failed',
        reason: 'a value the vault refused is reported as failed',
      );
      expect(
        metadata.list(),
        isEmpty,
        reason: 'metadata is never written for a refused value',
      );
      expect(SecretAcquisition.resultFor(prepared.decision).isError, isTrue);
    });

    test('without a metadata owner the value is still stored', () async {
      // A runtime that never opened the agent-state database, for example a
      // standalone CLI turn. The row is repaired by the next catalog read.
      final acquisition = SecretAcquisition(vault: userSecrets);
      final prepared = acquisition.prepare(
        decision(allowed: true, values: {'DEMO_DB_PASSWORD': canary}),
      );

      await prepared.commit();

      expect(store.values['custom:DEMO_DB_PASSWORD'], canary);
      expect(prepared.decision[SecretAcquisition.outcomeKey], 'stored');
      expect(metadata.list(), isEmpty);
    });

    test('a metadata failure never turns a stored value into a failure', () async {
      final detached = AgentStateDatabase.inMemory();
      addTearDown(detached.dispose);
      detached.db.execute('DROP TABLE user_secret_metadata');
      final acquisition = SecretAcquisition(
        vault: userSecrets,
        metadata: UserSecretMetadataRepository(detached),
      );

      final prepared = acquisition.prepare(
        decision(allowed: true, values: {'DEMO_DB_PASSWORD': canary}),
      );
      await prepared.commit();

      expect(
        prepared.decision[SecretAcquisition.outcomeKey],
        'stored',
        reason: 'a verified vault write is never reported as a failure',
      );
      expect(prepared.decision[SecretAcquisition.namesKey], [
        'DEMO_DB_PASSWORD',
      ]);
      expect(store.values['custom:DEMO_DB_PASSWORD'], canary);
    });

    test('a re-entered name keeps one row and advances updated_at', () async {
      final acquisition = SecretAcquisition(
        vault: userSecrets,
        metadata: metadata,
      );
      await acquisition
          .prepare(
            decision(allowed: true, values: {'DEMO_DB_PASSWORD': canary}),
          )
          .commit();
      final first = metadata.find('DEMO_DB_PASSWORD')!;

      await Future<void>.delayed(const Duration(milliseconds: 2));
      await acquisition
          .prepare(
            decision(allowed: true, values: {'DEMO_DB_PASSWORD': '$canary-2'}),
          )
          .commit();

      final second = metadata.find('DEMO_DB_PASSWORD')!;
      expect(metadata.list(), hasLength(1));
      expect(second.createdAt, first.createdAt);
      expect(second.updatedAt.isAfter(first.updatedAt), isTrue);
      expect(
        second.source,
        UserSecretSource.agentRequest,
        reason: 'the current value arrived through the card',
      );
    });
  });
}
