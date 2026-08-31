import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/provider_runtime/env_file_service.dart';
import 'package:sanad_agent/core/provider_runtime/model_options_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_credential_resolver.dart';
import 'package:sanad_agent/core/provider_runtime/provider_credential_store.dart';
import 'package:sanad_agent/engine/adapters/codex_models_service.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempWorkDir;
  late Directory tempSanadHome;

  setUp(() async {
    tempWorkDir = await Directory.systemTemp.createTemp(
      'sanad-model-options-test-work',
    );
    tempSanadHome = await Directory.systemTemp.createTemp(
      'sanad-model-options-test-home',
    );
    setSanadHomeOverride(tempSanadHome.path);
  });

  tearDown(() async {
    setSanadHomeOverride(null);
    if (tempWorkDir.existsSync()) await tempWorkDir.delete(recursive: true);
    if (tempSanadHome.existsSync()) await tempSanadHome.delete(recursive: true);
  });

  EnvFileService envWith(String content) {
    final file = File('${tempWorkDir.path}/.env');
    file.writeAsStringSync(content);
    return EnvFileService(envPath: file.path);
  }

  test(
    'ModelOptionsService optionsFor sorts live models according to fallback list',
    () async {
      final env = envWith('''
ACTIVE_PROVIDER=openai
OPENAI_API_KEY=sk-openai-test
''');
      final credStore = ProviderCredentialStore(
        storePath: '${tempSanadHome.path}/provider_auth.json',
      );
      final resolver = ProviderCredentialResolver(env, credStore);

      // Mock client that returns a list of live models in arbitrary order
      http.Client mockClientFactory() {
        final mock = _MockClient((request) async {
          if (request.url.path.endsWith('/models')) {
            return http.Response(
              jsonEncode({
                'data': [
                  {'id': 'gpt-4-custom'},
                  {'id': 'o1-mini'},
                  {'id': 'gpt-4o-mini'},
                  {'id': 'gpt-4o'},
                  {'id': 'some-other-model'},
                ],
              }),
              200,
            );
          }
          return http.Response('Not Found', 404);
        });
        return mock;
      }

      final service = ModelOptionsService(
        env,
        resolver,
        clientFactory: mockClientFactory,
      );

      // OpenAI fallback models in registry are: ['gpt-4o', 'gpt-4o-mini', 'o1-mini']
      // So the expected sorted models list should be:
      // 1. fallback models first in order: 'gpt-4o', 'gpt-4o-mini', 'o1-mini'
      // 2. remaining live models in their default/alphabetical order: 'gpt-4-custom', 'some-other-model'
      final result = await service.optionsFor('openai', fetchLive: true);

      expect(result.source, equals('live'));
      expect(
        result.models,
        equals([
          'gpt-4o',
          'gpt-4o-mini',
          'o1-mini',
          'gpt-4-custom',
          'some-other-model',
        ]),
      );
    },
  );

  test('ModelOptionsService parses the Codex model catalog', () async {
    final env = envWith('''
ACTIVE_PROVIDER=openai-codex
CHATGPT_SESSION_TOKEN=codex-token
''');
    final credStore = ProviderCredentialStore(
      storePath: '${tempSanadHome.path}/provider_auth.json',
    );
    await credStore.write(
      ProviderAuthRecord(
        providerId: 'openai-codex',
        accessToken: 'codex-token',
      ),
    );
    final resolver = ProviderCredentialResolver(env, credStore);
    late http.BaseRequest captured;
    final service = ModelOptionsService(
      env,
      resolver,
      clientFactory: () => _MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({
            'models': [
              {'slug': 'codex-beta', 'visibility': 'list', 'priority': 2},
              {'slug': 'codex-alpha', 'visibility': 'list', 'priority': 1},
            ],
          }),
          200,
        );
      }),
      codexModelsService: CodexModelsService(clientVersion: '1.2.3'),
    );

    final result = await service.optionsFor('openai-codex');

    expect(result.source, 'live');
    expect(result.models, ['codex-alpha', 'codex-beta']);
    expect(captured.url.queryParameters['client_version'], '1.2.3');
    expect(captured.headers['Authorization'], 'Bearer codex-token');
  });

  test('ModelOptionsService filters Copilot live models by policy', () async {
    final env = envWith('ACTIVE_PROVIDER=github-copilot\n');
    final credStore = ProviderCredentialStore(
      storePath: '${tempSanadHome.path}/provider_auth.json',
    );
    final resolver = ProviderCredentialResolver(env, credStore);
    late http.BaseRequest captured;
    final service = ModelOptionsService(
      env,
      resolver,
      clientFactory: () => _MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({
            'data': [
              {
                'id': 'gpt-4o',
                'capabilities': {
                  'supports': {'streaming': true, 'tool_calls': true},
                },
                'policy': {'state': 'enabled'},
              },
              {
                'id': 'blocked',
                'policy': {'state': 'disabled'},
                'capabilities': {
                  'supports': {'streaming': true, 'tool_calls': true},
                },
              },
            ],
          }),
          200,
        );
      }),
    );

    final result = await service.optionsFor('github-copilot');

    expect(result.source, 'live');
    expect(result.models, ['gpt-4o']);
    expect(captured.url.path, endsWith('/models'));
    expect(captured.headers['Copilot-Integration-Id'], 'vscode-chat');
  });
}

class _MockClient extends http.BaseClient {
  final Future<http.Response> Function(http.BaseRequest request) _handler;
  _MockClient(this._handler);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await _handler(request);
    return http.StreamedResponse(
      Stream.value(response.bodyBytes),
      response.statusCode,
      contentLength: response.contentLength,
      request: request,
      headers: response.headers,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
      reasonPhrase: response.reasonPhrase,
    );
  }
}
