import 'dart:io';

import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/core/provider_runtime/provider_protocol_constants.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/session_db.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

ProviderInstance _instance({
  required String id,
  String templateId = 'openai',
  String displayName = 'OpenAI',
  String protocol = ProviderProtocol.openaiCompatible,
  String authMethod = ProviderAuthMethod.apiKey,
  String? baseUrl,
  String? defaultModel,
  String status = InstanceStatus.ready,
  bool isDefault = false,
  DateTime? createdAt,
}) {
  final now = createdAt ?? DateTime.utc(2025, 1, 1);
  return ProviderInstance(
    id: id,
    templateId: templateId,
    displayName: displayName,
    protocol: protocol,
    authMethod: authMethod,
    baseUrl: baseUrl,
    defaultModel: defaultModel,
    status: status,
    isDefault: isDefault,
    createdAt: now,
    updatedAt: now,
  );
}

void main() {
  late AgentStateDatabase state;
  late ProviderInstanceRepository repo;

  setUp(() {
    state = AgentStateDatabase.inMemory();
    repo = ProviderInstanceRepository.fromDatabase(state.db);
  });

  tearDown(() {
    state.dispose();
  });

  group('ProviderInstanceRepository', () {
    test('createInstance and findById round-trip successfully', () {
      final inst = _instance(id: 'inst-1', displayName: 'OpenAI Work');
      repo.createInstance(inst);

      final found = repo.findById('inst-1');
      expect(found, isNotNull);
      expect(found!.id, equals('inst-1'));
      expect(found.displayName, equals('OpenAI Work'));
      expect(found.templateId, equals('openai'));
      expect(found.protocol, equals(ProviderProtocol.openaiCompatible));
    });

    test('findAll returns all instances ordered by newest first', () {
      repo.createInstance(
        _instance(id: 'a', displayName: 'A', createdAt: DateTime.utc(2025, 1, 1)),
      );
      repo.createInstance(
        _instance(id: 'b', displayName: 'B', createdAt: DateTime.utc(2025, 1, 2)),
      );

      final all = repo.findAll();
      expect(all.length, equals(2));
      expect(all.first.id, equals('b'));
      expect(all.last.id, equals('a'));
    });

    test('findByTemplate returns only matching template instances', () {
      repo.createInstance(
        _instance(id: 'a', templateId: 'openai', displayName: 'OpenAI'),
      );
      repo.createInstance(
        _instance(
          id: 'b',
          templateId: 'anthropic',
          displayName: 'Anthropic',
          protocol: ProviderProtocol.anthropicCompatible,
        ),
      );

      expect(repo.findByTemplate('openai').length, equals(1));
      expect(repo.findByTemplate('anthropic').first.id, equals('b'));
    });

    test('unknown id returns null (fail-closed, no fallback)', () {
      expect(repo.findById('does-not-exist'), isNull);
    });
  });

  group('multiple instances from one template', () {
    test('two instances from openai template are independent', () {
      repo.createInstance(
        _instance(
          id: 'work',
          templateId: 'openai',
          displayName: 'OpenAI Work',
          baseUrl: 'https://api.openai.com/v1',
          defaultModel: 'gpt-4o',
        ),
      );
      repo.createInstance(
        _instance(
          id: 'personal',
          templateId: 'openai',
          displayName: 'OpenAI Personal',
          baseUrl: 'https://api.openai.com/v1',
          defaultModel: 'gpt-4o-mini',
        ),
      );

      final work = repo.findById('work')!;
      final personal = repo.findById('personal')!;
      expect(work.id, isNot(equals(personal.id)));
      expect(work.displayName, equals('OpenAI Work'));
      expect(personal.displayName, equals('OpenAI Personal'));
      expect(work.defaultModel, equals('gpt-4o'));
      expect(personal.defaultModel, equals('gpt-4o-mini'));
    });
  });

  group('rename preserves identity', () {
    test('renaming keeps the same UUID and updates the name', () {
      repo.createInstance(_instance(id: 'r1', displayName: 'OpenAI'));
      final before = repo.findById('r1')!;
      expect(before.displayName, equals('OpenAI'));

      final renamed = before.copyWith(
        displayName: 'OpenAI Work',
        updatedAt: DateTime.utc(2025, 1, 2),
      );
      repo.update(renamed);

      final after = repo.findById('r1')!;
      expect(after.id, equals('r1'));
      expect(after.displayName, equals('OpenAI Work'));
      expect(after.templateId, equals(before.templateId));
    });
  });

  group('default constraint', () {
    test('at most one instance is default after setDefault', () {
      repo.createInstance(_instance(id: 'a', displayName: 'A'));
      repo.createInstance(_instance(id: 'b', displayName: 'B'));

      repo.setDefault('a');
      expect(repo.findDefault()!.id, equals('a'));

      repo.setDefault('b');
      final defaults = repo.findAll().where((i) => i.isDefault).toList();
      expect(defaults.length, equals(1));
      expect(defaults.first.id, equals('b'));
    });

    test(
      'setDefault on unknown id throws and does not clear existing default',
      () {
        repo.createInstance(
          _instance(id: 'a', displayName: 'A', isDefault: true),
        );

        expect(() => repo.setDefault('nope'), throwsStateError);
        expect(repo.findDefault()!.id, equals('a'));
      },
    );

    test('clearDefault removes the default flag', () {
      repo.createInstance(
        _instance(id: 'a', displayName: 'A', isDefault: true),
      );
      repo.clearDefault();
      expect(repo.findDefault(), isNull);
    });

    test('DB rejects a second default even when bypassing setDefault', () {
      repo.createInstance(
        _instance(id: 'a', displayName: 'A', isDefault: true),
      );
      // Attempt to insert a second default row directly (bypassing setDefault).
      expect(
        () => repo.createInstance(
          _instance(id: 'b', displayName: 'B', isDefault: true),
        ),
        throwsA(isA<SqliteException>()),
      );
    });

    test('update to is_default=1 on a second row is rejected by the DB', () {
      repo.createInstance(
        _instance(id: 'a', displayName: 'A', isDefault: true),
      );
      repo.createInstance(
        _instance(id: 'b', displayName: 'B', isDefault: false),
      );
      final bumped = repo.findById('b')!.copyWith(isDefault: true);
      expect(() => repo.update(bumped), throwsA(isA<SqliteException>()));
    });
  });

  group('display name uniqueness', () {
    test('duplicate name (case-insensitive) is detected', () {
      repo.createInstance(_instance(id: 'a', displayName: 'OpenAI'));
      expect(repo.isDisplayNameTaken('OpenAI'), isTrue);
      expect(repo.isDisplayNameTaken('openai'), isTrue);
      expect(repo.isDisplayNameTaken('OPENAI'), isTrue);
    });

    test('excludeId ignores the owning instance during rename', () {
      repo.createInstance(_instance(id: 'a', displayName: 'OpenAI'));
      expect(repo.isDisplayNameTaken('OpenAI', excludeId: 'a'), isFalse);
    });

    test('distinct names are allowed', () {
      repo.createInstance(_instance(id: 'a', displayName: 'OpenAI Work'));
      expect(repo.isDisplayNameTaken('OpenAI Personal'), isFalse);
    });
  });

  group('delete cascade', () {
    test('deleting an instance removes it and its cache + recent rows', () {
      repo.createInstance(_instance(id: 'a', displayName: 'A'));
      repo.upsertModelCache(
        instanceId: 'a',
        cacheKey: 'default',
        models: ['gpt-4o'],
        fetchedAt: DateTime.utc(2025, 1, 1),
        source: 'live',
        configRevision: 1,
        credentialRevision: 1,
      );
      repo.recordRecentSelection(
        instanceId: 'a',
        modelId: 'gpt-4o',
        selectedAt: DateTime.utc(2025, 1, 1),
      );

      repo.delete('a');

      expect(repo.findById('a'), isNull);
      expect(repo.readModelCache('a', 'default'), isNull);
      expect(repo.recentSelections(), isEmpty);
    });

    test('deleting one instance leaves others untouched', () {
      repo.createInstance(_instance(id: 'a', displayName: 'A'));
      repo.createInstance(_instance(id: 'b', displayName: 'B'));
      repo.delete('a');
      expect(repo.findById('a'), isNull);
      expect(repo.findById('b'), isNotNull);
    });
  });

  group('model cache', () {
    test('upsert then read round-trips models', () {
      repo.createInstance(_instance(id: 'a', displayName: 'A'));
      repo.upsertModelCache(
        instanceId: 'a',
        cacheKey: 'default',
        models: ['gpt-4o', 'o1-mini'],
        fetchedAt: DateTime.utc(2025, 1, 1),
        source: 'live',
        endpointFingerprint: 'fp1',
        configRevision: 1,
        credentialRevision: 1,
      );

      final cached = repo.readModelCache('a', 'default')!;
      expect(cached['models'], equals(['gpt-4o', 'o1-mini']));
      expect(cached['source'], equals('live'));
      expect(cached['endpoint_fingerprint'], equals('fp1'));
    });

    test('upsert overwrites a previous successful cache entry', () {
      repo.createInstance(_instance(id: 'a', displayName: 'A'));
      repo.upsertModelCache(
        instanceId: 'a',
        cacheKey: 'default',
        models: ['old'],
        fetchedAt: DateTime.utc(2025, 1, 1),
        source: 'live',
        configRevision: 1,
        credentialRevision: 1,
      );
      repo.upsertModelCache(
        instanceId: 'a',
        cacheKey: 'default',
        models: ['new1', 'new2'],
        fetchedAt: DateTime.utc(2025, 1, 2),
        source: 'live',
        configRevision: 1,
        credentialRevision: 1,
      );

      expect(
        (repo.readModelCache('a', 'default')!['models'] as List).length,
        equals(2),
      );
    });
  });

  group('recent selections', () {
    test('upserting the same pair bumps it to the top', () {
      repo.createInstance(_instance(id: 'a', displayName: 'OpenAI'));
      repo.createInstance(_instance(id: 'b', displayName: 'Anthropic'));

      repo.recordRecentSelection(
        instanceId: 'a',
        modelId: 'gpt-4o',
        selectedAt: DateTime.utc(2025, 1, 1),
      );
      repo.recordRecentSelection(
        instanceId: 'b',
        modelId: 'claude',
        selectedAt: DateTime.utc(2025, 1, 2),
      );
      repo.recordRecentSelection(
        instanceId: 'a',
        modelId: 'gpt-4o',
        selectedAt: DateTime.utc(2025, 1, 3),
      );

      final recent = repo.recentSelections();
      expect(recent.first['instance_id'], equals('a'));
      expect(recent.length, equals(2));
    });

    test('recent is capped at the requested limit', () {
      for (var i = 0; i < 8; i++) {
        repo.createInstance(_instance(id: 'i$i', displayName: 'I$i'));
        repo.recordRecentSelection(
          instanceId: 'i$i',
          modelId: 'm$i',
          selectedAt: DateTime.utc(2025, 1, i + 1),
        );
      }
      expect(repo.recentSelections(limit: 5).length, equals(5));
    });

    test('recent reflects current display name after rename', () {
      repo.createInstance(_instance(id: 'a', displayName: 'Old Name'));
      repo.recordRecentSelection(
        instanceId: 'a',
        modelId: 'gpt-4o',
        selectedAt: DateTime.utc(2025, 1, 1),
      );

      repo.update(repo.findById('a')!.copyWith(displayName: 'New Name'));

      final recent = repo.recentSelections();
      expect(recent.first['instance_display_name'], equals('New Name'));
    });
  });

  group('revisions', () {
    test('config/credential revisions persist', () {
      repo.createInstance(_instance(id: 'a', displayName: 'A'));
      final bumped = repo
          .findById('a')!
          .copyWith(configRevision: 3, credentialRevision: 5);
      repo.update(bumped);

      final found = repo.findById('a')!;
      expect(found.configRevision, equals(3));
      expect(found.credentialRevision, equals(5));
    });
  });

  // ── Plan 29 storage-correction verification (state.db, not providers.db) ─
  group('Plan 29 storage lives inside state.db (not providers.db)', () {
    late Directory tempHome;

    setUp(() async {
      tempHome = await Directory.systemTemp.createTemp('sanad-state-db-test');
      setSanadStateHomeOverride(tempHome.path);
    });

    tearDown(() async {
      setSanadStateHomeOverride(null);
      if (tempHome.existsSync()) await tempHome.delete(recursive: true);
    });

    test('provider tables are created inside state.db', () {
      final stateDb = AgentStateDatabase();
      try {
        final tables = stateDb.db
            .select(
              "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name",
            )
            .map((r) => r['name'] as String)
            .toSet();
        expect(tables, contains('provider_instances'));
        expect(tables, contains('provider_model_cache'));
        expect(tables, contains('recent_model_selections'));
      } finally {
        stateDb.dispose();
      }
    });

    test(
      'opening AgentStateDatabase creates only state.db, never providers.db',
      () {
        final stateDb = AgentStateDatabase();
        try {
          final stateDbFile = File(p.join(tempHome.path, 'state.db'));
          expect(
            stateDbFile.existsSync(),
            isTrue,
            reason: 'state.db must exist',
          );
          final providersDbFile = File(p.join(tempHome.path, 'providers.db'));
          expect(
            providersDbFile.existsSync(),
            isFalse,
            reason: 'providers.db must NOT be created',
          );
        } finally {
          stateDb.dispose();
        }
        // After dispose, still no providers.db.
        expect(
          File(p.join(tempHome.path, 'providers.db')).existsSync(),
          isFalse,
        );
      },
    );

    test('partial unique index exists and guards a single default', () {
      final stateDb = AgentStateDatabase();
      try {
        final indexes = stateDb.db
            .select(
              "SELECT name FROM sqlite_master WHERE type='index' AND name='idx_provider_single_default'",
            )
            .map((r) => r['name'] as String)
            .toList();
        expect(indexes, contains('idx_provider_single_default'));
      } finally {
        stateDb.dispose();
      }
    });

    test('provider tables contain no secret-bearing columns', () {
      final stateDb = AgentStateDatabase();
      try {
        // Columns that would indicate raw secret storage. The `*_revision`
        // columns are counters (config_revision, credential_revision), not
        // secrets — they track when the adapter/cache must be rebuilt.
        const forbiddenSubstrings = <String>[
          'secret',
          'token',
          'api_key',
          'apikey',
          'password',
          'passwd',
          'access_token',
          'refresh_token',
        ];
        for (final table in [
          'provider_instances',
          'provider_model_cache',
          'recent_model_selections',
        ]) {
          final cols = stateDb.db
              .select('PRAGMA table_info($table)')
              .map((r) => r['name'] as String)
              .toList();
          for (final col in cols) {
            final lower = col.toLowerCase();
            for (final bad in forbiddenSubstrings) {
              expect(
                lower,
                isNot(contains(bad)),
                reason: '$table.$col must not store a secret',
              );
            }
          }
        }
      } finally {
        stateDb.dispose();
      }
    });

    test('SessionDB and ProviderInstanceRepository share one state.db', () {
      final shared = AgentStateDatabase();
      try {
        final sessionDb = SessionDB.fromState(shared);
        final repo = ProviderInstanceRepository.fromDatabase(shared.db);
        repo.createInstance(_instance(id: 'shared', displayName: 'Shared'));
        // Both see the same underlying db file and tables.
        expect(repo.findById('shared'), isNotNull);
        // The sessions table is also writable through the same connection.
        expect(() => sessionDb.getAllSessions(), returnsNormally);
      } finally {
        shared.dispose();
      }
    });
  });
}
