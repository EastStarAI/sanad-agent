import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sanad_agent/capabilities/models/tool_schema.dart';
import 'package:sanad_agent/capabilities/registry/tools_registry.dart';
import 'package:sanad_agent/capabilities/runtime/workspace_path_resolver.dart';
import 'package:sanad_agent/capabilities/runtime/workspace_tools/view_image_handler.dart';
import 'package:sanad_agent/capabilities/tools/base_tool.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/models/tool_call.dart';
import 'package:sanad_agent/core/models/tool_execution_result.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/core/provider_runtime/provider_protocol_constants.dart';
import 'package:sanad_agent/core/provider_runtime/provider_rate_limiter.dart';
import 'package:sanad_agent/core/provider_runtime/route_capability_resolver.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_failure_reason.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_notice.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_recovery_exception.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_recovery_service.dart';
import 'package:sanad_agent/engine/adapters/base_openai_adapter.dart';
import 'package:sanad_agent/engine/adapters/provider_registry.dart';
import 'package:sanad_agent/engine/agent_runner.dart';
import 'package:sanad_agent/evolution/attachments/attachment_store.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:test/test.dart';

final class _TestViewImageTool extends BaseTool {
  _TestViewImageTool({
    required this.handler,
    required this.workspacePath,
  });

  final ViewImageHandler handler;
  final String workspacePath;

  @override
  ToolSchema get schema => ToolSchema(
    name: 'view_image',
    description: 'Inspect one local image',
    parameters: {
      'type': 'object',
      'properties': {
        'path': {'type': 'string'},
        'detail': {'type': 'string', 'default': 'auto'},
      },
      'required': ['path'],
    },
  );

  @override
  Future<String> execute(Map<String, dynamic> args, {ToolContext? context}) async {
    final res = await executeResult(args, context: context);
    return res.displayText;
  }

  @override
  Future<ToolExecutionResult> executeResult(
    Map<String, dynamic> args, {
    ToolContext? context,
  }) => handler.executeResult(
    args,
    workspacePath: workspacePath,
    admittedAttachmentPaths: const [],
    authorizeExternal: (_, _, _) async {},
    context: context,
  );
}

