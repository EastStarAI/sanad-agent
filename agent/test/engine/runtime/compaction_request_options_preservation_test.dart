import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:sanad_agent/core/agent_runtime_service.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/models/user_attachment.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/core/provider_thinking/native_thinking_directive.dart';
import 'package:sanad_agent/engine/adapters/llm_request_options.dart';
import 'package:sanad_agent/engine/adapters/provider_watchdog_config.dart';
import 'package:sanad_agent/engine/adapters/tool_result_wire_codec.dart';
import 'package:sanad_agent/engine/compaction/compaction.dart';
import 'package:sanad_agent/engine/runtime/compaction_request_factory.dart';
import 'package:sanad_agent/engine/runtime/run_cancellation_scope.dart';
import 'package:sanad_agent/evolution/attachments/attachment_store.dart';
import 'package:sanad_agent/evolution/compaction/model_projection_builder.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/compaction_boundary_repository.dart';
import 'package:sanad_agent/evolution/db/session_db.dart';
import 'package:sanad_agent/evolution/db/session_history_revision_repository.dart';
import 'package:sanad_agent/evolution/db/session_projection_revision_repository.dart';
import 'package:sanad_agent/evolution/models/session_state.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:test/test.dart';

class _MockRuntimeService extends AgentRuntimeService {
  _MockRuntimeService(super.config, super.repo);

  @override
  RouteSignature resolveSignature({String? providerId, String? modelId}) {
    return const RouteSignature(
      providerInstanceId: 'provider-test',
      templateId: 'openai',
      protocol: 'openai_compatible',
      normalizedBaseUrl: 'https://api.example.com/v1',
      modelId: 'gpt-4o',
      configRevision: 1,
      credentialRevision: 1,
    );
  }
}

