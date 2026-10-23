import 'dart:convert';
import 'dart:io';

import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';
import 'package:sanad_agent/capabilities/permissions/command_authority.dart';
import 'package:sanad_agent/capabilities/secrets/user_secret_catalog.dart';
import 'package:sanad_agent/capabilities/secrets/user_secret_vault.dart';
import 'package:sanad_agent/core/auth/auth_manager.dart';
import 'package:sanad_agent/core/auth/secret_vault.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/sanad_home/sanad_home_bootstrap.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/user_secret_metadata_repository.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/handlers/secret_command_handler.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/sanad_protocol_bridge.dart';
import 'package:test/test.dart';

import '../../../../support/memory_agent_secret_store.dart';

class _FakeAuthManager implements AuthManager {
  @override
  String? get hardwareId => 'test-device-id';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  const canary = 'canary-secret-value-7f8a9b1c2d3e';

  late Directory root;
  late MemoryAgentSecretStore store;
  late SecretVaults vaults;
  late UserSecretVault userSecrets;
  late AgentStateDatabase state;
  late UserSecretMetadataRepository metadata;
  late UserSecretCatalog catalog;
  late SanadProtocolBridge bridge;
  late SecretCommandHandler handler;
  late List<CanonicalEvent> broadcasts;
  late List<String> logged;

  setUp(() async {
    root = Directory(
      Directory.systemTemp
          .createTempSync('sanad-secret-handler-test-')
          .resolveSymbolicLinksSync(),
    );
    final home = Directory('${root.path}/home')..createSync();
    setSanadHomeOverride(home.resolveSymbolicLinksSync());
    setSanadStateHomeOverride(home.resolveSymbolicLinksSync());
    await SanadHomeBootstrap.identity().prepare();

    final getIt = GetIt.instance;
    if (getIt.isRegistered<AuthManager>()) {
      getIt.unregister<AuthManager>();
    }
    getIt.registerSingleton<AuthManager>(_FakeAuthManager());

    store = MemoryAgentSecretStore();
    vaults = await SecretVaults.open(store: store);
    userSecrets = UserSecretVault(vaults: () => vaults);
    state = AgentStateDatabase.inMemory();
    metadata = UserSecretMetadataRepository(state);
    catalog = UserSecretCatalog(vault: userSecrets, metadata: metadata);
    broadcasts = [];
    logged = [];

    bridge = SanadProtocolBridge();
    handler = SecretCommandHandler(
      catalog: catalog,
      bridge: bridge,
      broadcastFamilyEvent: broadcasts.add,
    );
  });

  tearDown(() async {
    await SecretVaults.closeAll();
    setSanadHomeOverride(null);
    setSanadStateHomeOverride(null);
    state.dispose();
    if (root.existsSync()) root.deleteSync(recursive: true);
    final getIt = GetIt.instance;
    if (getIt.isRegistered<AuthManager>()) {
      getIt.unregister<AuthManager>();
    }
  });

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

  CanonicalEvent listEvent({
    String? requestId = 'req-list-1',
    CommandAuthority authority = CommandAuthority.owner,
    Map<String, dynamic> extra = const {},
  }) {
    return CanonicalEvent(
      type: CanonicalEventTypes.secretsList,
      payload: {
        'request_id': ?requestId,
        CommandAuthority.payloadKey: authority.value,
        ...extra,
      },
    );
  }

  CanonicalEvent setEvent({
    String? requestId = 'req-set-1',
    required String name,
    required String value,
    String? description,
    CommandAuthority authority = CommandAuthority.owner,
    Map<String, dynamic> extra = const {},
  }) {
    return CanonicalEvent(
      type: CanonicalEventTypes.secretSet,
      payload: {
        'request_id': ?requestId,
        CommandAuthority.payloadKey: authority.value,
        'name': name,
        'value': value,
        'description': ?description,
        ...extra,
      },
    );
  }

  CanonicalEvent deleteEvent({
    String? requestId = 'req-del-1',
    required String name,
    bool? confirm = true,
    CommandAuthority authority = CommandAuthority.owner,
    Map<String, dynamic> extra = const {},
  }) {
    return CanonicalEvent(
      type: CanonicalEventTypes.secretDelete,
      payload: {
        'request_id': ?requestId,
        CommandAuthority.payloadKey: authority.value,
        'name': name,
        'confirm': ?confirm,
        ...extra,
      },
    );
  }

