import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sanad_agent/core/provider_runtime/copilot_credential_lifecycle.dart';
import 'package:sanad_agent/core/provider_runtime/provider_credential_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_protocol_constants.dart';
import 'package:sanad_agent/core/provider_runtime/secret_record.dart';
import 'package:sanad_agent/core/provider_runtime/secure_file_secret_store.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:test/test.dart';

void main() {
  late AgentStateDatabase state;
  late ProviderInstanceRepository repo;
  late ProviderInstanceService instances;
  late SecureFileSecretStore secrets;
  late ProviderCredentialService creds;
  late String instanceId;

  setUp(() async {
    state = AgentStateDatabase.inMemory();
    repo = ProviderInstanceRepository.fromDatabase(state.db);
    instances = ProviderInstanceService(repo);
    secrets = SecureFileSecretStore(storePath: _tempStorePath());
    creds = ProviderCredentialService(repo, secrets);
    instanceId = instances
        .create(
          templateId: kGithubCopilotTemplateId,
          displayName: 'Copilot Refresh',
          authMethod: ProviderAuthMethod.deviceCode,
        )
        .id;
  });

  tearDown(() {
    state.dispose();
  });

  CopilotCredentialLifecycle lifecycle({
    required http.Client Function() clientFactory,
  }) {
    return CopilotCredentialLifecycle(
      instances: repo,
      creds: creds,
      clientFactory: clientFactory,
    );
  }

  Future<void> seed({
    required String access,
    required String refresh,
    required DateTime expiresAt,
    String status = 'authenticated',
  }) {
    return creds.writeOAuthBundle(
      instanceId,
      SecretRecord(
        instanceId: instanceId,
        accessToken: access,
        refreshToken: refresh,
        expiresAt: expiresAt.millisecondsSinceEpoch,
        status: status,
        authMethod: ProviderAuthMethod.deviceCode,
      ),
    );
  }

  test('proactively exchanges when the token is inside the 120s margin', () async {
    final now = DateTime.utc(2026, 8, 30, 12);
    await seed(
      access: 'old-copilot',
      refresh: 'ghu_user',
      expiresAt: now.add(const Duration(seconds: 60)),
    );
    var hits = 0;
    final life = lifecycle(
      clientFactory: () => MockClient((request) async {
        hits++;
        expect(request.headers['Authorization'], equals('token ghu_user'));
        return http.Response(
          '{"token":"tid=fresh;exp=1","expires_at":1788080400}',
          200,
        );
      }),
    );

    final changed = await life.ensureFresh(instanceId, now: now);
    expect(changed, isTrue);
    expect(hits, equals(1));
    expect(secrets.read(instanceId)!.accessToken, equals('tid=fresh;exp=1'));
    expect(secrets.read(instanceId)!.refreshToken, equals('ghu_user'));
    expect(repo.findById(instanceId)!.credentialRevision, greaterThan(1));
  });

  test('exchanges when remaining lifetime is exactly the 120s margin', () async {
    final now = DateTime.utc(2026, 8, 30, 12);
    await seed(
      access: 'edge-copilot',
      refresh: 'ghu_user',
      expiresAt: now.add(const Duration(seconds: 120)),
    );
    var hits = 0;
    final life = lifecycle(
      clientFactory: () => MockClient((request) async {
        hits++;
        return http.Response(
          '{"token":"tid=edge;exp=1","expires_at":1788080400}',
          200,
        );
      }),
    );

    expect(await life.ensureFresh(instanceId, now: now), isTrue);
    expect(hits, equals(1));
  });

  test('skips exchange when remaining lifetime is just outside 120s', () async {
    final now = DateTime.utc(2026, 8, 30, 12);
    await seed(
      access: 'still-fresh',
      refresh: 'ghu_user',
      expiresAt: now.add(const Duration(seconds: 121)),
    );
    var hits = 0;
    final life = lifecycle(
      clientFactory: () => MockClient((request) async {
        hits++;
        return http.Response('{}', 500);
      }),
    );

    expect(await life.ensureFresh(instanceId, now: now), isFalse);
    expect(hits, equals(0));
  });

  test('skips exchange when the token is still fresh', () async {
    final now = DateTime.utc(2026, 8, 30, 12);
    await seed(
      access: 'fresh-copilot',
      refresh: 'ghu_user',
      expiresAt: now.add(const Duration(minutes: 20)),
    );
    var hits = 0;
    final life = lifecycle(
      clientFactory: () => MockClient((request) async {
        hits++;
        return http.Response('{}', 500);
      }),
    );

    expect(await life.ensureFresh(instanceId, now: now), isFalse);
    expect(hits, equals(0));
    expect(secrets.read(instanceId)!.accessToken, equals('fresh-copilot'));
  });

  test('coalesces concurrent ensureFresh calls into one exchange', () async {
    final now = DateTime.utc(2026, 8, 30, 12);
    await seed(
      access: 'old-copilot',
      refresh: 'ghu_user',
      expiresAt: now.add(const Duration(seconds: 10)),
    );
    var hits = 0;
    final life = lifecycle(
      clientFactory: () => MockClient((request) async {
        hits++;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return http.Response(
          '{"token":"tid=once;exp=1","expires_at":1788080400}',
          200,
        );
      }),
    );

    final results = await Future.wait([
      life.ensureFresh(instanceId, now: now),
      life.ensureFresh(instanceId, now: now),
    ]);
    expect(results, equals([true, true]));
    expect(hits, equals(1));
  });

  test('recoverUnauthorized exchanges even if the token looks fresh', () async {
    final now = DateTime.utc(2026, 8, 30, 12);
    await seed(
      access: 'stale-but-unexpired',
      refresh: 'ghu_user',
      expiresAt: now.add(const Duration(minutes: 20)),
    );
    final life = lifecycle(
      clientFactory: () => MockClient((request) async {
        return http.Response(
          '{"token":"tid=reissued;exp=1","expires_at":1788080400}',
          200,
        );
      }),
    );

    expect(await life.recoverUnauthorized(instanceId), isTrue);
    expect(
      secrets.read(instanceId)!.accessToken,
      equals('tid=reissued;exp=1'),
    );
  });

  test('permanent exchange failure becomes relogin_required', () async {
    final now = DateTime.utc(2026, 8, 30, 12);
    await seed(
      access: 'old-copilot',
      refresh: 'ghu_user',
      expiresAt: now.add(const Duration(seconds: 10)),
    );
    final life = lifecycle(
      clientFactory: () => MockClient((request) async {
        return http.Response('{"message":"no copilot"}', 403);
      }),
    );

    expect(await life.ensureFresh(instanceId, now: now), isFalse);
    expect(secrets.read(instanceId)!.status, equals('relogin_required'));
    expect(await life.ensureFresh(instanceId, now: now), isFalse);
  });

  test('classic GitHub PAT becomes relogin_required without exchanging', () async {
    final now = DateTime.utc(2026, 8, 30, 12);
    await seed(
      access: 'old-copilot',
      refresh: 'ghp_classic',
      expiresAt: now.add(const Duration(seconds: 10)),
    );
    var hits = 0;
    final life = lifecycle(
      clientFactory: () => MockClient((request) async {
        hits++;
        return http.Response('{}', 200);
      }),
    );

    expect(await life.ensureFresh(instanceId, now: now), isFalse);
    expect(hits, equals(0));
    expect(secrets.read(instanceId)!.status, equals('relogin_required'));
  });

  test('missing GitHub user token becomes relogin_required', () async {
    await creds.writeOAuthBundle(
      instanceId,
      SecretRecord(
        instanceId: instanceId,
        accessToken: 'orphan-copilot',
        authMethod: ProviderAuthMethod.deviceCode,
      ),
    );
    final life = lifecycle(
      clientFactory: () => MockClient((request) async {
        fail('should not exchange');
      }),
    );
    expect(await life.ensureFresh(instanceId), isFalse);
    expect(secrets.read(instanceId)!.status, equals('relogin_required'));
  });

  test('transient exchange failure does not become relogin_required', () async {
    final now = DateTime.utc(2026, 8, 30, 12);
    await seed(
      access: 'old-copilot',
      refresh: 'ghu_user',
      expiresAt: now.add(const Duration(seconds: 10)),
    );
    final life = lifecycle(
      clientFactory: () => MockClient((request) async {
        return http.Response('{"message":"unavailable"}', 500);
      }),
    );

    expect(await life.ensureFresh(instanceId, now: now), isFalse);
    expect(secrets.read(instanceId)!.status, equals('authenticated'));
    expect(secrets.read(instanceId)!.accessToken, equals('old-copilot'));
  });

  test('refreshing one instance does not mutate another Copilot instance', () async {
    final now = DateTime.utc(2026, 8, 30, 12);
    final otherId = instances
        .create(
          templateId: kGithubCopilotTemplateId,
          displayName: 'Copilot Other',
          authMethod: ProviderAuthMethod.deviceCode,
        )
        .id;
    await seed(
      access: 'old-a',
      refresh: 'ghu_a',
      expiresAt: now.add(const Duration(seconds: 10)),
    );
    await creds.writeOAuthBundle(
      otherId,
      SecretRecord(
        instanceId: otherId,
        accessToken: 'keep-b',
        refreshToken: 'ghu_b',
        expiresAt: now.add(const Duration(minutes: 20)).millisecondsSinceEpoch,
        authMethod: ProviderAuthMethod.deviceCode,
      ),
    );
    final beforeB = repo.findById(otherId)!.credentialRevision;
    final life = lifecycle(
      clientFactory: () => MockClient((request) async {
        expect(request.headers['Authorization'], equals('token ghu_a'));
        return http.Response(
          '{"token":"tid=a;exp=1","expires_at":1788080400}',
          200,
        );
      }),
    );

    expect(await life.ensureFresh(instanceId, now: now), isTrue);
    expect(secrets.read(instanceId)!.accessToken, equals('tid=a;exp=1'));
    expect(secrets.read(otherId)!.accessToken, equals('keep-b'));
    expect(secrets.read(otherId)!.refreshToken, equals('ghu_b'));
    expect(repo.findById(otherId)!.credentialRevision, equals(beforeB));
  });
}

String _tempStorePath() =>
    '${Directory.systemTemp.path}/sanad-copilot-life-${DateTime.now().microsecondsSinceEpoch}.json';
