import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sanad_agent/core/provider_runtime/copilot_token_exchanger.dart';
import 'package:sanad_agent/core/provider_runtime/provider_auth_session_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_credential_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_credential_store.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_protocol_constants.dart';
import 'package:sanad_agent/core/provider_runtime/secure_file_secret_store.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:test/test.dart';

void main() {
  late AgentStateDatabase state;
  late ProviderInstanceRepository repo;
  late ProviderInstanceService instances;
  late SecureFileSecretStore secrets;
  late ProviderCredentialService creds;
  late ProviderCredentialStore legacyStore;

  setUp(() {
    state = AgentStateDatabase.inMemory();
    repo = ProviderInstanceRepository.fromDatabase(state.db);
    instances = ProviderInstanceService(repo);
    secrets = SecureFileSecretStore(storePath: _tempStorePath());
    creds = ProviderCredentialService(repo, secrets);
    legacyStore = ProviderCredentialStore(storePath: _tempStorePath());
  });

  tearDown(() {
    state.dispose();
  });

  ProviderAuthSessionService serviceFor(http.Client Function() factory) {
    return ProviderAuthSessionService(
      legacyStore,
      credService: creds,
      instanceService: instances,
      clientFactory: factory,
    );
  }

  group('GitHub Copilot device-code flow', () {
    test('start returns user code and GitHub verification URI', () async {
      final svc = serviceFor(
        () => _CopilotMock(
          deviceCode: _deviceCodeResponse(),
          tokenPoll: _pending('authorization_pending'),
        ),
      );
      final inst = instances.create(
        templateId: kGithubCopilotTemplateId,
        displayName: 'Copilot Work',
        authMethod: ProviderAuthMethod.deviceCode,
      );

      final start = await svc.startForInstance(
        instanceId: inst.id,
        templateId: kGithubCopilotTemplateId,
        authMethod: ProviderAuthMethod.deviceCode,
      );

      expect(start.flow, equals(AuthFlowKind.deviceCode));
      expect(start.userCode, equals('WDJB-MJHT'));
      expect(start.verificationUri, equals('https://github.com/login/device'));
      expect(start.interval, equals(5));
      expect(start.expiresAt, isNotNull);
    });

    test('rejects a verification URI on a foreign host', () async {
      final svc = serviceFor(
        () => _CopilotMock(
          deviceCode: _deviceCodeResponse(
            verificationUri: 'https://evil.example/login/device',
          ),
          tokenPoll: _pending('authorization_pending'),
        ),
      );
      final start = await svc.start(kGithubCopilotTemplateId);
      expect(start.verificationUri, equals('https://github.com/login/device'));
    });

    test('authorization_pending stays pending', () async {
      final svc = serviceFor(
        () => _CopilotMock(
          deviceCode: _deviceCodeResponse(),
          tokenPoll: _pending('authorization_pending'),
        ),
      );
      final start = await svc.start(kGithubCopilotTemplateId);
      final poll = await svc.poll(start.sessionId);
      expect(poll.status, equals(AuthSessionStatus.pending));
      expect(secrets.listIds(), isEmpty);
    });

    test('slow_down increases the poll interval by 5 seconds', () async {
      final svc = serviceFor(
        () => _CopilotMock(
          deviceCode: _deviceCodeResponse(interval: 5),
          tokenPoll: _pending('slow_down'),
        ),
      );
      final start = await svc.start(kGithubCopilotTemplateId);
      expect(start.interval, equals(5));
      final poll = await svc.poll(start.sessionId);
      expect(poll.status, equals(AuthSessionStatus.pending));
      expect(poll.interval, equals(10));
      final again = await svc.poll(start.sessionId);
      expect(again.interval, equals(15));
    });

    test('cancel drops the in-flight session without storing secrets', () async {
      final svc = serviceFor(
        () => _CopilotMock(
          deviceCode: _deviceCodeResponse(),
          tokenPoll: _pending('authorization_pending'),
        ),
      );
      final start = await svc.start(kGithubCopilotTemplateId);
      svc.cancel(start.sessionId);
      final poll = await svc.poll(start.sessionId);
      expect(poll.status, equals(AuthSessionStatus.cancelled));
      expect(secrets.listIds(), isEmpty);
      final later = await svc.poll(start.sessionId);
      expect(later.status, equals(AuthSessionStatus.error));
    });

    test('expired_token expires the session', () async {
      final svc = serviceFor(
        () => _CopilotMock(
          deviceCode: _deviceCodeResponse(),
          tokenPoll: _pending('expired_token'),
        ),
      );
      final start = await svc.start(kGithubCopilotTemplateId);
      final poll = await svc.poll(start.sessionId);
      expect(poll.status, equals(AuthSessionStatus.expired));
      final later = await svc.poll(start.sessionId);
      expect(later.status, equals(AuthSessionStatus.error));
    });

    test(
      'access_denied returns a typed error without storing secrets',
      () async {
        final svc = serviceFor(
          () => _CopilotMock(
            deviceCode: _deviceCodeResponse(),
            tokenPoll: _pending('access_denied'),
          ),
        );
        final inst = instances.create(
          templateId: kGithubCopilotTemplateId,
          displayName: 'Copilot Denied',
          authMethod: ProviderAuthMethod.deviceCode,
        );
        final start = await svc.startForInstance(
          instanceId: inst.id,
          templateId: kGithubCopilotTemplateId,
          authMethod: ProviderAuthMethod.deviceCode,
        );
        final poll = await svc.poll(start.sessionId);
        expect(poll.status, equals(AuthSessionStatus.error));
        expect(poll.errorMessage, contains('denied'));
        expect(secrets.read(inst.id), isNull);
      },
    );

    test(
      'writes SecretRecord only after GitHub approval and Copilot exchange',
      () async {
        final svc = serviceFor(
          () => _CopilotMock(
            deviceCode: _deviceCodeResponse(),
            tokenPoll: _approved(githubToken: 'ghu_user_token'),
            exchange: _exchange(
              token:
                  'tid=abc;exp=1;proxy-ep=proxy.enterprise.githubcopilot.com',
              expiresAt: 1788080400,
              endpointsApi: 'https://api.enterprise.githubcopilot.com',
            ),
          ),
        );
        final inst = instances.create(
          templateId: kGithubCopilotTemplateId,
          displayName: 'Copilot Personal',
          authMethod: ProviderAuthMethod.deviceCode,
        );

        final start = await svc.startForInstance(
          instanceId: inst.id,
          templateId: kGithubCopilotTemplateId,
          authMethod: ProviderAuthMethod.deviceCode,
        );
        final poll = await svc.poll(start.sessionId);

        expect(poll.status, equals(AuthSessionStatus.approved));
        final stored = secrets.read(inst.id);
        expect(stored, isNotNull);
        expect(stored!.refreshToken, equals('ghu_user_token'));
        expect(
          stored.accessToken,
          equals('tid=abc;exp=1;proxy-ep=proxy.enterprise.githubcopilot.com'),
        );
        expect(stored.expiresAt, equals(1788080400 * 1000));
        expect(stored.authMethod, equals(ProviderAuthMethod.deviceCode));
        expect(
          repo.findById(inst.id)!.baseUrl,
          equals('https://api.enterprise.githubcopilot.com'),
        );
      },
    );

    test('does not persist GitHub token when Copilot exchange fails', () async {
      final svc = serviceFor(
        () => _CopilotMock(
          deviceCode: _deviceCodeResponse(),
          tokenPoll: _approved(githubToken: 'ghu_user_token'),
          exchangeStatus: 403,
        ),
      );
      final inst = instances.create(
        templateId: kGithubCopilotTemplateId,
        displayName: 'Copilot Blocked',
        authMethod: ProviderAuthMethod.deviceCode,
      );
      final start = await svc.startForInstance(
        instanceId: inst.id,
        templateId: kGithubCopilotTemplateId,
        authMethod: ProviderAuthMethod.deviceCode,
      );
      final poll = await svc.poll(start.sessionId);
      expect(poll.status, equals(AuthSessionStatus.error));
      expect(secrets.read(inst.id), isNull);
      expect(poll.errorMessage, isNot(contains('ghu_')));
    });

    test('rejects classic ghp_ tokens without calling exchange', () async {
      var exchangeHits = 0;
      final svc = serviceFor(
        () => _CopilotMock(
          deviceCode: _deviceCodeResponse(),
          tokenPoll: _approved(githubToken: 'ghp_classic'),
          onExchange: () => exchangeHits++,
        ),
      );
      final start = await svc.start(kGithubCopilotTemplateId);
      final poll = await svc.poll(start.sessionId);
      expect(poll.status, equals(AuthSessionStatus.error));
      expect(poll.errorMessage, contains('ghp_*'));
      expect(exchangeHits, equals(0));
    });

    test('isolates two Copilot instances', () async {
      var n = 0;
      final svc = serviceFor(
        () => _CopilotMock(
          deviceCode: _deviceCodeResponse(),
          tokenPollBuilder: () {
            n++;
            return _approved(githubToken: 'ghu_user_$n');
          },
          exchangeBuilder: () {
            return _exchange(
              token: 'tid=token-$n;exp=1',
              expiresAt: 1788080400,
            );
          },
        ),
      );
      final i1 = instances.create(
        templateId: kGithubCopilotTemplateId,
        displayName: 'Copilot A',
        authMethod: ProviderAuthMethod.deviceCode,
      );
      final i2 = instances.create(
        templateId: kGithubCopilotTemplateId,
        displayName: 'Copilot B',
        authMethod: ProviderAuthMethod.deviceCode,
      );
      final s1 = await svc.startForInstance(
        instanceId: i1.id,
        templateId: kGithubCopilotTemplateId,
        authMethod: ProviderAuthMethod.deviceCode,
      );
      final s2 = await svc.startForInstance(
        instanceId: i2.id,
        templateId: kGithubCopilotTemplateId,
        authMethod: ProviderAuthMethod.deviceCode,
      );
      expect((await svc.poll(s1.sessionId)).status, AuthSessionStatus.approved);
      expect((await svc.poll(s2.sessionId)).status, AuthSessionStatus.approved);
      expect(secrets.read(i1.id)!.refreshToken, equals('ghu_user_1'));
      expect(secrets.read(i2.id)!.refreshToken, equals('ghu_user_2'));
      expect(
        secrets.read(i1.id)!.accessToken,
        isNot(equals(secrets.read(i2.id)!.accessToken)),
      );
    });
  });

  group('CopilotTokenExchanger', () {
    test('exchanges a GitHub user token for a Copilot API token', () async {
      final client = MockClient((request) async {
        expect(request.method, equals('GET'));
        expect(
          request.url.toString(),
          equals(GithubCopilotProtocol.tokenExchangeUrl),
        );
        expect(request.headers['Authorization'], equals('token ghu_ok'));
        expect(
          request.headers['Copilot-Integration-Id'],
          equals('vscode-chat'),
        );
        return http.Response(
          jsonEncode({'token': 'tid=ok;exp=1', 'expires_at': 1788080400}),
          200,
        );
      });
      final result = await CopilotTokenExchanger().exchange(
        client: client,
        githubUserToken: 'ghu_ok',
      );
      expect(result.token, equals('tid=ok;exp=1'));
      expect(result.expiresAt, equals(1788080400 * 1000));
    });

    test('rejects classic PATs before any HTTP call', () async {
      var hits = 0;
      final client = MockClient((request) async {
        hits++;
        return http.Response('{}', 200);
      });
      expect(
        () => CopilotTokenExchanger().exchange(
          client: client,
          githubUserToken: 'ghp_classic',
        ),
        throwsA(isA<FormatException>()),
      );
      expect(hits, equals(0));
    });
  });
}

