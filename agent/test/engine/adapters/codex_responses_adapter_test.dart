import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sanad_agent/capabilities/models/tool_schema.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/models/agent_response.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/models/tool_execution_result.dart';
import 'package:sanad_agent/core/models/tool_call.dart';
import 'package:sanad_agent/core/models/llm_provider_state.dart';
import 'package:sanad_agent/core/provider_runtime/provider_rate_limiter.dart';
import 'package:sanad_agent/engine/adapters/base_anthropic_adapter.dart';
import 'package:sanad_agent/engine/adapters/base_openai_adapter.dart';
import 'package:sanad_agent/engine/adapters/codex_responses_adapter.dart';
import 'package:sanad_agent/engine/adapters/codex_responses_codec.dart';
import 'package:sanad_agent/engine/adapters/codex_responses_policy.dart';
import 'package:sanad_agent/engine/adapters/codex_models_service.dart';
import 'package:sanad_agent/engine/adapters/llm_request_options.dart';
import 'package:sanad_agent/core/provider_runtime/route_capability_resolver.dart';
import 'package:sanad_agent/core/provider_thinking/native_thinking_directive.dart';
import 'package:sanad_agent/engine/adapters/e2e_fixture_adapter.dart';
import 'package:sanad_agent/engine/adapters/llm_adapter.dart';
import 'package:sanad_agent/engine/adapters/missing_provider_adapter.dart';
import 'package:sanad_agent/engine/adapters/mock_adapter.dart';
import 'package:sanad_agent/engine/adapters/ollama_adapter.dart';
import 'package:sanad_agent/engine/adapters/rate_limited_llm_adapter.dart';
import 'package:sanad_agent/engine/adapters/llm_http_exception.dart';
import 'package:sanad_agent/engine/adapters/provider_state_rejected_exception.dart';
import 'package:sanad_agent/engine/adapters/provider_profile.dart';
import 'package:test/test.dart';