  Map<String, dynamic> payloadOf(Map<String, dynamic> envelope) =>
      envelope['payload'] as Map<String, dynamic>;

  group('secrets.list (Commands & Projection)', () {
    test('returns empty secrets list when no secrets exist', () async {
      final envelope = await handler.buildListEnvelope(listEvent());

      expect(envelope['type'], 'event');
      expect(envelope['event'], CanonicalEventTypes.secretsListResult);
      expect(envelope['request_id'], 'req-list-1');
      final payload = payloadOf(envelope);
      expect(payload['request_id'], 'req-list-1');
      expect(payload['secrets'], isEmpty);
      expect(payload['truncated'], isFalse);
    });

    test('returns joined metadata and is structurally value-free', () async {
      await handler.buildSetEnvelope(
        setEvent(
          name: 'DATABASE_PASSWORD',
          value: canary,
          description: 'Staging database password',
        ),
      );

      final envelope = await handler.buildListEnvelope(listEvent());

      expect(envelope['event'], CanonicalEventTypes.secretsListResult);
      final payload = payloadOf(envelope);
      final secrets = payload['secrets'] as List;
      expect(secrets, hasLength(1));

      final first = secrets.first as Map<String, dynamic>;
      expect(first['name'], 'DATABASE_PASSWORD');
      expect(first['description'], 'Staging database password');
      expect(first['source'], 'user');
      expect(first['created_at'], isNotEmpty);
      expect(first['updated_at'], isNotEmpty);

      // Verify no value appears in the list projection
      final serialized = jsonEncode(payload);
      expect(serialized, isNot(contains(canary)));
      expect(serialized, isNot(contains(canary.substring(0, 8))));
      expect(first.containsKey('value'), isFalse);
    });

    test('repairs missing metadata row on read with source=agent_request', () async {
      // Seed directly into the vault without metadata
      await vaults.put(vaults.custom, {'LEGACY_SECRET': 'legacy_val'});

      final envelope = await handler.buildListEnvelope(listEvent());
      final secrets = payloadOf(envelope)['secrets'] as List;
      expect(secrets, hasLength(1));
      final first = secrets.first as Map<String, dynamic>;
      expect(first['name'], 'LEGACY_SECRET');
      expect(first['source'], 'agent_request');
      expect(first['description'], isNull);
      expect(first['created_at'], isNotEmpty);
      expect(first['updated_at'], isNotEmpty);
    });

    test('prunes orphan metadata rows whose vault entry is gone', () async {
      metadata.recordValue(
        name: 'ORPHAN_SECRET',
        description: 'orphan',
        source: UserSecretSource.user,
      );

      final envelope = await handler.buildListEnvelope(listEvent());
      final secrets = payloadOf(envelope)['secrets'] as List;
      expect(secrets, isEmpty);
      expect(metadata.find('ORPHAN_SECRET'), isNull);
    });
  });

  group('secret.set (Add, Replace, and Broadcast)', () {
    test('adds a secret, returns metadata, and broadcasts secrets.changed', () async {
      final envelope = await handler.buildSetEnvelope(
        setEvent(
          name: 'DATABASE_PASSWORD',
          value: canary,
          description: 'Production DB',
        ),
      );

      expect(envelope['type'], 'event');
      expect(envelope['event'], CanonicalEventTypes.secretSaved);
      expect(envelope['request_id'], 'req-set-1');
      final payload = payloadOf(envelope);
      expect(payload['name'], 'DATABASE_PASSWORD');
      expect(payload['description'], 'Production DB');
      expect(payload['source'], 'user');
      expect(payload['created_at'], isNotEmpty);
      expect(payload['updated_at'], isNotEmpty);
      expect(payload.containsKey('value'), isFalse);

      // Value was stored in vault
      expect(store.values['custom:DATABASE_PASSWORD'], canary);

      // Broadcast was emitted
      expect(broadcasts, hasLength(1));
      final broadcast = broadcasts.single;
      expect(broadcast.type, CanonicalEventTypes.secretsChanged);
      expect(broadcast.payload['name'], 'DATABASE_PASSWORD');
      expect(broadcast.payload['change'], 'set');
      expect(broadcast.payload.containsKey('value'), isFalse);
    });

    test('replaces an existing secret, advances updated_at, keeps source=user', () async {
      final first = await handler.buildSetEnvelope(
        setEvent(
          name: 'API_TOKEN',
          value: 'old_value_123',
          description: 'Initial token',
        ),
      );
      final firstUpdatedAt = payloadOf(first)['updated_at'] as String;

      await Future<void>.delayed(const Duration(milliseconds: 10));

      final second = await handler.buildSetEnvelope(
        setEvent(
          name: 'API_TOKEN',
          value: canary,
          description: 'Rotated token',
        ),
      );

      expect(payloadOf(second)['name'], 'API_TOKEN');
      expect(payloadOf(second)['description'], 'Rotated token');
      expect(payloadOf(second)['source'], 'user');
      final secondUpdatedAt = payloadOf(second)['updated_at'] as String;
      expect(DateTime.parse(secondUpdatedAt).isAfter(DateTime.parse(firstUpdatedAt)), isTrue);
      expect(store.values['custom:API_TOKEN'], canary);

      expect(broadcasts, hasLength(2));
      expect(broadcasts[1].payload['name'], 'API_TOKEN');
      expect(broadcasts[1].payload['change'], 'set');
    });

    test('clears description when whitespace-only or null', () async {
      final envelope = await handler.buildSetEnvelope(
        setEvent(
          name: 'TOKEN_NO_DESC',
          value: canary,
          description: '   ',
        ),
      );

      expect(payloadOf(envelope)['description'], isNull);
    });
  });

