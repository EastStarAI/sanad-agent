import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/provider_runtime/provider_auth_session_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_credential_store.dart';
import 'package:sanad_agent/core/provider_runtime/provider_credential_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_protocol_constants.dart';
import 'package:sanad_agent/core/provider_runtime/secret_record.dart';
import 'package:sanad_agent/core/provider_runtime/secure_file_secret_store.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/engine/adapters/provider_registry.dart';

void main() {
  late AgentStateDatabase state;
  late ProviderInstanceRepository repo;
  late ProviderInstanceService instanceService;
  late SecureFileSecretStore secrets;

  setUp(() {
    state = AgentStateDatabase.inMemory();
    repo = ProviderInstanceRepository.fromDatabase(state.db);
    instanceService = ProviderInstanceService(repo);
  });

  tearDown(() {
    state.dispose();
  });

  group('ProviderInstanceService — name suggestion', () {
    test('suggests base name when free', () {
      final t = ProviderRegistry.findByNameOrAlias('openai')!;
      expect(instanceService.suggestName(t), equals('OpenAI'));
    });

    test('suggests OpenAI 2, OpenAI 3 when base taken', () {
      final t = ProviderRegistry.findByNameOrAlias('openai')!;
      instanceService.create(
        templateId: 'openai',
        displayName: 'OpenAI',
        authMethod: ProviderAuthMethod.apiKey,
      );
      expect(instanceService.suggestName(t), equals('OpenAI 2'));
      instanceService.create(
        templateId: 'openai',
        displayName: 'OpenAI 2',
        authMethod: ProviderAuthMethod.apiKey,
      );
      expect(instanceService.suggestName(t), equals('OpenAI 3'));
    });
  });

  group('ProviderInstanceService — create', () {
    test('create assigns a UUID and draft status', () {
      final inst = instanceService.create(
        templateId: 'openai',
        displayName: 'OpenAI Work',
        authMethod: ProviderAuthMethod.apiKey,
      );
      expect(inst.id, isNotEmpty);
      expect(inst.templateId, equals('openai'));
      expect(inst.status, equals(InstanceStatus.draft));
      expect(inst.protocol, equals(ProviderProtocol.openaiCompatible));
    });

    test('create rejects duplicate display name (case-insensitive)', () {
      instanceService.create(
        templateId: 'openai',
        displayName: 'OpenAI',
        authMethod: ProviderAuthMethod.apiKey,
      );
      expect(
        () => instanceService.create(
          templateId: 'openai',
          displayName: 'openai',
          authMethod: ProviderAuthMethod.apiKey,
        ),
        throwsArgumentError,
      );
    });

    test('create rejects empty display name', () {
      expect(
        () => instanceService.create(
          templateId: 'openai',
          displayName: '   ',
          authMethod: ProviderAuthMethod.apiKey,
        ),
        throwsArgumentError,
      );
    });

    test('custom requires explicit protocol + base URL', () {
      expect(
        () => instanceService.create(
          templateId: 'custom',
          displayName: 'My Gateway',
          authMethod: ProviderAuthMethod.apiKey,
        ),
        throwsArgumentError,
      );
      final inst = instanceService.create(
        templateId: 'custom',
        displayName: 'My Gateway',
        authMethod: ProviderAuthMethod.apiKey,
        protocol: ProviderProtocol.anthropicCompatible,
        baseUrl: 'https://gw.example.com/v1',
      );
      expect(inst.protocol, equals(ProviderProtocol.anthropicCompatible));
      expect(inst.baseUrl, equals('https://gw.example.com/v1'));
    });

    test('unknown template is rejected', () {
      expect(
        () => instanceService.create(
          templateId: 'no-such-template',
          displayName: 'X',
          authMethod: ProviderAuthMethod.apiKey,
        ),
        throwsArgumentError,
      );
    });

    test('rejects an auth method not advertised by the template', () {
      expect(
        () => instanceService.create(
          templateId: 'openai',
          displayName: 'Invalid OpenAI OAuth',
          authMethod: ProviderAuthMethod.deviceCode,
        ),
        throwsArgumentError,
      );
      expect(
        () => instanceService.create(
          templateId: 'openai-codex',
          displayName: 'Invalid Codex API Key',
          authMethod: ProviderAuthMethod.apiKey,
        ),
        throwsArgumentError,
      );
    });

    test('accepts the single auth method advertised by the template', () {
      final codex = instanceService.create(
        templateId: 'openai-codex',
        displayName: 'ChatGPT',
        authMethod: ProviderAuthMethod.deviceCode,
      );
      expect(codex.authMethod, equals(ProviderAuthMethod.deviceCode));
    });

    test('makeDefault marks the instance default', () {
      final inst = instanceService.create(
        templateId: 'openai',
        displayName: 'OpenAI',
        authMethod: ProviderAuthMethod.apiKey,
        makeDefault: true,
      );
      expect(instanceService.findDefault()!.id, equals(inst.id));
    });
  });

  group('ProviderInstanceService — rename preserves identity', () {
    test('rename keeps UUID, updates name, does not bump revisions', () {
      final inst = instanceService.create(
        templateId: 'openai',
        displayName: 'OpenAI',
        authMethod: ProviderAuthMethod.apiKey,
      );
      final before = instanceService.findById(inst.id)!;
      final renamed = instanceService.rename(inst.id, 'OpenAI Work');
      expect(renamed.id, equals(inst.id));
      expect(renamed.displayName, equals('OpenAI Work'));
      expect(renamed.configRevision, equals(before.configRevision));
      expect(renamed.credentialRevision, equals(before.credentialRevision));
    });

    test('rename rejects duplicate name', () {
      instanceService.create(
        templateId: 'openai',
        displayName: 'OpenAI',
        authMethod: ProviderAuthMethod.apiKey,
      );
      final b = instanceService.create(
        templateId: 'openai',
        displayName: 'OpenAI 2',
        authMethod: ProviderAuthMethod.apiKey,
      );
      expect(() => instanceService.rename(b.id, 'OpenAI'), throwsArgumentError);
    });
  });

  group('ProviderInstanceService — metadata update bumps configRevision', () {
    test('changing base URL bumps config revision', () {
      final inst = instanceService.create(
        templateId: 'custom',
        displayName: 'GW',
        authMethod: ProviderAuthMethod.apiKey,
        protocol: ProviderProtocol.openaiCompatible,
        baseUrl: 'https://gw.example.com/v1',
      );
      final updated = instanceService.updateMetadata(
        inst.id,
        baseUrl: 'https://gw2.example.com/v1',
      );
      expect(updated.configRevision, equals(inst.configRevision + 1));
    });

    test('unchanged base URL does not bump config revision', () {
      final inst = instanceService.create(
        templateId: 'openai',
        displayName: 'OpenAI',
        authMethod: ProviderAuthMethod.apiKey,
      );
      final updated = instanceService.updateMetadata(
        inst.id,
        baseUrl: inst.baseUrl,
      );
      expect(updated.configRevision, equals(inst.configRevision));
    });

    test('changing base URL demotes a ready instance back to draft', () {
      final inst = instanceService.create(
        templateId: 'openai',
        displayName: 'OpenAI',
        authMethod: ProviderAuthMethod.apiKey,
        defaultModel: 'gpt-4o',
      );
      repo.upsertModelCache(
        instanceId: inst.id,
        cacheKey: 'models',
        models: const [
          {'value': 'gpt-4o', 'label': 'GPT-4o'},
        ],
        fetchedAt: DateTime.now(),
        source: 'live',
        configRevision: inst.configRevision,
        credentialRevision: inst.credentialRevision,
      );
      instanceService.markReadyIfComplete(inst.id);

      final updated = instanceService.updateMetadata(
        inst.id,
        baseUrl: 'https://proxy.example.com/v1',
      );

      expect(updated.status, equals(InstanceStatus.draft));
    });
  });

  group(
    'ProviderInstanceService — ready promotion requires verified cache',
    () {
      test(
        'markReadyIfComplete keeps draft without a successful cache row',
        () {
          final inst = instanceService.create(
            templateId: 'openai',
            displayName: 'OpenAI',
            authMethod: ProviderAuthMethod.apiKey,
            defaultModel: 'gpt-4o',
          );

          instanceService.markReadyIfComplete(inst.id);

          expect(
            instanceService.findById(inst.id)!.status,
            equals(InstanceStatus.draft),
          );
        },
      );

      test(
        'markReadyIfComplete promotes only after matching cache success',
        () {
          final inst = instanceService.create(
            templateId: 'openai',
            displayName: 'OpenAI',
            authMethod: ProviderAuthMethod.apiKey,
            defaultModel: 'gpt-4o',
          );
          repo.upsertModelCache(
            instanceId: inst.id,
            cacheKey: 'models',
            models: const [
              {'value': 'gpt-4o', 'label': 'GPT-4o'},
            ],
            fetchedAt: DateTime.now(),
            source: 'live',
            configRevision: inst.configRevision,
            credentialRevision: inst.credentialRevision,
          );

          instanceService.markReadyIfComplete(inst.id);

          expect(
            instanceService.findById(inst.id)!.status,
            equals(InstanceStatus.ready),
          );
        },
      );
    },
  );

  group('ProviderInstanceService — reconcileStatus and default safety', () {
    test(
      'reconcileStatus keeps optional-key instances in draft after remove',
      () {
        final inst = instanceService.create(
          templateId: 'custom',
          displayName: 'Local Gateway',
          authMethod: ProviderAuthMethod.apiKey,
          protocol: ProviderProtocol.openaiCompatible,
          baseUrl: 'http://localhost:11434/v1',
          defaultModel: 'llama3.1',
        );
        instanceService.reconcileStatus(inst.id, credentialConfigured: false);

        expect(
          instanceService.findById(inst.id)!.status,
          equals(InstanceStatus.draft),
        );
      },
    );

    test('setDefault rejects non-ready instances', () {
      final inst = instanceService.create(
        templateId: 'openai',
        displayName: 'OpenAI',
        authMethod: ProviderAuthMethod.apiKey,
      );

      expect(() => instanceService.setDefault(inst.id), throwsStateError);
    });
  });

  group('ProviderCredentialService — keep/replace/remove isolation', () {
    setUp(() async {
      secrets = SecureFileSecretStore(storePath: _tempStorePath());
    });
    tearDown(() async {
      await secrets.remove('a');
      await secrets.remove('b');
    });

    ProviderCredentialService credService() =>
        ProviderCredentialService(repo, secrets);

    test('keep does not change the secret or revision', () async {
      final a = instanceService.create(
        templateId: 'openai',
        displayName: 'OpenAI A',
        authMethod: ProviderAuthMethod.apiKey,
      );
      await credService().applyApiKeyEdit(
        a.id,
        action: CredentialAction.replace,
        newApiKey: 'sk-aaa',
      );
      final before = repo.findById(a.id)!;
      final beforeKey = secrets.read(a.id)!.apiKey;

      await credService().applyApiKeyEdit(a.id, action: CredentialAction.keep);

      expect(secrets.read(a.id)!.apiKey, equals(beforeKey));
      expect(
        repo.findById(a.id)!.credentialRevision,
        equals(before.credentialRevision),
      );
    });

    test('replace writes the new key and bumps credentialRevision', () async {
      final a = instanceService.create(
        templateId: 'openai',
        displayName: 'OpenAI A',
        authMethod: ProviderAuthMethod.apiKey,
      );
      await credService().applyApiKeyEdit(
        a.id,
        action: CredentialAction.replace,
        newApiKey: 'sk-aaa',
      );
      final rev1 = repo.findById(a.id)!.credentialRevision;

      await credService().applyApiKeyEdit(
        a.id,
        action: CredentialAction.replace,
        newApiKey: 'sk-aaa-new',
      );

      expect(secrets.read(a.id)!.apiKey, equals('sk-aaa-new'));
      expect(repo.findById(a.id)!.credentialRevision, equals(rev1 + 1));
    });

    test('replace prunes secrets for instances absent from metadata', () async {
      final active = instanceService.create(
        templateId: 'openai',
        displayName: 'OpenAI Active',
        authMethod: ProviderAuthMethod.apiKey,
      );
      const orphanId = 'deleted-instance';
      await secrets.write(
        orphanId,
        SecureFileSecretStore.apiKeyRecord(orphanId, 'sk-orphan'),
      );

      await credService().applyApiKeyEdit(
        active.id,
        action: CredentialAction.replace,
        newApiKey: 'sk-active',
      );

      expect(secrets.listIds(), equals([active.id]));
      expect(secrets.read(active.id)!.apiKey, equals('sk-active'));
      expect(secrets.read(orphanId), isNull);
    });

    test(
      'replace does not prune across an isolated state-home boundary',
      () async {
        final active = instanceService.create(
          templateId: 'openai',
          displayName: 'OpenAI Isolated',
          authMethod: ProviderAuthMethod.apiKey,
        );
        const orphanId = 'other-state-instance';
        await secrets.write(
          orphanId,
          SecureFileSecretStore.apiKeyRecord(orphanId, 'sk-other-state'),
        );
        setSanadHomeOverride('/sanad-home');
        setSanadStateHomeOverride('/isolated-state-home');
        try {
          await credService().applyApiKeyEdit(
            active.id,
            action: CredentialAction.replace,
            newApiKey: 'sk-active',
          );

          expect(secrets.read(orphanId), isNotNull);
        } finally {
          setSanadStateHomeOverride(null);
          setSanadHomeOverride(null);
        }
      },
    );

    test('replace with empty value is rejected', () async {
      final a = instanceService.create(
        templateId: 'openai',
        displayName: 'OpenAI A',
        authMethod: ProviderAuthMethod.apiKey,
      );
      expect(
        () => credService().applyApiKeyEdit(
          a.id,
          action: CredentialAction.replace,
          newApiKey: '   ',
        ),
        throwsArgumentError,
      );
    });

    test('remove deletes the secret and bumps revision', () async {
      final a = instanceService.create(
        templateId: 'openai',
        displayName: 'OpenAI A',
        authMethod: ProviderAuthMethod.apiKey,
      );
      await credService().applyApiKeyEdit(
        a.id,
        action: CredentialAction.replace,
        newApiKey: 'sk-aaa',
      );
      final rev1 = repo.findById(a.id)!.credentialRevision;

      await credService().applyApiKeyEdit(
        a.id,
        action: CredentialAction.remove,
      );

      expect(secrets.read(a.id), isNull);
      expect(repo.findById(a.id)!.credentialRevision, equals(rev1 + 1));
    });

    test('replace/remove on one instance never touches another', () async {
      final a = instanceService.create(
        templateId: 'openai',
        displayName: 'OpenAI A',
        authMethod: ProviderAuthMethod.apiKey,
      );
      final b = instanceService.create(
        templateId: 'openai',
        displayName: 'OpenAI B',
        authMethod: ProviderAuthMethod.apiKey,
      );
      await credService().applyApiKeyEdit(
        a.id,
        action: CredentialAction.replace,
        newApiKey: 'sk-aaa',
      );
      await credService().applyApiKeyEdit(
        b.id,
        action: CredentialAction.replace,
        newApiKey: 'sk-bbb',
      );
      final bRevBefore = repo.findById(b.id)!.credentialRevision;

      await credService().applyApiKeyEdit(
        a.id,
        action: CredentialAction.replace,
        newApiKey: 'sk-aaa-new',
      );

      expect(secrets.read(a.id)!.apiKey, equals('sk-aaa-new'));
      expect(secrets.read(b.id)!.apiKey, equals('sk-bbb'));
      expect(repo.findById(b.id)!.credentialRevision, equals(bRevBefore));
    });

    test('summary is masked and never returns the raw key', () async {
      final a = instanceService.create(
        templateId: 'openai',
        displayName: 'OpenAI A',
        authMethod: ProviderAuthMethod.apiKey,
      );
      await credService().applyApiKeyEdit(
        a.id,
        action: CredentialAction.replace,
        newApiKey: 'sk-1234567890abcdef',
      );
      final summary = credService().summary(a.id);
      expect(summary.maskedKeyHint, isNot(contains('1234567890abcdef')));
      expect(summary.configured, isTrue);
    });
  });

  group('Multi-account OAuth — two independent instances', () {
    setUp(() {
      _FakeClient._counter = 0;
      _FakeClient._tokenCounter = 0;
      secrets = SecureFileSecretStore(storePath: _tempStorePath());
    });
    tearDown(() async {
      // Remove any leaked secrets for instances created in these tests.
      for (final inst in repo.findAll()) {
        await secrets.remove(inst.id);
      }
    });

    test(
      'both reach approved; tokens stored independently by instance UUID',
      () async {
        final cred = ProviderCredentialService(repo, secrets);
        final svc = ProviderAuthSessionService(
          _legacyStore(),
          credService: cred,
          clientFactory: _FakeClient.successFactory(),
        );
        final i1 = instanceService.create(
          templateId: 'openai-codex',
          displayName: 'Codex Work',
          authMethod: ProviderAuthMethod.deviceCode,
        );
        final i2 = instanceService.create(
          templateId: 'openai-codex',
          displayName: 'Codex Personal',
          authMethod: ProviderAuthMethod.deviceCode,
        );

        final s1 = await svc.startForInstance(
          instanceId: i1.id,
          templateId: 'openai-codex',
          authMethod: ProviderAuthMethod.deviceCode,
        );
        final s2 = await svc.startForInstance(
          instanceId: i2.id,
          templateId: 'openai-codex',
          authMethod: ProviderAuthMethod.deviceCode,
        );
        final r1 = await svc.poll(s1.sessionId);
        final r2 = await svc.poll(s2.sessionId);

        expect(r1.status, equals(AuthSessionStatus.approved));
        expect(r2.status, equals(AuthSessionStatus.approved));

        final t1 = secrets.read(i1.id);
        final t2 = secrets.read(i2.id);
        expect(t1, isNotNull);
        expect(t2, isNotNull);
        expect(t1!.accessToken, isNot(equals(t2!.accessToken)));
        expect(t1.accountLabel, equals('user-1@example.com'));
        expect(t1.accountName, equals('User 1'));
        expect(t2.accountLabel, equals('user-2@example.com'));
        expect(t2.accountName, equals('User 2'));
        expect(repo.findById(i1.id)!.credentialRevision, greaterThan(0));
        expect(repo.findById(i2.id)!.credentialRevision, greaterThan(0));
      },
    );

    test('failure in one instance never mutates the other', () async {
      final cred = ProviderCredentialService(repo, secrets);
      final i1 = instanceService.create(
        templateId: 'openai-codex',
        displayName: 'Codex Work',
        authMethod: ProviderAuthMethod.deviceCode,
      );
      final i2 = instanceService.create(
        templateId: 'openai-codex',
        displayName: 'Codex Personal',
        authMethod: ProviderAuthMethod.deviceCode,
      );
      // Seed instance 2 with a successful token first.
      await cred.writeOAuthBundle(
        i2.id,
        SecretRecord(
          instanceId: i2.id,
          accessToken: 'pre-existing',
          authMethod: ProviderAuthMethod.deviceCode,
        ),
      );
      final before2 = repo.findById(i2.id)!.credentialRevision;

      final svc = ProviderAuthSessionService(
        _legacyStore(),
        credService: cred,
        clientFactory: _FakeClient.failureFactory(),
      );

      final s1 = await svc.startForInstance(
        instanceId: i1.id,
        templateId: 'openai-codex',
        authMethod: ProviderAuthMethod.deviceCode,
      );
      final r1 = await svc.poll(s1.sessionId);

      expect(r1.status, equals(AuthSessionStatus.error));
      expect(secrets.read(i1.id), isNull);
      // Instance 2 untouched.
      expect(secrets.read(i2.id)!.accessToken, equals('pre-existing'));
      expect(repo.findById(i2.id)!.credentialRevision, equals(before2));
    });

    test('api-key instance cannot start an OAuth flow', () async {
      final cred = ProviderCredentialService(repo, secrets);
      final svc = ProviderAuthSessionService(
        _legacyStore(),
        credService: cred,
        clientFactory: _FakeClient.successFactory(),
      );
      expect(
        () => svc.startForInstance(
          instanceId: 'inst-key',
          templateId: 'openai',
          authMethod: ProviderAuthMethod.apiKey,
        ),
        throwsStateError,
      );
    });

    test(
      'reconnect/disconnect operate only on the targeted instance',
      () async {
        final cred = ProviderCredentialService(repo, secrets);
        final svc = ProviderAuthSessionService(
          _legacyStore(),
          credService: cred,
          clientFactory: _FakeClient.successFactory(),
        );
        // Create two instances.
        instanceService.create(
          templateId: 'openai-codex',
          displayName: 'Codex 1',
          authMethod: ProviderAuthMethod.deviceCode,
        );
        final id1 = repo
            .findAll()
            .firstWhere((i) => i.templateId == 'openai-codex')
            .id;
        instanceService.create(
          templateId: 'openai-codex',
          displayName: 'Codex 2',
          authMethod: ProviderAuthMethod.deviceCode,
        );
        final id2 = repo
            .findAll()
            .firstWhere((i) => i.templateId == 'openai-codex' && i.id != id1)
            .id;

        final start = await svc.reconnectForInstance(
          instanceId: id1,
          templateId: 'openai-codex',
          authMethod: ProviderAuthMethod.deviceCode,
        );
        await svc.poll(start.sessionId);
        expect(secrets.read(id1), isNotNull);
        expect(secrets.read(id2), isNull);

        await svc.disconnectForInstance(id1);
        expect(secrets.read(id1), isNull);
      },
    );
  });

  group('delete cascade includes secret', () {
    setUp(() {
      secrets = SecureFileSecretStore(storePath: _tempStorePath());
    });
    tearDown(() async {
      await secrets.remove('del-1');
    });

    test('deleteInstance clears the secret too', () async {
      final cred = ProviderCredentialService(repo, secrets);
      final inst = instanceService.create(
        templateId: 'openai',
        displayName: 'OpenAI',
        authMethod: ProviderAuthMethod.apiKey,
      );
      await cred.applyApiKeyEdit(
        inst.id,
        action: CredentialAction.replace,
        newApiKey: 'sk-x',
      );
      expect(secrets.read(inst.id), isNotNull);

      await cred.deleteSecret(inst.id);
      instanceService.delete(inst.id);

      expect(secrets.read(inst.id), isNull);
      expect(instanceService.findById(inst.id), isNull);
    });
  });
}

