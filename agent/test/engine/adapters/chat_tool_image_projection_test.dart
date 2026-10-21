import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/models/user_attachment.dart';
import 'package:sanad_agent/core/models/llm_provider_state.dart';
import 'package:sanad_agent/core/provider_runtime/provider_protocol_constants.dart';
import 'package:sanad_agent/engine/adapters/base_anthropic_adapter.dart';
import 'package:sanad_agent/engine/adapters/provider_profile.dart';
import 'package:sanad_agent/engine/adapters/tool_result_wire_codec.dart';
import 'package:sanad_agent/core/models/tool_call.dart';
import 'package:sanad_agent/core/models/tool_execution_result.dart';
import 'package:sanad_agent/engine/adapters/base_openai_adapter.dart';
import 'package:sanad_agent/engine/adapters/models_dev_service.dart';
import 'package:sanad_agent/engine/adapters/provider_registry.dart';
import 'package:sanad_agent/core/agent_runtime_service.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/models/agent_response.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/core/provider_runtime/provider_model_cache_service.dart';
import 'package:sanad_agent/core/provider_runtime/route_capability_resolver.dart';
import 'package:sanad_agent/core/provider_thinking/provider_thinking_di.dart';
import 'package:sanad_agent/engine/adapters/llm_adapter.dart';
import 'package:sanad_agent/engine/adapters/llm_request_options.dart';
import 'package:sanad_agent/evolution/attachments/attachment_store.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:get_it/get_it.dart';
import 'package:sanad_agent/engine/agent_runner.dart';
import 'package:sanad_agent/capabilities/image/image_policy.dart';
import 'package:sanad_agent/capabilities/image/image_worker.dart';
import 'package:sanad_agent/capabilities/models/tool_schema.dart';
import 'package:sanad_agent/capabilities/registry/tools_registry.dart';
import 'package:sanad_agent/capabilities/runtime/workspace_path_resolver.dart';
import 'package:sanad_agent/capabilities/runtime/workspace_tools/view_image_handler.dart';
import 'package:sanad_agent/capabilities/tools/base_tool.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/capabilities.dart';
import 'package:test/test.dart';

