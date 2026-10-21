/// Task 120 — OpenCode Go per-model wire routing through
/// `AgentRuntimeService`: catalog-declared Responses / Messages models get
/// their own adapter and endpoint, while every unchanged Chat route keeps its
/// exact wire, base URL and provider-state issuer. Synthetic catalog only.
library;

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sanad_agent/core/agent_runtime_service.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/core/provider_runtime/provider_protocol_constants.dart';
import 'package:sanad_agent/engine/adapters/base_anthropic_adapter.dart';
import 'package:sanad_agent/engine/adapters/base_openai_adapter.dart';
import 'package:sanad_agent/engine/adapters/codex_responses_adapter.dart';
import 'package:sanad_agent/engine/adapters/llm_request_options.dart';
import 'package:sanad_agent/engine/adapters/models_dev_service.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:test/test.dart';

import '../../engine/adapters/projection_fixtures.dart';

const _goTemplateBase = 'https://opencode.ai/zen/go/v1';

ProviderInstance _instance({
  String id = goInstance,
  String templateId = 'opencode-go',
  String? baseUrl,
  String protocol = ProviderProtocol.openaiCompatible,
}) => ProviderInstance(
  id: id,
  templateId: templateId,
  displayName: 'Instance $id',
  protocol: protocol,
  authMethod: ProviderAuthMethod.apiKey,
  baseUrl: baseUrl,
  defaultModel: deepseek,
  status: 'ready',
  createdAt: DateTime.utc(2026, 10, 21),
  updatedAt: DateTime.utc(2026, 10, 21),
);

void main() {
  late Directory home;
  late AgentStateDatabase state;
  late ProviderInstanceRepository repo;
  late ModelsDevService catalog;
  late AgentRuntimeService runtime;

  setUp(() {
    home = Directory.systemTemp.createTempSync('sanad_120_runtime_');
    setSanadHomeOverride(home.path);
    state = AgentStateDatabase.inMemory();
    repo = ProviderInstanceRepository.fromDatabase(state.db);
    catalog = goWireModelsDev();
    runtime = AgentRuntimeService(
      Config(environment: {'SANAD_HOME': home.path}),
      repo,
      modelsDevService: catalog,
    );
    repo.createInstance(_instance());
  });

  tearDown(() {
    state.dispose();
    setSanadHomeOverride(null);
    if (home.existsSync()) home.deleteSync(recursive: true);
  });

  RouteSignature resolve(String model, {String id = goInstance}) =>
      runtime.resolveSignature(providerId: id, modelId: model);

  test(
    'Responses-served Go model dispatches on its catalog Responses wire',
    () {
      final signature = resolve(goResponsesModel);
      expect(signature.protocol, ProviderProtocol.openaiCompatible);
      expect(signature.normalizedBaseUrl, goOpenAiApi);

      final adapter = runtime.adapterFor(signature);
      expect(adapter, isA<CodexResponsesAdapter>());
      final responses = adapter as CodexResponsesAdapter;
      expect(responses.baseUrl, goOpenAiApi);
      expect(responses.profile.name, 'opencode-go');
      expect(responses.profile.apiMode, 'codex_responses');
    },
  );

  test('Messages-served Go model dispatches on its catalog Messages wire', () {
    final signature = resolve(goMessagesModel);
    expect(signature.protocol, ProviderProtocol.anthropicCompatible);
    expect(signature.normalizedBaseUrl, goAnthropicApi);

    final adapter = runtime.adapterFor(signature);
    expect(adapter, isA<BaseAnthropicAdapter>());
    final messages = adapter as BaseAnthropicAdapter;
    expect(messages.baseUrlOverride, goAnthropicApi);
    expect(messages.profile.name, 'opencode-go');
    expect(
      messages.profile.effectiveProtocol,
      ProviderProtocol.anthropicCompatible,
    );
  });

  test('unchanged Chat route keeps its exact wire, base and issuer', () async {
    final signature = resolve(deepseek);
    expect(signature.protocol, ProviderProtocol.openaiCompatible);
    expect(signature.normalizedBaseUrl, _goTemplateBase);

    final adapter = runtime.adapterFor(signature);
    expect(adapter.runtimeType, BaseOpenAIAdapter);
    final chat = adapter as BaseOpenAIAdapter;
    expect(chat.baseUrl, _goTemplateBase);
    expect(chat.profile.apiMode, 'chat_completions');

    // The adapter the runtime builds, re-instantiated with a wire recorder:
    // the minted provider-state issuer is byte-identical to the pre-120 one.
    Uri? url;
    final wired = BaseOpenAIAdapter(
      FixedRouteConfig(chat.baseUrl),
      chat.profile,
      providerInstanceId: signature.providerInstanceId,
      baseUrlOverride: signature.normalizedBaseUrl,
      apiKeyOverride: 'fixture-key',
      defaultModelOverride: signature.modelId,
      modelsDevService: catalog,
      client: MockClient((request) async {
        url = request.url;
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'role': 'assistant',
                  'content': '',
                  'reasoning_content': 'plan',
                  'tool_calls': [
                    {
                      'id': 'c1',
                      'type': 'function',
                      'function': {'name': 'read_file', 'arguments': '{}'},
                    },
                  ],
                },
                'finish_reason': 'tool_calls',
              },
            ],
          }),
          200,
        );
      }),
    );
    final response = await wired.generateResponse([
      Message(role: MessageRole.user, content: 'go'),
    ], options: const LLMRequestOptions(providerInstanceId: goInstance));
    expect(url.toString(), '$_goTemplateBase/chat/completions');
    expect(
      response.message.providerState?.issuer,
      'go-1|openai_compatible|https://opencode.ai/zen/go/v1',
    );
  });

  test(
    'a catalog wire without provider.api keeps the configured Chat wire',
    () {
      final signature = resolve('responses-without-api');
      expect(signature.protocol, ProviderProtocol.openaiCompatible);
      expect(signature.normalizedBaseUrl, _goTemplateBase);
      expect(runtime.adapterFor(signature).runtimeType, BaseOpenAIAdapter);
    },
  );

  test('an unrecognized package (Google) keeps the configured Chat wire', () {
    final signature = resolve('google-served');
    expect(signature.normalizedBaseUrl, _goTemplateBase);
    expect(runtime.adapterFor(signature).runtimeType, BaseOpenAIAdapter);
  });

  test('templates that do not opt in never follow catalog wires', () {
    repo.createInstance(_instance(id: 'ds-1', templateId: 'deepseek'));
    final signature = resolve('deepseek-chat', id: 'ds-1');
    expect(signature.protocol, ProviderProtocol.openaiCompatible);
    expect(signature.normalizedBaseUrl, 'https://api.deepseek.com');
    expect(runtime.adapterFor(signature).runtimeType, BaseOpenAIAdapter);
  });

  test('Chat and Responses models on one instance build distinct adapters', () {
    final chat = runtime.adapterFor(resolve(deepseek));
    final responses = runtime.adapterFor(resolve(goResponsesModel));
    expect(identical(chat, responses), isFalse);
    expect(
      identical(runtime.adapterFor(resolve(goResponsesModel)), responses),
      isTrue,
    );
  });
}
