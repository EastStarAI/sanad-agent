import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/models/tool_call.dart';
import 'package:sanad_agent/core/models/tool_execution_result.dart';
import 'package:sanad_agent/core/models/user_attachment.dart';
import 'package:sanad_agent/core/provider_runtime/route_capability_resolver.dart';
import 'package:sanad_agent/core/provider_thinking/native_thinking_directive.dart';
import 'package:sanad_agent/engine/adapters/llm_request_options.dart';
import 'package:sanad_agent/engine/adapters/models_dev_service.dart';
import 'package:sanad_agent/engine/adapters/ollama_adapter.dart';
import 'package:sanad_agent/engine/adapters/provider_registry.dart';
import 'package:sanad_agent/engine/adapters/provider_request_cancelled_exception.dart';
import 'package:sanad_agent/engine/runtime/run_cancellation_scope.dart';
import 'package:sanad_agent/evolution/attachments/attachment_store.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:get_it/get_it.dart';
import 'package:test/test.dart';

class _CountingClient extends http.BaseClient {
  final http.Client _inner;
  bool isClosed = false;
  _CountingClient(this._inner);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    return _inner.send(request);
  }

  @override
  void close() {
    isClosed = true;
    _inner.close();
  }
}

class _MutableConfig extends Config {
  ModelCapabilityOverride? overrideCapability;

  _MutableConfig() : super(environment: const {});

  @override
  ModelAwareRuntimePolicy get modelAwarePolicy => ModelAwareRuntimePolicy(
    contextModelLimits: ModelAwareRuntimePolicy.defaults.contextModelLimits,
    compaction: ModelAwareRuntimePolicy.defaults.compaction,
    modelCapabilities: overrideCapability != null
        ? {'llama3.2-vision': overrideCapability!}
        : const {},
  );
}