void main() {
  late Directory scratch;
  late AgentStateDatabase db;
  late AttachmentStore store;
  late Map<String, dynamic> registry;
  late List<Map<String, dynamic>> requests;
  late int catalogRequests;

  setUp(() {
    scratch = Directory.systemTemp.createTempSync('sanad-chat-image-test-');
    setSanadHomeOverride(scratch.path);
    db = AgentStateDatabase.inMemory();
    store = AttachmentStore(db, stateHome: scratch.path);
    requests = [];
    catalogRequests = 0;
    registry = {
      'opencode-go': {
        'api': 'https://opencode.ai/inference/go/v1',
        'models': {
          'deepseek-v4-flash-vision-exp': {
            'modalities': {
              'input': ['text', 'image'],
            },
          },
          'text-model': {
            'modalities': {
              'input': ['text'],
            },
          },
          'missing-modalities': {},
          'malformed-modalities': {
            'modalities': {'input': 'image'},
          },
        },
      },
    };
    File('${scratch.path}/catalog.json').writeAsStringSync(jsonEncode(registry));
  });
  tearDown(() {
    GetIt.I.reset();
    SessionManager.resetForTesting();
    setSanadHomeOverride(null);
    db.dispose();
    scratch.deleteSync(recursive: true);
  });

  BaseOpenAIAdapter adapter({
    String? endpoint,
    String? providerInstanceId,
    Config? configOverride,
  }) {
    return BaseOpenAIAdapter(
      configOverride ?? Config(environment: const {}),
      ProviderRegistry.findByNameOrAlias('opencode-go')!,
      providerInstanceId: providerInstanceId,
      defaultModelOverride: 'deepseek-v4-flash-vision-exp',
      apiKeyOverride: 'fixture-key',
      baseUrlOverride: endpoint,
      modelsDevService: ModelsDevService(
        cacheFilePathOverride: '${scratch.path}/catalog.json',
        client: MockClient((_) async {
          catalogRequests++;
          return http.Response(jsonEncode(registry), 200);
        }),
      ),
      client: MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        requests.add(body);
        if (body['stream'] == true) {
          return http.Response(
            'data: {"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n',
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        }
        return http.Response(
          '{"choices":[{"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}',
          200,
        );
      }),
    );
  }

  ToolExecutionResult imageResult() => ToolExecutionResult(
    blocks: [
      ToolTextBlock(text: 'Image loaded'),
      ToolImageBlock(
        dataBase64: base64Encode([1, 2, 3]),
        mimeType: 'image/png',
        width: 1,
        height: 1,
        detail: ToolImageDetail.original,
      ),
    ],
  );

  List<Message> history({bool image = true}) => [
    Message(role: MessageRole.user, content: 'Inspect the image'),
    Message(
      role: MessageRole.assistant,
      toolCalls: [
        ToolCall(id: 'image-call', name: 'view_image', arguments: const {}),
        ToolCall(id: 'text-call', name: 'other', arguments: const {}),
      ],
    ),
    Message(
      role: MessageRole.tool,
      toolCallId: 'image-call',
      content: 'Image loaded',
      toolResult: image ? imageResult() : null,
    ),
    Message(
      role: MessageRole.tool,
      toolCallId: 'text-call',
      content: 'Other result',
    ),
  ];

  test(
    'supported Go sync/stream projects images after all parallel results',
    () async {
      final source = history();
      final before = jsonEncode(source.map((m) => m.toJson()).toList());
      final subject = adapter();
      await subject.generateResponse(source);
      await subject.generateStream(source).toList();
      for (final request in requests) {
        final messages = request['messages'] as List;
        expect(messages, hasLength(5));
        expect(messages[2]['role'], 'tool');
        expect(messages[2]['tool_call_id'], 'image-call');
        expect(messages[2]['content'], 'Image loaded');
        expect(messages[3]['tool_call_id'], 'text-call');
        expect(messages[4]['role'], 'user');
        final content = messages[4]['content'] as List;
        expect(content.last['type'], 'image_url');
        expect(content.last['image_url']['url'], 'data:image/png;base64,AQID');
        expect(content.last['image_url']['detail'], 'high');
        expect(jsonEncode(request), isNot(contains('Image omitted')));
      }
      expect(jsonEncode(source.map((m) => m.toJson()).toList()), before);
      expect(catalogRequests, 0); // No network during body assembly/measurement
    },
  );

  for (final model in [
    'text-model',
    'missing-modalities',
    'malformed-modalities',
    'unknown-vision',
  ]) {
    test('$model fails closed despite image in canonical history', () async {
      expect(
        () => adapter().generateResponse(history(), modelOverride: model),
        throwsA(isA<UnsupportedError>()),
      );
      expect(requests, isEmpty);
    });
  }

  test(
    'custom and proxy endpoints support known models through intrinsic catalog, but fail closed for unknown models',
    () async {
      // Known model in catalog succeeds on custom endpoint
      await adapter(
        endpoint: 'https://custom.proxy.internal/v1',
      ).generateResponse(history());
      expect(requests.single['messages'], hasLength(5));

      // Unknown model on custom endpoint fails closed
      requests.clear();
      expect(
        () => adapter(
          endpoint: 'https://custom.proxy.internal/v1',
        ).generateResponse(history(), modelOverride: 'text-model'),
        throwsA(isA<UnsupportedError>()),
      );
      expect(requests, isEmpty);
    },
  );

  test('catalog-owned current Go endpoint supports image context', () async {
    await adapter(
      endpoint: 'https://opencode.ai/inference/go/v1',
    ).generateResponse(history());
    expect(requests.single['messages'], hasLength(5));
  });

  test(
    'incomplete batch does not insert user context between tool results',
    () async {
      await adapter().generateResponse(history().sublist(0, 3));
      expect(requests.single['messages'], hasLength(3));
      expect(jsonEncode(requests.single), isNot(contains('data:image')));
    },
  );

  test(
    'multiple image results preserve batch and image order across replay',
    () async {
      final source = history();
      source[3] = Message(
        role: MessageRole.tool,
        toolCallId: 'text-call',
        content: 'Image loaded',
        toolResult: imageResult(),
      );
      final replay = source
          .map((message) => Message.fromJson(message.toJson()))
          .toList();
      await adapter().generateResponse(replay);
      final messages = requests.single['messages'] as List;
      expect(messages, hasLength(5));
      expect(messages.sublist(2, 4).map((m) => m['role']), ['tool', 'tool']);
      expect(
        (messages.last['content'] as List).where(
          (p) => p['type'] == 'image_url',
        ),
        hasLength(2),
      );
    },
  );

  test('pruned image result creates no synthetic media', () async {
    final source = history();
    source[2] = Message(
      role: MessageRole.tool,
      toolCallId: 'image-call',
      content: '[image data removed after model processing]',
      toolResult: ToolExecutionResult.text(
        '[image data removed after model processing]',
      ),
    );
    await adapter().generateResponse(source);
    expect(catalogRequests, 0);
    expect(requests.single['messages'], hasLength(4));
  });

  test(
    'catalog image evidence resolves known models across providers and endpoints, but rejects suffixes, malformed metadata and conflicts',
    () async {
      final multiRegistry = {
        'opencode-go': {
          'api': 'https://opencode.ai/inference/go/v1',
          'models': {
            'deepseek-v4-flash-vision-exp': {
              'modalities': {
                'input': ['text', 'image'],
              },
            },
            'text-model': {
              'modalities': {
                'input': ['text'],
              },
            },
            'missing-modalities': {},
            'malformed-modalities': {
              'modalities': {'input': 'image'},
            },
            'conflict-model': {
              'modalities': {
                'input': ['text', 'image'],
              },
            },
          },
        },
        'anthropic': {
          'api': 'https://api.anthropic.com',
          'models': {
            'claude-haiku-4.5': {
              'modalities': {
                'input': ['text', 'image'],
              },
            },
            'conflict-model': {
              'modalities': {
                'input': ['text'],
              },
            },
          },
        },
      };

      final service = ModelsDevService(
        cacheFilePathOverride: '${scratch.path}/exact.json',
        client: MockClient(
          (_) async => http.Response(jsonEncode(multiRegistry), 200),
        ),
      );

      // Known model resolves true purely from model identity without provider/baseUrl hints
      expect(
        await service.supportsImageInput('deepseek-v4-flash-vision-exp'),
        isTrue,
      );

      // Grounded same-generation alias claude-haiku-4.5 resolves true
      expect(
        await service.supportsImageInput('claude-haiku-4.5'),
        isTrue,
      );

      // Text-only model resolves false
      expect(await service.supportsImageInput('text-model'), isFalse);

      // Missing or malformed modalities resolve false
      expect(await service.supportsImageInput('missing-modalities'), isFalse);
      expect(await service.supportsImageInput('malformed-modalities'), isFalse);

      // Suffix and un-aliased case variants do not match and resolve false
      for (final model in [
        'deepseek-v4-flash-vision-exp:cloud',
        'DEEPSEEK-V4-FLASH-VISION-EXP',
      ]) {
        expect(
          await service.supportsImageInput(model),
          isFalse,
        );
      }

      // Conflicting models across vendors fail closed to false (unknown)
      expect(
        await service.supportsImageInput('conflict-model'),
        isFalse,
      );

      // Genuinely unknown models resolve false
      expect(
        await service.supportsImageInput('completely-unknown-model'),
        isFalse,
      );
    },
  );

  test(
    'reasoning replay remains issuer-scoped with synthetic images',
    () async {
      final source = history();
      source[1] = Message(
        role: MessageRole.assistant,
        toolCalls: source[1].toolCalls,
        providerState: LLMProviderState(
          namespace: 'openai_chat_completions',
          issuer: 'opencode-go|openai_compatible|https://opencode.ai/zen/go/v1',
          data: const {'reasoning_content': 'opaque reasoning'},
        ),
        // Legacy state without `issuer_model` replays only when the stored
        // model matches the destination (Task 116 D2).
        metadata: {'model': adapter().resolveModel(null)},
      );
      await adapter().generateResponse(source);
      expect(
        (requests.single['messages'] as List)[1]['reasoning_content'],
        'opaque reasoning',
      );
    },
  );

  test('validated codec rejects invalid image blocks before HTTP', () {
    // Core construction rejects malformed blocks before a codec can project them.
    expect(
      () => ToolImageBlock(
        dataBase64: 'not-base64!',
        mimeType: 'image/png',
        width: 1,
        height: 1,
        detail: ToolImageDetail.auto,
      ),
      throwsArgumentError,
    );
    expect(ToolResultWireCodec.hasImages(history()), isTrue);
  });

  test('no images means no catalog fetch or synthetic context', () async {
    await adapter().generateResponse(history(image: false));
    expect(catalogRequests, 0);
    expect(requests.single['messages'], hasLength(4));
  });

  test(
    'effective model override is used instead of text-only default',
    () async {
      final subject = adapter();
      expect(
        () => subject.generateResponse(history(), modelOverride: 'text-model'),
        throwsA(isA<UnsupportedError>()),
      );
      await subject.generateResponse(
        history(),
        modelOverride: 'deepseek-v4-flash-vision-exp',
        options: const LLMRequestOptions(),
      );
      expect(requests.single['messages'], hasLength(5));
    },
  );

  test(
    'exact-route capability override enables PNG and JPEG image projection on custom route',
    () async {
      final configFile = File('${scratch.path}/config.yaml');
      configFile.writeAsStringSync('''
model_capabilities:
  custom-model:
    supports_image_input: true
''');
      final config = Config(environment: const {});
      final subject = adapter(
        providerInstanceId: 'custom-provider',
        configOverride: config,
      );

      final jpegResult = ToolExecutionResult(
        blocks: [
          ToolTextBlock(text: 'JPEG loaded'),
          ToolImageBlock(
            dataBase64: base64Encode([4, 5, 6]),
            mimeType: 'image/jpeg',
            width: 2,
            height: 2,
            detail: ToolImageDetail.high,
          ),
        ],
      );
      final customHistory = [
        Message(role: MessageRole.user, content: 'Check custom images'),
        Message(
          role: MessageRole.assistant,
          toolCalls: [
            ToolCall(id: 'c1', name: 'view_image', arguments: const {}),
            ToolCall(id: 'c2', name: 'view_image', arguments: const {}),
          ],
        ),
        Message(
          role: MessageRole.tool,
          toolCallId: 'c1',
          content: 'Image loaded',
          toolResult: imageResult(),
        ),
        Message(
          role: MessageRole.tool,
          toolCallId: 'c2',
          content: 'JPEG loaded',
          toolResult: jpegResult,
        ),
      ];

      await subject.generateResponse(
        customHistory,
        modelOverride: 'custom-model',
      );

      expect(requests, hasLength(1));
      final messages = requests.single['messages'] as List;
      expect(messages, hasLength(5));
      final syntheticUser = messages[4] as Map<String, dynamic>;
      expect(syntheticUser['role'], 'user');
      final content = syntheticUser['content'] as List;
      expect(content, hasLength(4));
      expect(content[1]['type'], 'image_url');
      expect(content[1]['image_url']['url'], 'data:image/png;base64,AQID');
      expect(content[3]['type'], 'image_url');
      expect(content[3]['image_url']['url'], 'data:image/jpeg;base64,BAUG');
    },
  );

  BaseAnthropicAdapter customAnthropicAdapter({
    required String providerInstanceId,
    Config? configOverride,
    List<Map<String, dynamic>>? anthropicRequests,
  }) {
    const profile = ProviderProfile(
      name: 'custom',
      displayName: 'Custom Anthropic',
      description: 'Custom Anthropic provider',
      defaultBaseUrl: 'https://custom.anthropic.test',
      authType: 'api_key',
      apiMode: 'anthropic_messages',
      protocol: ProviderProtocol.anthropicCompatible,
      apiKeyRequirement: ApiKeyRequirement.optional,
      authMethods: [ProviderAuthMethod.apiKey],
    );
    return BaseAnthropicAdapter(
      configOverride ?? Config(environment: const {}),
      profile,
      providerInstanceId: providerInstanceId,
      apiKeyOverride: 'fixture-key',
      baseUrlOverride: 'https://custom.anthropic.test',
      client: MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        anthropicRequests?.add(body);
        return http.Response(
          jsonEncode({
            'id': 'msg_123',
            'type': 'message',
            'role': 'assistant',
            'content': [
              {'type': 'text', 'text': 'ok'},
            ],
            'model': 'custom-model',
            'stop_reason': 'end_turn',
            'usage': {'input_tokens': 10, 'output_tokens': 10},
          }),
          200,
        );
      }),
    );
  }

  const validPngBytes = [
    0x89,
    0x50,
    0x4E,
    0x47,
    0x0D,
    0x0A,
    0x1A,
    0x0A,
    0x00,
    0x00,
    0x00,
    0x0D,
    0x49,
    0x48,
    0x44,
    0x52,
  ];
  const validJpegBytes = [
    0xFF,
    0xD8,
    0xFF,
    0xE0,
    0x00,
    0x10,
    0x4A,
    0x46,
    0x49,
    0x46,
    0x00,
    0x01,
    0x01,
    0x01,
    0x00,
    0x60,
  ];
  final validPngBase64 = base64Encode(validPngBytes);
  final validJpegBase64 = base64Encode(validJpegBytes);

  Message userWithImageAttachments({
    List<int>? customPngBytes,
    List<int>? customJpegBytes,
    UserAttachmentStatus status = UserAttachmentStatus.available,
    String? pngRefOverride,
    String? jpegRefOverride,
    int? sizeOverride,
    String? hashOverride,
  }) {
    final pngBytes = customPngBytes ?? validPngBytes;
    final jpegBytes = customJpegBytes ?? validJpegBytes;
    final pngDir = Directory('${scratch.path}/attachments/att-png-1')
      ..createSync(recursive: true);
    final jpegDir = Directory('${scratch.path}/attachments/att-jpeg-1')
      ..createSync(recursive: true);
    File('${pngDir.path}/payload').writeAsBytesSync(pngBytes);
    File('${jpegDir.path}/payload').writeAsBytesSync(jpegBytes);
    return Message(
      role: MessageRole.user,
      content: 'Inspect attachments',
      attachments: [
        UserAttachment(
          id: 'att-png-1',
          safeName: 'test.png',
          mimeType: 'image/png',
          sizeBytes: sizeOverride ?? pngBytes.length,
          sha256: hashOverride ?? sha256.convert(pngBytes).toString(),
          kind: UserAttachmentKind.image,
          status: status,
          agentLocalReference:
              pngRefOverride ?? 'attachments/att-png-1/payload',
          mediaId: 'media-png-1',
        ),
        UserAttachment(
          id: 'att-jpeg-1',
          safeName: 'test.jpg',
          mimeType: 'image/jpeg',
          sizeBytes: sizeOverride ?? jpegBytes.length,
          sha256: hashOverride ?? sha256.convert(jpegBytes).toString(),
          kind: UserAttachmentKind.image,
          status: status,
          agentLocalReference:
              jpegRefOverride ?? 'attachments/att-jpeg-1/payload',
          mediaId: 'media-jpeg-1',
        ),
      ],
    );
  }

  test(
    'exact-route capability override with supports_image_input: false fails closed before HTTP',
    () async {
      final configFile = File('${scratch.path}/config.yaml');
      configFile.writeAsStringSync('''
model_capabilities:
  deepseek-v4-flash-vision-exp:
    supports_image_input: false
''');
      final config = Config(environment: const {});
      final subject = adapter(
        providerInstanceId: 'custom-provider',
        configOverride: config,
      );

      expect(
        () => subject.generateResponse(
          history(),
          modelOverride: 'deepseek-v4-flash-vision-exp',
        ),
        throwsA(isA<UnsupportedError>()),
      );
      expect(requests, isEmpty);
    },
  );

  test(
    'OpenAI adapter projects user image attachments (PNG and JPEG) to wire format',
    () async {
      final configFile = File('${scratch.path}/config.yaml');
      configFile.writeAsStringSync('''
model_capabilities:
  vision-model:
    supports_image_input: true
''');
      final config = Config(environment: const {});
      final subject = adapter(
        providerInstanceId: 'custom-provider',
        configOverride: config,
      );

      await subject.generateResponse(
        [userWithImageAttachments()],
        modelOverride: 'vision-model',
        options: LLMRequestOptions(attachmentStore: store),
      );

      expect(requests, hasLength(1));
      final messages = requests.single['messages'] as List;
      expect(messages, hasLength(1));
      final userMessage = messages.first as Map<String, dynamic>;
      expect(userMessage['role'], 'user');
      final content = userMessage['content'] as List;
      expect(content, hasLength(3));
      expect(content[0], {'type': 'text', 'text': 'Inspect attachments'});
      expect(content[1]['type'], 'image_url');
      expect(
        content[1]['image_url']['url'],
        'data:image/png;base64,$validPngBase64',
      );
      expect(content[2]['type'], 'image_url');
      expect(
        content[2]['image_url']['url'],
        'data:image/jpeg;base64,$validJpegBase64',
      );
    },
  );

  test(
    'Anthropic adapter projects user image attachments (PNG and JPEG) to wire format',
    () async {
      final configFile = File('${scratch.path}/config.yaml');
      configFile.writeAsStringSync('''
model_capabilities:
  claude-vision:
    supports_image_input: true
''');
      final config = Config(environment: const {});
      final anthropicRequests = <Map<String, dynamic>>[];
      final subject = customAnthropicAdapter(
        providerInstanceId: 'custom-anthropic',
        configOverride: config,
        anthropicRequests: anthropicRequests,
      );

      await subject.generateResponse(
        [userWithImageAttachments()],
        modelOverride: 'claude-vision',
        options: LLMRequestOptions(attachmentStore: store),
      );

      expect(anthropicRequests, hasLength(1));
      final messages = anthropicRequests.single['messages'] as List;
      expect(messages, hasLength(1));
      final userMessage = messages.first as Map<String, dynamic>;
      expect(userMessage['role'], 'user');
      final content = userMessage['content'] as List;
      expect(content, hasLength(3));
      expect(content[0], {'type': 'text', 'text': 'Inspect attachments'});
      expect(content[1], {
        'type': 'image',
        'source': {
          'type': 'base64',
          'media_type': 'image/png',
          'data': validPngBase64,
        },
      });
      expect(content[2], {
        'type': 'image',
        'source': {
          'type': 'base64',
          'media_type': 'image/jpeg',
          'data': validJpegBase64,
        },
      });
    },
  );

  test(
    'OpenAI adapter custom route with unknown image capability halts actionably before HTTP',
    () async {
      final subject = adapter(providerInstanceId: 'custom-provider');
      expect(
        () => subject.generateResponse([
          userWithImageAttachments(),
        ], modelOverride: 'unconfigured-model'),
        throwsA(
          isA<LocalImageCapabilityException>().having(
            (e) => e.message,
            'message',
            'Image input capability is unknown for model "unconfigured-model". Specify supports_image_input in config.yaml under model_capabilities.',
          ),
        ),
      );
      expect(requests, isEmpty);
    },
  );

  test(
    'Anthropic adapter custom route with unknown image capability halts actionably before HTTP',
    () async {
      final anthropicRequests = <Map<String, dynamic>>[];
      final subject = customAnthropicAdapter(
        providerInstanceId: 'custom-anthropic',
        anthropicRequests: anthropicRequests,
      );
      expect(
        () => subject.generateResponse([
          userWithImageAttachments(),
        ], modelOverride: 'unconfigured-model'),
        throwsA(
          isA<LocalImageCapabilityException>().having(
            (e) => e.message,
            'message',
            'Image input capability is unknown for model "unconfigured-model". Specify supports_image_input in config.yaml under model_capabilities.',
          ),
        ),
      );
      expect(anthropicRequests, isEmpty);
    },
  );

  test(
    'OpenAI adapter unsupported route halts actionably with distinct error before HTTP',
    () async {
      final configFile = File('${scratch.path}/config.yaml');
      configFile.writeAsStringSync('''
model_capabilities:
  text-only:
    supports_image_input: false
''');
      final config = Config(environment: const {});
      final subject = adapter(
        providerInstanceId: 'custom-provider',
        configOverride: config,
      );

      expect(
        () => subject.generateResponse([
          userWithImageAttachments(),
        ], modelOverride: 'text-only'),
        throwsA(
          isA<LocalImageCapabilityException>().having(
            (e) => e.message,
            'message',
            'The selected model "text-only" does not support image input.',
          ),
        ),
      );
      expect(requests, isEmpty);
    },
  );

  test(
    'Anthropic adapter unsupported route halts actionably with distinct error before HTTP',
    () async {
      final configFile = File('${scratch.path}/config.yaml');
      configFile.writeAsStringSync('''
model_capabilities:
  text-only:
    supports_image_input: false
''');
      final config = Config(environment: const {});
      final anthropicRequests = <Map<String, dynamic>>[];
      final subject = customAnthropicAdapter(
        providerInstanceId: 'custom-anthropic',
        configOverride: config,
        anthropicRequests: anthropicRequests,
      );

      expect(
        () => subject.generateResponse([
          userWithImageAttachments(),
        ], modelOverride: 'text-only'),
        throwsA(
          isA<LocalImageCapabilityException>().having(
            (e) => e.message,
            'message',
            'The selected model "text-only" does not support image input.',
          ),
        ),
      );
      expect(anthropicRequests, isEmpty);
    },
  );

  test(
    'in-flight admitted request options snapshot is unaffected by config reload during request assembly',
    () async {
      final configFile = File('${scratch.path}/config.yaml');
      configFile.writeAsStringSync('''
model_capabilities:
  snapshot-model:
    supports_image_input: true
''');
      final config = Config(environment: const {});
      final subject = adapter(
        providerInstanceId: 'custom-provider',
        configOverride: config,
      );

      // Admitted options captures snapshot supportsImageInput: true
      final admittedSupportedOptions = LLMRequestOptions(
        providerInstanceId: 'custom-provider',
        attachmentStore: store,
        routeCapabilitySnapshot: const ModelCapabilityOverride(
          supportsImageInput: true,
        ),
      );

      // Mutate config on disk to false while in-flight turn proceeds
      configFile.writeAsStringSync('''
model_capabilities:
  snapshot-model:
    supports_image_input: false
''');

      // Request succeeds because routeCapabilitySnapshot takes precedence
      await subject.generateResponse(
        [userWithImageAttachments()],
        modelOverride: 'snapshot-model',
        options: admittedSupportedOptions,
      );
      expect(requests, hasLength(1));

      // Conversely, if admitted options captured false, config changing to true does not admit images
      requests.clear();
      configFile.writeAsStringSync('''
model_capabilities:
  snapshot-model:
    supports_image_input: true
''');
      const admittedUnsupportedOptions = LLMRequestOptions(
        providerInstanceId: 'custom-provider',
        routeCapabilitySnapshot: ModelCapabilityOverride(
          supportsImageInput: false,
        ),
      );

      expect(
        () => subject.generateResponse(
          [userWithImageAttachments()],
          modelOverride: 'snapshot-model',
          options: admittedUnsupportedOptions,
        ),
        throwsA(isA<UnsupportedError>()),
      );
      expect(requests, isEmpty);
    },
  );

  group('Verified attachment reader and image security boundaries', () {
    test(
      'unavailable attachment status halts actionably before HTTP with StateError',
      () async {
        final configFile = File('${scratch.path}/config.yaml');
        configFile.writeAsStringSync('''
model_capabilities:
  vision-model:
    supports_image_input: true
''');
        final config = Config(environment: const {});
        final subject = adapter(
          providerInstanceId: 'custom-provider',
          configOverride: config,
        );

        expect(
          () => subject.generateResponse(
            [
              userWithImageAttachments(
                status: UserAttachmentStatus.unavailable,
              ),
            ],
            modelOverride: 'vision-model',
            options: LLMRequestOptions(attachmentStore: store),
          ),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains(
                'attachment is missing, unavailable, corrupted, or outside private storage',
              ),
            ),
          ),
        );
        expect(requests, isEmpty);
      },
    );

    test(
      'deleted payload file halts actionably before HTTP with StateError',
      () async {
        final configFile = File('${scratch.path}/config.yaml');
        configFile.writeAsStringSync('''
model_capabilities:
  vision-model:
    supports_image_input: true
''');
        final config = Config(environment: const {});
        final subject = adapter(
          providerInstanceId: 'custom-provider',
          configOverride: config,
        );

        final msg = userWithImageAttachments();
        final pngPayload = File(
          '${scratch.path}/attachments/att-png-1/payload',
        );
        if (pngPayload.existsSync()) pngPayload.deleteSync();

        expect(
          () => subject.generateResponse(
            [msg],
            modelOverride: 'vision-model',
            options: LLMRequestOptions(attachmentStore: store),
          ),
          throwsA(isA<StateError>()),
        );
        expect(requests, isEmpty);
      },
    );

    test(
      'mutated payload bytes / hash mismatch halts actionably before HTTP with StateError',
      () async {
        final configFile = File('${scratch.path}/config.yaml');
        configFile.writeAsStringSync('''
model_capabilities:
  vision-model:
    supports_image_input: true
''');
        final config = Config(environment: const {});
        final subject = adapter(
          providerInstanceId: 'custom-provider',
          configOverride: config,
        );

        final unmutatedHash = sha256.convert(validPngBytes).toString();
        final mutatedBytes = List<int>.from(validPngBytes)..[12] = 0xAA;
        final msg = userWithImageAttachments(
          customPngBytes: mutatedBytes,
          hashOverride: unmutatedHash,
        );

        expect(
          () => subject.generateResponse(
            [msg],
            modelOverride: 'vision-model',
            options: LLMRequestOptions(attachmentStore: store),
          ),
          throwsA(isA<StateError>()),
        );
        expect(requests, isEmpty);
      },
    );

    test(
      'corrupted size mismatch halts actionably before HTTP with StateError',
      () async {
        final configFile = File('${scratch.path}/config.yaml');
        configFile.writeAsStringSync('''
model_capabilities:
  vision-model:
    supports_image_input: true
''');
        final config = Config(environment: const {});
        final subject = adapter(
          providerInstanceId: 'custom-provider',
          configOverride: config,
        );

        final msg = userWithImageAttachments(sizeOverride: 99999);

        expect(
          () => subject.generateResponse(
            [msg],
            modelOverride: 'vision-model',
            options: LLMRequestOptions(attachmentStore: store),
          ),
          throwsA(isA<StateError>()),
        );
        expect(requests, isEmpty);
      },
    );

    test(
      'CWD shadow reference outside private store halts actionably before HTTP with StateError',
      () async {
        final configFile = File('${scratch.path}/config.yaml');
        configFile.writeAsStringSync('''
model_capabilities:
  vision-model:
    supports_image_input: true
''');
        final config = Config(environment: const {});
        final subject = adapter(
          providerInstanceId: 'custom-provider',
          configOverride: config,
        );

        final cwdShadow = File('${Directory.current.path}/shadow_fixture.png')
          ..writeAsBytesSync(validPngBytes);
        try {
          final msg = userWithImageAttachments(pngRefOverride: cwdShadow.path);
          expect(
            () => subject.generateResponse(
              [msg],
              modelOverride: 'vision-model',
              options: LLMRequestOptions(attachmentStore: store),
            ),
            throwsA(isA<StateError>()),
          );
          expect(requests, isEmpty);
        } finally {
          if (cwdShadow.existsSync()) cwdShadow.deleteSync();
        }
      },
    );

    test(
      'path traversal / escape reference halts actionably before HTTP with StateError',
      () async {
        final configFile = File('${scratch.path}/config.yaml');
        configFile.writeAsStringSync('''
model_capabilities:
  vision-model:
    supports_image_input: true
''');
        final config = Config(environment: const {});
        final subject = adapter(
          providerInstanceId: 'custom-provider',
          configOverride: config,
        );

        final msg = userWithImageAttachments(
          pngRefOverride: '../../escape.png',
        );

        expect(
          () => subject.generateResponse(
            [msg],
            modelOverride: 'vision-model',
            options: LLMRequestOptions(attachmentStore: store),
          ),
          throwsA(isA<StateError>()),
        );
        expect(requests, isEmpty);
      },
    );

    test(
      'invalid magic bytes (ASCII text declared as PNG) halts actionably before HTTP with FormatException',
      () async {
        final configFile = File('${scratch.path}/config.yaml');
        configFile.writeAsStringSync('''
model_capabilities:
  vision-model:
    supports_image_input: true
''');
        final config = Config(environment: const {});
        final subject = adapter(
          providerInstanceId: 'custom-provider',
          configOverride: config,
        );

        final textBytes = utf8.encode('this is plain text not a png image');
        final msg = userWithImageAttachments(
          customPngBytes: textBytes,
          hashOverride: sha256.convert(textBytes).toString(),
          sizeOverride: textBytes.length,
        );

        expect(
          () => subject.generateResponse(
            [msg],
            modelOverride: 'vision-model',
            options: LLMRequestOptions(attachmentStore: store),
          ),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('declared image/png format'),
            ),
          ),
        );
        expect(requests, isEmpty);
      },
    );

    test(
      'missing store on image attachment halts actionably before HTTP with StateError',
      () async {
        final configFile = File('${scratch.path}/config.yaml');
        configFile.writeAsStringSync('''
model_capabilities:
  vision-model:
    supports_image_input: true
''');
        final config = Config(environment: const {});
        final subject = adapter(
          providerInstanceId: 'custom-provider',
          configOverride: config,
        );

        final msg = userWithImageAttachments();

        expect(
          () => subject.generateResponse(
            [msg],
            modelOverride: 'vision-model',
            options: const LLMRequestOptions(attachmentStore: null),
          ),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains(
                'No AttachmentStore provided to verify user image attachment',
              ),
            ),
          ),
        );
        expect(requests, isEmpty);
      },
    );

    test('isolated store prevents cross-Home attachment access', () async {
      final configFile = File('${scratch.path}/config.yaml');
      configFile.writeAsStringSync('''
model_capabilities:
  vision-model:
    supports_image_input: true
''');
      final config = Config(environment: const {});
      final subject = adapter(
        providerInstanceId: 'custom-provider',
        configOverride: config,
      );

      // Attachment written in scratch (Home 1)
      final msg = userWithImageAttachments();

      // Separate Home 2 without the attachment
      final home2 = Directory.systemTemp.createTempSync('sanad-home2-test-');
      final db2 = AgentStateDatabase.inMemory();
      final store2 = AttachmentStore(db2, stateHome: home2.path);

      try {
        expect(
          () => subject.generateResponse(
            [msg],
            modelOverride: 'vision-model',
            options: LLMRequestOptions(attachmentStore: store2),
          ),
          throwsA(isA<StateError>()),
        );
        expect(requests, isEmpty);
      } finally {
        db2.dispose();
        home2.deleteSync(recursive: true);
      }
    });

    test(
      'routeCapabilityProfile snapshot takes absolute precedence over live config and catalogs',
      () async {
        final subject = adapter(providerInstanceId: 'custom-provider');

        // Admitted with supported
        final supportedProfile = RouteCapabilityProfile(
          providerInstanceId: 'custom-provider',
          modelId: 'opaque-model',
          imageSupport: RouteImageSupport.supported,
          evidenceSource: 'test',
        );

        await subject.generateResponse(
          [userWithImageAttachments()],
          modelOverride: 'opaque-model',
          options: LLMRequestOptions(
            providerInstanceId: 'custom-provider',
            routeCapabilityProfile: supportedProfile,
            attachmentStore: store,
          ),
        );
        expect(requests, hasLength(1));

        requests.clear();

        // Admitted with unsupported
        final unsupportedProfile = RouteCapabilityProfile(
          providerInstanceId: 'custom-provider',
          modelId: 'opaque-model',
          imageSupport: RouteImageSupport.unsupported,
          evidenceSource: 'test',
        );

        expect(
          () => subject.generateResponse(
            [userWithImageAttachments()],
            modelOverride: 'opaque-model',
            options: LLMRequestOptions(
              providerInstanceId: 'custom-provider',
              routeCapabilityProfile: unsupportedProfile,
              attachmentStore: store,
            ),
          ),
          throwsA(
            isA<LocalImageCapabilityException>().having(
              (e) => e.message,
              'message',
              'The selected model "opaque-model" does not support image input.',
            ),
          ),
        );
        expect(requests, isEmpty);

        // Admitted with unknown
        final unknownProfile = RouteCapabilityProfile(
          providerInstanceId: 'custom-provider',
          modelId: 'opaque-model',
          imageSupport: RouteImageSupport.unknown,
          evidenceSource: 'test',
        );

        expect(
          () => subject.generateResponse(
            [userWithImageAttachments()],
            modelOverride: 'opaque-model',
            options: LLMRequestOptions(
              providerInstanceId: 'custom-provider',
              routeCapabilityProfile: unknownProfile,
              attachmentStore: store,
            ),
          ),
          throwsA(
            isA<LocalImageCapabilityException>().having(
              (e) => e.message,
              'message',
              'Image input capability is unknown for model "opaque-model". Specify supports_image_input in config.yaml under model_capabilities.',
            ),
          ),
        );
        expect(requests, isEmpty);
      },
    );

    group('production path: discovery -> catalog refresh -> Runner admission -> HTTP body', () {
      test(
        'names-only discovery + same-generation 4.5 catalog resolves supported on custom UUID provider and projects PNG/JPEG attachments and typed tool images into HTTP body',
        () async {
          GetIt.I.registerSingleton<AgentStateDatabase>(db);
          GetIt.I.registerSingleton<AttachmentStore>(store);
          await store.initialize();
          final repo = ProviderInstanceRepository.fromDatabase(db.db);
          final sessionManager = SessionManager();

          final now = DateTime.now();
          final customProvider1 = ProviderInstance(
            id: 'custom-haiku-relay-uuid-1',
            templateId: kCustomProviderTemplateId,
            displayName: 'Custom Haiku Relay 1',
            protocol: ProviderProtocol.openaiCompatible,
            authMethod: ProviderAuthMethod.apiKey,
            baseUrl: 'http://127.0.0.1:8088/v1',
            createdAt: now,
            updatedAt: now,
          ).copyWith(configRevision: 1, credentialRevision: 1);
          repo.createInstance(customProvider1);

          final customProvider2 = ProviderInstance(
            id: 'custom-haiku-relay-uuid-2',
            templateId: kCustomProviderTemplateId,
            displayName: 'Custom Haiku Relay 2',
            protocol: ProviderProtocol.openaiCompatible,
            authMethod: ProviderAuthMethod.apiKey,
            baseUrl: 'http://127.0.0.1:8089/v1',
            createdAt: now,
            updatedAt: now,
          ).copyWith(configRevision: 1, credentialRevision: 1);
          repo.createInstance(customProvider2);

          // 1. DI setup (zero config override initially)
          final configFile = File('${scratch.path}/config.yaml');
          configFile.writeAsStringSync('model_capabilities: {}\n');
          final config = Config(environment: const {});

          // 2. Hydrated catalog with actual Anthropic catalog ID 'claude-haiku-4-5' under anthropic
          int catalogNetworkCount = 0;
          final catalogCacheFile = File('${scratch.path}/prod_path_mdev_cache.json');
          final modelsDev = ModelsDevService(
            cacheFilePathOverride: catalogCacheFile.path,
            client: MockClient((request) async {
              catalogNetworkCount++;
              return http.Response(
                jsonEncode({
                  'anthropic': {
                    'api': 'https://api.anthropic.com',
                    'models': {
                      'claude-haiku-4-5': {
                        'modalities': {
                          'input': ['text', 'image'],
                        },
                      },
                    },
                  },
                }),
                200,
              );
            }),
          );
          await modelsDev.ensureLoaded();
          expect(catalogNetworkCount, 1, reason: 'Initial catalog hydration before turn admission');

          // 3. Names-only endpoint discovery obtained via ProviderModelCacheService.refresh
          final fakeRuntime = _TestRuntimeService(
            [
              ModelOption(value: 'claude-haiku-4.5', label: 'Claude Haiku 4.5'),
            ],
            config,
            repo,
          );
          final cacheService = ProviderModelCacheService(
            repo,
            fakeRuntime,
            buildDefaultThinkingCapabilityAssembler(),
            config: config,
            modelsDevService: modelsDev,
          );
          await cacheService.refresh('custom-haiku-relay-uuid-1', manual: true);
          await cacheService.refresh('custom-haiku-relay-uuid-2', manual: true);

          final resolver = RouteCapabilityResolver(
            instances: repo,
            config: config,
            modelsDevService: modelsDev,
          );

          GetIt.I.registerSingleton<Config>(config);
          GetIt.I.registerSingleton<ProviderInstanceRepository>(repo);
          GetIt.I.registerSingleton<ModelsDevService>(modelsDev);
          GetIt.I.registerSingleton<RouteCapabilityResolver>(resolver);

          // 4. Session and pre-existing tool history with view_image calls and PNG/JPEG tool results
          final session = sessionManager.createSession(
            'claude-haiku-4.5',
            providerId: 'custom-haiku-relay-uuid-1',
          );

          sessionManager.saveSessionHistory(session.sessionId, [
            Message(
              role: MessageRole.user,
              content: 'Please view the images',
            ),
            Message(
              role: MessageRole.assistant,
              content: 'Calling view_image',
              toolCalls: [
                ToolCall(
                  id: 'call_view_img_1',
                  name: 'view_image',
                  arguments: {'path': 'image.png'},
                ),
                ToolCall(
                  id: 'call_view_img_2',
                  name: 'view_image',
                  arguments: {'path': 'image.jpg'},
                ),
              ],
            ),
            Message(
              role: MessageRole.tool,
              content: 'Loaded PNG image',
              toolCallId: 'call_view_img_1',
              toolResult: ToolExecutionResult(
                blocks: [
                  ToolTextBlock(text: 'Loaded PNG image'),
                  ToolImageBlock(
                    dataBase64: validPngBase64,
                    mimeType: 'image/png',
                    width: 1,
                    height: 1,
                    detail: ToolImageDetail.original,
                  ),
                ],
              ),
            ),
            Message(
              role: MessageRole.tool,
              content: 'Loaded JPEG image',
              toolCallId: 'call_view_img_2',
              toolResult: ToolExecutionResult(
                blocks: [
                  ToolTextBlock(text: 'Loaded JPEG image'),
                  ToolImageBlock(
                    dataBase64: validJpegBase64,
                    mimeType: 'image/jpeg',
                    width: 1,
                    height: 1,
                    detail: ToolImageDetail.original,
                  ),
                ],
              ),
            ),
          ]);

          // 5. Verified user attachments in store (PNG and JPEG) staged for admission
          final uploadPng = await store.create(
            fileName: 'test.png',
            declaredMime: 'image/png',
            expectedSize: validPngBytes.length,
            expectedSha256: sha256.convert(validPngBytes).toString(),
          );
          await store.write(uploadPng, validPngBytes);
          final pngAttachment = await store.commit(
            uploadPng,
            sessionId: session.sessionId,
            admissionId: 'req-prod-path-1',
          );

          final uploadJpeg = await store.create(
            fileName: 'test.jpg',
            declaredMime: 'image/jpeg',
            expectedSize: validJpegBytes.length,
            expectedSha256: sha256.convert(validJpegBytes).toString(),
          );
          await store.write(uploadJpeg, validJpegBytes);
          final jpegAttachment = await store.commit(
            uploadJpeg,
            sessionId: session.sessionId,
            admissionId: 'req-prod-path-1',
          );

          // 6. BaseOpenAIAdapter targeting custom HTTP URL capturing outgoing request
          final outgoingRequests = <Map<String, dynamic>>[];
          final adapter = BaseOpenAIAdapter(
            config,
            ProviderRegistry.findByNameOrAlias(kCustomProviderTemplateId)!,
            providerInstanceId: 'custom-haiku-relay-uuid-1',
            defaultModelOverride: 'claude-haiku-4.5',
            apiKeyOverride: 'test-api-key',
            baseUrlOverride: 'http://127.0.0.1:8088/v1',
            modelsDevService: modelsDev,
            client: MockClient((request) async {
              final body = jsonDecode(request.body) as Map<String, dynamic>;
              outgoingRequests.add(body);
              if (body['stream'] == true) {
                return http.Response(
                  'data: {"choices":[{"delta":{"content":"Images analyzed"},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n',
                  200,
                  headers: {'content-type': 'text/event-stream'},
                );
              }
              return http.Response(
                '{"choices":[{"message":{"role":"assistant","content":"Images analyzed"},"finish_reason":"stop"}]}',
                200,
              );
            }),
          );

          // 7. Actual AgentRunner admission and execution
          final runner = AgentRunner(
            adapter,
            ToolsRegistry(),
            sessionManager,
            existingSessionId: session.sessionId,
            attachmentStore: store,
          );
          runner.configureUserAttachments([pngAttachment, jpegAttachment]);

          final stream = runner.streamMessage(
            'Analyze these photos please',
            requestId: 'req-prod-path-1',
            providerId: 'custom-haiku-relay-uuid-1',
            model: 'claude-haiku-4.5',
          );
          await for (final _ in stream) {}

          // 8. Assert zero catalog HTTP requests during runner admission, body building, and measurement
          expect(catalogNetworkCount, 3, reason: 'Zero catalog network requests during admission and body building (3 calls were from initial hydration and provider refreshes)');

          // 9. Assert admitted profile snapshot
          final admittedProfile = runner.debugTurnCapabilityProfile;
          expect(admittedProfile, isNotNull);
          expect(admittedProfile!.imageSupport, RouteImageSupport.supported);
          expect(admittedProfile.evidenceSource, 'catalog');

          // 10. Assert HTTP request body: exact bytes, MIME types, model wire identity, and detached projection
          expect(outgoingRequests, hasLength(1));
          final requestBody = outgoingRequests.single;
          expect(requestBody['model'], 'claude-haiku-4.5', reason: 'Wire request preserves exact relay selected model ID');
          final messages = requestBody['messages'] as List<dynamic>;

          // User message with 2 attachments
          final emittedUserMsg = messages.firstWhere(
            (m) =>
                m['role'] == 'user' &&
                m['content'] is List &&
                (m['content'] as List).any(
                  (p) => p['type'] == 'text' && p['text'] == 'Analyze these photos please',
                ),
          );
          final userParts = emittedUserMsg['content'] as List<dynamic>;

          final pngPart = userParts.firstWhere(
            (p) =>
                p['type'] == 'image_url' &&
                (p['image_url']['url'] as String).startsWith('data:image/png;base64,'),
          );
          expect(pngPart['image_url']['url'], 'data:image/png;base64,$validPngBase64');

          final jpegPart = userParts.firstWhere(
            (p) =>
                p['type'] == 'image_url' &&
                (p['image_url']['url'] as String).startsWith('data:image/jpeg;base64,'),
          );
          expect(jpegPart['image_url']['url'], 'data:image/jpeg;base64,$validJpegBase64');

          // Tool call / tool result pairing intact
          final toolMsg1 = messages.firstWhere((m) => m['role'] == 'tool' && m['tool_call_id'] == 'call_view_img_1');
          expect(toolMsg1['content'], 'Loaded PNG image');
          final toolMsg2 = messages.firstWhere((m) => m['role'] == 'tool' && m['tool_call_id'] == 'call_view_img_2');
          expect(toolMsg2['content'], 'Loaded JPEG image');

          // Synthetic user message directly after tool results contains both projected tool image blocks (PNG and JPEG)
          final detachedMsg = messages.firstWhere(
            (m) =>
                m['role'] == 'user' &&
                m['content'] is List &&
                (m['content'] as List).any(
                  (p) =>
                      p['type'] == 'text' &&
                      ((p['text'] as String?)?.contains('Image context from preceding tool result') ?? false),
                ),
          );
          final detachedParts = detachedMsg['content'] as List<dynamic>;
          final toolPngPart = detachedParts.firstWhere(
            (p) =>
                p['type'] == 'image_url' &&
                (p['image_url']['url'] as String).startsWith('data:image/png;base64,'),
          );
          expect(
            toolPngPart['image_url']['url'],
            'data:image/png;base64,$validPngBase64',
          );
          final toolJpegPart = detachedParts.firstWhere(
            (p) =>
                p['type'] == 'image_url' &&
                (p['image_url']['url'] as String).startsWith('data:image/jpeg;base64,'),
          );
          expect(
            toolJpegPart['image_url']['url'],
            'data:image/jpeg;base64,$validJpegBase64',
          );

          // 11. Model-only configuration override once applies across multiple providers
          configFile.writeAsStringSync('''
model_capabilities:
  "claude-haiku-4.5":
    supports_image_input: false
''');
          config.reloadModelAwarePolicy();

          final profileP1 = resolver.resolveSync(
            providerInstanceId: 'custom-haiku-relay-uuid-1',
            modelId: 'claude-haiku-4.5',
          );
          expect(profileP1.imageSupport, RouteImageSupport.unsupported);
          expect(profileP1.evidenceSource, 'override');

          final profileP2 = resolver.resolveSync(
            providerInstanceId: 'custom-haiku-relay-uuid-2',
            modelId: 'claude-haiku-4.5',
          );
          expect(profileP2.imageSupport, RouteImageSupport.unsupported);
          expect(profileP2.evidenceSource, 'override');

          // 12. Removing override restores catalog supported resolution
          configFile.writeAsStringSync('model_capabilities: {}\n');
          config.reloadModelAwarePolicy();

          final profileRestoredP1 = resolver.resolveSync(
            providerInstanceId: 'custom-haiku-relay-uuid-1',
            modelId: 'claude-haiku-4.5',
          );
          expect(profileRestoredP1.imageSupport, RouteImageSupport.supported);
          expect(profileRestoredP1.evidenceSource, 'catalog');

          final profileRestoredP2 = resolver.resolveSync(
            providerInstanceId: 'custom-haiku-relay-uuid-2',
            modelId: 'claude-haiku-4.5',
          );
          expect(profileRestoredP2.imageSupport, RouteImageSupport.supported);
          expect(profileRestoredP2.evidenceSource, 'catalog');
        },
      );

      test(
        'live streaming turn executes view_image and produces detached image projection on continuation',
        () async {
          GetIt.I.registerSingleton<AgentStateDatabase>(db);
          GetIt.I.registerSingleton<AttachmentStore>(store);
          await store.initialize();
          final repo = ProviderInstanceRepository.fromDatabase(db.db);
          final sessionManager = SessionManager();

          final now = DateTime.now();
          final relayProvider = ProviderInstance(
            id: 'custom-haiku-relay-live',
            templateId: kCustomProviderTemplateId,
            displayName: 'Custom Haiku Live Relay',
            protocol: ProviderProtocol.openaiCompatible,
            authMethod: ProviderAuthMethod.apiKey,
            baseUrl: 'http://127.0.0.1:8099/v1',
            createdAt: now,
            updatedAt: now,
          ).copyWith(configRevision: 1, credentialRevision: 1);
          repo.createInstance(relayProvider);

          final configFile = File('${scratch.path}/config.yaml');
          configFile.writeAsStringSync('model_capabilities: {}\n');
          final config = Config(environment: const {});

          final modelsDev = ModelsDevService(
            cacheFilePathOverride: '${scratch.path}/prod_path_mdev_cache.json',
            client: MockClient(
              (request) async => http.Response(
                jsonEncode({
                  'anthropic': {
                    'api': 'https://api.anthropic.com',
                    'models': {
                      'claude-haiku-4-5': {
                        'modalities': {
                          'input': ['text', 'image'],
                        },
                      },
                    },
                  },
                }),
                200,
              ),
            ),
          );
          await modelsDev.ensureLoaded();

          final fakeRuntime = _TestRuntimeService(
            [ModelOption(value: 'claude-haiku-4.5', label: 'Claude Haiku 4.5')],
            config,
            repo,
          );
          final cacheService = ProviderModelCacheService(
            repo,
            fakeRuntime,
            buildDefaultThinkingCapabilityAssembler(),
            config: config,
            modelsDevService: modelsDev,
          );
          await cacheService.refresh('custom-haiku-relay-live', manual: true);

          final resolver = RouteCapabilityResolver(
            instances: repo,
            config: config,
            modelsDevService: modelsDev,
          );

          GetIt.I.registerSingleton<Config>(config);
          GetIt.I.registerSingleton<ProviderInstanceRepository>(repo);
          GetIt.I.registerSingleton<ModelsDevService>(modelsDev);
          GetIt.I.registerSingleton<RouteCapabilityResolver>(resolver);

          // Create workspace and a real sample image file
          final workspaceDir = Directory('${scratch.path}/live_workspace')..createSync(recursive: true);
          File('${workspaceDir.path}/sample.png').writeAsBytesSync(validPngBytes);

          final handler = ViewImageHandler(
            const WorkspacePathResolver(),
            imageWorker: _TestImageWorker(validPngBytes),
          );
          final toolsRegistry = ToolsRegistry()..registerTool(_TestViewImageTool(handler, workspaceDir.path));

          final outgoingRequests = <Map<String, dynamic>>[];
          int requestIndex = 0;

          final testAdapter = BaseOpenAIAdapter(
            config,
            ProviderRegistry.findByNameOrAlias('custom')!,
            providerInstanceId: 'custom-haiku-relay-live',
            defaultModelOverride: 'claude-haiku-4.5',
            apiKeyOverride: 'fixture-key',
            baseUrlOverride: 'http://127.0.0.1:8099/v1',
            modelsDevService: modelsDev,
            client: MockClient((request) async {
              final body = jsonDecode(request.body) as Map<String, dynamic>;
              outgoingRequests.add(body);
              requestIndex++;

              if (requestIndex == 1) {
                // First turn: assistant calls view_image tool
                final sseData =
                    'data: {"choices":[{"delta":{"content":null,"tool_calls":[{"index":0,"id":"call_view_img_live","type":"function","function":{"name":"view_image","arguments":"{\\"path\\":\\"sample.png\\"}"}}]},"finish_reason":null}]}\n\n'
                    'data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}\n\n'
                    'data: [DONE]\n\n';
                return http.Response(
                  sseData,
                  200,
                  headers: {'content-type': 'text/event-stream'},
                );
              } else {
                // Continuation turn: assistant returns final interpretation
                final sseData =
                    'data: {"choices":[{"delta":{"content":"I see a valid test image with 1x1 dimensions."},"finish_reason":"stop"}]}\n\n'
                    'data: [DONE]\n\n';
                return http.Response(
                  sseData,
                  200,
                  headers: {'content-type': 'text/event-stream'},
                );
              }
            }),
          );

          final session = sessionManager.createSession(
            'claude-haiku-4.5',
            providerId: 'custom-haiku-relay-live',
          );

          final runner = AgentRunner(
            testAdapter,
            toolsRegistry,
            sessionManager,
            existingSessionId: session.sessionId,
            attachmentStore: store,
          );

          final stream = runner.streamMessage(
            'Please view sample.png and describe what you see',
            requestId: 'req-live-view-1',
            providerId: 'custom-haiku-relay-live',
            model: 'claude-haiku-4.5',
          );
          final chunks = <String>[];
          await for (final chunk in stream) {
            chunks.add(chunk);
          }

          expect(chunks.join(), 'I see a valid test image with 1x1 dimensions.');

          // Verify exactly two requests were made: initial tool call + continuation
          expect(outgoingRequests, hasLength(2));

          // Request 1: Initial user message with tools
          final req1 = outgoingRequests[0];
          expect(req1['model'], 'claude-haiku-4.5');
          expect(req1['tools'], isNotEmpty);
          final toolNames = (req1['tools'] as List).map((t) => t['function']['name']).toList();
          expect(toolNames, contains('view_image'));

          // Request 2: Continuation with tool result and detached image projection
          final req2 = outgoingRequests[1];
          expect(req2['model'], 'claude-haiku-4.5');
          final messages2 = req2['messages'] as List<dynamic>;
          expect(messages2, hasLength(5));

          // Message 0: system prompt
          expect(messages2[0]['role'], 'system');

          // Message 1: user instruction
          expect(messages2[1]['role'], 'user');
          expect(messages2[1]['content'], 'Please view sample.png and describe what you see');

          // Message 2: assistant tool call
          expect(messages2[2]['role'], 'assistant');
          expect(messages2[2]['tool_calls'], hasLength(1));
          expect(messages2[2]['tool_calls'][0]['id'], 'call_view_img_live');

          // Message 3: tool result
          expect(messages2[3]['role'], 'tool');
          expect(messages2[3]['tool_call_id'], 'call_view_img_live');
          expect(messages2[3]['content'], contains('Image loaded'));

          // Message 4: detached user image projection
          expect(messages2[4]['role'], 'user');
          final parts = messages2[4]['content'] as List<dynamic>;
          expect(parts, hasLength(2));
          expect(parts[0]['type'], 'text');
          expect(parts[0]['text'], contains('Image context from preceding tool result 1'));
          expect(parts[1]['type'], 'image_url');
          expect(parts[1]['image_url']['url'], 'data:image/png;base64,$validPngBase64');
          expect(parts[1]['image_url']['detail'], 'auto');
        },
      );
    });
  });
}