  group('secret.delete (Deletion, Status, and Broadcast)', () {
    test('deletes existing secret and broadcasts secrets.changed', () async {
      await handler.buildSetEnvelope(
        setEvent(name: 'EXPIRED_KEY', value: canary),
      );
      broadcasts.clear();

      final envelope = await handler.buildDeleteEnvelope(
        deleteEvent(name: 'EXPIRED_KEY'),
      );

      expect(envelope['type'], 'event');
      expect(envelope['event'], CanonicalEventTypes.secretDeleted);
      expect(envelope['request_id'], 'req-del-1');
      final payload = payloadOf(envelope);
      expect(payload['name'], 'EXPIRED_KEY');
      expect(payload['status'], 'deleted');

      // Removed from vault and metadata
      expect(store.values.containsKey('custom:EXPIRED_KEY'), isFalse);
      expect(metadata.find('EXPIRED_KEY'), isNull);

      // Broadcast was emitted
      expect(broadcasts, hasLength(1));
      expect(broadcasts.single.type, CanonicalEventTypes.secretsChanged);
      expect(broadcasts.single.payload['name'], 'EXPIRED_KEY');
      expect(broadcasts.single.payload['change'], 'deleted');
    });

    test('deleting non-existent secret reports not_found and does NOT broadcast', () async {
      final envelope = await handler.buildDeleteEnvelope(
        deleteEvent(name: 'NON_EXISTENT_KEY'),
      );

      expect(envelope['event'], CanonicalEventTypes.secretDeleted);
      final payload = payloadOf(envelope);
      expect(payload['name'], 'NON_EXISTENT_KEY');
      expect(payload['status'], 'not_found');

      expect(broadcasts, isEmpty);
    });
  });

  group('Authority validation (Owner only)', () {
    test('rejects unverified authority on secrets.list', () async {
      final envelope = await handler.buildListEnvelope(
        listEvent(authority: CommandAuthority.unverified),
      );

      expect(envelope['event'], 'error');
      final payload = payloadOf(envelope);
      expect(payload['code'], 'permission_denied');
      expect(broadcasts, isEmpty);
    });

    test('rejects unverified authority on secret.set', () async {
      final envelope = await handler.buildSetEnvelope(
        setEvent(
          name: 'DENIED_KEY',
          value: canary,
          authority: CommandAuthority.unverified,
        ),
      );

      expect(envelope['event'], 'error');
      final payload = payloadOf(envelope);
      expect(payload['code'], 'permission_denied');
      expect(store.values.containsKey('custom:DENIED_KEY'), isFalse);
      expect(broadcasts, isEmpty);
    });

    test('rejects unverified authority on secret.delete', () async {
      await handler.buildSetEnvelope(
        setEvent(name: 'SAFE_KEY', value: canary),
      );
      broadcasts.clear();

      final envelope = await handler.buildDeleteEnvelope(
        deleteEvent(
          name: 'SAFE_KEY',
          authority: CommandAuthority.unverified,
        ),
      );

      expect(envelope['event'], 'error');
      final payload = payloadOf(envelope);
      expect(payload['code'], 'permission_denied');
      expect(store.values.containsKey('custom:SAFE_KEY'), isTrue);
      expect(broadcasts, isEmpty);
    });
  });