void main() {
  group('CodexResponsesAdapter', () {
    late Config config;
    late ProviderProfile profile;

    setUp(() {
      config = Config(
        environment: {
          'ACTIVE_PROVIDER': 'openai-codex',
          'CHATGPT_SESSION_TOKEN': 'test-codex-key',
          'LLM_API_KEY': 'test-codex-key',
          'LLM_MODEL': 'gpt-5.4',
          'CHATGPT_MODEL': 'gpt-5.4',
          'LLM_BASE_URL': 'https://chatgpt.com/backend-api/codex',
          'AGENT_NAME': 'TestAgent',
        },
      );
      profile = const ProviderProfile(
        name: 'openai-codex',
        defaultBaseUrl: 'https://chatgpt.com/backend-api/codex',
        fallbackModels: ['gpt-5.4'],
        apiMode: 'codex_responses',
      );
    });

    test('declares closed capabilities and delegates wrappers', () {
      const openAi = ProviderProfile(name: 'openai', apiMode: 'chat');
      const anthropic = ProviderProfile(
        name: 'anthropic',
        apiMode: 'anthropic_messages',
      );
      const ollama = ProviderProfile(name: 'ollama', apiMode: 'chat');
      final richAdapters = <LLMAdapter>[
        BaseAnthropicAdapter(config, anthropic),
        CodexResponsesAdapter(config, profile),
        const E2eFixtureAdapter(),
      ];
      final textAdapters = <LLMAdapter>[
        BaseOpenAIAdapter(config, openAi),
        OllamaAdapter(config, ollama),
        const MissingProviderAdapter(message: 'missing'),
        MockLLMAdapter(),
        const E2eFixtureAdapter(
          toolResultMediaCapability: ToolResultMediaCapability.textOnly,
        ),
      ];

      expect(
        richAdapters.map((adapter) => adapter.toolResultMediaCapability),
        everyElement(ToolResultMediaCapability.imageToolResults),
      );
      expect(
        textAdapters.map((adapter) => adapter.toolResultMediaCapability),
        everyElement(ToolResultMediaCapability.textOnly),
      );
      for (final inner in [...richAdapters, ...textAdapters]) {
        final wrapper = RateLimitedLLMAdapter(
          inner,
          providerInstanceId: 'test',
          requestsPerMinute: 0,
          limiter: ProviderRateLimiter(),
        );
        expect(
          wrapper.toolResultMediaCapability,
          inner.toolResultMediaCapability,
        );
      }
    });

    test(
      'route change projects one immutable text fallback in sync and stream',
      () async {
        final richResult = ToolExecutionResult(
          blocks: [
            ToolTextBlock(text: 'visible summary'),
            ToolImageBlock(
              dataBase64: 'cGl4ZWxz',
              mimeType: 'image/png',
              width: 1,
              height: 1,
              detail: ToolImageDetail.auto,
            ),
          ],
        );
        final history = [
          Message(role: MessageRole.user, content: 'inspect'),
          Message(
            role: MessageRole.assistant,
            toolCalls: [
              ToolCall(id: 'call_route', name: 'view_image', arguments: {}),
            ],
          ),
          Message(
            role: MessageRole.tool,
            content: richResult.displayText,
            toolCallId: 'call_route',
            toolResult: richResult,
          ),
        ];
        final canonicalBefore = jsonEncode(
          history.map((message) => message.toJson()).toList(),
        );
        late Map<String, dynamic> richBody;
        final richAdapter = CodexResponsesAdapter(
          config,
          profile,
          client: MockClient.streaming((request, _) async {
            richBody = _map(jsonDecode((request as http.Request).body));
            return http.StreamedResponse(
              Stream.value(
                utf8.encode(
                  _sseResponse({
                    'status': 'completed',
                    'output': [
                      {
                        'type': 'message',
                        'role': 'assistant',
                        'status': 'completed',
                        'content': [
                          {'type': 'output_text', 'text': 'ok'},
                        ],
                      },
                    ],
                  }),
                ),
              ),
              200,
            );
          }),
        );
        final syncAdapter = BaseOpenAIAdapter(
          config,
          const ProviderProfile(name: 'openai', apiMode: 'chat'),
          baseUrlOverride: 'https://example.test/v1',
          apiKeyOverride: 'test',
          defaultModelOverride: 'test-model',
          client: MockClient((request) async {
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
        );
        final streamAdapter = BaseOpenAIAdapter(
          config,
          const ProviderProfile(name: 'custom', apiMode: 'chat'),
          baseUrlOverride: 'https://example.test/v1',
          apiKeyOverride: 'test',
          defaultModelOverride: 'test-model',
          client: MockClient.streaming((request, _) async {
            return http.StreamedResponse(
              Stream.value(
                utf8.encode(
                  'data: ${jsonEncode({
                    'choices': [
                      {
                        'delta': {'content': 'ok'},
                        'finish_reason': 'stop',
                      },
                    ],
                  })}\n\ndata: [DONE]\n\n',
                ),
              ),
              200,
              headers: {'content-type': 'text/event-stream'},
            );
          }),
        );

        const supportedOptions = LLMRequestOptions(
          routeCapabilityProfile: RouteCapabilityProfile(
            providerInstanceId: 'openai-codex',
            modelId: 'gpt-5.4',
            imageSupport: RouteImageSupport.supported,
            evidenceSource: 'test_fixture',
          ),
        );
        await richAdapter.generateResponse(history, options: supportedOptions);
        expect((richBody['input'] as List).last['output'], isA<List>());

        // Non-image routes halt actionably without sending HTTP request (77i5 contract)
        expect(
          () => syncAdapter.generateResponse(history),
          throwsA(isA<UnsupportedError>()),
        );
        expect(
          () => streamAdapter.generateStream(history).toList(),
          throwsA(isA<UnsupportedError>()),
        );
        expect(
          jsonEncode(history.map((message) => message.toJson()).toList()),
          canonicalBefore,
        );
      },
    );

    test('fetches the Codex-specific model catalog', () async {
      late http.Request captured;
      final adapter = CodexResponsesAdapter(
        config,
        profile,
        client: MockClient((request) async {
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
        modelsService: CodexModelsService(clientVersion: '1.2.3'),
      );

      final models = await adapter.getAvailableModels();

      expect(models.map((model) => model.value), ['codex-alpha', 'codex-beta']);
      expect(adapter.availableModelsSource, 'live');
      expect(captured.url.queryParameters['client_version'], '1.2.3');
      expect(captured.headers['Authorization'], 'Bearer test-codex-key');
    });

    test('keeps the existing fallback when Codex discovery fails', () async {
      final adapter = CodexResponsesAdapter(
        config,
        profile,
        client: MockClient((_) async => http.Response('{}', 401)),
        modelsService: CodexModelsService(clientVersion: '1.2.3'),
      );

      final models = await adapter.getAvailableModels();

      expect(adapter.availableModelsSource, 'fallback');
      expect(models.map((model) => model.value), ['gpt-5.4']);
    });

    test(
      'builds one stateless reasoning request and normalizes all output',
      () async {
        late Map<String, dynamic> requestBody;
        final mockClient = MockClient.streaming((request, _) async {
          expect(
            request.url.toString(),
            'https://chatgpt.com/backend-api/codex/responses',
          );
          expect(request.headers['Authorization'], 'Bearer test-codex-key');
          requestBody = _map(jsonDecode((request as http.Request).body));
          return http.StreamedResponse(
            Stream.value(
              utf8.encode(
                _sseResponse({
                  'id': 'resp_1',
                  'status': 'completed',
                  'model': 'gpt-5.4-2026-07-01',
                  'output': [
                    {
                      'id': 'rs_1',
                      'type': 'reasoning',
                      'encrypted_content': 'opaque-reasoning',
                      'summary': [
                        {'type': 'summary_text', 'text': 'Think '},
                        {'type': 'summary_text', 'text': 'carefully'},
                      ],
                    },
                    {
                      'id': 'msg_1',
                      'type': 'message',
                      'role': 'assistant',
                      'status': 'completed',
                      'phase': 'final_answer',
                      'content': [
                        {'type': 'output_text', 'text': 'Hello '},
                        {'type': 'output_text', 'text': 'world'},
                      ],
                    },
                  ],
                  'usage': {
                    'input_tokens': 10,
                    'output_tokens': 7,
                    'total_tokens': 17,
                    'output_tokens_details': {'reasoning_tokens': 3},
                  },
                }),
              ),
            ),
            200,
          );
        });
        final adapter = CodexResponsesAdapter(
          config,
          profile,
          client: mockClient,
        );

        final response = await adapter.generateResponse(
          [
            Message(role: MessageRole.system, content: 'System instructions'),
            Message(role: MessageRole.user, content: 'Hello codex'),
          ],
          options: const LLMRequestOptions(
            providerInstanceId: 'provider-1',
            thinkingDirective: ResponsesReasoningDirective(effort: 'high'),
            maxOutputTokens: 2048,
          ),
        );

        expect(requestBody['stream'], isTrue);
        expect(requestBody['store'], isFalse);
        expect(requestBody['include'], ['reasoning.encrypted_content']);
        expect(requestBody['reasoning'], {'effort': 'high', 'summary': 'auto'});
        expect(requestBody['max_output_tokens'], 2048);
        expect(requestBody['instructions'], 'System instructions');
        expect(requestBody['input'][0]['content'][0]['type'], 'input_text');
        expect(response.message.content, 'Hello world');
        expect(response.message.reasoning, 'Think \n\ncarefully');
        expect(response.finishReason, LLMFinishReason.stop);
        expect(response.usage?['reasoning_tokens'], 3);
        expect(response.model, 'gpt-5.4-2026-07-01');
        expect(response.message.metadata?['response_id'], 'resp_1');
        expect(
          response.message.providerState?.issuer,
          'provider-1|codex_responses|https://chatgpt.com/backend-api/codex',
        );
        expect(
          response.message.providerState?.data['reasoning_items'],
          hasLength(1),
        );
        expect(
          response.message.providerState?.data['message_items'][0]['phase'],
          'final_answer',
        );
      },
    );

    test(
      'generateResponse always sends stream=true for Codex compatibility',
      () async {
        late Map<String, dynamic> requestBody;
        final adapter = CodexResponsesAdapter(
          config,
          profile,
          client: MockClient.streaming((request, _) async {
            requestBody = _map(jsonDecode((request as http.Request).body));
            return http.StreamedResponse(
              Stream.value(
                utf8.encode(
                  _sseResponse({
                    'status': 'completed',
                    'output': [
                      {
                        'type': 'message',
                        'role': 'assistant',
                        'status': 'completed',
                        'content': [
                          {'type': 'output_text', 'text': 'Title'},
                        ],
                      },
                    ],
                  }),
                ),
              ),
              200,
            );
          }),
        );

        await adapter.generateResponse([
          Message(role: MessageRole.user, content: 'Generate a title'),
        ]);

        // Regression: Codex Responses API rejects non-streaming requests with
        // 400 "Stream must be set to true". generateResponse must send
        // stream=true internally even though it returns a single AgentResponse.
        expect(requestBody['stream'], isTrue);
      },
    );

    test(
      'keeps xAI Responses schema sanitization inside provider policy',
      () async {
        late Map<String, dynamic> requestBody;
        const xaiProfile = ProviderProfile(
          name: 'xai-oauth',
          defaultBaseUrl: 'https://x.com/i/api/v1/grok',
          fallbackModels: ['grok-3'],
          apiMode: 'codex_responses',
        );
        final adapter = CodexResponsesAdapter(
          config,
          xaiProfile,
          client: MockClient.streaming((request, _) async {
            requestBody = _map(jsonDecode((request as http.Request).body));
            return http.StreamedResponse(
              Stream.value(
                utf8.encode(
                  _sseResponse({
                    'status': 'completed',
                    'output': [
                      {
                        'type': 'message',
                        'role': 'assistant',
                        'status': 'completed',
                        'content': [
                          {'type': 'output_text', 'text': 'ok'},
                        ],
                      },
                    ],
                  }),
                ),
              ),
              200,
            );
          }),
          defaultModelOverride: 'grok-3',
        );

        await adapter.generateResponse(
          [Message(role: MessageRole.user, content: 'Use tool')],
          tools: [
            ToolSchema(
              name: 'choose_model',
              description: 'Choose',
              parameters: {
                'type': 'object',
                'properties': {
                  'model': {
                    'type': 'string',
                    'enum': ['safe-model', 'Qwen/Qwen3.5-0.8B'],
                  },
                },
              },
            ),
          ],
        );

        expect(
          requestBody['tools'][0]['parameters']['properties']['model']['enum'],
          ['safe-model'],
        );
      },
    );

    test('replays guarded encrypted reasoning without wire IDs', () async {
      final capturedBodies = <Map<String, dynamic>>[];
      var call = 0;
      final mockClient = MockClient.streaming((request, _) async {
        capturedBodies.add(_map(jsonDecode((request as http.Request).body)));
        call++;
        return http.StreamedResponse(
          Stream.value(
            utf8.encode(
              _sseResponse({
                'status': 'completed',
                'output': [
                  if (call == 1)
                    {
                      'id': 'rs_replay',
                      'type': 'reasoning',
                      'encrypted_content': 'sealed',
                      'summary': const [],
                    },
                  {
                    'id': 'msg_replay',
                    'type': 'message',
                    'role': 'assistant',
                    'status': 'completed',
                    'phase': 'final_answer',
                    'content': [
                      {
                        'type': 'output_text',
                        'text': call == 1 ? 'First' : 'Next',
                      },
                    ],
                  },
                ],
              }),
            ),
          ),
          200,
        );
      });
      final adapter = CodexResponsesAdapter(
        config,
        profile,
        client: mockClient,
      );
      const options = LLMRequestOptions(providerInstanceId: 'provider-1');

      final first = await adapter.generateResponse([], options: options);
      await adapter.generateResponse([first.message], options: options);

      final replayInput = capturedBodies[1]['input'] as List;
      final reasoning = replayInput.firstWhere(
        (item) => item['type'] == 'reasoning',
      );
      expect(reasoning, isNot(contains('id')));
      expect(reasoning['encrypted_content'], 'sealed');
      final message = replayInput.firstWhere(
        (item) => item['type'] == 'message',
      );
      expect(message['id'], 'msg_replay');
      expect(message['phase'], 'final_answer');

      final changedEndpoint = CodexResponsesAdapter(
        config,
        profile,
        client: mockClient,
        baseUrlOverride: 'https://other-endpoint.test/v1/',
      );
      await changedEndpoint.generateResponse([first.message], options: options);
      final changedInput = capturedBodies[2]['input'] as List;
      expect(
        changedInput.where((item) => item['type'] == 'reasoning'),
        isEmpty,
      );
      expect(changedInput.single['role'], 'assistant');
      expect(changedInput.single['content'][0]['text'], 'First');
    });

    test(
      'marks invalid encrypted content as replay rejection only when sent',
      () async {
        const issuer =
            'provider-1|codex_responses|https://chatgpt.com/backend-api/codex';
        final adapter = CodexResponsesAdapter(
          config,
          profile,
          client: MockClient.streaming(
            (_, _) async => http.StreamedResponse(
              Stream.value(
                utf8.encode('{"error":{"code":"invalid_encrypted_content"}}'),
              ),
              400,
            ),
          ),
        );
        final replayMessage = Message(
          role: MessageRole.assistant,
          providerState: const LLMProviderState(
            namespace: CodexResponsesCodec.providerStateNamespace,
            issuer: issuer,
            data: {
              'reasoning_items': [
                {'type': 'reasoning', 'encrypted_content': 'sealed'},
              ],
            },
          ),
        );

        expect(
          () => adapter.generateResponse(
            [replayMessage],
            options: const LLMRequestOptions(providerInstanceId: 'provider-1'),
          ),
          throwsA(
            isA<ProviderStateRejectedException>()
                .having((error) => error.issuer, 'issuer', issuer)
                .having(
                  (error) => error.dataKeysToClear,
                  'keys',
                  contains('reasoning_items'),
                ),
          ),
        );
        expect(
          () => adapter.generateResponse(
            [Message(role: MessageRole.user, content: 'No replay')],
            options: const LLMRequestOptions(providerInstanceId: 'provider-1'),
          ),
          throwsA(isA<LlmHttpException>()),
        );
      },
    );

    test(
      'marks streamed invalid encrypted replay as provider-state rejection',
      () async {
        const issuer =
            'provider-1|codex_responses|https://chatgpt.com/backend-api/codex';
        final adapter = CodexResponsesAdapter(
          config,
          profile,
          client: MockClient.streaming(
            (_, _) async => http.StreamedResponse(
              Stream.value(
                utf8.encode('{"error":{"code":"invalid_encrypted_content"}}'),
              ),
              400,
            ),
          ),
        );
        final replayMessage = Message(
          role: MessageRole.assistant,
          providerState: const LLMProviderState(
            namespace: CodexResponsesCodec.providerStateNamespace,
            issuer: issuer,
            data: {
              'reasoning_items': [
                {'type': 'reasoning', 'encrypted_content': 'sealed'},
              ],
            },
          ),
        );

        expect(
          () => adapter.generateStream(
            [replayMessage],
            options: const LLMRequestOptions(providerInstanceId: 'provider-1'),
          ).toList(),
          throwsA(isA<ProviderStateRejectedException>()),
        );
      },
    );

    test('normalizes function and custom tool calls with stable IDs', () async {
      final mockClient = MockClient.streaming(
        (_, _) async => http.StreamedResponse(
          Stream.value(
            utf8.encode(
              _sseResponse({
                'status': 'completed',
                'output': [
                  {
                    'id': 'fc_abc',
                    'type': 'function_call',
                    'name': 'read_file',
                    'arguments': '{"path":"a.txt"}',
                    'status': 'completed',
                  },
                  {
                    'id': 'ct_1',
                    'type': 'custom_tool_call',
                    'name': 'shell',
                    'input': 'pwd',
                    'status': 'completed',
                  },
                ],
              }),
            ),
          ),
          200,
        ),
      );
      final adapter = CodexResponsesAdapter(
        config,
        profile,
        client: mockClient,
      );

      final first = await adapter.generateResponse([]);
      final second = await adapter.generateResponse([]);

      expect(first.finishReason, LLMFinishReason.toolCalls);
      expect(first.message.toolCalls, hasLength(2));
      expect(first.message.toolCalls?[0].id, 'call_abc');
      expect(first.message.toolCalls?[0].arguments, {'path': 'a.txt'});
      expect(
        first.message.toolCalls?[0].providerState?.data['response_item_id'],
        'fc_abc',
      );
      expect(first.message.toolCalls?[1].arguments, {'input': 'pwd'});
      expect(first.message.toolCalls?[1].id, second.message.toolCalls?[1].id);
    });

    test(
      'rejects malformed function arguments instead of executing empty args',
      () async {
        final adapter = CodexResponsesAdapter(
          config,
          profile,
          client: MockClient.streaming(
            (_, _) async => http.StreamedResponse(
              Stream.value(
                utf8.encode(
                  _sseResponse({
                    'status': 'completed',
                    'output': [
                      {
                        'type': 'function_call',
                        'call_id': 'call_bad',
                        'name': 'dangerous_tool',
                        'arguments': '{bad json',
                      },
                    ],
                  }),
                ),
              ),
              200,
            ),
          ),
        );

        expect(
          () => adapter.generateResponse([]),
          throwsA(isA<FormatException>()),
        );
      },
    );

    test(
      'classifies reasoning-only and commentary-only output as incomplete',
      () async {
        var call = 0;
        final adapter = CodexResponsesAdapter(
          config,
          profile,
          client: MockClient.streaming((_, _) async {
            call++;
            return http.StreamedResponse(
              Stream.value(
                utf8.encode(
                  _sseResponse({
                    'status': 'completed',
                    'output': call == 1
                        ? [
                            {
                              'id': 'rs_only',
                              'type': 'reasoning',
                              'encrypted_content': 'opaque',
                              'summary': const [],
                            },
                          ]
                        : [
                            {
                              'type': 'message',
                              'role': 'assistant',
                              'phase': 'commentary',
                              'status': 'completed',
                              'content': [
                                {
                                  'type': 'output_text',
                                  'text': 'Still working',
                                },
                              ],
                            },
                          ],
                  }),
                ),
              ),
              200,
            );
          }),
        );

        final reasoningOnly = await adapter.generateResponse([]);
        final commentaryOnly = await adapter.generateResponse([]);

        expect(reasoningOnly.finishReason, LLMFinishReason.incomplete);
        expect(reasoningOnly.message.content, isNull);
        expect(reasoningOnly.message.providerState, isNotNull);
        expect(commentaryOnly.finishReason, LLMFinishReason.incomplete);
        expect(commentaryOnly.message.content, isNull);
        expect(commentaryOnly.message.thought, 'Still working');
        expect(commentaryOnly.message.reasoning, isNull);
      },
    );

    test('classifies leaked textual tool syntax as incomplete', () async {
      final adapter = CodexResponsesAdapter(
        config,
        profile,
        client: MockClient.streaming(
          (_, _) async => http.StreamedResponse(
            Stream.value(
              utf8.encode(
                _sseResponse({
                  'status': 'completed',
                  'output': [
                    {
                      'type': 'message',
                      'role': 'assistant',
                      'status': 'completed',
                      'content': [
                        {
                          'type': 'output_text',
                          'text':
                              'assistant to=functions.read_file {"path":"a.txt"}',
                        },
                      ],
                    },
                  ],
                }),
              ),
            ),
            200,
          ),
        ),
      );

      final response = await adapter.generateResponse([]);

      expect(response.finishReason, LLMFinishReason.incomplete);
      expect(response.message.content, isNull);
      expect(response.message.toolCalls, isNull);
    });

    test('surfaces terminal response errors with provider code', () async {
      final adapter = CodexResponsesAdapter(
        config,
        profile,
        client: MockClient.streaming(
          (_, _) async => http.StreamedResponse(
            Stream.value(
              utf8.encode(
                _sseResponse({
                  'status': 'failed',
                  'error': {'code': 'model_overloaded', 'message': 'Try later'},
                  'output': const [],
                }, type: 'response.failed'),
              ),
            ),
            200,
          ),
        ),
      );

      expect(
        () => adapter.generateResponse([]),
        throwsA(
          isA<CodexResponsesException>()
              .having((error) => error.code, 'code', 'model_overloaded')
              .having((error) => error.message, 'message', 'Try later'),
        ),
      );
    });

    test('stream accumulates split SSE text, reasoning, arguments, and usage', () async {
      late Map<String, dynamic> streamRequest;
      final terminal = jsonEncode({
        'type': 'response.completed',
        'response': {
          'id': 'resp_stream',
          'status': 'completed',
          'model': 'gpt-5.4',
          'output': [
            {
              'id': 'rs_stream',
              'type': 'reasoning',
              'encrypted_content': 'opaque-stream',
              'summary': [
                {'type': 'summary_text', 'text': 'Plan'},
              ],
            },
            {
              'id': 'msg_stream',
              'type': 'message',
              'role': 'assistant',
              'phase': 'final_answer',
              'status': 'completed',
              'content': [
                {'type': 'output_text', 'text': 'Hello'},
              ],
            },
            {
              'id': 'fc_stream',
              'type': 'function_call',
              'call_id': 'call_stream',
              'name': 'read_file',
              'arguments': '{"path":"a.txt"}',
              'status': 'completed',
            },
          ],
          'usage': {'input_tokens': 4, 'output_tokens': 5, 'total_tokens': 9},
        },
      });
      final events = [
        'data: ${jsonEncode({
          'type': 'response.output_item.added',
          'output_index': 0,
          'item': {'id': 'rs_stream', 'type': 'reasoning', 'summary': []},
        })}\n\n',
        'data: ${jsonEncode({'type': 'response.reasoning_summary_text.delta', 'output_index': 0, 'summary_index': 0, 'delta': 'Plan'})}\n\n',
        'data: ${jsonEncode({
          'type': 'response.output_item.added',
          'output_index': 1,
          'item': {'id': 'msg_stream', 'type': 'message', 'role': 'assistant', 'phase': 'final_answer', 'content': []},
        })}\n\n',
        'data: ${jsonEncode({'type': 'response.output_text.delta', 'output_index': 1, 'content_index': 0, 'delta': 'Hel'})}\n\n',
        'data: ${jsonEncode({'type': 'response.output_text.delta', 'output_index': 1, 'content_index': 0, 'delta': 'lo'})}\n\n',
        'data: ${jsonEncode({
          'type': 'response.output_item.added',
          'output_index': 2,
          'item': {'id': 'fc_stream', 'type': 'function_call', 'call_id': 'call_stream', 'name': 'read_file', 'arguments': ''},
        })}\n\n',
        'data: ${jsonEncode({'type': 'response.function_call_arguments.delta', 'output_index': 2, 'delta': '{"path":'})}\n\n',
        'data: ${jsonEncode({'type': 'response.function_call_arguments.delta', 'output_index': 2, 'delta': '"a.txt"}'})}\n\n',
        'data: $terminal\n\n',
      ].join();
      final splitAt = events.indexOf('"delta":"Hel') + 10;
      final chunks = [events.substring(0, splitAt), events.substring(splitAt)];
      final adapter = CodexResponsesAdapter(
        config,
        profile,
        client: MockClient.streaming((request, _) async {
          streamRequest = _map(jsonDecode((request as http.Request).body));
          return http.StreamedResponse(
            Stream.fromIterable(chunks.map(utf8.encode)),
            200,
          );
        }),
      );

      final responses = await adapter.generateStream([]).toList();

      expect(streamRequest['stream'], isTrue);
      expect(streamRequest['store'], isFalse);
      expect(streamRequest['include'], ['reasoning.encrypted_content']);
      expect(
        responses
            .map((response) => response.message.content)
            .whereType<String>()
            .join(),
        'Hello',
      );
      expect(
        responses
            .map((response) => response.message.reasoning)
            .whereType<String>()
            .join(),
        'Plan',
      );
      final terminalResponse = responses.last;
      expect(terminalResponse.finishReason, LLMFinishReason.toolCalls);
      expect(terminalResponse.message.toolCalls?.single.arguments, {
        'path': 'a.txt',
      });
      expect(terminalResponse.message.providerState, isNotNull);
      expect(terminalResponse.usage?['total_tokens'], 9);
    });

    test(
      'stream separates commentary thoughts and delimits reasoning summaries',
      () async {
        const firstSummary = '**Planning robust fetch state management**';
        const secondSummary = '**Refining initial backend fetch handling**';
        const commentary =
            'سأعدّل منطق الحالة بحيث تنتهي حالة التحميل عند نجاح الطلب.';
        final terminalOutput = [
          {
            'id': 'rs_mixed',
            'type': 'reasoning',
            'summary': [
              {'type': 'summary_text', 'text': firstSummary},
              {'type': 'summary_text', 'text': secondSummary},
            ],
          },
          {
            'id': 'msg_commentary',
            'type': 'message',
            'role': 'assistant',
            'phase': 'commentary',
            'status': 'completed',
            'content': [
              {'type': 'output_text', 'text': commentary},
            ],
          },
          {
            'id': 'msg_final',
            'type': 'message',
            'role': 'assistant',
            'phase': 'final_answer',
            'status': 'completed',
            'content': [
              {'type': 'output_text', 'text': 'Done'},
            ],
          },
        ];
        final events = [
          {
            'type': 'response.output_item.added',
            'output_index': 0,
            'item': {'id': 'rs_mixed', 'type': 'reasoning', 'summary': []},
          },
          {
            'type': 'response.reasoning_summary_text.delta',
            'output_index': 0,
            'summary_index': 0,
            'delta': firstSummary,
          },
          {
            'type': 'response.reasoning_summary_text.delta',
            'output_index': 0,
            'summary_index': 1,
            'delta': secondSummary,
          },
          {
            'type': 'response.output_item.added',
            'output_index': 1,
            'item': {
              'id': 'msg_commentary',
              'type': 'message',
              'role': 'assistant',
              'phase': 'commentary',
              'content': [],
            },
          },
          {
            'type': 'response.output_text.delta',
            'output_index': 1,
            'content_index': 0,
            'delta': commentary,
          },
          {
            'type': 'response.output_item.added',
            'output_index': 2,
            'item': {
              'id': 'msg_final',
              'type': 'message',
              'role': 'assistant',
              'phase': 'final_answer',
              'content': [],
            },
          },
          {
            'type': 'response.output_text.delta',
            'output_index': 2,
            'content_index': 0,
            'delta': 'Done',
          },
          {
            'type': 'response.completed',
            'response': {
              'status': 'completed',
              'model': 'gpt-5.4',
              'output': terminalOutput,
            },
          },
        ].map((event) => 'data: ${jsonEncode(event)}\n\n').join();
        final adapter = CodexResponsesAdapter(
          config,
          profile,
          client: MockClient.streaming(
            (_, _) async =>
                http.StreamedResponse(Stream.value(utf8.encode(events)), 200),
          ),
        );

        final responses = await adapter.generateStream([]).toList();

        expect(
          responses
              .map((response) => response.message.reasoning)
              .whereType<String>()
              .join(),
          '$firstSummary\n\n$secondSummary',
        );
        expect(
          responses
              .map((response) => response.message.thought)
              .whereType<String>()
              .join(),
          commentary,
        );
        expect(
          responses
              .map((response) => response.message.content)
              .whereType<String>()
              .join(),
          'Done',
        );
      },
    );

    test('stream classifies terminal incomplete reasoning state', () async {
      final event = jsonEncode({
        'type': 'response.incomplete',
        'response': {
          'status': 'incomplete',
          'incomplete_details': {'reason': 'max_output_tokens'},
          'output': [
            {
              'id': 'rs_incomplete',
              'type': 'reasoning',
              'encrypted_content': 'opaque',
              'summary': const [],
            },
          ],
        },
      });
      final adapter = CodexResponsesAdapter(
        config,
        profile,
        client: MockClient.streaming(
          (_, _) async => http.StreamedResponse(
            Stream.value(utf8.encode('data: $event\n\n')),
            200,
          ),
        ),
      );

      final responses = await adapter.generateStream([]).toList();

      expect(responses.single.finishReason, LLMFinishReason.incomplete);
      expect(responses.single.message.content, isNull);
      expect(responses.single.message.providerState, isNotNull);
      expect(
        responses.single.message.metadata?['incomplete_details']['reason'],
        'max_output_tokens',
      );
    });

    test(
      'sync and stream send ordered rich function output with exact call id',
      () async {
        final bodies = <Map<String, dynamic>>[];
        final adapter = CodexResponsesAdapter(
          config,
          profile,
          client: MockClient.streaming((request, _) async {
            bodies.add(_map(jsonDecode((request as http.Request).body)));
            return http.StreamedResponse(
              Stream.value(
                utf8.encode(
                  _sseResponse({
                    'status': 'completed',
                    'output': [
                      {
                        'type': 'message',
                        'role': 'assistant',
                        'status': 'completed',
                        'content': [
                          {'type': 'output_text', 'text': 'ok'},
                        ],
                      },
                    ],
                  }),
                ),
              ),
              200,
            );
          }),
        );
        final richResult = ToolExecutionResult(
          blocks: [
            ToolTextBlock(text: 'before'),
            ToolImageBlock(
              dataBase64: 'AQID',
              mimeType: 'image/png',
              width: 1,
              height: 1,
              detail: ToolImageDetail.original,
            ),
            ToolTextBlock(text: 'after'),
          ],
        );
        final history = [
          Message(role: MessageRole.user, content: 'inspect'),
          Message(
            role: MessageRole.assistant,
            toolCalls: [
              ToolCall(id: 'call_image_1', name: 'view_image', arguments: {}),
            ],
          ),
          Message(
            role: MessageRole.tool,
            content: richResult.displayText,
            toolCallId: 'call_image_1',
            toolResult: richResult,
          ),
        ];

        const supportedOptions = LLMRequestOptions(
          routeCapabilityProfile: RouteCapabilityProfile(
            providerInstanceId: 'openai-codex',
            modelId: 'gpt-5.4',
            imageSupport: RouteImageSupport.supported,
            evidenceSource: 'test_fixture',
          ),
        );
        await adapter.generateResponse(history, options: supportedOptions);
        await adapter.generateStream(history, options: supportedOptions).toList();

        expect(bodies, hasLength(2));
        for (final body in bodies) {
          final output = (body['input'] as List).last as Map;
          expect(output['call_id'], 'call_image_1');
          expect(output['output'], [
            {'type': 'input_text', 'text': 'before'},
            {
              'type': 'input_image',
              'image_url': 'data:image/png;base64,AQID',
              'detail': 'high',
            },
            {'type': 'input_text', 'text': 'after'},
          ]);
        }
        expect(richResult.blocks[1], isA<ToolImageBlock>());
      },
    );

    test('preflight rejects malformed tool history before network', () async {
      var sent = false;
      final adapter = CodexResponsesAdapter(
        config,
        profile,
        client: MockClient.streaming((_, _) async {
          sent = true;
          return http.StreamedResponse(
            Stream.value(utf8.encode(_sseResponse({}))),
            200,
          );
        }),
      );

      expect(
        () => adapter.generateResponse([
          Message(role: MessageRole.tool, content: 'result'),
        ]),
        throwsA(isA<FormatException>()),
      );
      expect(sent, isFalse);
    });

    test(
      'wire measurement recognizes only strict request extensions',
      () async {
        final adapter = CodexResponsesAdapter(config, profile);
        final baseline = await adapter.measureInput([
          Message(role: MessageRole.system, content: 'Stable instructions'),
          Message(role: MessageRole.user, content: 'Measured request'),
        ]);
        final extended = await adapter.measureInput([
          Message(role: MessageRole.system, content: 'Stable instructions'),
          Message(role: MessageRole.user, content: 'Measured request'),
          Message(role: MessageRole.user, content: 'Small suffix'),
        ]);
        final changedInstructions = await adapter.measureInput([
          Message(role: MessageRole.system, content: 'Changed instructions'),
          Message(role: MessageRole.user, content: 'Measured request'),
          Message(role: MessageRole.user, content: 'Small suffix'),
        ]);

        expect(extended!.extendsMeasurement(baseline!), isTrue);
        expect(extended.estimatedTokens, greaterThan(baseline.estimatedTokens));
        expect(changedInstructions!.extendsMeasurement(baseline), isFalse);
      },
    );

    test('stream propagates typed stream-level errors', () async {
      final adapter = CodexResponsesAdapter(
        config,
        profile,
        client: MockClient.streaming(
          (_, _) async => http.StreamedResponse(
            Stream.value(
              utf8.encode(
                'data: {"type":"error","error":{"code":"rate_limit_exceeded","message":"Slow down"}}\n\n',
              ),
            ),
            200,
          ),
        ),
      );

      expect(
        () => adapter.generateStream([]).toList(),
        throwsA(
          isA<CodexResponsesException>()
              .having((error) => error.code, 'code', 'rate_limit_exceeded')
              .having(
                (error) => error.message,
                'message',
                'Failed to generate stream: Slow down',
              ),
        ),
      );
    });
  });

  group('Codex prompt cache routing affinity', () {
    late Config config;
    late ProviderProfile profile;

    setUp(() {
      config = Config(
        environment: {
          'ACTIVE_PROVIDER': 'openai-codex',
          'LLM_API_KEY': 'test-codex-key',
          'LLM_MODEL': 'gpt-5.4',
          'LLM_BASE_URL': 'https://chatgpt.com/backend-api/codex',
          'AGENT_NAME': 'TestAgent',
        },
      );
      profile = const ProviderProfile(
        name: 'openai-codex',
        defaultBaseUrl: 'https://chatgpt.com/backend-api/codex',
        fallbackModels: ['gpt-5.4'],
        apiMode: 'codex_responses',
      );
    });

    Config configFor(
      String baseUrl, {
      String provider = 'openai-codex',
      String model = 'gpt-5.4',
    }) => Config(
      environment: {
        'ACTIVE_PROVIDER': provider,
        'LLM_API_KEY': 'test-codex-key',
        'LLM_MODEL': model,
        'LLM_BASE_URL': baseUrl,
        'AGENT_NAME': 'TestAgent',
      },
    );

    ProviderProfile profileFor(
      String baseUrl, {
      String name = 'openai-codex',
      String model = 'gpt-5.4',
    }) => ProviderProfile(
      name: name,
      defaultBaseUrl: baseUrl,
      fallbackModels: [model],
      apiMode: 'codex_responses',
    );

    Future<http.Request> dispatch(
      Config adapterConfig,
      ProviderProfile adapterProfile, {
      required List<Message> history,
      List<ToolSchema>? tools,
      LLMRequestOptions options = const LLMRequestOptions(sessionId: 'sess-a'),
      bool stream = false,
    }) async {
      late http.Request captured;
      final adapter = CodexResponsesAdapter(
        adapterConfig,
        adapterProfile,
        client: MockClient.streaming((request, _) async {
          captured = request as http.Request;
          return http.StreamedResponse(
            Stream.value(
              utf8.encode(_sseResponse({'status': 'completed', 'output': []})),
            ),
            200,
          );
        }),
      );
      if (stream) {
        await adapter
            .generateStream(history, tools: tools, options: options)
            .toList();
      } else {
        await adapter.generateResponse(history, tools: tools, options: options);
      }
      return captured;
    }

    ToolSchema tool(String name, Map<String, dynamic> properties) => ToolSchema(
      name: name,
      description: '$name description',
      parameters: {'type': 'object', 'properties': properties},
    );

    List<ToolSchema> baseTools() => [
      tool('read_file', {
        'path': {'type': 'string'},
      }),
      tool('terminal', {
        'cmd': {'type': 'string'},
      }),
    ];

    Message systemMessage([
      String text = 'Stable conversation instructions',
    ]) => Message(role: MessageRole.system, content: text);

    Message userMessage(String text) =>
        Message(role: MessageRole.user, content: text);

    CodexResponsesCodec codec() => CodexResponsesCodec(
      issuer: 'inst-a|codex_responses|https://chatgpt.com/backend-api/codex',
      defaultProvider: 'openai-codex',
    );

    String? keyFor({
      String instructions = 'Stable conversation instructions',
      List<ToolSchema>? tools,
      String? sessionId = 'sess-a',
    }) => codec()
        .buildRequest(
          history: [systemMessage(instructions), userMessage('Inspect')],
          model: 'gpt-5.4',
          options: LLMRequestOptions(sessionId: sessionId),
          tools: tools,
        )['prompt_cache_key']
        as String?;

    test('prompt-cache host policy excludes only GitHub Responses hosts', () {
      final policy = CodexResponsesPolicy.forProfile(
        const ProviderProfile(name: 'openai-codex'),
      );

      for (final supported in [
        'https://api.x.ai/v1',
        'https://chatgpt.com/backend-api/codex',
        'https://api.openai.com/v1',
        'https://example.com/v1',
        'https://notgithub.ai/v1',
        'https://github.ai.evil.test/v1',
        'https://api.github.com.evil.test/v1',
      ]) {
        expect(
          policy.promptCacheKeySupportedForHost(supported),
          isTrue,
          reason: supported,
        );
      }

      for (final unsupported in [
        'https://api.github.com',
        'https://models.github.ai/inference',
        'https://github.ai/v1',
        'https://api.githubcopilot.com',
        'https://githubcopilot.com',
      ]) {
        expect(
          policy.promptCacheKeySupportedForHost(unsupported),
          isFalse,
          reason: unsupported,
        );
      }
    });

    test('sync and stream send the same key and affinity headers', () async {
      final history = [systemMessage(), userMessage('Inspect the cache')];
      final sync = await dispatch(
        config,
        profile,
        history: history,
        tools: baseTools(),
      );
      final stream = await dispatch(
        config,
        profile,
        history: history,
        tools: baseTools(),
        stream: true,
      );

      final syncBody = _map(jsonDecode(sync.body));
      final streamBody = _map(jsonDecode(stream.body));
      final syncKey = syncBody['prompt_cache_key'];

      expect(syncKey, isA<String>());
      expect(syncKey, startsWith('pck_'));
      expect(streamBody['prompt_cache_key'], syncKey);
      expect(syncBody['stream'], isTrue);
      expect(streamBody['stream'], isTrue);

      expect(sync.headers['session_id'], 'sess-a');
      expect(stream.headers['session_id'], 'sess-a');
      expect(sync.headers['x-client-request-id'], syncKey);
      expect(stream.headers['x-client-request-id'], syncKey);
    });

    test('xAI keeps the body key without Codex-only headers', () async {
      const baseUrl = 'https://api.x.ai/v1';
      final xaiConfig = configFor(
        baseUrl,
        provider: 'xai-oauth',
        model: 'grok-4.7',
      );
      final xaiProfile = profileFor(
        baseUrl,
        name: 'xai-oauth',
        model: 'grok-4.7',
      );
      final history = [systemMessage(), userMessage('Inspect the cache')];

      for (final stream in [false, true]) {
        final request = await dispatch(
          xaiConfig,
          xaiProfile,
          history: history,
          tools: baseTools(),
          stream: stream,
        );
        final body = _map(jsonDecode(request.body));

        expect(body['prompt_cache_key'], startsWith('pck_'));
        expect(request.headers.containsKey('session_id'), isFalse);
        expect(request.headers.containsKey('x-client-request-id'), isFalse);
      }
    });

    test('GitHub Responses hosts drop the routing field', () async {
      final history = [systemMessage(), userMessage('Inspect the cache')];
      for (final baseUrl in [
        'https://api.github.com',
        'https://models.github.ai/inference',
        'https://api.githubcopilot.com',
      ]) {
        final request = await dispatch(
          configFor(baseUrl),
          profileFor(baseUrl),
          history: history,
          tools: baseTools(),
        );
        final body = _map(jsonDecode(request.body));

        expect(
          body.containsKey('prompt_cache_key'),
          isFalse,
          reason: baseUrl,
        );
        expect(request.headers.containsKey('session_id'), isFalse);
        expect(request.headers.containsKey('x-client-request-id'), isFalse);
      }
    });

    test('ordinary OpenAI keeps the body key only', () async {
      const baseUrl = 'https://api.openai.com/v1';
      final openAiConfig = configFor(baseUrl);
      final openAiProfile = profileFor(baseUrl);
      final history = [systemMessage(), userMessage('Inspect the cache')];

      for (final stream in [false, true]) {
        final request = await dispatch(
          openAiConfig,
          openAiProfile,
          history: history,
          tools: baseTools(),
          stream: stream,
        );
        final body = _map(jsonDecode(request.body));

        expect(body['prompt_cache_key'], startsWith('pck_'));
        expect(request.headers.containsKey('session_id'), isFalse);
        expect(request.headers.containsKey('x-client-request-id'), isFalse);
      }
    });

    test('history extension never rotates the key in sync or stream', () async {
      final firstHistory = [systemMessage(), userMessage('Inspect the cache')];
      final extendedHistory = [
        ...firstHistory,
        Message(role: MessageRole.assistant, content: 'Prefix-stable reply'),
        userMessage('Continue'),
      ];

      for (final stream in [false, true]) {
        final first = await dispatch(
          config,
          profile,
          history: firstHistory,
          tools: baseTools(),
          stream: stream,
        );
        final extended = await dispatch(
          config,
          profile,
          history: extendedHistory,
          tools: baseTools(),
          stream: stream,
        );
        final firstBody = _map(jsonDecode(first.body));
        final extendedBody = _map(jsonDecode(extended.body));

        expect(
          extendedBody['prompt_cache_key'],
          firstBody['prompt_cache_key'],
          reason: 'Appending history must not rotate the routing key.',
        );
      }
    });

    test('instruction and tool changes rotate the key', () {
      final baseKey = keyFor(tools: baseTools());

      expect(baseKey, startsWith('pck_'));
      expect(
        keyFor(instructions: 'Changed instructions', tools: baseTools()),
        isNot(baseKey),
      );
      expect(keyFor(tools: [baseTools().first]), isNot(baseKey));
      expect(
        keyFor(
          tools: [
            tool('read_file', {
              'path': {'type': 'string'},
              'limit': {'type': 'integer'},
            }),
            baseTools()[1],
          ],
        ),
        isNot(baseKey),
      );
      expect(
        keyFor(
          tools: [
            ...baseTools(),
            tool('web_search', {
              'query': {'type': 'string'},
            }),
          ],
        ),
        isNot(baseKey),
      );
      expect(
        keyFor(
          tools: [
            tool('read_files', {
              'path': {'type': 'string'},
            }),
            baseTools()[1],
          ],
        ),
        isNot(baseKey),
      );
    });

    test('tool list and schema map insertion order keep the key', () {
      final toolsA = [
        tool('read_file', {
          'path': {'type': 'string'},
          'limit': {'type': 'integer'},
        }),
        baseTools()[1],
      ];
      final toolsB = [
        tool('read_file', {
          'limit': {'type': 'integer'},
          'path': {'type': 'string'},
        }),
        baseTools()[1],
      ];
      final keyA = keyFor(tools: toolsA);

      expect(keyFor(tools: toolsB), keyA);
      expect(keyFor(tools: toolsA.reversed.toList(growable: false)), keyA);
    });

    test('session scope separates keys', () {
      final tools = baseTools();
      final keyA = keyFor(tools: tools);

      expect(keyFor(tools: tools, sessionId: 'sess-a'), keyA);
      expect(keyFor(tools: tools, sessionId: 'sess-b'), isNot(keyA));
      expect(keyFor(tools: tools, sessionId: null), isNot(keyA));
    });

    test('null, blank, and long inputs stay bounded', () {
      expect(CodexResponsesCodec.boundedPromptCacheKey(null), isNull);
      expect(CodexResponsesCodec.boundedPromptCacheKey('   '), isNull);
      expect(
        CodexResponsesCodec.promptCacheKeyFor(
          scopeId: null,
          instructions: null,
          tools: null,
        ),
        isNull,
      );

      final longValue = 'x' * 500;
      final bounded = CodexResponsesCodec.boundedPromptCacheKey(longValue);
      expect(bounded, startsWith('pck_'));
      expect(bounded!.length, lessThanOrEqualTo(64));
      expect(CodexResponsesCodec.boundedPromptCacheKey(longValue), bounded);
      expect(
        CodexResponsesCodec.boundedPromptCacheKey('${longValue}y'),
        isNot(bounded),
      );

      final longKey = keyFor(
        instructions: 'i' * 20000,
        tools: baseTools(),
        sessionId: 's' * 500,
      );
      expect(longKey, startsWith('pck_'));
      expect(longKey!.length, lessThanOrEqualTo(64));
    });

    test(
      'chatgpt.com mirrors the body key without inventing a session',
      () async {
        final request = await dispatch(
          config,
          profile,
          history: [systemMessage(), userMessage('Inspect the cache')],
          tools: baseTools(),
          options: const LLMRequestOptions(sessionId: null),
        );
        final body = _map(jsonDecode(request.body));

        expect(body['prompt_cache_key'], startsWith('pck_'));
        expect(request.headers.containsKey('session_id'), isFalse);
        expect(
          request.headers['x-client-request-id'],
          body['prompt_cache_key'],
        );
      },
    );
  });
}

Map<String, dynamic> _map(dynamic value) =>
    (value as Map).map((key, value) => MapEntry('$key', value));

/// Wraps a JSON response object as a single SSE terminal event.
///
/// Used by tests that need to mock the streaming `generateResponse` path
/// without building granular SSE delta events.
String _sseResponse(
  Map<String, dynamic> response, {
  String type = 'response.completed',
}) {
  return 'data: ${jsonEncode({'type': type, 'response': response})}\n\n';
}
