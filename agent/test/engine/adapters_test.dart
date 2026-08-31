import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/models/agent_response.dart';
import 'package:sanad_agent/core/models/llm_provider_state.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/models/tool_call.dart';
import 'package:sanad_agent/core/models/llm_finish_reason.dart';
import 'package:sanad_agent/engine/adapters/provider_registry.dart';
import 'package:sanad_agent/engine/adapters/provider_profile.dart';
import 'package:sanad_agent/engine/adapters/base_openai_adapter.dart';
import 'package:sanad_agent/engine/adapters/base_anthropic_adapter.dart';
import 'package:sanad_agent/engine/adapters/ollama_adapter.dart';
import 'package:sanad_agent/engine/adapters/models_dev_service.dart';
import 'package:sanad_agent/engine/adapters/llm_http_exception.dart';
import 'package:sanad_agent/core/provider_thinking/native_thinking_directive.dart';
import 'package:sanad_agent/engine/adapters/llm_request_options.dart';

class MockConfig extends Config {
  @override
  String get llmApiKey => 'test-key';
  @override
  String get llmBaseUrl => 'https://api.test.com';
  @override
  String get llmModel => 'test-model';

  @override
  String apiKeyFor(ProviderProfile profile) => 'test-key';
  @override
  String baseUrlFor(ProviderProfile profile) => 'https://api.test.com';
}

class OpenRouterMockConfig extends MockConfig {
  @override
  String get llmBaseUrl => 'https://openrouter.ai/api/v1';

  @override
  String get llmModel => 'openai/gpt-5.5';

  @override
  String baseUrlFor(ProviderProfile profile) => 'https://openrouter.ai/api/v1';
}

class NvidiaAutoDetectConfig extends Config {
  NvidiaAutoDetectConfig({super.environment});

  @override
  String get activeProvider => '';
}

class StreamingTestClient extends http.BaseClient {
  final http.StreamedResponse Function(http.BaseRequest request) _handler;

  StreamingTestClient(this._handler);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    return _handler(request);
  }
}

String getTempCachePath() {
  final tempDir = Directory.systemTemp.createTempSync('models_dev_test_');
  return p.join(tempDir.path, 'models_dev_cache.json');
}

void _cleanupTempCache(String path) {
  try {
    final file = File(path);
    if (file.existsSync()) {
      file.deleteSync();
    }
    final parent = Directory(p.dirname(path));
    if (parent.existsSync()) {
      parent.deleteSync(recursive: true);
    }
  } catch (_) {}
}

