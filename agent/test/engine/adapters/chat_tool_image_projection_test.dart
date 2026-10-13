import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/models/llm_provider_state.dart';
import 'package:sanad_agent/engine/adapters/tool_result_wire_codec.dart';
import 'package:sanad_agent/core/models/tool_call.dart';
import 'package:sanad_agent/core/models/tool_execution_result.dart';
import 'package:sanad_agent/engine/adapters/base_openai_adapter.dart';
import 'package:sanad_agent/engine/adapters/models_dev_service.dart';
import 'package:sanad_agent/engine/adapters/provider_registry.dart';
import 'package:sanad_agent/engine/adapters/llm_request_options.dart';
import 'package:test/test.dart';

void main() {
  late Directory scratch;
  late Map<String, dynamic> registry;
  late List<Map<String, dynamic>> requests;
  late int catalogRequests;

  setUp(() {
    scratch = Directory.systemTemp.createTempSync('sanad-chat-image-test-');
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
  });
  tearDown(() => scratch.deleteSync(recursive: true));

  BaseOpenAIAdapter adapter({String? endpoint}) {
    return BaseOpenAIAdapter(
      Config(environment: const {}),
      ProviderRegistry.findByNameOrAlias('opencode-go')!,
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
      expect(catalogRequests, 1);
    },
  );

  for (final model in [
    'text-model',
    'missing-modalities',
    'malformed-modalities',
    'unknown-vision',
  ]) {
    test('$model fails closed despite image in canonical history', () async {
      await adapter().generateResponse(history(), modelOverride: model);
      final messages = requests.single['messages'] as List;
      expect(messages, hasLength(4));
      expect(messages[2]['content'], contains('Image omitted'));
      expect(jsonEncode(messages), isNot(contains('data:image')));
    });
  }

  test(
    'unrelated custom endpoint does not inherit official model support',
    () async {
      await adapter(
        endpoint: 'https://unrelated.invalid/v1',
      ).generateResponse(history());
      expect(requests.single['messages'], hasLength(4));
      expect(jsonEncode(requests.single), isNot(contains('data:image')));
    },
  );

  test('different OpenCode product endpoint fails closed', () async {
    await adapter(
      endpoint: 'https://opencode.ai/zen/v1',
    ).generateResponse(history());
    expect(requests.single['messages'], hasLength(4));
  });

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
    'catalog image evidence cannot cross provider, suffix or malformed metadata',
    () async {
      final service = ModelsDevService(
        cacheFilePathOverride: '${scratch.path}/exact.json',
        client: MockClient(
          (_) async => http.Response(jsonEncode(registry), 200),
        ),
      );
      for (final provider in ['custom', 'openai', 'unknown']) {
        expect(
          await service.supportsImageInput(
            provider,
            'deepseek-v4-flash-vision-exp',
            baseUrl: 'https://opencode.ai/zen/go/v1',
          ),
          isFalse,
        );
      }
      for (final model in [
        'deepseek-v4-flash-vision-exp:cloud',
        'DEEPSEEK-V4-FLASH-VISION-EXP',
      ]) {
        expect(
          await service.supportsImageInput(
            'opencode-go',
            model,
            baseUrl: 'https://opencode.ai/zen/go/v1',
          ),
          isFalse,
        );
      }
      for (final endpoint in [
        'http://opencode.ai/zen/go/v1',
        'https://opencode.ai/zen/go/v1?route=other',
        'https://someone@opencode.ai/zen/go/v1',
        'https://opencode.ai:444/zen/go/v1',
      ]) {
        expect(
          await service.supportsImageInput(
            'opencode-go',
            'deepseek-v4-flash-vision-exp',
            baseUrl: endpoint,
          ),
          isFalse,
        );
      }
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
      await subject.generateResponse(history(), modelOverride: 'text-model');
      await subject.generateResponse(
        history(),
        modelOverride: 'deepseek-v4-flash-vision-exp',
        options: const LLMRequestOptions(),
      );
      expect(requests.first['messages'], hasLength(4));
      expect(requests.last['messages'], hasLength(5));
    },
  );
}