  group('Request validation and Error codes', () {
    test('rejects unknown fields on secrets.list', () async {
      final envelope = await handler.buildListEnvelope(
        listEvent(extra: {'unknown_field': 'bad'}),
      );

      expect(envelope['event'], 'error');
      expect(payloadOf(envelope)['code'], 'invalid_request');
    });

    test('rejects unknown fields on secret.set mutating nothing', () async {
      final envelope = await handler.buildSetEnvelope(
        setEvent(
          name: 'NEW_KEY',
          value: canary,
          extra: {'unexpected': 'mutation'},
        ),
      );

      expect(envelope['event'], 'error');
      expect(payloadOf(envelope)['code'], 'invalid_request');
      expect(store.values.containsKey('custom:NEW_KEY'), isFalse);
      expect(broadcasts, isEmpty);
    });

    test('rejects unknown fields on secret.delete mutating nothing', () async {
      await handler.buildSetEnvelope(setEvent(name: 'KEEP_KEY', value: canary));
      broadcasts.clear();

      final envelope = await handler.buildDeleteEnvelope(
        deleteEvent(
          name: 'KEEP_KEY',
          extra: {'extra_param': 123},
        ),
      );

      expect(envelope['event'], 'error');
      expect(payloadOf(envelope)['code'], 'invalid_request');
      expect(store.values.containsKey('custom:KEEP_KEY'), isTrue);
      expect(broadcasts, isEmpty);
    });

    test('rejects missing or non-string name on secret.set', () async {
      final envelope = await handler.buildSetEnvelope(
        CanonicalEvent(
          type: CanonicalEventTypes.secretSet,
          payload: {
            'request_id': 'req-bad-name',
            CommandAuthority.payloadKey: 'owner',
            'value': 'val',
          },
        ),
      );
      expect(payloadOf(envelope)['code'], 'invalid_request');

      final envelope2 = await handler.buildSetEnvelope(
        CanonicalEvent(
          type: CanonicalEventTypes.secretSet,
          payload: {
            'request_id': 'req-bad-name-2',
            CommandAuthority.payloadKey: 'owner',
            'name': 123,
            'value': 'val',
          },
        ),
      );
      expect(payloadOf(envelope2)['code'], 'invalid_request');
    });

    test('rejects missing or non-string value on secret.set', () async {
      final envelope = await handler.buildSetEnvelope(
        CanonicalEvent(
          type: CanonicalEventTypes.secretSet,
          payload: {
            'request_id': 'req-bad-val',
            CommandAuthority.payloadKey: 'owner',
            'name': 'API_KEY',
          },
        ),
      );
      expect(payloadOf(envelope)['code'], 'invalid_request');

      final envelope2 = await handler.buildSetEnvelope(
        CanonicalEvent(
          type: CanonicalEventTypes.secretSet,
          payload: {
            'request_id': 'req-bad-val-2',
            CommandAuthority.payloadKey: 'owner',
            'name': 'API_KEY',
            'value': 999,
          },
        ),
      );
      expect(payloadOf(envelope2)['code'], 'invalid_request');
    });

    test('rejects non-boolean or false confirm on secret.delete', () async {
      final envelope = await handler.buildDeleteEnvelope(
        deleteEvent(name: 'API_KEY', confirm: null),
      );
      expect(payloadOf(envelope)['code'], 'invalid_request');

      final envelope2 = await handler.buildDeleteEnvelope(
        deleteEvent(name: 'API_KEY', confirm: false),
      );
      expect(payloadOf(envelope2)['code'], 'invalid_request');
    });

    test('rejects invalid secret names with invalid_secret_name', () async {
      for (final invalid in ['1ABC', 'A-B', '', 'bad name!']) {
        final setRes = await handler.buildSetEnvelope(
          setEvent(name: invalid, value: canary),
        );
        expect(payloadOf(setRes)['code'], 'invalid_secret_name', reason: invalid);

        final delRes = await handler.buildDeleteEnvelope(
          deleteEvent(name: invalid),
        );
        expect(payloadOf(delRes)['code'], 'invalid_secret_name', reason: invalid);
      }
    });

    test('rejects reserved secret names with reserved_secret_name', () async {
      for (final reserved in ['PATH', 'OPENAI_API_KEY', 'SANAD_HOME']) {
        final setRes = await handler.buildSetEnvelope(
          setEvent(name: reserved, value: canary),
        );
        expect(payloadOf(setRes)['code'], 'reserved_secret_name', reason: reserved);

        final delRes = await handler.buildDeleteEnvelope(
          deleteEvent(name: reserved),
        );
        expect(payloadOf(delRes)['code'], 'reserved_secret_name', reason: reserved);
      }
    });

    test('rejects invalid secret values with invalid_secret_value', () async {
      // Empty value
      final emptyRes = await handler.buildSetEnvelope(
        setEvent(name: 'API_KEY', value: ''),
      );
      expect(payloadOf(emptyRes)['code'], 'invalid_secret_value');

      // Value too long
      final longRes = await handler.buildSetEnvelope(
        setEvent(
          name: 'API_KEY',
          value: 'x' * (UserSecretVault.maxValueLength + 1),
        ),
      );
      expect(payloadOf(longRes)['code'], 'invalid_secret_value');

      // Redaction sentinel
      final sentinelRes = await handler.buildSetEnvelope(
        setEvent(name: 'API_KEY', value: '[REDACTED:API_KEY]'),
      );
      expect(payloadOf(sentinelRes)['code'], 'invalid_secret_value');
    });

    test('rejects oversized description on secret.set with invalid_request', () async {
      final envelope = await handler.buildSetEnvelope(
        setEvent(
          name: 'API_KEY',
          value: canary,
          description: 'a' * 257,
        ),
      );

      expect(payloadOf(envelope)['code'], 'invalid_request');
      expect(store.values.containsKey('custom:API_KEY'), isFalse);
    });

    test('reports vault_unavailable when vault store fails', () async {
      await SecretVaults.closeAll();
      // Reopen with corrupt writes to simulate store failure
      store.corruptWrites = true;
      vaults = await SecretVaults.open(store: store);
      userSecrets = UserSecretVault(vaults: () => vaults);
      catalog = UserSecretCatalog(vault: userSecrets, metadata: metadata);
      handler = SecretCommandHandler(
        catalog: catalog,
        bridge: bridge,
        broadcastFamilyEvent: broadcasts.add,
      );

      final envelope = await handler.buildSetEnvelope(
        setEvent(name: 'FAIL_VAULT', value: canary),
      );

      expect(payloadOf(envelope)['code'], 'vault_unavailable');
    });
  });