// ── Test helpers ─────────────────────────────────────────────────────────

/// A unique temp path for the secret store per test process.
String _tempStorePath() =>
    '/tmp/sanad-secret-store-test-${DateTime.now().microsecondsSinceEpoch}-${const Uuid().v4()}.json';

/// A throwaway legacy provider credential store so the legacy path is wired
/// (never used by the instance-keyed tests, but the constructor requires it).
ProviderCredentialStore _legacyStore() =>
    ProviderCredentialStore(storePath: _tempStorePath());

/// A fake http client that returns canned device-auth + token responses keyed
/// by the requested device_auth_id, so two parallel flows get distinct tokens.
class _FakeClient extends http.BaseClient {
  final bool _succeed;
  // Shared across concurrent clients so parallel flows get distinct tokens.
  static int _counter = 0;
  static int _tokenCounter = 0;

  _FakeClient(this._succeed);

  static http.Client Function() successFactory() =>
      () => _FakeClient(true);
  static http.Client Function() failureFactory() =>
      () => _FakeClient(false);

  static String _jwt(Map<String, dynamic> claims) {
    final header = base64Url
        .encode(utf8.encode(jsonEncode({'alg': 'none', 'typ': 'JWT'})))
        .replaceAll('=', '');
    final payload = base64Url
        .encode(utf8.encode(jsonEncode(claims)))
        .replaceAll('=', '');
    return '$header.$payload.test-signature';
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final uri = request.url.toString();
    if (uri.endsWith('/usercode')) {
      final id = 'device_auth_${++_counter}';
      final body = jsonEncode({
        'user_code': 'UC-$id',
        'device_auth_id': id,
        'interval': 5,
      });
      return _resp(body, 200);
    }
    if (uri.endsWith('/token') && uri.contains('deviceauth')) {
      // The poll body isn't parsed here; just approve immediately.
      final body = jsonEncode({
        'authorization_code': 'code-$_counter',
        'code_verifier': 'ver-$_counter',
      });
      return _resp(body, 200);
    }
    if (uri.endsWith('oauth/token')) {
      if (!_succeed) {
        return _resp('{"error":"denied"}', 400);
      }
      final n = ++_tokenCounter;
      final body = jsonEncode({
        'access_token': 'access-for-$n',
        'refresh_token': 'refresh-$n',
        'id_token': _jwt({'email': 'user-$n@example.com', 'name': 'User $n'}),
        'token_type': 'Bearer',
        'expires_in': 3600,
        'scope': 'openid',
      });
      return _resp(body, 200);
    }
    return _resp('not found', 404);
  }

  http.StreamedResponse _resp(String body, int status) {
    final bytes = utf8.encode(body);
    return http.StreamedResponse(
      Stream<List<int>>.value(bytes),
      status,
      contentLength: bytes.length,
    );
  }
}