void main() {
  late Directory scratch;
  late AgentStateDatabase db;
  late AttachmentStore store;
  late List<Map<String, dynamic>> requests;
  late Map<String, dynamic> registry;
  late int probeRequestsCount;

  final validPngBytes = Uint8List.fromList([
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
    0x00,
    0x00,
    0x00,
    0x01,
    0x00,
    0x00,
    0x00,
    0x01,
    0x08,
    0x06,
    0x00,
    0x00,
    0x00,
    0x1F,
    0x15,
    0xC4,
    0x89,
  ]);
  final validPngBase64 = base64Encode(validPngBytes);

  final validJpegBytes = Uint8List.fromList([
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
    0x00,
    0x00,
    0x01,
    0x00,
    0x01,
    0x00,
    0x00,
    0xFF,
    0xDB,
    0x00,
    0x43,
    0x00,
    0xFF,
    0xD9,
  ]);
  final validJpegBase64 = base64Encode(validJpegBytes);

  setUp(() {
    scratch = Directory.systemTemp.createTempSync('sanad-ollama-image-test-');
    setSanadHomeOverride(scratch.path);
    db = AgentStateDatabase.inMemory();
    store = AttachmentStore(db, stateHome: scratch.path);
    requests = [];
    probeRequestsCount = 0;
    registry = {
      'ollama': {
        'api': 'http://127.0.0.1:11434',
        'models': {
          'llama3.2-vision': {
            'modalities': {
              'input': ['text', 'image'],
            },
          },
          'llama3.2': {
            'modalities': {
              'input': ['text'],
            },
          },
        },
      },
    };
    File(
      '${scratch.path}/catalog.json',
    ).writeAsStringSync(jsonEncode(registry));
  });

  tearDown(() {
    GetIt.I.reset();
    SessionManager.resetForTesting();
    setSanadHomeOverride(null);
    db.dispose();
    scratch.deleteSync(recursive: true);
  });

  OllamaAdapter makeAdapter({
    String? defaultModel = 'llama3.2-vision',
    String? providerInstanceId = 'ollama-test-instance',
    Config? configOverride,
  }) {
    final profile = ProviderRegistry.findByNameOrAlias('ollama')!;
    return OllamaAdapter(
      configOverride ?? Config(environment: const {}),
      profile,
      defaultModelOverride: defaultModel,
      providerInstanceId: providerInstanceId,
      modelsDevService: ModelsDevService(
        cacheFilePathOverride: '${scratch.path}/catalog.json',
      ),
      client: MockClient((request) async {
        if (request.url.path.endsWith('/api/show') ||
            request.url.path.endsWith('/api/tags')) {
          probeRequestsCount++;
        }
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        requests.add(body);
        if (body['stream'] == true) {
          final sseData = [
            '{"message": {"role": "assistant", "content": "I see the image", "thinking": "thought"}, "done": false}',
            '{"message": {"role": "assistant", "content": ""}, "done": true}',
          ].join('\n');
          return http.Response(
            sseData,
            200,
            headers: {'content-type': 'application/x-ndjson'},
          );
        }
        return http.Response(
          jsonEncode({
            'message': {
              'role': 'assistant',
              'content': 'I see the image',
              'thinking': 'thought',
            },
            'done': true,
          }),
          200,
        );
      }),
    );
  }

  ToolExecutionResult makeImageResult({
    String text = 'Image loaded from workspace',
    bool isPng = true,
    ToolImageDetail detail = ToolImageDetail.original,
  }) => ToolExecutionResult(
    blocks: [
      ToolTextBlock(text: text),
      ToolImageBlock(
        dataBase64: isPng ? validPngBase64 : validJpegBase64,
        mimeType: isPng ? 'image/png' : 'image/jpeg',
        width: 1,
        height: 1,
        detail: detail,
      ),
    ],
  );

  List<Message> makeToolHistory({
    bool isPng = true,
    ToolImageDetail detail = ToolImageDetail.original,
  }) => [
    Message(role: MessageRole.user, content: 'Please view the image'),
    Message(
      role: MessageRole.assistant,
      toolCalls: [
        ToolCall(id: 'call-img-1', name: 'view_image', arguments: const {}),
      ],
    ),
    Message(
      role: MessageRole.tool,
      toolCallId: 'call-img-1',
      content: 'Image loaded from workspace',
      toolResult: makeImageResult(isPng: isPng, detail: detail),
    ),
  ];

  Message userWithAttachment({bool isPng = true, String idSuffix = '1'}) {
    final bytes = isPng ? validPngBytes : validJpegBytes;
    final id = 'att-$idSuffix';
    final mime = isPng ? 'image/png' : 'image/jpeg';
    final name = isPng ? 'sample$idSuffix.png' : 'sample$idSuffix.jpg';

    final dir = Directory('${scratch.path}/attachments/$id')
      ..createSync(recursive: true);
    File('${dir.path}/payload').writeAsBytesSync(bytes);

    return Message(
      role: MessageRole.user,
      content: 'Here is an attached image',
      attachments: [
        UserAttachment(
          id: id,
          safeName: name,
          mimeType: mime,
          sizeBytes: bytes.length,
          sha256: sha256.convert(bytes).toString(),
          kind: UserAttachmentKind.image,
          status: UserAttachmentStatus.available,
          agentLocalReference: 'attachments/$id/payload',
          mediaId: 'media-$id',
        ),
      ],
    );
  }

  Message userWithMultipleAttachments() {
    final dirPng = Directory('${scratch.path}/attachments/att-multi-png')
      ..createSync(recursive: true);
    File('${dirPng.path}/payload').writeAsBytesSync(validPngBytes);

    final dirJpeg = Directory('${scratch.path}/attachments/att-multi-jpeg')
      ..createSync(recursive: true);
    File('${dirJpeg.path}/payload').writeAsBytesSync(validJpegBytes);

    return Message(
      role: MessageRole.user,
      content: 'Here are two images',
      attachments: [
        UserAttachment(
          id: 'att-multi-png',
          safeName: 'first.png',
          mimeType: 'image/png',
          sizeBytes: validPngBytes.length,
          sha256: sha256.convert(validPngBytes).toString(),
          kind: UserAttachmentKind.image,
          status: UserAttachmentStatus.available,
          agentLocalReference: 'attachments/att-multi-png/payload',
          mediaId: 'media-png',
        ),
        UserAttachment(
          id: 'att-multi-jpeg',
          safeName: 'second.jpg',
          mimeType: 'image/jpeg',
          sizeBytes: validJpegBytes.length,
          sha256: sha256.convert(validJpegBytes).toString(),
          kind: UserAttachmentKind.image,
          status: UserAttachmentStatus.available,
          agentLocalReference: 'attachments/att-multi-jpeg/payload',
          mediaId: 'media-jpeg',
        ),
      ],
    );
  }

  group('OllamaAdapter Native Image Transport', () {
    test(
      'supported Ollama sync projects typed tool image pixels into native request',
      () async {
        final subject = makeAdapter();
        final history = makeToolHistory(isPng: true);
        final beforeJson = jsonEncode(history.map((m) => m.toJson()).toList());
        const options = LLMRequestOptions(
          routeCapabilityProfile: RouteCapabilityProfile(
            providerInstanceId: 'ollama-test',
            modelId: 'llama3.2-vision',
            imageSupport: RouteImageSupport.supported,
            evidenceSource: 'catalog',
          ),
        );

        await subject.generateResponse(history, options: options);

        expect(requests, hasLength(1));
        final messages = requests.single['messages'] as List;
        expect(messages.length, greaterThanOrEqualTo(4));
        final lastMsg = messages.last as Map<String, dynamic>;
        expect(lastMsg['role'], 'user');
        expect(
          lastMsg['content'],
          contains('Image context from preceding tool result 1'),
        );
        expect(lastMsg['images'], isA<List>());
        expect(lastMsg['images'], [validPngBase64]);
        // Native Ollama images: no Chat parts (content is string, not list of maps)
        expect(lastMsg['content'], isA<String>());
        // No source mutation
        expect(jsonEncode(history.map((m) => m.toJson()).toList()), beforeJson);
        // No request-time probes
        expect(probeRequestsCount, 0);
      },
    );

    test(
      'supported Ollama stream projects typed tool image pixels into native request',
      () async {
        final subject = makeAdapter();
        final history = makeToolHistory(isPng: false); // JPEG
        const options = LLMRequestOptions(
          routeCapabilityProfile: RouteCapabilityProfile(
            providerInstanceId: 'ollama-test',
            modelId: 'llama3.2-vision',
            imageSupport: RouteImageSupport.supported,
            evidenceSource: 'catalog',
          ),
        );

        await subject.generateStream(history, options: options).toList();

        expect(requests, hasLength(1));
        final messages = requests.single['messages'] as List;
        expect(messages.length, greaterThanOrEqualTo(4));
        final lastMsg = messages.last as Map<String, dynamic>;
        expect(lastMsg['role'], 'user');
        expect(lastMsg['images'], isA<List>());
        expect(lastMsg['images'], [validJpegBase64]);
      },
    );

    test(
      'supported Ollama sync and stream project direct user PNG attachments into native request',
      () async {
        final subject = makeAdapter();
        final userMsg = userWithAttachment(isPng: true);
        final history = [userMsg];
        final options = LLMRequestOptions(
          attachmentStore: store,
          routeCapabilityProfile: const RouteCapabilityProfile(
            providerInstanceId: 'ollama-test',
            modelId: 'llama3.2-vision',
            imageSupport: RouteImageSupport.supported,
            evidenceSource: 'catalog',
          ),
        );

        await subject.generateResponse(history, options: options);
        await subject.generateStream(history, options: options).toList();

        expect(requests, hasLength(2));
        for (final req in requests) {
          final messages = req['messages'] as List;
          expect(messages, hasLength(1));
          final firstMsg = messages.first as Map<String, dynamic>;
          expect(firstMsg['role'], 'user');
          expect(firstMsg['content'], 'Here is an attached image');
          expect(firstMsg['images'], [validPngBase64]);
        }
      },
    );

    test(
      'supported Ollama sync and stream project direct user JPEG attachments into native request',
      () async {
        final subject = makeAdapter();
        final userMsg = userWithAttachment(
          isPng: false,
          idSuffix: 'jpeg-direct',
        );
        final history = [userMsg];
        final options = LLMRequestOptions(
          attachmentStore: store,
          routeCapabilityProfile: const RouteCapabilityProfile(
            providerInstanceId: 'ollama-test',
            modelId: 'llama3.2-vision',
            imageSupport: RouteImageSupport.supported,
            evidenceSource: 'catalog',
          ),
        );

        await subject.generateResponse(history, options: options);
        await subject.generateStream(history, options: options).toList();

        expect(requests, hasLength(2));
        for (final req in requests) {
          final messages = req['messages'] as List;
          expect(messages, hasLength(1));
          final firstMsg = messages.first as Map<String, dynamic>;
          expect(firstMsg['role'], 'user');
          expect(firstMsg['content'], 'Here is an attached image');
          expect(firstMsg['images'], [validJpegBase64]);
        }
      },
    );

    test(
      'malformed image bytes, MIME deception, or unavailable attachment fails closed before HTTP (zero HTTP)',
      () async {
        final subject = makeAdapter();

        // Deceptive / malformed bytes: declared image/png but bytes are random text
        final badBytes = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
        final badHash = sha256.convert(badBytes).toString();
        final badAttId = 'att-corrupt';
        final badFile = File('${scratch.path}/attachments/$badAttId/payload');
        badFile.parent.createSync(recursive: true);
        badFile.writeAsBytesSync(badBytes);
        final badAtt = UserAttachment(
          id: badAttId,
          safeName: 'corrupt.png',
          mimeType: 'image/png',
          sizeBytes: badBytes.length,
          sha256: badHash,
          kind: UserAttachmentKind.image,
          agentLocalReference: 'attachments/$badAttId/payload',
          mediaId: 'media-$badAttId',
          status: UserAttachmentStatus.available,
        );
        final badMsg = Message(
          role: MessageRole.user,
          content: 'Bad attachment',
          attachments: [badAtt],
        );

        final optionsWithStore = LLMRequestOptions(
          attachmentStore: store,
          routeCapabilityProfile: const RouteCapabilityProfile(
            providerInstanceId: 'ollama-test',
            modelId: 'llama3.2-vision',
            imageSupport: RouteImageSupport.supported,
            evidenceSource: 'catalog',
          ),
        );

        await expectLater(
          () => subject.generateResponse([badMsg], options: optionsWithStore),
          throwsA(isA<FormatException>()),
        );

        // Unavailable attachment (missing in store)
        final missingAtt = UserAttachment(
          id: 'att-missing',
          safeName: 'missing.png',
          mimeType: 'image/png',
          sizeBytes: 100,
          sha256:
              '0000000000000000000000000000000000000000000000000000000000000000',
          kind: UserAttachmentKind.image,
          agentLocalReference: '${scratch.path}/missing/payload',
          mediaId: 'media-missing',
          status: UserAttachmentStatus.unavailable,
        );
        final missingMsg = Message(
          role: MessageRole.user,
          content: 'Missing attachment',
          attachments: [missingAtt],
        );

        await expectLater(
          () =>
              subject.generateResponse([missingMsg], options: optionsWithStore),
          throwsA(isA<StateError>()),
        );

        expect(requests, isEmpty);
      },
    );

    test(
      'deterministic multi-image order across direct attachments and multiple tool results',
      () async {
        final subject = makeAdapter();
        final userMsg = userWithMultipleAttachments();
        final history = [
          userMsg,
          Message(
            role: MessageRole.assistant,
            toolCalls: [
              ToolCall(id: 'call-1', name: 'view_image', arguments: const {}),
              ToolCall(id: 'call-2', name: 'view_image', arguments: const {}),
            ],
          ),
          Message(
            role: MessageRole.tool,
            toolCallId: 'call-1',
            content: 'First result',
            toolResult: makeImageResult(text: 'First result', isPng: true),
          ),
          Message(
            role: MessageRole.tool,
            toolCallId: 'call-2',
            content: 'Second result',
            toolResult: makeImageResult(text: 'Second result', isPng: false),
          ),
        ];
        final options = LLMRequestOptions(
          attachmentStore: store,
          routeCapabilityProfile: const RouteCapabilityProfile(
            providerInstanceId: 'ollama-test',
            modelId: 'llama3.2-vision',
            imageSupport: RouteImageSupport.supported,
            evidenceSource: 'catalog',
          ),
        );

        await subject.generateResponse(history, options: options);

        expect(requests, hasLength(1));
        final messages = requests.single['messages'] as List;
        expect(messages, hasLength(5));

        // User direct attachments in deterministic order (PNG then JPEG)
        final firstUser = messages[0] as Map<String, dynamic>;
        expect(firstUser['images'], [validPngBase64, validJpegBase64]);

        // Tool results are followed by a single detached user message combining tool images in deterministic order
        final tool1 = messages[2] as Map<String, dynamic>;
        expect(tool1['role'], 'tool');
        expect(tool1['tool_call_id'], 'call-1');
        expect(tool1.containsKey('images'), isFalse);

        final tool2 = messages[3] as Map<String, dynamic>;
        expect(tool2['role'], 'tool');
        expect(tool2['tool_call_id'], 'call-2');
        expect(tool2.containsKey('images'), isFalse);

        final detached = messages[4] as Map<String, dynamic>;
        expect(detached['role'], 'user');
        expect(detached['images'], [validPngBase64, validJpegBase64]);
        expect(detached['content'], contains('preceding tool result 1'));
        expect(detached['content'], contains('preceding tool result 2'));
      },
    );

    test(
      'incomplete image tool batch fails closed with FormatException before HTTP (sync and stream)',
      () async {
        final subject = makeAdapter();
        // Assistant expected 2 tool calls, but only 1 tool result arrived
        final history = [
          Message(role: MessageRole.user, content: 'Analyze image'),
          Message(
            role: MessageRole.assistant,
            toolCalls: [
              ToolCall(id: 'call-1', name: 'view_image', arguments: const {}),
              ToolCall(id: 'call-2', name: 'other_tool', arguments: const {}),
            ],
          ),
          Message(
            role: MessageRole.tool,
            toolCallId: 'call-1',
            content: 'Image loaded',
            toolResult: makeImageResult(text: 'Image loaded', isPng: true),
          ),
        ];
        const options = LLMRequestOptions(
          routeCapabilityProfile: RouteCapabilityProfile(
            providerInstanceId: 'ollama-test',
            modelId: 'llama3.2-vision',
            imageSupport: RouteImageSupport.supported,
            evidenceSource: 'catalog',
          ),
        );

        await expectLater(
          () => subject.generateResponse(history, options: options),
          throwsA(isA<FormatException>()),
        );
        await expectLater(
          () => subject.generateStream(history, options: options).toList(),
          throwsA(isA<FormatException>()),
        );
        expect(requests, isEmpty);
      },
    );

    test(
      'orphan, duplicate, or mismatched image tool results fail closed before HTTP',
      () async {
        final subject = makeAdapter();
        final imgResult = makeImageResult(text: 'Image loaded', isPng: true);
        const options = LLMRequestOptions(
          routeCapabilityProfile: RouteCapabilityProfile(
            providerInstanceId: 'ollama-test',
            modelId: 'llama3.2-vision',
            imageSupport: RouteImageSupport.supported,
            evidenceSource: 'catalog',
          ),
        );

        // Orphan tool result
        final orphanHistory = [
          Message(
            role: MessageRole.tool,
            toolCallId: 'call-1',
            content: 'Image loaded',
            toolResult: imgResult,
          ),
        ];
        await expectLater(
          () => subject.generateResponse(orphanHistory, options: options),
          throwsA(isA<FormatException>()),
        );

        // Duplicate tool results
        final duplicateResultsHistory = [
          Message(
            role: MessageRole.assistant,
            toolCalls: [
              ToolCall(id: 'call-1', name: 'view_image', arguments: const {}),
            ],
          ),
          Message(
            role: MessageRole.tool,
            toolCallId: 'call-1',
            content: 'Image loaded',
            toolResult: imgResult,
          ),
          Message(
            role: MessageRole.tool,
            toolCallId: 'call-1',
            content: 'Image loaded',
            toolResult: imgResult,
          ),
        ];
        await expectLater(
          () => subject.generateResponse(
            duplicateResultsHistory,
            options: options,
          ),
          throwsA(isA<FormatException>()),
        );

        // Mismatched toolCallId
        final mismatchedHistory = [
          Message(
            role: MessageRole.assistant,
            toolCalls: [
              ToolCall(id: 'call-1', name: 'view_image', arguments: const {}),
            ],
          ),
          Message(
            role: MessageRole.tool,
            toolCallId: 'call-unknown',
            content: 'Image loaded',
            toolResult: imgResult,
          ),
        ];
        await expectLater(
          () => subject.generateResponse(mismatchedHistory, options: options),
          throwsA(isA<FormatException>()),
        );
        expect(requests, isEmpty);
      },
    );

    test(
      'immutable admitted profile is strictly honored despite mutable config changes',
      () async {
        final mutableConfig = _MutableConfig();
        final subject = OllamaAdapter(
          mutableConfig,
          ProviderRegistry.findByNameOrAlias('ollama')!,
          client: MockClient((request) async {
            requests.add(jsonDecode(request.body) as Map<String, dynamic>);
            return http.Response(
              jsonEncode({
                'message': {'role': 'assistant', 'content': 'I see the image'},
                'done': true,
              }),
              200,
            );
          }),
        );

        final history = makeToolHistory(isPng: true);

        // Case A: Admitted as supported, but config changes to unsupported
        mutableConfig.overrideCapability = const ModelCapabilityOverride(
          supportsImageInput: false,
        );
        const supportedOptions = LLMRequestOptions(
          routeCapabilityProfile: RouteCapabilityProfile(
            providerInstanceId: 'ollama-test',
            modelId: 'llama3.2-vision',
            imageSupport: RouteImageSupport.supported,
            evidenceSource: 'catalog',
          ),
        );

        final resp = await subject.generateResponse(
          history,
          options: supportedOptions,
        );
        expect(resp.message.content, 'I see the image');
        expect(requests, hasLength(1));
        expect(jsonEncode(requests.single), contains(validPngBase64));

        requests.clear();

        // Case B: Admitted as unknown, but config changes to supported
        mutableConfig.overrideCapability = const ModelCapabilityOverride(
          supportsImageInput: true,
        );
        const unknownOptions = LLMRequestOptions(
          routeCapabilityProfile: RouteCapabilityProfile(
            providerInstanceId: 'ollama-test',
            modelId: 'llama3.2-vision',
            imageSupport: RouteImageSupport.unknown,
            evidenceSource: 'unknown',
          ),
        );

        expect(
          () => subject.generateResponse(history, options: unknownOptions),
          throwsA(isA<LocalImageCapabilityException>()),
        );
        expect(requests, isEmpty);
      },
    );

    test(
      'requestClientFactory creates request-scoped client closed upon completion or cancellation',
      () async {
        final createdClients = <_CountingClient>[];
        final subject = OllamaAdapter(
          Config(environment: const {}),
          ProviderRegistry.findByNameOrAlias('ollama')!,
          requestClientFactory: () {
            final c = _CountingClient(
              MockClient((request) async {
                return http.Response(
                  jsonEncode({
                    'message': {'role': 'assistant', 'content': 'ok'},
                    'done': true,
                  }),
                  200,
                );
              }),
            );
            createdClients.add(c);
            return c;
          },
        );

        final history = [Message(role: MessageRole.user, content: 'Hello')];
        final res = await subject.generateResponse(history);
        expect(res.message.content, 'ok');
        expect(createdClients, hasLength(1));
        expect(createdClients.single.isClosed, isTrue);

        // Now with cancellation
        final cancelScope = RunCancellationScope(
          sessionId: 'test-session-id',
          runId: 'test-cancel-run',
          workItemId: 'test-work-item',
          generation: 1,
        );
        final c2 = _CountingClient(
          MockClient((request) async {
            await Future.delayed(const Duration(milliseconds: 50));
            return http.Response(
              jsonEncode({
                'message': {'role': 'assistant', 'content': 'late'},
                'done': true,
              }),
              200,
            );
          }),
        );
        createdClients.clear();

        final cancelSubject = OllamaAdapter(
          Config(environment: const {}),
          ProviderRegistry.findByNameOrAlias('ollama')!,
          requestClientFactory: () {
            createdClients.add(c2);
            return c2;
          },
        );

        final future = cancelSubject.generateResponse(
          history,
          options: LLMRequestOptions(cancellationScope: cancelScope),
        );
        await cancelScope.cancel();

        await expectLater(
          future,
          throwsA(isA<ProviderRequestCancelledException>()),
        );
        expect(createdClients.single.isClosed, isTrue);
      },
    );

    test(
      'unsupported model fails closed before HTTP dispatch (zero HTTP)',
      () async {
        final subject = makeAdapter();
        final history = makeToolHistory(isPng: true);
        const options = LLMRequestOptions(
          routeCapabilityProfile: RouteCapabilityProfile(
            providerInstanceId: 'ollama-test',
            modelId: 'llama3.2',
            imageSupport: RouteImageSupport.unsupported,
            evidenceSource: 'catalog',
          ),
        );

        expect(
          () => subject.generateResponse(history, options: options),
          throwsA(isA<LocalImageCapabilityException>()),
        );
        expect(
          () => subject.generateStream(history, options: options).toList(),
          throwsA(isA<LocalImageCapabilityException>()),
        );
        // Zero HTTP requests sent
        expect(requests, isEmpty);
      },
    );

    test(
      'unknown capability model fails closed before HTTP dispatch (zero HTTP)',
      () async {
        final subject = makeAdapter();
        final history = makeToolHistory(isPng: true);
        const options = LLMRequestOptions(
          routeCapabilityProfile: RouteCapabilityProfile(
            providerInstanceId: 'ollama-test',
            modelId: 'custom-unknown-model',
            imageSupport: RouteImageSupport.unknown,
            evidenceSource: 'unknown',
          ),
        );

        expect(
          () => subject.generateResponse(history, options: options),
          throwsA(isA<LocalImageCapabilityException>()),
        );
        expect(requests, isEmpty);
      },
    );

    test(
      'preserves thinking directives and text in native request body',
      () async {
        final subject = makeAdapter();
        final history = [
          Message(role: MessageRole.user, content: 'Test prompt'),
        ];
        const options = LLMRequestOptions(
          thinkingDirective: ThinkingToggleDirective(enabled: true),
          routeCapabilityProfile: RouteCapabilityProfile(
            providerInstanceId: 'ollama-test',
            modelId: 'llama3.2-vision',
            imageSupport: RouteImageSupport.supported,
            evidenceSource: 'catalog',
          ),
        );

        final response = await subject.generateResponse(
          history,
          options: options,
        );

        expect(requests, hasLength(1));
        expect(requests.single['think'], isTrue);
        expect(response.message.content, 'I see the image');
        expect(response.message.reasoning, 'thought');
      },
    );
  });

  group('RouteCapabilityResolver Ollama Vision Discovery', () {
    test('recognizes ollama_capabilities vision as supported', () {
      final declared = RouteCapabilityResolver.parseDeclaredImageSupport({
        'ollama_capabilities': ['completion', 'vision', 'tools'],
      });
      expect(declared, isTrue);
    });

    test('recognizes ollama_capabilities non-vision as unsupported', () {
      final declared = RouteCapabilityResolver.parseDeclaredImageSupport({
        'ollama_capabilities': ['completion', 'tools'],
      });
      expect(declared, isFalse);
    });

    test('recognizes capabilities list with vision as supported', () {
      final declared = RouteCapabilityResolver.parseDeclaredImageSupport({
        'capabilities': ['completion', 'vision', 'tools'],
      });
      expect(declared, isTrue);
    });

    test(
      'recognizes generic capabilities list without vision as unknown (does not veto)',
      () {
        final declared = RouteCapabilityResolver.parseDeclaredImageSupport({
          'capabilities': ['completion', 'tools'],
        });
        expect(declared, isNull);
      },
    );

    test('malformed Ollama capability evidence stays unknown', () {
      for (final value in [
        <Object?>[42],
        <Object?>[null],
        <Object?>['vision', 42],
        <Object?>[' '],
      ]) {
        expect(
          RouteCapabilityResolver.parseDeclaredImageSupport({
            'ollama_capabilities': value,
          }),
          isNull,
        );
      }
    });

    test(
      'generic non-image capability list does not veto explicit modalities',
      () {
        expect(
          RouteCapabilityResolver.parseDeclaredImageSupport({
            'capabilities': ['tools'],
            'input_modalities': ['text', 'image'],
          }),
          isTrue,
        );
      },
    );

    test('returns null for empty or malformed ollama_capabilities', () {
      expect(
        RouteCapabilityResolver.parseDeclaredImageSupport({
          'ollama_capabilities': [],
        }),
        isNull,
      );
      expect(
        RouteCapabilityResolver.parseDeclaredImageSupport({
          'ollama_capabilities': 'not-a-list',
        }),
        isNull,
      );
    });
  });
}