  group('Security & Sentinel canary assertions (Security)', () {
    test('canary value NEVER appears in logs, responses, or broadcasts on set', () async {
      late Map<String, dynamic> responseEnvelope;

      await captureLogs(() async {
        responseEnvelope = await handler.buildSetEnvelope(
          setEvent(
            name: 'CANARY_TEST_SECRET',
            value: canary,
            description: 'Canary test description',
          ),
        );
      });

      // 1. Response envelope check
      final responseJson = jsonEncode(responseEnvelope);
      expect(responseJson, isNot(contains(canary)));
      expect(responseJson, isNot(contains(canary.substring(0, 8))));

      // 2. Broadcast payload check
      expect(broadcasts, hasLength(1));
      final broadcastJson = jsonEncode(broadcasts.first.payload);
      expect(broadcastJson, isNot(contains(canary)));
      expect(broadcastJson, isNot(contains(canary.substring(0, 8))));

      // 3. Log transcript check
      final logTranscript = logged.join('\n');
      expect(logTranscript, contains('CANARY_TEST_SECRET'));
      expect(logTranscript, isNot(contains(canary)));
      expect(logTranscript, isNot(contains(canary.substring(0, 8))));
    });

    test('canary value NEVER appears in error responses or logs on failing paths', () async {
      await captureLogs(() async {
        // Attempt set with reserved name + canary value
        final err1 = await handler.buildSetEnvelope(
          setEvent(name: 'PATH', value: canary),
        );
        expect(jsonEncode(err1), isNot(contains(canary)));

        // Attempt set with invalid name + canary value
        final err2 = await handler.buildSetEnvelope(
          setEvent(name: '1_INVALID', value: canary),
        );
        expect(jsonEncode(err2), isNot(contains(canary)));

        // Attempt set with oversized description + canary value
        final err3 = await handler.buildSetEnvelope(
          setEvent(name: 'GOOD_NAME', value: canary, description: 'z' * 300),
        );
        expect(jsonEncode(err3), isNot(contains(canary)));

        // Attempt set with unverified authority + canary value
        final err4 = await handler.buildSetEnvelope(
          setEvent(
            name: 'UNVERIFIED_KEY',
            value: canary,
            authority: CommandAuthority.unverified,
          ),
        );
        expect(jsonEncode(err4), isNot(contains(canary)));
      });

      final logTranscript = logged.join('\n');
      expect(logTranscript, isNot(contains(canary)));
      expect(logTranscript, isNot(contains(canary.substring(0, 8))));
    });

    test('canary value never reaches request_dumps or state database', () async {
      await handler.buildSetEnvelope(
        setEvent(name: 'DUMP_SCAN_KEY', value: canary),
      );

      final dumps = Directory('${root.path}/home/request_dumps');
      if (dumps.existsSync()) {
        for (final entity in dumps.listSync(recursive: true)) {
          if (entity is! File) continue;
          expect(
            entity.readAsStringSync(),
            isNot(contains(canary)),
            reason: '${entity.path} must not contain canary',
          );
        }
      }

      final storedDb = state.db
          .select('SELECT * FROM user_secret_metadata')
          .map((row) => Map<String, dynamic>.from(row).values.join('|'))
          .join('\n');
      expect(storedDb, isNot(contains(canary)));
      expect(storedDb, isNot(contains(canary.substring(0, 8))));
    });
  });