String _tempStorePath() =>
    '${Directory.systemTemp.path}/sanad-copilot-${DateTime.now().microsecondsSinceEpoch}-${identityHashCode(Object())}.json';

Map<String, dynamic> _deviceCodeResponse({
  String verificationUri = 'https://github.com/login/device',
  int interval = 5,
}) => {
  'device_code': 'device-abc',
  'user_code': 'WDJB-MJHT',
  'verification_uri': verificationUri,
  'expires_in': 900,
  'interval': interval,
};

Map<String, dynamic> _pending(String error) => {'error': error};

Map<String, dynamic> _approved({required String githubToken}) => {
  'access_token': githubToken,
  'token_type': 'bearer',
  'scope': 'read:user',
};

Map<String, dynamic> _exchange({
  required String token,
  required int expiresAt,
  String? endpointsApi,
}) => {
  'token': token,
  'expires_at': expiresAt,
  if (endpointsApi != null) 'endpoints': {'api': endpointsApi},
};

class _CopilotMock extends http.BaseClient {
  final Map<String, dynamic> deviceCode;
  final Map<String, dynamic>? tokenPoll;
  final Map<String, dynamic> Function()? tokenPollBuilder;
  final Map<String, dynamic>? exchange;
  final Map<String, dynamic> Function()? exchangeBuilder;
  final int exchangeStatus;
  final void Function()? onExchange;

  _CopilotMock({
    required this.deviceCode,
    this.tokenPoll,
    this.tokenPollBuilder,
    this.exchange,
    this.exchangeBuilder,
    this.exchangeStatus = 200,
    this.onExchange,
  });

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final path = request.url.path;
    if (path == '/login/device/code') {
      return _json(deviceCode, 200);
    }
    if (path == '/login/oauth/access_token') {
      return _json(tokenPollBuilder?.call() ?? tokenPoll ?? const {}, 200);
    }
    if (path == '/copilot_internal/v2/token') {
      onExchange?.call();
      if (exchangeStatus != 200) {
        return _json({'message': 'denied'}, exchangeStatus);
      }
      return _json(
        exchangeBuilder?.call() ??
            exchange ??
            {'token': 'tid=fallback;exp=1', 'expires_at': 1788080400},
        200,
      );
    }
    return _json({'error': 'not_found'}, 404);
  }

  http.StreamedResponse _json(Map<String, dynamic> body, int status) {
    final bytes = utf8.encode(jsonEncode(body));
    return http.StreamedResponse(
      Stream<List<int>>.value(bytes),
      status,
      contentLength: bytes.length,
      headers: {'content-type': 'application/json'},
    );
  }
}