void main() {
  group('G7 Request Options and Thinking Preservation', () {
    late AgentStateDatabase stateDb;
    late SessionDB sessionDb;
    late SessionHistoryRevisionRepository historyRepo;
    late SessionProjectionRevisionRepository projRepo;
    late CompactionBoundaryRepository boundaryRepo;
    late ModelProjectionBuilder projBuilder;
    late Directory tempDir;

    setUp(() async {
      getIt.reset();
      tempDir = Directory.systemTemp.createTempSync('compaction_g7_test_');
      stateDb = AgentStateDatabase.inMemory();
      sessionDb = SessionDB.fromState(stateDb);
      historyRepo = SessionHistoryRevisionRepository(stateDb);
      projRepo = SessionProjectionRevisionRepository(stateDb);
      boundaryRepo = CompactionBoundaryRepository(stateDb, historyRepo);
      projBuilder = ModelProjectionBuilder(
        sessions: sessionDb,
        boundaries: boundaryRepo,
      );

      final config = Config();
      final providerRepo = ProviderInstanceRepository(stateDb);
      final runtime = _MockRuntimeService(config, providerRepo);

      getIt.registerSingleton<AgentStateDatabase>(stateDb);
      getIt.registerSingleton<SessionHistoryRevisionRepository>(historyRepo);
      getIt.registerSingleton<SessionProjectionRevisionRepository>(projRepo);
      getIt.registerSingleton<ModelProjectionBuilder>(projBuilder);
      getIt.registerSingleton<AgentRuntimeService>(runtime);
      getIt.registerSingleton<Config>(config);
      getIt.registerSingleton<SessionManager>(SessionManager());

      final now = DateTime.utc(2026, 1, 1);
      sessionDb.saveSession(
        SessionState(
          sessionId: 'test-session',
          model: 'gpt-4o',
          providerId: 'provider-test',
          thinkingMode: 'high',
          createdAt: now,
          updatedAt: now,
          lastUserMessageAt: now,
        ),
      );
      sessionDb.replaceMessages('test-session', [
        Message(role: MessageRole.user, content: 'goal: test G7 preservation'),
        Message(role: MessageRole.assistant, content: 'working'),
      ]);
    });

    tearDown(() {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
      getIt.reset();
    });

    test(
      'CompactionRequestFactory.buildCompactionRequestOptions derives complete options accounting for all fields',
      () {
        const thinkingDirective = OpenAiEffortDirective('medium');
        final attachmentStore = AttachmentStore(stateDb, stateHome: tempDir.path);
        http.Client customClient() => http.Client();
        const customWatchdogs = ProviderWatchdogConfig(
          connectTimeout: Duration(seconds: 45),
        );
        final cancellationScope = RunCancellationScope(
          sessionId: 'test-session',
          runId: 'run-1',
          workItemId: 'work-1',
          generation: 1,
        );

        final base = LLMRequestOptions(
          sessionId: 'test-session',
          providerInstanceId: 'provider-test',
          thinkingMode: 'medium',
          thinkingDirective: thinkingDirective,
          timeout: const Duration(seconds: 60),
          maxOutputTokens: 1024,
          cancellationScope: cancellationScope,
          watchdogs: customWatchdogs,
          attachmentStore: attachmentStore,
          requestClientFactory: customClient,
        );

        const route = RouteSignature(
          providerInstanceId: 'provider-test',
          templateId: 'openai',
          protocol: 'openai_compatible',
          normalizedBaseUrl: 'https://api.example.com/v1',
          modelId: 'gpt-4o',
          configRevision: 1,
          credentialRevision: 1,
        );

        final derived = CompactionRequestFactory.buildCompactionRequestOptions(
          sessionId: 'test-session',
          compactionId: 'cmp-123',
          routeSignature: route,
          baseOptions: base,
          fallbackThinkingMode: 'high',
        );

        expect(derived.sessionId, 'test-session');
        expect(derived.requestId, 'compaction:cmp-123');
        expect(derived.providerInstanceId, 'provider-test');
        expect(derived.thinkingMode, 'medium');
        expect(derived.thinkingDirective, same(thinkingDirective));
        expect(derived.timeout, const Duration(seconds: 60));
        expect(derived.maxOutputTokens, 1024);
        expect(derived.cancellationScope, same(cancellationScope));
        // Task 118: the response-arrival watchdog of a compaction pass is the
        // central compaction pass timeout, not the normal-turn value.
        expect(
          derived.watchdogs.connectTimeout,
          ModelAwareCompactionPolicy.defaultPassTimeout,
        );
        expect(
          derived.watchdogs.firstByteTimeout,
          customWatchdogs.firstByteTimeout,
        );
        expect(derived.attachmentStore, same(attachmentStore));
        expect(derived.requestClientFactory, isNotNull);
      },
    );

    test(
      'cancellationScope is cleared when expired or terminal instead of blindly copied',
      () {
        final expiredScope = RunCancellationScope(
          sessionId: 'test-session',
          runId: 'run-expired',
          workItemId: 'work-expired',
          generation: 1,
        );
        expiredScope.invalidate();

        final base = LLMRequestOptions(
          sessionId: 'test-session',
          cancellationScope: expiredScope,
        );

        const route = RouteSignature(
          providerInstanceId: 'provider-test',
          templateId: 'openai',
          protocol: 'openai_compatible',
          normalizedBaseUrl: 'https://api.example.com/v1',
          modelId: 'gpt-4o',
          configRevision: 1,
          credentialRevision: 1,
        );

        final derived = CompactionRequestFactory.buildCompactionRequestOptions(
          sessionId: 'test-session',
          compactionId: 'cmp-scope-test',
          routeSignature: route,
          baseOptions: base,
        );

        expect(derived.cancellationScope, isNull);
      },
    );

    test(
      'CompactionRequestFactory.forSession preserves options and thinking directive on manual compaction',
      () async {
        const thinkingDirective = AnthropicBudgetDirective(4096);
        final attachmentStore = AttachmentStore(stateDb, stateHome: tempDir.path);

        final inputOptions = LLMRequestOptions(
          sessionId: 'test-session',
          providerInstanceId: 'provider-test',
          thinkingMode: 'high',
          thinkingDirective: thinkingDirective,
          attachmentStore: attachmentStore,
        );

        final engineRequest = await CompactionRequestFactory.forSession(
          sessionId: 'test-session',
          trigger: CompactionTrigger.manual,
          compactionId: 'cmp-test-manual',
          providerRequestOptions: inputOptions,
        );

        expect(engineRequest, isNotNull);
        final opts = engineRequest!.providerRequestOptions;
        expect(opts.thinkingDirective, same(thinkingDirective));
        expect(opts.attachmentStore, same(attachmentStore));
        expect(opts.requestId, 'compaction:cmp-test-manual');

        // Stored session thinking selection remains unchanged
        final session = sessionDb.getSession('test-session');
        expect(session?.thinkingMode, 'high');
      },
    );

    test(
      'image-bearing request succeeds through real adapter builder with verified attachment store',
      () async {
        final attachmentStore = AttachmentStore(stateDb, stateHome: tempDir.path);
        await attachmentStore.initialize();

        // Valid 1x1 PNG bytes
        final validPngBytes = base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
        );

        final upload = await attachmentStore.create(
          fileName: 'test.png',
          declaredMime: 'image/png',
          expectedSize: validPngBytes.length,
        );
        await attachmentStore.write(upload, validPngBytes);
        final userAttachment = await attachmentStore.commit(
          upload,
          sessionId: 'test-session',
          admissionId: 'admission-test',
        );

        final history = [
          Message(
            role: MessageRole.user,
            content: 'Describe this image',
            attachments: [userAttachment],
          ),
        ];

        final opts = LLMRequestOptions(
          sessionId: 'test-session',
          attachmentStore: attachmentStore,
        );

        final loaded = await ToolResultWireCodec.loadVerifiedUserAttachments(
          history,
          attachmentStore: opts.attachmentStore,
        );

        expect(loaded, contains(userAttachment.id));
        expect(loaded[userAttachment.id], base64Encode(validPngBytes));
      },
    );

    test(
      'absent, corrupt, or unauthorized image attachment fails specifically before HTTP',
      () async {
        final attachmentStore = AttachmentStore(stateDb, stateHome: tempDir.path);
        await attachmentStore.initialize();

        // Missing attachment (not stored in AttachmentStore)
        final missingAttachment = UserAttachment(
          id: 'missing-att-id',
          safeName: 'missing.png',
          mimeType: 'image/png',
          sizeBytes: 100,
          sha256: '0' * 64,
          kind: UserAttachmentKind.image,
          agentLocalReference: 'ref-missing',
          mediaId: 'media-missing',
        );

        final history = [
          Message(
            role: MessageRole.user,
            content: 'Look at missing image',
            attachments: [missingAttachment],
          ),
        ];

        final opts = LLMRequestOptions(
          sessionId: 'test-session',
          attachmentStore: attachmentStore,
        );

        expect(
          () => ToolResultWireCodec.loadVerifiedUserAttachments(
            history,
            attachmentStore: opts.attachmentStore,
          ),
          throwsA(isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('Failed to verify user image attachment'),
          )),
        );
      },
    );
  });
}