void main() {
  late Directory scratch;
  late AgentStateDatabase db;
  late AttachmentStore store;
  late ProviderInstanceRepository repo;
  late SessionManager sessionManager;
  late RuntimeRecoveryService recovery;
  late Config config;
  late RouteCapabilityResolver resolver;

  final samplePngBytes = [
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
    0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4,
    0x89, 0x00, 0x00, 0x00, 0x0a, 0x49, 0x44, 0x41,
    0x54, 0x78, 0x9c, 0x63, 0x00, 0x01, 0x00, 0x00,
    0x05, 0x00, 0x01, 0x0d, 0x0a, 0x2d, 0xb4, 0x00,
    0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae,
    0x42, 0x60, 0x82,
  ];

  setUp(() async {
    scratch = Directory.systemTemp.createTempSync('unsupported-image-recovery-');
    setSanadHomeOverride(scratch.path);
    db = AgentStateDatabase.inMemory();
    store = AttachmentStore(db, stateHome: scratch.path);
    await store.initialize();
    repo = ProviderInstanceRepository.fromDatabase(db.db);

    final now = DateTime.now();
    final customProvider = ProviderInstance(
      id: 'custom-text-provider-uuid',
      templateId: kCustomProviderTemplateId,
      displayName: 'Custom Text Provider',
      protocol: ProviderProtocol.openaiCompatible,
      authMethod: ProviderAuthMethod.apiKey,
      baseUrl: 'http://127.0.0.1:8088/v1',
      createdAt: now,
      updatedAt: now,
    ).copyWith(configRevision: 1, credentialRevision: 1);
    repo.createInstance(customProvider);

    final configFile = File('${scratch.path}/config.yaml');
    configFile.writeAsStringSync('''
model_capabilities:
  "text-only-model":
    supports_image_input: false
''');
    config = Config(environment: const {});
    resolver = RouteCapabilityResolver(
      instances: repo,
      config: config,
    );
    recovery = RuntimeRecoveryService(repo, ProviderRateLimiter());

    await getIt.reset();
    getIt.registerSingleton<AgentStateDatabase>(db);
    getIt.registerSingleton<AttachmentStore>(store);
    getIt.registerSingleton<Config>(config);
    getIt.registerSingleton<ProviderInstanceRepository>(repo);
    getIt.registerSingleton<RouteCapabilityResolver>(resolver);
    getIt.registerSingleton<RuntimeRecoveryService>(recovery);

    SessionManager.resetForTesting();
    sessionManager = SessionManager();
  });

  tearDown(() async {
    SessionManager.resetForTesting();
    await getIt.reset();
    try {
      scratch.deleteSync(recursive: true);
    } catch (_) {}
  });

  test(
    'real pipeline: view_image on text-only model returns typed text error and continuation completes cleanly with zero fatal notice',
    () async {
      final session = sessionManager.createSession(
        'text-only-model',
        providerId: 'custom-text-provider-uuid',
      );

      final workspaceDir = Directory('${scratch.path}/workspace')..createSync();
      final sampleFile = File('${workspaceDir.path}/sample.png')
        ..writeAsBytesSync(samplePngBytes);

      final outgoingBodies = <Map<String, dynamic>>[];
      int requestCount = 0;

      final adapter = BaseOpenAIAdapter(
        config,
        ProviderRegistry.findByNameOrAlias(kCustomProviderTemplateId)!,
        providerInstanceId: 'custom-text-provider-uuid',
        defaultModelOverride: 'text-only-model',
        apiKeyOverride: 'test-key',
        baseUrlOverride: 'http://127.0.0.1:8088/v1',
        client: MockClient((request) async {
          requestCount++;
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          outgoingBodies.add(body);

          if (requestCount == 1) {
            // First model response streams view_image tool call
            final toolArgs = jsonEncode({'path': sampleFile.path});
            final sse = [
              'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_view_1","type":"function","function":{"name":"view_image","arguments":${jsonEncode(toolArgs)}}}]},"finish_reason":null}]}',
              'data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}',
              'data: [DONE]',
            ].join('\n\n');
            return http.Response(
              sse,
              200,
              headers: {'content-type': 'text/event-stream'},
            );
          } else {
            // Second model response streams final answer acknowledging tool error
            final sse = [
              'data: {"choices":[{"delta":{"content":"I understand that image inspection is not supported by this model route."},"finish_reason":null}]}',
              'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}',
              'data: [DONE]',
            ].join('\n\n');
            return http.Response(
              sse,
              200,
              headers: {'content-type': 'text/event-stream'},
            );
          }
        }),
      );

      final registry = ToolsRegistry();
      registry.registerTool(
        _TestViewImageTool(
          handler: ViewImageHandler(const WorkspacePathResolver()),
          workspacePath: workspaceDir.path,
        ),
      );

      final runner = AgentRunner(
        adapter,
        registry,
        sessionManager,
        existingSessionId: session.sessionId,
        attachmentStore: store,
      );

      final chunks = await runner.streamMessage(
        'Please inspect sample.png',
        requestId: 'req-unsupported-turn-1',
        providerId: 'custom-text-provider-uuid',
        model: 'text-only-model',
      ).toList();

      // Verify the turn completed successfully
      expect(chunks.join(), contains('I understand that image inspection is not supported by this model route.'));
      expect(
        runner.history.last.content,
        'I understand that image inspection is not supported by this model route.',
      );

      // Verify two HTTP requests occurred
      expect(requestCount, 2);

      // Verify continuation HTTP request body
      final continuationBody = outgoingBodies[1];
      final reqMessages = continuationBody['messages'] as List<dynamic>;

      // Check tool call and result pairing in continuation messages
      final toolCallMsg = reqMessages.firstWhere(
        (m) => m['role'] == 'assistant' && m['tool_calls'] != null,
      );
      expect(toolCallMsg['tool_calls'][0]['id'], 'call_view_1');

      final toolResultMsg = reqMessages.firstWhere(
        (m) => m['role'] == 'tool' && m['tool_call_id'] == 'call_view_1',
      );
      expect(
        toolResultMsg['content'],
        'Image inspection is not supported because the active model route does not support image input.',
      );

      // Verify zero image_url parts anywhere in outgoing requests
      for (final body in outgoingBodies) {
        final bodyStr = jsonEncode(body);
        expect(bodyStr, isNot(contains('image_url')));
        expect(bodyStr, isNot(contains('data:image/')));
      }

      // Verify recovery service recorded no active failure or blocked notice
      expect(recovery.hasActiveNotice(session.sessionId), isFalse);
    },
  );

  test(
    'frozen admission: ToolContext receives admitted profile even if config changes during the turn',
    () async {
      final session = sessionManager.createSession(
        'text-only-model',
        providerId: 'custom-text-provider-uuid',
      );

      final workspaceDir = Directory('${scratch.path}/workspace')..createSync();
      final sampleFile = File('${workspaceDir.path}/sample.png')
        ..writeAsBytesSync(samplePngBytes);

      int toolExecutionCount = 0;

      final adapter = BaseOpenAIAdapter(
        config,
        ProviderRegistry.findByNameOrAlias(kCustomProviderTemplateId)!,
        providerInstanceId: 'custom-text-provider-uuid',
        defaultModelOverride: 'text-only-model',
        apiKeyOverride: 'test-key',
        baseUrlOverride: 'http://127.0.0.1:8088/v1',
        client: MockClient((request) async {
          toolExecutionCount++;
          if (toolExecutionCount == 1) {
            final toolArgs = jsonEncode({'path': sampleFile.path});
            final sse = [
              'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_frozen_1","type":"function","function":{"name":"view_image","arguments":${jsonEncode(toolArgs)}}}]},"finish_reason":null}]}',
              'data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}',
              'data: [DONE]',
            ].join('\n\n');
            return http.Response(
              sse,
              200,
              headers: {'content-type': 'text/event-stream'},
            );
          } else {
            final sse = [
              'data: {"choices":[{"delta":{"content":"Done."},"finish_reason":null}]}',
              'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}',
              'data: [DONE]',
            ].join('\n\n');
            return http.Response(
              sse,
              200,
              headers: {'content-type': 'text/event-stream'},
            );
          }
        }),
      );

      final viewImageHandler = ViewImageHandler(const WorkspacePathResolver());
      final registry = ToolsRegistry();
      registry.registerTool(
        _TestViewImageTool(
          handler: viewImageHandler,
          workspacePath: workspaceDir.path,
        ),
      );

      final runner = AgentRunner(
        adapter,
        registry,
        sessionManager,
        existingSessionId: session.sessionId,
        attachmentStore: store,
      );

      // Mutate config on disk during execution to true
      final configFile = File('${scratch.path}/config.yaml');
      configFile.writeAsStringSync('''
model_capabilities:
  "text-only-model":
    supports_image_input: true
''');

      await runner.streamMessage(
        'Inspect this',
        requestId: 'req-frozen-turn-1',
        providerId: 'custom-text-provider-uuid',
        model: 'text-only-model',
      ).toList();

      // Verify the tool result in history has the text failure for unsupported
      final toolMsg = runner.history.firstWhere(
        (m) => m.role == MessageRole.tool && m.toolCallId == 'call_frozen_1',
      );
      expect(toolMsg.toolResult?.isError, isTrue);
      expect(
        toolMsg.toolResult?.displayText,
        'Image inspection is not supported because the active model route does not support image input.',
      );
    },
  );

  test(
    'guard: legacy pixel-bearing history triggers preflight LocalImageCapabilityException and fails closed with clean local notice',
    () async {
      final session = sessionManager.createSession(
        'text-only-model',
        providerId: 'custom-text-provider-uuid',
      );

      // Seed history with a legacy tool result that contains a ToolImageBlock
      sessionManager.saveSessionHistory(session.sessionId, [
        Message(
          role: MessageRole.user,
          content: 'Here is an earlier image result',
        ),
        Message(
          role: MessageRole.assistant,
          content: 'Looking at image',
          toolCalls: [
            ToolCall(
              id: 'legacy_call_1',
              name: 'view_image',
              arguments: {'path': 'old.png'},
            ),
          ],
        ),
        Message(
          role: MessageRole.tool,
          content: 'Loaded image',
          toolCallId: 'legacy_call_1',
          toolResult: ToolExecutionResult(
            blocks: [
              ToolTextBlock(text: 'Loaded image'),
              ToolImageBlock(
                dataBase64: base64Encode(samplePngBytes),
                mimeType: 'image/png',
                width: 1,
                height: 1,
                detail: ToolImageDetail.original,
              ),
            ],
          ),
        ),
      ]);

      int httpCalls = 0;
      final adapter = BaseOpenAIAdapter(
        config,
        ProviderRegistry.findByNameOrAlias(kCustomProviderTemplateId)!,
        providerInstanceId: 'custom-text-provider-uuid',
        defaultModelOverride: 'text-only-model',
        apiKeyOverride: 'test-key',
        baseUrlOverride: 'http://127.0.0.1:8088/v1',
        client: MockClient((request) async {
          httpCalls++;
          return http.Response('{"choices":[]}', 200);
        }),
      );

      final runner = AgentRunner(
        adapter,
        ToolsRegistry(),
        sessionManager,
        existingSessionId: session.sessionId,
        attachmentStore: store,
      );

      // Running the turn should throw RuntimeRecoveryRequired
      await expectLater(
        runner.streamMessage(
          'Next question',
          requestId: 'req-legacy-pixel-turn',
          providerId: 'custom-text-provider-uuid',
          model: 'text-only-model',
        ).toList(),
        throwsA(
          isA<RuntimeRecoveryRequired>().having(
            (e) => e.reason,
            'reason',
            RuntimeFailureReason.invalidRequest,
          ),
        ),
      );

      // Zero HTTP requests made to provider
      expect(httpCalls, 0);

      // Recovery notice is active and truthfully describes the capability error
      final notice = recovery.activeNotice(session.sessionId);
      expect(notice, isNotNull);
      expect(notice!.status, RuntimeNoticeStatus.blocked);
      expect(notice.reason, RuntimeFailureReason.invalidRequest);
      expect(notice.title, 'Image input not supported');
      expect(
        notice.message,
        'The selected model "text-only-model" does not support image input.',
      );
      // Must NOT contain provider UUID, "Provider response", or contact-failure wording
      expect(notice.message, isNot(contains('custom-text-provider-uuid')));
      expect(notice.message, isNot(contains('Provider response')));
      expect(notice.message, isNot(contains('contact')));

      // Session history is preserved and not rewritten/stripped
      final savedHistory = sessionManager.getSession(session.sessionId)!.messages;
      expect(savedHistory.length, 4);
      final legacyToolMessage = savedHistory.firstWhere(
        (m) => m.role == MessageRole.tool && m.toolCallId == 'legacy_call_1',
      );
      expect(
        legacyToolMessage.toolResult?.blocks.whereType<ToolImageBlock>(),
        isNotEmpty,
      );
    },
  );

  test(
    'guard: direct user image attachment on text-only route is projected to text with honest guidance and zero wire image parts',
    () async {
      final session = sessionManager.createSession(
        'text-only-model',
        providerId: 'custom-text-provider-uuid',
      );
      final upload = await store.create(
        fileName: 'user_pic.png',
        declaredMime: 'image/png',
        expectedSize: samplePngBytes.length,
        expectedSha256: sha256.convert(samplePngBytes).toString(),
      );
      await store.write(upload, samplePngBytes);
      final attachment = await store.commit(
        upload,
        sessionId: session.sessionId,
        admissionId: 'adm-attach-1',
      );

      final projected = await AgentRunner.projectUserAttachmentsForProvider(
        store: store,
        sessionId: session.sessionId,
        messages: [
          Message(
            role: MessageRole.user,
            content: 'Describe this photo',
            attachments: [attachment],
          ),
        ],
        supportsImageInput: false,
      );

      expect(projected.length, 1);
      final msg = projected.single;
      expect(msg.attachments, isEmpty);
      expect(msg.content, contains('Agent-local attachments'));
      expect(
        msg.content,
        contains(
          'image inspection is not supported by the current model route',
        ),
      );
      expect(msg.content, isNot(contains('Use view_image')));
    },
  );

  test(
    'guard: unrelated HTTP error still produces standard notice and preserves error classification',
    () async {
      final session = sessionManager.createSession(
        'text-only-model',
        providerId: 'custom-text-provider-uuid',
      );

      final adapter = BaseOpenAIAdapter(
        config,
        ProviderRegistry.findByNameOrAlias(kCustomProviderTemplateId)!,
        providerInstanceId: 'custom-text-provider-uuid',
        defaultModelOverride: 'text-only-model',
        apiKeyOverride: 'test-key',
        baseUrlOverride: 'http://127.0.0.1:8088/v1',
        client: MockClient((request) async {
          return http.Response('Internal Server Error Occurred', 500);
        }),
      );

      final runner = AgentRunner(
        adapter,
        ToolsRegistry(),
        sessionManager,
        existingSessionId: session.sessionId,
        attachmentStore: store,
      );

      await expectLater(
        runner.streamMessage(
          'Hello',
          requestId: 'req-unrelated-error',
          providerId: 'custom-text-provider-uuid',
          model: 'text-only-model',
        ).toList(),
        throwsA(isA<RuntimeRecoveryRequired>()),
      );

      final notice = recovery.activeNotice(session.sessionId);
      expect(notice, isNotNull);
      // Standard notice should have provider response text appended
      expect(notice!.message, contains('Provider response:'));
    },
  );
}