  group('Bridge dispatch integration (handle & handleCommand)', () {
    test('handler.handle dispatches secrets.list, secret.set, secret.delete', () async {
      final emitted = <Map<String, dynamic>>[];

      await handler.handle(
        setEvent(name: 'BRIDGE_KEY', value: canary, description: 'desc'),
        (env) async => emitted.add(env),
      );
      expect(emitted, hasLength(1));
      expect(emitted.first['event'], CanonicalEventTypes.secretSaved);

      await handler.handle(
        listEvent(),
        (env) async => emitted.add(env),
      );
      expect(emitted, hasLength(2));
      expect(emitted[1]['event'], CanonicalEventTypes.secretsListResult);

      await handler.handle(
        deleteEvent(name: 'BRIDGE_KEY'),
        (env) async => emitted.add(env),
      );
      expect(emitted, hasLength(3));
      expect(emitted[2]['event'], CanonicalEventTypes.secretDeleted);
    });

    test('bridge.handleCommand dispatches wire commands to the handler', () async {
      bridge.setSecretCommandHandlerForTesting(handler);
      final emitted = <Map<String, dynamic>>[];

      // 1. secret.set
      final setHandled = await bridge.handleCommand({
        'command': CanonicalEventTypes.secretSet,
        'payload': {
          'request_id': 'cmd-set-1',
          'name': 'WIRE_KEY',
          'value': canary,
          'description': 'wire desc',
          CommandAuthority.payloadKey: 'owner',
        },
      }, (env) async => emitted.add(env));

      expect(setHandled, isTrue);
      expect(emitted, hasLength(1));
      expect(emitted.first['event'], CanonicalEventTypes.secretSaved);
      expect(payloadOf(emitted.first)['name'], 'WIRE_KEY');

      // 2. secrets.list
      final listHandled = await bridge.handleCommand({
        'command': CanonicalEventTypes.secretsList,
        'payload': {
          'request_id': 'cmd-list-1',
          CommandAuthority.payloadKey: 'owner',
        },
      }, (env) async => emitted.add(env));

      expect(listHandled, isTrue);
      expect(emitted, hasLength(2));
      expect(emitted[1]['event'], CanonicalEventTypes.secretsListResult);
      final secrets = payloadOf(emitted[1])['secrets'] as List;
      expect(secrets, hasLength(1));
      expect((secrets.first as Map)['name'], 'WIRE_KEY');

      // 3. secret.delete
      final deleteHandled = await bridge.handleCommand({
        'command': CanonicalEventTypes.secretDelete,
        'payload': {
          'request_id': 'cmd-del-1',
          'name': 'WIRE_KEY',
          'confirm': true,
          CommandAuthority.payloadKey: 'owner',
        },
      }, (env) async => emitted.add(env));

      expect(deleteHandled, isTrue);
      expect(emitted, hasLength(3));
      expect(emitted[2]['event'], CanonicalEventTypes.secretDeleted);
      expect(payloadOf(emitted[2])['status'], 'deleted');
    });
  });
}