void main() {
  final config = MockConfig();

  group('BaseOpenAIAdapter (Standard OpenAI Profile)', () {
    final profile = ProviderRegistry.findByNameOrAlias('openai')!;

    test('should parse successful response', () async {
      final mockClient = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'role': 'assistant',
                  'content': 'Hello from OpenAI',
                },
              },
            ],
          }),
          200,
        );
      });

      final adapter = BaseOpenAIAdapter(config, profile, client: mockClient);
      final response = await adapter.generateResponse([
        Message(role: MessageRole.user, content: 'Hi'),
      ]);

      expect(response.message.content, 'Hello from OpenAI');
    });

    test('should filter models using ModelsDevService', () async {
      final tempCachePath = getTempCachePath();
      addTearDown(() => _cleanupTempCache(tempCachePath));

      final mockRegistryData = {
        'openai': {
          'name': 'OpenAI',
          'models': {
            'gpt-4o': {
              'name': 'GPT-4o',
              'tool_call': true,
              'reasoning': false,
              'limit': {'context': 128000},
            },
            'text-embedding-3-small': {
              'name': 'Text Embedding 3 Small',
              'tool_call': false,
              'reasoning': false,
              'limit': {'context': 8192},
            },
          },
        },
      };

      final mockHttpClient = MockClient((request) async {
        if (request.url.path.endsWith('/models')) {
          return http.Response(
            jsonEncode({
              'data': [
                {'id': 'gpt-4o'},
                {'id': 'text-embedding-3-small'},
              ],
            }),
            200,
          );
        }
        return http.Response(jsonEncode(mockRegistryData), 200);
      });

      final modelsDevService = ModelsDevService(
        client: mockHttpClient,
        cacheFilePathOverride: tempCachePath,
      );
      final adapter = BaseOpenAIAdapter(
        config,
        profile,
        client: mockHttpClient,
        modelsDevService: modelsDevService,
      );

      final models = await adapter.getAvailableModels();
      final values = models.map((m) => m.value).toList();

      expect(values, contains('gpt-4o'));
      expect(values, isNot(contains('text-embedding-3-small')));
    });

    test(
      'should keep live family variants when models.dev misses exact GLM ids',
      () async {
        final tempCachePath = getTempCachePath();
        addTearDown(() => _cleanupTempCache(tempCachePath));

        final zaiCodingProfile = ProviderRegistry.findByNameOrAlias(
          'zai-coding',
        )!;
        final mockHttpClient = MockClient((request) async {
          if (request.url.path.endsWith('/models')) {
            return http.Response(
              jsonEncode({
                'data': [
                  {'id': 'glm-4.5'},
                  {'id': 'glm-4.5-air'},
                  {'id': 'glm-4.6'},
                  {'id': 'glm-4.7'},
                  {'id': 'glm-5'},
                  {'id': 'glm-5-turbo'},
                  {'id': 'glm-5.1'},
                  {'id': 'glm-5.2'},
                ],
              }),
              200,
            );
          }
          return http.Response(
            jsonEncode({
              'zai-coding-plan': {
                'name': 'Z.AI Coding Plan',
                'models': {
                  'glm-4.5-air': {
                    'tool_call': true,
                    'reasoning': true,
                    'limit': {'context': 131072},
                  },
                  'glm-4.7': {
                    'tool_call': true,
                    'reasoning': true,
                    'limit': {'context': 204800},
                  },
                  'glm-5-turbo': {
                    'tool_call': true,
                    'reasoning': true,
                    'limit': {'context': 200000},
                  },
                  'glm-5.1': {
                    'tool_call': true,
                    'reasoning': true,
                    'limit': {'context': 200000},
                  },
                  'glm-5.2': {
                    'tool_call': true,
                    'reasoning': true,
                    'limit': {'context': 1000000},
                  },
                },
              },
            }),
            200,
          );
        });

        final modelsDevService = ModelsDevService(
          client: mockHttpClient,
          cacheFilePathOverride: tempCachePath,
        );
        final adapter = BaseOpenAIAdapter(
          config,
          zaiCodingProfile,
          client: mockHttpClient,
          modelsDevService: modelsDevService,
        );

        final models = await adapter.getAvailableModels();
        final values = models.map((m) => m.value).toList();

        expect(
          values,
          containsAll([
            'glm-4.5',
            'glm-4.5-air',
            'glm-4.6',
            'glm-4.7',
            'glm-5',
            'glm-5-turbo',
            'glm-5.1',
            'glm-5.2',
          ]),
        );
      },
    );

    test('should extract reasoning from tags', () async {
      final mockClient = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'role': 'assistant',
                  'content': '<thought>Thinking process</thought>Actual answer',
                },
              },
            ],
          }),
          200,
        );
      });

      final adapter = BaseOpenAIAdapter(config, profile, client: mockClient);
      final response = await adapter.generateResponse([]);

      expect(response.message.reasoning, 'Thinking process');
      expect(response.message.content, 'Actual answer');
    });

    test(
      'uses one request builder for sync and stream reasoning options',
      () async {
        final capturedBodies = <Map<String, dynamic>>[];
        final mockClient = StreamingTestClient((request) {
          final body = jsonDecode((request as http.Request).body);
          capturedBodies.add((body as Map).cast<String, dynamic>());
          final isStream = body['stream'] == true;
          final payload = isStream
              ? [
                  'data: ${jsonEncode({
                    'choices': [
                      {
                        'delta': {'content': 'Hello'},
                        'finish_reason': 'stop',
                      },
                    ],
                  })}',
                  'data: [DONE]',
                ].join('\n')
              : jsonEncode({
                  'choices': [
                    {
                      'message': {'content': 'Hello'},
                      'finish_reason': 'stop',
                    },
                  ],
                });
          return http.StreamedResponse(
            Stream.value(utf8.encode(payload)),
            200,
            headers: {
              'content-type': isStream
                  ? 'text/event-stream'
                  : 'application/json',
            },
          );
        });
        final openRouterProfile = ProviderRegistry.findByNameOrAlias(
          'openrouter',
        )!;
        final adapter = BaseOpenAIAdapter(
          config,
          openRouterProfile,
          client: mockClient,
        );
        const options = LLMRequestOptions(
          thinkingDirective: OpenAiEffortDirective('high'),
          maxOutputTokens: 4096,
        );

        await adapter.generateResponse(
          [Message(role: MessageRole.user, content: 'Hi')],
          modelOverride: 'o3',
          options: options,
        );
        await adapter
            .generateStream(
              [Message(role: MessageRole.user, content: 'Hi')],
              modelOverride: 'o3',
              options: options,
            )
            .toList();

        expect(capturedBodies, hasLength(2));
        expect(capturedBodies[0]['reasoning'], {
          'enabled': true,
          'effort': 'high',
        });
        expect(capturedBodies[0].containsKey('reasoning_effort'), isFalse);
        expect(capturedBodies[0]['max_completion_tokens'], 4096);
        final streamOnlyKeys = {'stream', 'stream_options'};
        expect(
          Map.of(capturedBodies[1])
            ..removeWhere((key, _) => streamOnlyKeys.contains(key)),
          capturedBodies[0],
        );
      },
    );

    test(
      'uses top-level reasoning_effort for OpenAI Chat sync and stream',
      () async {
        final capturedBodies = <Map<String, dynamic>>[];
        final mockClient = StreamingTestClient((request) {
          final body = jsonDecode((request as http.Request).body);
          capturedBodies.add((body as Map).cast<String, dynamic>());
          final isStream = body['stream'] == true;
          final payload = isStream
              ? [
                  'data: ${jsonEncode({
                    'choices': [
                      {
                        'delta': {'content': 'Hello'},
                        'finish_reason': 'stop',
                      },
                    ],
                  })}',
                  'data: [DONE]',
                ].join('\n')
              : jsonEncode({
                  'choices': [
                    {
                      'message': {'content': 'Hello'},
                      'finish_reason': 'stop',
                    },
                  ],
                });
          return http.StreamedResponse(
            Stream.value(utf8.encode(payload)),
            200,
            headers: {
              'content-type': isStream
                  ? 'text/event-stream'
                  : 'application/json',
            },
          );
        });
        final adapter = BaseOpenAIAdapter(
          config,
          profile,
          client: mockClient,
        );
        const options = LLMRequestOptions(
          thinkingDirective: OpenAiEffortDirective('medium'),
        );

        await adapter.generateResponse(
          [Message(role: MessageRole.user, content: 'Hi')],
          modelOverride: 'o3',
          options: options,
        );
        await adapter
            .generateStream(
              [Message(role: MessageRole.user, content: 'Hi')],
              modelOverride: 'o3',
              options: options,
            )
            .toList();

        expect(capturedBodies, hasLength(2));
        expect(capturedBodies[0]['reasoning_effort'], 'medium');
        expect(capturedBodies[0].containsKey('reasoning'), isFalse);
        final streamOnlyKeys = {'stream', 'stream_options'};
        expect(
          Map.of(capturedBodies[1])
            ..removeWhere((key, _) => streamOnlyKeys.contains(key)),
          capturedBodies[0],
        );
      },
    );

    test(
      'uses nested google thinking_config for Gemini profile requests',
      () async {
        late Map<String, dynamic> requestBody;
        final geminiProfile = ProviderRegistry.findByNameOrAlias('gemini')!;
        final mockClient = MockClient((request) async {
          requestBody = (jsonDecode(request.body) as Map)
              .cast<String, dynamic>();
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': 'Hello'},
                  'finish_reason': 'stop',
                },
              ],
            }),
            200,
          );
        });
        final adapter = BaseOpenAIAdapter(
          config,
          geminiProfile,
          client: mockClient,
        );

        await adapter.generateResponse(
          [Message(role: MessageRole.user, content: 'Hi')],
          modelOverride: 'gemini-2.5-flash',
          options: const LLMRequestOptions(
            thinkingDirective: GoogleBudgetDirective(8192),
          ),
        );

        expect(requestBody['extra_body'], {
          'google': {
            'thinking_config': {'thinking_budget': 8192},
          },
        });
        expect(requestBody.containsKey('reasoning_effort'), isFalse);
      },
    );

    test(
      'prefers structured reasoning and preserves guarded provider state',
      () async {
        late Map<String, dynamic> requestBody;
        final reasoningDetails = [
          {
            'type': 'reasoning.encrypted',
            'data': 'opaque',
            'summary': 'Structured thought',
          },
        ];
        final mockClient = MockClient((request) async {
          requestBody = (jsonDecode(request.body) as Map)
              .cast<String, dynamic>();
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {
                    'content': '<thought>tag fallback</thought>Final answer',
                    'reasoning_content': 'Structured thought',
                    'reasoning_details': reasoningDetails,
                  },
                  'finish_reason': 'stop',
                },
              ],
            }),
            200,
          );
        });
        final adapter = BaseOpenAIAdapter(config, profile, client: mockClient);
        const options = LLMRequestOptions(providerInstanceId: 'provider-1');

        final first = await adapter.generateResponse([], options: options);
        expect(first.message.reasoning, 'Structured thought');
        expect(first.message.content, 'Final answer');
        expect(first.finishReason, LLMFinishReason.stop);
        expect(
          first.message.providerState?.data['reasoning_details'],
          reasoningDetails,
        );
        expect(
          first.message.providerState?.issuer,
          'provider-1|openai_compatible|https://api.test.com',
        );

        await adapter.generateResponse([first.message], options: options);
        expect(
          (requestBody['messages'] as List).single['reasoning_details'],
          reasoningDetails,
        );

        await adapter.generateResponse([
          first.message,
        ], options: const LLMRequestOptions(providerInstanceId: 'provider-2'));
        expect(
          (requestBody['messages'] as List).single,
          isNot(contains('reasoning_details')),
        );

        final endpointChangedAdapter = BaseOpenAIAdapter(
          config,
          profile,
          client: mockClient,
          baseUrlOverride: 'https://other-endpoint.test/v1/',
        );
        await endpointChangedAdapter.generateResponse([
          first.message,
        ], options: options);
        expect(
          (requestBody['messages'] as List).single,
          isNot(contains('reasoning_details')),
        );
      },
    );

    test(
      'extracts streamed reasoning separately and normalizes terminal state',
      () async {
        final streamEvents = [
          {
            'choices': [
              {
                'delta': {'reasoning_content': 'Think '},
                'finish_reason': null,
              },
            ],
          },
          {
            'choices': [
              {
                'delta': {
                  'reasoning_details': [
                    {'type': 'reasoning.text', 'text': 'carefully'},
                  ],
                },
                'finish_reason': null,
              },
            ],
          },
          {
            'choices': [
              {
                'delta': {'content': 'Answer'},
                'finish_reason': 'length',
              },
            ],
            'usage': {'prompt_tokens': 2, 'completion_tokens': 3},
          },
        ];
        final mockClient = StreamingTestClient(
          (_) => http.StreamedResponse(
            Stream.value(
              utf8.encode(
                [
                  for (final event in streamEvents)
                    'data: ${jsonEncode(event)}',
                  'data: [DONE]',
                ].join('\n'),
              ),
            ),
            200,
            headers: {'content-type': 'text/event-stream'},
          ),
        );
        final adapter = BaseOpenAIAdapter(config, profile, client: mockClient);

        final responses = await adapter
            .generateStream(
              [],
              options: const LLMRequestOptions(
                providerInstanceId: 'provider-stream',
              ),
            )
            .toList();

        expect(
          responses
              .map((response) => response.message.reasoning)
              .whereType<String>()
              .join(),
          'Think carefully',
        );
        expect(
          responses
              .map((response) => response.message.content)
              .whereType<String>()
              .join(),
          'Answer',
        );
        expect(
          responses.any(
            (response) => response.finishReason == LLMFinishReason.length,
          ),
          isTrue,
        );
        final state = responses
            .map((response) => response.message.providerState)
            .whereType<LLMProviderState>()
            .single;
        expect(
          state.issuer,
          'provider-stream|openai_compatible|https://api.test.com',
        );
        expect(state.data['reasoning_details'], hasLength(1));
      },
    );

    test('uses thought tags only as a streamed reasoning fallback', () async {
      final chunks = ['<tho', 'ught>Fallback', ' thought</thought>Final'];
      final mockClient = StreamingTestClient(
        (_) => http.StreamedResponse(
          Stream.value(
            utf8.encode(
              [
                for (var i = 0; i < chunks.length; i++)
                  'data: ${jsonEncode({
                    'choices': [
                      {
                        'delta': {'content': chunks[i]},
                        'finish_reason': i == chunks.length - 1 ? 'stop' : null,
                      },
                    ],
                  })}',
                'data: [DONE]',
              ].join('\n'),
            ),
          ),
          200,
          headers: {'content-type': 'text/event-stream'},
        ),
      );
      final adapter = BaseOpenAIAdapter(config, profile, client: mockClient);

      final responses = await adapter.generateStream([]).toList();

      expect(
        responses
            .map((response) => response.message.reasoning)
            .whereType<String>()
            .join(),
        'Fallback thought',
      );
      expect(
        responses
            .map((response) => response.message.content)
            .whereType<String>()
            .join(),
        'Final',
      );
    });

    test('extracts split think tags without leaking the closing tag', () async {
      final chunks = [
        '<thi',
        'nk>Hidden reasoning',
        '</thi',
        'nk>Final answer',
      ];
      final mockClient = StreamingTestClient(
        (_) => http.StreamedResponse(
          Stream.value(
            utf8.encode(
              [
                for (var i = 0; i < chunks.length; i++)
                  'data: ${jsonEncode({
                    'choices': [
                      {
                        'delta': {'content': chunks[i]},
                        'finish_reason': i == chunks.length - 1 ? 'stop' : null,
                      },
                    ],
                  })}',
                'data: [DONE]',
              ].join('\n'),
            ),
          ),
          200,
          headers: {'content-type': 'text/event-stream'},
        ),
      );
      final adapter = BaseOpenAIAdapter(config, profile, client: mockClient);

      final responses = await adapter.generateStream([]).toList();

      expect(
        responses
            .map((response) => response.message.reasoning)
            .whereType<String>()
            .join(),
        'Hidden reasoning',
      );
      final visible = responses
          .map((response) => response.message.content)
          .whereType<String>()
          .join();
      expect(visible, 'Final answer');
      expect(visible, isNot(contains('</think>')));
      final reasoningResponseIndex = responses.indexWhere(
        (response) => response.message.reasoning?.isNotEmpty ?? false,
      );
      final contentResponseIndex = responses.indexWhere(
        (response) => response.message.content?.isNotEmpty ?? false,
      );
      expect(
        reasoningResponseIndex,
        lessThan(contentResponseIndex),
        reason: 'tagged reasoning must be emitted before the post-tag answer',
      );
    });

    test('should return curated OpenRouter models in fixed order', () async {
      final mockClient = MockClient((request) async {
        if (request.url.toString() == 'https://openrouter.ai/api/v1/models') {
          return http.Response(
            jsonEncode({
              'data': [
                {'id': 'google/gemma-4-31b-it', 'context_length': 262144},
                {'id': 'openai/gpt-5.5', 'context_length': 1050000},
                {'id': 'anthropic/claude-opus-4.7', 'context_length': 1000000},
                {
                  'id': '~anthropic/claude-sonnet-latest',
                  'context_length': 1000000,
                },
              ],
            }),
            200,
          );
        }

        return http.Response('{}', 404);
      });

      final orProfile = ProviderRegistry.findByNameOrAlias('openrouter')!;
      final adapter = BaseOpenAIAdapter(
        OpenRouterMockConfig(),
        orProfile,
        client: mockClient,
      );
      final models = await adapter.getAvailableModels();

      expect(
        models.map((m) => m.label).toList(),
        equals([
          'GPT 5.5',
          'Claude Opus 4.7',
          'Claude Sonnet Latest',
          'Gemma 4 31b It',
        ]),
      );
    });

    test('should fall back to curated models when live fetch fails', () async {
      final codexProfile = ProviderRegistry.findByNameOrAlias('openai-codex')!;
      final mockClient = MockClient(
        (request) async => http.Response('{}', 404),
      );

      final adapter = BaseOpenAIAdapter(
        MockConfig(),
        codexProfile,
        client: mockClient,
        defaultModelOverride: 'gpt-5.5',
      );
      final models = await adapter.getAvailableModels();

      expect(models.length, greaterThan(3));
      expect(models.first.value, equals('gpt-5.5'));
      expect(models.map((m) => m.value), contains('gpt-5.4'));
      expect(models.map((m) => m.value), contains('gpt-4o'));
    });

    test(
      'should retry custom openai-compatible model fetch under /v1/models',
      () async {
        final customProfile = const ProviderProfile(
          name: 'custom',
          displayName: 'Custom Provider',
          authType: 'api_key',
          apiMode: 'chat_completions',
        );
        final mockClient = MockClient((request) async {
          if (request.url.toString() == 'http://localhost:9000/models') {
            return http.Response('{"detail":"Not Found"}', 404);
          }
          if (request.url.toString() == 'http://localhost:9000/v1/models') {
            return http.Response(
              jsonEncode({
                'data': [
                  {'id': 'claude-sonnet-4.5'},
                  {'id': 'claude-haiku-4.5'},
                ],
              }),
              200,
            );
          }
          return http.Response('{}', 404);
        });

        final adapter = BaseOpenAIAdapter(
          MockConfig(),
          customProfile,
          client: mockClient,
          baseUrlOverride: 'http://localhost:9000',
          defaultModelOverride: 'claude-sonnet-4.5',
        );
        final models = await adapter.getAvailableModels();

        expect(models.map((m) => m.value), contains('claude-sonnet-4.5'));
        expect(models.map((m) => m.value), contains('claude-haiku-4.5'));
      },
    );

    test(
      'should keep the full live model list for custom openai-compatible providers',
      () async {
        final customProfile = const ProviderProfile(
          name: 'custom',
          displayName: 'Custom Provider',
          authType: 'api_key',
          authFlow: 'custom_endpoint',
          apiMode: 'chat_completions',
        );
        final mockClient = MockClient((request) async {
          return http.Response(
            jsonEncode({
              'data': [
                {'id': 'auto-kiro'},
                {'id': 'claude-haiku-4.5'},
                {'id': 'claude-opus-4.5'},
                {'id': 'claude-opus-4.6'},
                {'id': 'claude-opus-4.7'},
                {'id': 'claude-sonnet-4'},
                {'id': 'claude-sonnet-4.5'},
                {'id': 'claude-sonnet-4.6'},
                {'id': 'deepseek-3.2'},
                {'id': 'glm-5'},
                {'id': 'minimax-m2.1'},
                {'id': 'minimax-m2.5'},
                {'id': 'qwen3-coder-next'},
              ],
            }),
            200,
          );
        });

        final adapter = BaseOpenAIAdapter(
          MockConfig(),
          customProfile,
          client: mockClient,
          baseUrlOverride: 'http://localhost:9000/v1',
          apiKeyOverride: 'test-key',
        );
        final models = await adapter.getAvailableModels();

        expect(models, hasLength(13));
        expect(models.map((m) => m.value), contains('auto-kiro'));
        expect(models.map((m) => m.value), contains('qwen3-coder-next'));
      },
    );

    test(
      'should accumulate streamed tool call arguments before decoding',
      () async {
        final streamEvents = [
          {
            'choices': [
              {
                'delta': {
                  'tool_calls': [
                    {
                      'index': 0,
                      'id': 'call_1',
                      'function': {'name': 'search', 'arguments': '{"q":'},
                    },
                  ],
                },
              },
            ],
          },
          {
            'choices': [
              {
                'delta': {
                  'tool_calls': [
                    {
                      'index': 0,
                      'function': {'arguments': '"hello"}'},
                    },
                  ],
                },
              },
            ],
          },
          {
            'choices': [],
            'usage': {
              'prompt_tokens': 10,
              'completion_tokens': 4,
              'total_tokens': 14,
            },
          },
        ];
        final streamedBody = [
          for (final event in streamEvents) 'data: ${jsonEncode(event)}',
          'data: [DONE]',
        ].join('\n');

        final mockClient = StreamingTestClient((request) {
          if (request.method == 'POST' &&
              request.url.toString() ==
                  'https://api.test.com/chat/completions') {
            return http.StreamedResponse(
              Stream.value(utf8.encode(streamedBody)),
              200,
              headers: {'content-type': 'text/event-stream'},
            );
          }
          return http.StreamedResponse(Stream.value(utf8.encode('')), 404);
        });

        final adapter = BaseOpenAIAdapter(config, profile, client: mockClient);
        final responses = await adapter.generateStream([
          Message(role: MessageRole.user, content: 'hi'),
        ]).toList();

        final toolResponse = responses.firstWhere((r) => r.isToolCall);
        expect(toolResponse.message.toolCalls, isNotNull);
        expect(toolResponse.message.toolCalls!.single.name, 'search');
        expect(
          toolResponse.message.toolCalls!.single.arguments,
          equals({'q': 'hello'}),
        );
      },
    );

    test('should parse OpenAI HTTP-200 SSE error', () async {
      final sseErrorPayload =
          'data: ${jsonEncode({
            'error': {'type': 'invalid_request_error', 'code': 'invalid_value', 'message': 'Some invalid value'},
          })}\n\n';

      final mockClient = StreamingTestClient((request) {
        return http.StreamedResponse(
          Stream.value(utf8.encode(sseErrorPayload)),
          200,
          headers: {
            'content-type': 'text/event-stream',
            'X-Test-Header': 'val',
          },
        );
      });

      final adapter = BaseOpenAIAdapter(config, profile, client: mockClient);

      expect(
        () => adapter.generateStream([
          Message(role: MessageRole.user, content: 'hi'),
        ]).toList(),
        throwsA(
          isA<LlmHttpException>()
              .having((e) => e.body, 'body', contains('invalid_request_error'))
              .having(
                (e) => e.headers['X-Test-Header'],
                'headers',
                equals('val'),
              ),
        ),
      );
    });

    test('should parse SSE rate limit with Retry-After header', () async {
      final sseErrorPayload =
          'data: ${jsonEncode({
            'error': {'type': 'rate_limit_error', 'code': 'rate_limit_exceeded', 'message': 'Rate limit reached'},
          })}\n\n';

      final mockClient = StreamingTestClient((request) {
        return http.StreamedResponse(
          Stream.value(utf8.encode(sseErrorPayload)),
          200,
          headers: {'content-type': 'text/event-stream', 'retry-after': '45'},
        );
      });

      final adapter = BaseOpenAIAdapter(config, profile, client: mockClient);

      try {
        await adapter.generateStream([
          Message(role: MessageRole.user, content: 'hi'),
        ]).toList();
        fail('Expected LlmHttpException');
      } on LlmHttpException catch (e) {
        expect(e.headers['retry-after'], equals('45'));
        expect(e.retryAfter, equals(const Duration(seconds: 45)));
      }
    });
  });

  group('OllamaAdapter (Ollama Profile)', () {
    final profile = ProviderRegistry.findByNameOrAlias('ollama')!;

    test('should parse successful Ollama response', () async {
      final mockClient = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'message': {'role': 'assistant', 'content': 'Hello from Ollama'},
            'prompt_eval_count': 10,
            'eval_count': 5,
            'done': true,
          }),
          200,
        );
      });

      final adapter = OllamaAdapter(config, profile, client: mockClient);
      final response = await adapter.generateResponse([]);

      expect(response.message.content, 'Hello from Ollama');
      expect(response.usage?['prompt_tokens'], 10);
      expect(response.usage?['completion_tokens'], 5);
      expect(response.usage, isNot(contains('total_tokens')));
    });

    test(
      'keeps Ollama structured reasoning separate from final content',
      () async {
        final mockClient = MockClient((request) async {
          return http.Response(
            jsonEncode({
              'message': {
                'role': 'assistant',
                'thinking': 'Inspecting locally',
                'content': 'Finished',
              },
              'done': true,
            }),
            200,
          );
        });

        final adapter = OllamaAdapter(config, profile, client: mockClient);
        final response = await adapter.generateResponse([]);

        expect(response.message.reasoning, 'Inspecting locally');
        expect(response.message.content, 'Finished');
      },
    );

    test('streams Ollama reasoning separately from answer chunks', () async {
      final payload = [
        jsonEncode({
          'message': {'thinking': 'Plan ', 'content': ''},
          'done': false,
        }),
        jsonEncode({
          'message': {'thinking': 'carefully', 'content': ''},
          'done': false,
        }),
        jsonEncode({
          'message': {'content': 'Answer'},
          'done': true,
        }),
      ].join('\n');
      final mockClient = StreamingTestClient(
        (_) => http.StreamedResponse(Stream.value(utf8.encode(payload)), 200),
      );

      final adapter = OllamaAdapter(config, profile, client: mockClient);
      final responses = await adapter.generateStream([]).toList();

      expect(
        responses
            .map((response) => response.message.reasoning)
            .whereType<String>()
            .join(),
        'Plan carefully',
      );
      expect(
        responses
            .map((response) => response.message.content)
            .whereType<String>()
            .join(),
        'Answer',
      );
    });

    test(
      'uses one request builder for sync and stream Ollama think directives',
      () async {
        final capturedBodies = <Map<String, dynamic>>[];
        final mockClient = StreamingTestClient((request) {
          final body = jsonDecode((request as http.Request).body);
          capturedBodies.add((body as Map).cast<String, dynamic>());
          final isStream = body['stream'] == true;
          final payload = isStream
              ? jsonEncode({
                  'message': {'content': 'Hello'},
                  'done': true,
                })
              : jsonEncode({
                  'message': {'content': 'Hello'},
                  'done': true,
                });
          return http.StreamedResponse(
            Stream.value(utf8.encode(payload)),
            200,
          );
        });
        final adapter = OllamaAdapter(config, profile, client: mockClient);
        const options = LLMRequestOptions(
          thinkingDirective: OllamaThinkLevelDirective('medium'),
        );

        await adapter.generateResponse(
          [Message(role: MessageRole.user, content: 'Hi')],
          modelOverride: 'qwen3:8b',
          options: options,
        );
        await adapter
            .generateStream(
              [Message(role: MessageRole.user, content: 'Hi')],
              modelOverride: 'qwen3:8b',
              options: options,
            )
            .toList();

        expect(capturedBodies, hasLength(2));
        expect(capturedBodies[0]['think'], 'medium');
        expect(capturedBodies[1]['think'], 'medium');
      },
    );
  });

  group('BaseAnthropicAdapter (Native Anthropic)', () {
    final profile = ProviderRegistry.findByNameOrAlias('anthropic')!;

    test('should parse successful Claude responses API format', () async {
      final mockClient = MockClient((request) async {
        expect(request.headers['x-api-key'], 'test-key');
        expect(request.headers['anthropic-version'], '2023-06-01');
        return http.Response(
          jsonEncode({
            'content': [
              {'type': 'thinking', 'thinking': 'Inspecting with Claude'},
              {'type': 'text', 'text': 'Hello from Claude'},
            ],
            'usage': {
              'input_tokens': 10,
              'output_tokens': 5,
              'cache_read_input_tokens': 7,
              'cache_creation_input_tokens': 2,
            },
          }),
          200,
        );
      });

      final adapter = BaseAnthropicAdapter(config, profile, client: mockClient);
      final response = await adapter.generateResponse([
        Message(role: MessageRole.user, content: 'Hi Claude'),
      ]);

      expect(response.message.content, 'Hello from Claude');
      expect(response.message.reasoning, 'Inspecting with Claude');
      expect(response.usage?['prompt_tokens'], 10);
      expect(response.usage?['completion_tokens'], 5);
      expect(response.usage?['cache_read_input_tokens'], 7);
      expect(response.usage?['cache_creation_input_tokens'], 2);
      expect(response.usage, isNot(contains('total_tokens')));
    });

    test(
      'uses one request builder for sync and stream manual thinking directives',
      () async {
        final capturedBodies = <Map<String, dynamic>>[];
        final mockClient = StreamingTestClient((request) {
          final body = jsonDecode((request as http.Request).body);
          capturedBodies.add((body as Map).cast<String, dynamic>());
          final isStream = body['stream'] == true;
          final payload = isStream
              ? [
                  'event: message_start\ndata: ${jsonEncode({
                    'type': 'message_start',
                    'message': {
                      'content': [],
                      'usage': {'input_tokens': 1, 'output_tokens': 0},
                    },
                  })}\n',
                  'event: content_block_delta\ndata: ${jsonEncode({
                    'type': 'content_block_delta',
                    'delta': {'type': 'text_delta', 'text': 'Hello'},
                  })}\n',
                  'event: message_stop\ndata: ${jsonEncode({'type': 'message_stop'})}\n',
                ].join()
              : jsonEncode({
                  'content': [
                    {'type': 'text', 'text': 'Hello'},
                  ],
                });
          return http.StreamedResponse(
            Stream.value(utf8.encode(payload)),
            200,
            headers: {
              'content-type': isStream
                  ? 'text/event-stream'
                  : 'application/json',
            },
          );
        });
        final adapter = BaseAnthropicAdapter(config, profile, client: mockClient);
        const options = LLMRequestOptions(
          maxOutputTokens: 16384,
          thinkingDirective: AnthropicBudgetDirective(8192),
        );

        await adapter.generateResponse(
          [Message(role: MessageRole.user, content: 'Hi')],
          modelOverride: 'claude-sonnet-4-5',
          options: options,
        );
        await adapter
            .generateStream(
              [Message(role: MessageRole.user, content: 'Hi')],
              modelOverride: 'claude-sonnet-4-5',
              options: options,
            )
            .toList();

        expect(capturedBodies, hasLength(2));
        expect(capturedBodies[0]['thinking'], {
          'type': 'enabled',
          'budget_tokens': 8192,
        });
        expect(capturedBodies[0].containsKey('output_config'), isFalse);
        expect(
          Map.of(capturedBodies[1])..remove('stream'),
          capturedBodies[0],
        );
      },
    );

    test(
      'uses adaptive thinking shape for opus models without manual budget',
      () async {
        late Map<String, dynamic> requestBody;
        final mockClient = MockClient((request) async {
          requestBody = (jsonDecode(request.body) as Map)
              .cast<String, dynamic>();
          return http.Response(
            jsonEncode({
              'content': [
                {'type': 'text', 'text': 'Hello'},
              ],
            }),
            200,
          );
        });
        final adapter = BaseAnthropicAdapter(config, profile, client: mockClient);
        await adapter.generateResponse(
          [Message(role: MessageRole.user, content: 'Hi')],
          modelOverride: 'claude-opus-4-7',
          options: const LLMRequestOptions(
            thinkingDirective: AnthropicAdaptiveDirective('high'),
          ),
        );

        expect(requestBody['thinking'], {'type': 'adaptive'});
        expect(requestBody['output_config'], {'effort': 'high'});
        expect(requestBody['thinking'], isNot(contains('budget_tokens')));
      },
    );

    test('should fetch live model list from anthropic-compatible /models', () async {
      final profile = ProviderRegistry.findByNameOrAlias('anthropic')!;
      final mockClient = MockClient((request) async {
        if (request.url.path.endsWith('/models')) {
          return http.Response(
            jsonEncode({
              'data': [
                {'id': 'claude-sonnet-4.5'},
                {'id': 'claude-haiku-4.5'},
              ],
            }),
            200,
          );
        }
        return http.Response('{}', 404);
      });

      final adapter = BaseAnthropicAdapter(
        config,
        profile,
        client: mockClient,
        defaultModelOverride: 'claude-sonnet-4.5',
      );
      final models = await adapter.getAvailableModels();

      expect(models.map((m) => m.value), contains('claude-sonnet-4.5'));
      expect(models.map((m) => m.value), contains('claude-haiku-4.5'));
    });

    test(
      'should retry anthropic-compatible model fetch with bearer auth when x-api-key fails',
      () async {
        final profile = ProviderRegistry.findByNameOrAlias('anthropic')!;
        var requestCount = 0;
        final mockClient = MockClient((request) async {
          requestCount++;
          expect(
            request.url.toString(),
            equals('http://localhost:9000/v1/models'),
          );
          if (requestCount == 1) {
            expect(
              request.headers['content-type'],
              contains('application/json'),
            );
            expect(request.headers['x-api-key'], equals('test-key'));
            expect(request.headers['anthropic-version'], equals('2023-06-01'));
            return http.Response(
              jsonEncode({'detail': 'Invalid or missing API Key'}),
              401,
            );
          }
          expect(request.headers['content-type'], contains('application/json'));
          expect(request.headers['Authorization'], equals('Bearer test-key'));
          expect(request.headers['anthropic-version'], equals('2023-06-01'));
          return http.Response(
            jsonEncode({
              'data': [
                {'id': 'claude-sonnet-4.5'},
                {'id': 'claude-opus-4.7'},
              ],
            }),
            200,
          );
        });

        final adapter = BaseAnthropicAdapter(
          config,
          profile,
          client: mockClient,
          baseUrlOverride: 'http://localhost:9000',
        );
        final models = await adapter.getAvailableModels();

        expect(requestCount, equals(2));
        expect(models.map((m) => m.value), contains('claude-sonnet-4.5'));
        expect(models.map((m) => m.value), contains('claude-opus-4.7'));
        expect(adapter.availableModelsSource, equals('live'));
      },
    );

    test(
      'custom anthropic-compatible profiles send requests to /v1/messages with x-api-key',
      () async {
        final customAnthropicProfile = ProviderProfile(
          name: 'custom',
          displayName: 'Custom Provider',
          authType: 'api_key',
          authFlow: 'custom_endpoint',
          apiMode: 'anthropic_messages',
          protocol: 'anthropic_compatible',
        );

        final mockClient = MockClient((request) async {
          expect(
            request.url.toString(),
            equals('http://localhost:9000/v1/messages'),
          );
          expect(request.headers['x-api-key'], equals('test-key'));
          expect(request.headers['anthropic-version'], equals('2023-06-01'));
          expect(request.headers.containsKey('Authorization'), isFalse);
          return http.Response(
            jsonEncode({
              'content': [
                {'type': 'text', 'text': 'Hello from custom anthropic'},
              ],
              'usage': {'input_tokens': 10, 'output_tokens': 5},
            }),
            200,
          );
        });

        final adapter = BaseAnthropicAdapter(
          config,
          customAnthropicProfile,
          client: mockClient,
          baseUrlOverride: 'http://localhost:9000/v1',
        );

        final response = await adapter.generateResponse([
          Message(role: MessageRole.user, content: 'Hi'),
        ]);

        expect(response.message.content, equals('Hello from custom anthropic'));
      },
    );

    test('streams Anthropic thinking blocks separately from text', () async {
      final events = [
        {
          'type': 'message_start',
          'message': {
            'usage': {'input_tokens': 2},
          },
        },
        {
          'type': 'content_block_start',
          'index': 0,
          'content_block': {'type': 'thinking', 'thinking': ''},
        },
        {
          'type': 'content_block_delta',
          'index': 0,
          'delta': {'type': 'thinking_delta', 'thinking': 'Inspecting'},
        },
        {
          'type': 'content_block_start',
          'index': 1,
          'content_block': {'type': 'text', 'text': ''},
        },
        {
          'type': 'content_block_delta',
          'index': 1,
          'delta': {'type': 'text_delta', 'text': 'Answer'},
        },
        {
          'type': 'message_delta',
          'delta': {'stop_reason': 'end_turn'},
          'usage': {'output_tokens': 4},
        },
      ];
      final mockClient = StreamingTestClient(
        (_) => http.StreamedResponse(
          Stream.value(
            utf8.encode(
              events.map((event) => 'data: ${jsonEncode(event)}').join('\n'),
            ),
          ),
          200,
          headers: {'content-type': 'text/event-stream'},
        ),
      );
      final adapter = BaseAnthropicAdapter(config, profile, client: mockClient);

      final responses = await adapter.generateStream([]).toList();

      expect(
        responses
            .map((response) => response.message.reasoning)
            .whereType<String>()
            .join(),
        'Inspecting',
      );
      expect(
        responses
            .map((response) => response.message.content)
            .whereType<String>()
            .join(),
        'Answer',
      );
    });

    test('should parse Anthropic overloaded_error inside SSE', () async {
      final sseErrorPayload =
          'event: error\n'
          'data: ${jsonEncode({
            'type': 'error',
            'error': {'type': 'overloaded_error', 'message': 'Anthropic is overloaded'},
          })}\n\n';

      final mockClient = StreamingTestClient((request) {
        return http.StreamedResponse(
          Stream.value(utf8.encode(sseErrorPayload)),
          200,
          headers: {
            'content-type': 'text/event-stream',
            'X-Test-Header': 'val',
          },
        );
      });

      final adapter = BaseAnthropicAdapter(config, profile, client: mockClient);

      expect(
        () => adapter.generateStream([
          Message(role: MessageRole.user, content: 'hi'),
        ]).toList(),
        throwsA(
          isA<LlmHttpException>()
              .having((e) => e.body, 'body', contains('overloaded_error'))
              .having(
                (e) => e.headers['X-Test-Header'],
                'headers',
                equals('val'),
              ),
        ),
      );
    });

    test(
      'should merge consecutive tool results into one user message and strip orphan tool_use',
      () async {
        late Map<String, dynamic> capturedBody;
        final mockClient = MockClient((request) async {
          capturedBody = (jsonDecode(request.body) as Map)
              .cast<String, dynamic>();
          return http.Response(
            jsonEncode({
              'content': [
                {'type': 'text', 'text': 'Done'},
              ],
              'stop_reason': 'end_turn',
              'usage': {'input_tokens': 10, 'output_tokens': 5},
            }),
            200,
          );
        });

        final adapter = BaseAnthropicAdapter(
          config,
          profile,
          client: mockClient,
        );

        // History with:
        // - assistant message with 2 tool_use blocks (both answered)
        // - assistant message with 1 orphan tool_use (no matching tool_result)
        await adapter.generateResponse([
          Message(role: MessageRole.user, content: 'Search for two things'),
          Message(
            role: MessageRole.assistant,
            content: 'Let me search',
            toolCalls: [
              ToolCall(id: 'tool_1', name: 'search', arguments: {'q': 'a'}),
              ToolCall(id: 'tool_2', name: 'search', arguments: {'q': 'b'}),
            ],
          ),
          Message(
            role: MessageRole.tool,
            toolCallId: 'tool_1',
            content: 'result A',
          ),
          Message(
            role: MessageRole.tool,
            toolCallId: 'tool_2',
            content: 'result B',
          ),
          Message(
            role: MessageRole.assistant,
            content: 'Now an orphan',
            toolCalls: [
              ToolCall(
                id: 'orphan_tool',
                name: 'search',
                arguments: {'q': 'orphan'},
              ),
            ],
          ),
        ], options: const LLMRequestOptions(
          maxOutputTokens: 16384,
          thinkingDirective: AnthropicBudgetDirective(8192),
        ));

        final messages = capturedBody['messages'] as List;
        expect(capturedBody['thinking'], {
          'type': 'enabled',
          'budget_tokens': 8192,
        });

        // The orphan tool_use must not appear in the wire body.
        final allToolUseIds = <String>[];
        for (final m in messages) {
          if (m['content'] is List) {
            for (final block in m['content'] as List) {
              if (block is Map && block['type'] == 'tool_use') {
                allToolUseIds.add(block['id'].toString());
              }
            }
          }
        }
        expect(allToolUseIds, isNot(contains('orphan_tool')));

        // Find the user message that contains tool_results.
        // Both tool_result blocks should be in the SAME user message (merged).
        final toolResultUserMessages = messages.where((m) {
          if (m['role'] != 'user' || m['content'] is! List) return false;
          return (m['content'] as List).any(
            (b) => b is Map && b['type'] == 'tool_result',
          );
        }).toList();
        expect(toolResultUserMessages, hasLength(1));
        final toolResults = (toolResultUserMessages.first['content'] as List)
            .where((b) => b is Map && b['type'] == 'tool_result')
            .toList();
        expect(toolResults, hasLength(2));
      },
    );

    test('should respect maxOutputTokens from LLMRequestOptions', () async {
      late Map<String, dynamic> capturedBody;
      final mockClient = MockClient((request) async {
        capturedBody = (jsonDecode(request.body) as Map)
            .cast<String, dynamic>();
        return http.Response(
          jsonEncode({
            'content': [
              {'type': 'text', 'text': 'Done'},
            ],
            'stop_reason': 'end_turn',
          }),
          200,
        );
      });

      final adapter = BaseAnthropicAdapter(config, profile, client: mockClient);

      await adapter.generateResponse([
        Message(role: MessageRole.user, content: 'Hi'),
      ], options: const LLMRequestOptions(maxOutputTokens: 8192));

      expect(capturedBody['max_tokens'], equals(8192));
    });

    test(
      'lowers manual thinking budget when maxOutputTokens is smaller',
      () async {
        late Map<String, dynamic> capturedBody;
        final mockClient = MockClient((request) async {
          capturedBody = (jsonDecode(request.body) as Map)
              .cast<String, dynamic>();
          return http.Response(
            jsonEncode({
              'content': [
                {'type': 'text', 'text': 'Done'},
              ],
              'stop_reason': 'end_turn',
            }),
            200,
          );
        });

        final adapter = BaseAnthropicAdapter(config, profile, client: mockClient);
        await adapter.generateResponse(
          [Message(role: MessageRole.user, content: 'Hi')],
          modelOverride: 'claude-sonnet-4-5',
          options: const LLMRequestOptions(
            maxOutputTokens: 4096,
            thinkingDirective: AnthropicBudgetDirective(16384),
          ),
        );

        expect(capturedBody['max_tokens'], equals(4096));
        expect(capturedBody['thinking'], {
          'type': 'enabled',
          'budget_tokens': 4095,
        });
      },
    );

    test('should parse stop_reason into finishReason', () async {
      final mockClient = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'content': [
              {'type': 'text', 'text': 'Done'},
            ],
            'stop_reason': 'max_tokens',
          }),
          200,
        );
      });

      final adapter = BaseAnthropicAdapter(config, profile, client: mockClient);

      final response = await adapter.generateResponse([
        Message(role: MessageRole.user, content: 'Hi'),
      ]);

      expect(response.finishReason, equals(LLMFinishReason.length));
    });

    test(
      'should parse tool_use stop_reason into toolCalls finishReason',
      () async {
        final mockClient = MockClient((request) async {
          return http.Response(
            jsonEncode({
              'content': [
                {
                  'type': 'tool_use',
                  'id': 'call_1',
                  'name': 'search',
                  'input': {'q': 'test'},
                },
              ],
              'stop_reason': 'tool_use',
            }),
            200,
          );
        });

        final adapter = BaseAnthropicAdapter(
          config,
          profile,
          client: mockClient,
        );

        final response = await adapter.generateResponse([
          Message(role: MessageRole.user, content: 'Hi'),
        ]);

        expect(response.isToolCall, isTrue);
        expect(response.finishReason, equals(LLMFinishReason.toolCalls));
      },
    );
  });

  group('NVIDIA NIM Profile', () {
    final profile = ProviderRegistry.findByNameOrAlias('nvidia')!;

    test('should register correctly with default configurations', () {
      expect(profile, isNotNull);
      expect(profile.name, equals('nvidia'));
      expect(profile.displayName, equals('NVIDIA NIM'));
      expect(
        profile.defaultBaseUrl,
        equals('https://integrate.api.nvidia.com/v1'),
      );
      expect(profile.envApiKeyName, equals('NVIDIA_API_KEY'));
      expect(profile.envModelName, equals('NVIDIA_MODEL'));
      expect(profile.envBaseUrlName, equals('NVIDIA_API_BASE'));
      expect(profile.apiMode, equals('chat_completions'));
      expect(profile.fallbackModels, contains('stepfun-ai/step-3.7-flash'));
      expect(profile.fallbackModels, contains('google/gemma-4-31b-it'));
    });

    test('should identify as nvidia from base url', () {
      final config = NvidiaAutoDetectConfig(
        environment: {
          'LLM_BASE_URL': 'https://integrate.api.nvidia.com/v1',
          'LLM_MODEL': 'stepfun-ai/step-3.7-flash',
          'LLM_API_KEY': 'some-key',
        },
      );
      expect(config.resolveProviderName(), equals('nvidia'));
    });
  });

  group('OpenCode Go Profile', () {
    final profile = ProviderRegistry.findByNameOrAlias('opencode-go')!;

    test('should register correctly with default configurations', () {
      expect(profile, isNotNull);
      expect(profile.name, equals('opencode-go'));
      expect(profile.displayName, equals('OpenCode Go'));
      expect(profile.defaultBaseUrl, equals('https://opencode.ai/zen/go/v1'));
      expect(profile.envApiKeyName, equals('OPENCODE_GO_API_KEY'));
      expect(profile.envModelName, equals('OPENCODE_GO_MODEL'));
      expect(profile.envBaseUrlName, equals('OPENCODE_GO_BASE_URL'));
      expect(profile.apiMode, equals('chat_completions'));
      expect(profile.aliases, contains('opencode_go'));
      expect(profile.aliases, contains('go'));
      expect(profile.aliases, contains('opencode-go-sub'));
      expect(profile.fallbackModels, contains('kimi-k2.7-code'));
      expect(profile.fallbackModels, contains('glm-5.2'));
    });
  });

  group('ModelsDevService', () {
    final mockRegistryData = {
      'openai': {
        'name': 'OpenAI',
        'models': {
          'gpt-4o': {
            'name': 'GPT-4o',
            'tool_call': true,
            'reasoning': false,
            'limit': {'context': 128000},
          },
          'gpt-4o-mini': {
            'name': 'GPT-4o-mini',
            'tool_call': true,
            'reasoning': false,
            'limit': {'context': 128000},
          },
          'text-embedding-3-small': {
            'name': 'Text Embedding 3 Small',
            'tool_call': false,
            'reasoning': false,
            'limit': {'context': 8192},
          },
        },
      },
      'nvidia': {
        'name': 'NVIDIA',
        'models': {
          'stepfun-ai/step-3.7-flash': {
            'name': 'Step-3.7-Flash',
            'tool_call': true,
            'reasoning': true,
            'limit': {'context': 65536},
          },
        },
      },
    };

    test('should fetch and parse agentic models correctly', () async {
      final tempCachePath = getTempCachePath();
      addTearDown(() => _cleanupTempCache(tempCachePath));

      final mockClient = MockClient((request) async {
        return http.Response(jsonEncode(mockRegistryData), 200);
      });

      final service = ModelsDevService(
        client: mockClient,
        cacheFilePathOverride: tempCachePath,
      );
      final openaiModels = await service.listAgenticModels('openai');

      expect(openaiModels, contains('gpt-4o'));
      expect(openaiModels, contains('gpt-4o-mini'));
      expect(openaiModels, isNot(contains('text-embedding-3-small')));
    });

    test('should map zai-coding to the coding-plan registry catalog', () async {
      final tempCachePath = getTempCachePath();
      addTearDown(() => _cleanupTempCache(tempCachePath));

      final mockClient = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'zai-coding-plan': {
              'name': 'Z.AI Coding Plan',
              'models': {
                'glm-4.5-air': {
                  'tool_call': true,
                  'reasoning': false,
                  'limit': {'context': 128000},
                },
                'glm-4.7': {
                  'tool_call': true,
                  'reasoning': true,
                  'limit': {'context': 128000},
                },
                'glm-5.1': {
                  'tool_call': true,
                  'reasoning': true,
                  'limit': {'context': 256000},
                },
              },
            },
          }),
          200,
        );
      });

      final service = ModelsDevService(
        client: mockClient,
        cacheFilePathOverride: tempCachePath,
      );
      final zaiCodingModels = await service.listAgenticModels('zai-coding');

      expect(
        zaiCodingModels,
        containsAll(['glm-4.5-air', 'glm-4.7', 'glm-5.1']),
      );
    });

    test('should resolve reasoning correctly', () async {
      final tempCachePath = getTempCachePath();
      addTearDown(() => _cleanupTempCache(tempCachePath));

      final mockClient = MockClient((request) async {
        return http.Response(jsonEncode(mockRegistryData), 200);
      });

      final service = ModelsDevService(
        client: mockClient,
        cacheFilePathOverride: tempCachePath,
      );
      expect(
        await service.supportsReasoning('nvidia', 'stepfun-ai/step-3.7-flash'),
        isTrue,
      );
      expect(await service.supportsReasoning('openai', 'gpt-4o'), isFalse);
    });

    test('should resolve context limit correctly', () async {
      final tempCachePath = getTempCachePath();
      addTearDown(() => _cleanupTempCache(tempCachePath));

      final mockClient = MockClient((request) async {
        return http.Response(jsonEncode(mockRegistryData), 200);
      });

      final service = ModelsDevService(
        client: mockClient,
        cacheFilePathOverride: tempCachePath,
      );
      expect(
        await service.getContextLimit('nvidia', 'stepfun-ai/step-3.7-flash'),
        equals(65536),
      );
      expect(await service.getContextLimit('openai', 'gpt-4o'), equals(128000));
    });
  });
}