class _TestImageWorker extends ImageWorker {
  final List<int> imageBytes;
  _TestImageWorker(this.imageBytes);

  @override
  Future<ImagePolicyResult> process(
    Uint8List bytes, {
    required ToolImageDetail detail,
  }) async =>
      ImagePolicySuccess(
        bytes: Uint8List.fromList(imageBytes),
        mimeType: 'image/png',
        width: 1,
        height: 1,
      );
}

class _TestViewImageTool extends BaseTool {
  final ViewImageHandler handler;
  final String workspacePath;
  _TestViewImageTool(this.handler, this.workspacePath);

  @override
  ToolSchema get schema => ToolSchema(
    name: 'view_image',
    description: 'Inspect one local image',
    parameters: const {
      'type': 'object',
      'properties': {
        'path': {'type': 'string'},
        'detail': {'type': 'string'},
      },
      'required': ['path'],
    },
  );

  @override
  bool get restartReplaySafe => true;

  @override
  Future<String> execute(Map<String, dynamic> arguments, {ToolContext? context}) async {
    final result = await executeResult(arguments, context: context);
    return result.displayText;
  }

  @override
  Future<ToolExecutionResult> executeResult(Map<String, dynamic> arguments, {ToolContext? context}) async {
    return handler.executeResult(
      arguments,
      workspacePath: workspacePath,
      admittedAttachmentPaths: const [],
      authorizeExternal: (path, args, ctx) async {},
      context: context,
    );
  }
}

class _TestRuntimeService extends AgentRuntimeService {
  final List<ModelOption> models;
  _TestRuntimeService(this.models, super.config, super.instanceRepo);

  @override
  LLMAdapter adapterFor(RouteSignature signature) {
    return _FakeNamesOnlyAdapter(models);
  }
}

class _FakeNamesOnlyAdapter implements LLMAdapter {
  final List<ModelOption> models;
  _FakeNamesOnlyAdapter(this.models);

  @override
  Future<List<ModelOption>> getAvailableModels() async => models;

  @override
  Future<int> getContextLimit([String? modelOverride]) async => 4096;

  @override
  Future<AgentResponse> generateResponse(
    List<dynamic> history, {
    List<dynamic>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) => throw UnimplementedError();

  @override
  Stream<AgentResponse> generateStream(
    List<dynamic> history, {
    List<dynamic>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) => throw UnimplementedError();
}
