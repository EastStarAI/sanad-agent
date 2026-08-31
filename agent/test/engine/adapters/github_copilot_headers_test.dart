import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/provider_runtime/copilot_request_policy.dart';
import 'package:sanad_agent/core/provider_runtime/provider_protocol_constants.dart';
import 'package:sanad_agent/engine/adapters/base_openai_adapter.dart';
import 'package:sanad_agent/engine/adapters/codex_responses_adapter.dart';
import 'package:sanad_agent/engine/adapters/llm_request_options.dart';
import 'package:sanad_agent/engine/adapters/provider_registry.dart';
import 'package:test/test.dart';

void main() {
  final profile = ProviderRegistry.findByNameOrAlias(kGithubCopilotTemplateId)!;
  final config = Config();

  group('CopilotRequestPolicy', () {
    test('sets x-initiator user then agent and omits vision by default', () {
      expect(
        CopilotRequestPolicy.requestHeaders(
          afterToolResults: false,
          vision: false,
        ),
        containsPair('x-initiator', 'user'),
      );
      expect(
        CopilotRequestPolicy.requestHeaders(
          afterToolResults: true,
          vision: false,
        ),
        containsPair('x-initiator', 'agent'),
      );
      expect(
        CopilotRequestPolicy.requestHeaders(
          afterToolResults: false,
          vision: false,
        ).containsKey('Copilot-Vision-Request'),
        isFalse,
      );
    });

    test('adds Copilot-Vision-Request only when vision is present', () {
      expect(
        CopilotRequestPolicy.requestHeaders(
          afterToolResults: false,
          vision: true,
        ),
        containsPair('Copilot-Vision-Request', 'true'),
      );
      expect(
        CopilotRequestPolicy.historyHasVision([
          Message(
            role: MessageRole.user,
            content: 'see data:image/png;base64,abc',
          ),
        ]),
        isTrue,
      );
      expect(
        CopilotRequestPolicy.historyHasVision([
          Message(role: MessageRole.user, content: 'plain text'),
        ]),
        isFalse,
      );
    });

    test('routes Responses models only when the id names that protocol', () {
      expect(GithubCopilotProtocol.usesResponsesApi('gpt-4o'), isFalse);
      expect(GithubCopilotProtocol.usesResponsesApi('claude-sonnet-4.6'), isFalse);
      expect(GithubCopilotProtocol.usesResponsesApi('gpt-5-responses'), isTrue);
      expect(GithubCopilotProtocol.usesResponsesApi('gpt-5.4'), isFalse);
    });
  });

  group('BaseOpenAIAdapter Copilot headers', () {
    test('sends static Copilot headers plus initiator and vision', () async {
      late http.Request captured;
      final adapter = BaseOpenAIAdapter(
        config,
        profile,
        client: MockClient((request) async {
          captured = request;
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': 'ok'},
                  'finish_reason': 'stop',
                },
              ],
            }),
            200,
          );
        }),
        apiKeyOverride: 'copilot-token',
        defaultModelOverride: 'gpt-4o',
      );

      await adapter.generateResponse(
        [
          Message(
            role: MessageRole.user,
            content: 'look at data:image/png;base64,abc',
          ),
        ],
        options: const LLMRequestOptions(afterToolResults: true),
      );

      expect(captured.headers['Copilot-Integration-Id'], 'vscode-chat');
      expect(captured.headers['Openai-Intent'], 'conversation-edits');
      expect(captured.headers['Editor-Version'], 'vscode/1.104.1');
      expect(captured.headers['x-initiator'], 'agent');
      expect(captured.headers['Copilot-Vision-Request'], 'true');
      expect(captured.headers['Authorization'], 'Bearer copilot-token');
    });

    test('does not inject Copilot initiator headers on other providers', () {
      final openai = ProviderRegistry.findByNameOrAlias('openai')!;
      final adapter = BaseOpenAIAdapter(config, openai, apiKeyOverride: 'sk');
      final headers = adapter.requestHeaders(
        options: const LLMRequestOptions(afterToolResults: true),
        history: [
          Message(
            role: MessageRole.user,
            content: 'data:image/png;base64,abc',
          ),
        ],
      );
      expect(headers.containsKey('x-initiator'), isFalse);
      expect(headers.containsKey('Copilot-Vision-Request'), isFalse);
    });

    test('live Copilot models drop disabled SKUs and keep usable ones', () async {
      final adapter = BaseOpenAIAdapter(
        config,
        profile,
        client: MockClient((request) async {
          expect(request.url.path, contains('models'));
          expect(request.headers['Copilot-Integration-Id'], 'vscode-chat');
          return http.Response(
            jsonEncode({
              'data': [
                {
                  'id': 'gpt-4o',
                  'capabilities': {
                    'limits': {'max_context_window_tokens': 128000},
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
        apiKeyOverride: 'copilot-token',
        defaultModelOverride: 'gpt-4o',
      );

      final models = await adapter.getAvailableModels();
      expect(models.map((model) => model.value), ['gpt-4o']);
      expect(models.single.contextWindow, 128000);
    });

    test('stream requests reuse the same Copilot header policy', () {
      final adapter = BaseOpenAIAdapter(
        config,
        profile,
        apiKeyOverride: 'copilot-token',
        defaultModelOverride: 'gpt-4o',
      );
      final headers = adapter.requestHeaders(
        history: [Message(role: MessageRole.user, content: 'hello')],
      );
      expect(headers['x-initiator'], 'user');
      expect(headers.containsKey('Copilot-Vision-Request'), isFalse);
      expect(headers['Copilot-Integration-Id'], 'vscode-chat');
      expect(headers['Openai-Intent'], 'conversation-edits');
      expect(headers['Editor-Version'], 'vscode/1.104.1');
    });
  });

  group('CodexResponsesAdapter Copilot routing', () {
    test('reuses Copilot headers against the instance account endpoint', () {
      final adapter = CodexResponsesAdapter(
        config,
        profile,
        apiKeyOverride: 'copilot-token',
        defaultModelOverride: 'gpt-5-responses',
        baseUrlOverride: 'https://api.enterprise.githubcopilot.com',
      );

      expect(
        adapter.baseUrl,
        equals('https://api.enterprise.githubcopilot.com'),
      );
      final headers = adapter.requestHeaders(
        options: const LLMRequestOptions(afterToolResults: true),
        history: [
          Message(
            role: MessageRole.user,
            content: 'see data:image/png;base64,abc',
          ),
        ],
      );
      expect(headers['Copilot-Integration-Id'], 'vscode-chat');
      expect(headers['Openai-Intent'], 'conversation-edits');
      expect(headers['Editor-Version'], 'vscode/1.104.1');
      expect(headers['x-initiator'], 'agent');
      expect(headers['Copilot-Vision-Request'], 'true');
      expect(headers['Authorization'], 'Bearer copilot-token');
    });
  });
}
