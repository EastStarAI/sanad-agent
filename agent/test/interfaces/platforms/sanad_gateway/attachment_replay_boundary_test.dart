import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:get_it/get_it.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sanad_agent/capabilities/models/tool_schema.dart';
import 'package:sanad_agent/capabilities/registry/tools_registry.dart';
import 'package:sanad_agent/capabilities/runtime/local_runtime_catalog.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/models/agent_response.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/models/user_attachment.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/core/provider_runtime/provider_protocol_constants.dart';
import 'package:sanad_agent/core/provider_runtime/provider_rate_limiter.dart';
import 'package:sanad_agent/core/provider_runtime/route_capability_resolver.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_notice.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_recovery_service.dart';
import 'package:sanad_agent/core/sanad_home/sanad_home_bootstrap.dart';
import 'package:sanad_agent/engine/adapters/base_openai_adapter.dart';
import 'package:sanad_agent/engine/adapters/llm_adapter.dart';
import 'package:sanad_agent/engine/adapters/llm_request_options.dart';
import 'package:sanad_agent/engine/adapters/models_dev_service.dart';
import 'package:sanad_agent/engine/adapters/provider_registry.dart';
import 'package:sanad_agent/engine/agent_runner.dart';
import 'package:sanad_agent/evolution/attachments/attachment_store.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/compaction_boundary_repository.dart';
import 'package:sanad_agent/evolution/db/persisted_runtime_state_repository.dart';
import 'package:sanad_agent/evolution/db/session_history_revision_repository.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/interfaces/models/agent_turn_request.dart';
import 'package:sanad_agent/interfaces/models/gateway_event.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/capabilities.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/handlers/session_turn_replay_command_handler.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/sanad_protocol_bridge.dart';
import 'package:sanad_agent/interfaces/runtime/local_runtime_orchestrator.dart';
import 'package:sanad_agent/interfaces/runtime/local_workspace_runtime_service.dart';
import 'package:sanad_agent/interfaces/runtime/session_run_orchestrator.dart';
import 'package:sanad_agent/interfaces/runtime/session_turn_executor.dart';
import 'package:test/test.dart';

void main() {
  const validPngBytes = [
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
    0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  ];
  const validJpegBytes = [
    0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46,
    0x49, 0x46, 0x00, 0x01, 0x01, 0x01, 0x00, 0x48,
  ];

  late AgentStateDatabase state;
  late SessionManager sessions;
  late PersistedRuntimeStateRepository runtime;
  late CompactionBoundaryRepository compactionBoundaries;
  late AttachmentStore attachmentStore;
  late Directory tempHomeDir;
  late Config config;
  late ProviderInstanceRepository providerRepo;
  late ModelsDevService modelsDev;
  late RouteCapabilityResolver routeResolver;
  late _TestOrchestrator orchestrator;
  late SessionTurnReplayCommandHandler handler;
  late LocalRuntimeCatalog runtimeCatalog;
  late RuntimeRecoveryService recoveryService;
  late String sessionId;

  setUp(() async {
    await GetIt.I.reset();
    SessionManager.resetForTesting();
    state = AgentStateDatabase.inMemory();
    GetIt.I.registerSingleton<AgentStateDatabase>(state);

    sessions = SessionManager();
    GetIt.I.registerSingleton<SessionManager>(sessions);

    runtime = PersistedRuntimeStateRepository.fromState(state);
    GetIt.I.registerSingleton<PersistedRuntimeStateRepository>(runtime);

    compactionBoundaries = CompactionBoundaryRepository(
      state,
      SessionHistoryRevisionRepository(state),
    );

    tempHomeDir = Directory.systemTemp.createTempSync('replay_boundary_test_');
    final configFile = File('${tempHomeDir.path}/config.yaml');
    configFile.writeAsStringSync('model_capabilities: {}\n');
    config = Config(environment: {'SANAD_HOME': tempHomeDir.path});
    // The runtime boundary resolves its root from the process-level Sanad home,
    // so the harness redirects and prepares an isolated root instead of relying
    // on a developer machine's already prepared home.
    setSanadHomeOverride(tempHomeDir.path);
    await SanadHomeBootstrap.identity().prepare();
    GetIt.I.registerSingleton<Config>(config);

    providerRepo = ProviderInstanceRepository(state);
    GetIt.I.registerSingleton<ProviderInstanceRepository>(providerRepo);

    final now = DateTime.now();
    final customProvider = ProviderInstance(
      id: 'prov-haiku-relay-1',
      templateId: kCustomProviderTemplateId,
      displayName: 'Custom Haiku Relay',
      protocol: ProviderProtocol.openaiCompatible,
      authMethod: ProviderAuthMethod.apiKey,
      baseUrl: 'http://127.0.0.1:8088/v1',
      createdAt: now,
      updatedAt: now,
    ).copyWith(configRevision: 1, credentialRevision: 1);
    providerRepo.createInstance(customProvider);

    final catalogCacheFile = File('${tempHomeDir.path}/mdev_cache.json');
    modelsDev = ModelsDevService(
      cacheFilePathOverride: catalogCacheFile.path,
      client: MockClient((request) async {
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
    GetIt.I.registerSingleton<ModelsDevService>(modelsDev);

    routeResolver = RouteCapabilityResolver(
      instances: providerRepo,
      config: config,
      modelsDevService: modelsDev,
    );
    GetIt.I.registerSingleton<RouteCapabilityResolver>(routeResolver);

    attachmentStore = AttachmentStore(state, stateHome: tempHomeDir.path);
    await attachmentStore.initialize();
    GetIt.I.registerSingleton<AttachmentStore>(attachmentStore);

    final limiter = ProviderRateLimiter();
    recoveryService = RuntimeRecoveryService(providerRepo, limiter);
    recoveryService.attachPersistedState(runtime);
    GetIt.I.registerSingleton<RuntimeRecoveryService>(recoveryService);

    final workspaceRuntimeService = LocalWorkspaceRuntimeService();
    GetIt.I.registerSingleton<LocalWorkspaceRuntimeService>(workspaceRuntimeService);

    runtimeCatalog = LocalRuntimeCatalog(
      workspaceRuntimeService: workspaceRuntimeService,
    );
    GetIt.I.registerSingleton<LocalRuntimeCatalog>(runtimeCatalog);

    GetIt.I.registerSingleton<LocalRuntimeOrchestrator>(
      LocalRuntimeOrchestrator(
        workspaceRuntimeService,
        runtimeCatalog,
      ),
    );

    orchestrator = _TestOrchestrator();
    GetIt.I.registerSingleton<SessionRunOrchestrator>(orchestrator);

    handler = SessionTurnReplayCommandHandler(
      orchestrator: orchestrator,
      sessionManager: sessions,
      persistedState: runtime,
      compactionBoundaries: compactionBoundaries,
      bridge: _TestEnvelopeBridge(),
      attachmentStore: attachmentStore,
      idleWaitTimeout: const Duration(milliseconds: 100),
      idlePollInterval: const Duration(milliseconds: 10),
    );

    sessionId = sessions.createSession('claude-haiku-4.5', providerId: 'prov-haiku-relay-1').sessionId;
  });

  tearDown(() async {
    setSanadHomeOverride(null);
    if (tempHomeDir.existsSync()) {
      tempHomeDir.deleteSync(recursive: true);
    }
    SessionManager.resetForTesting();
    await GetIt.I.reset();
  });

  Future<UserAttachment> stageAndCommitAttachment({
    required String sessionId,
    required String admissionId,
    required String name,
    required List<int> bytes,
  }) async {
    final sha = sha256.convert(bytes).toString();
    final upload = await attachmentStore.create(
      fileName: name,
      expectedSize: bytes.length,
      expectedSha256: sha,
    );
    await attachmentStore.write(upload, bytes);
    return await attachmentStore.commit(
      upload,
      sessionId: sessionId,
      admissionId: admissionId,
    );
  }

  CanonicalEvent replayCommand({
    required String requestId,
    required String targetRequestId,
    String? targetMessageId,
    String? targetTurnId,
    Object? expectedHistoryRevision,
    String action = 'edit',
    String? message,
    List<Map<String, dynamic>>? attachmentEdits,
  }) {
    return CanonicalEvent(
      type: CanonicalEventTypes.sessionTurnReplay,
      sessionId: sessionId,
      payload: {
        'session_id': sessionId,
        'request_id': requestId,
        'target_request_id': targetRequestId,
        'target_message_id': ?targetMessageId,
        'target_turn_id': ?targetTurnId,
        'expected_history_revision':
            expectedHistoryRevision ??
            sessions.getSession(sessionId)?.historyRevision,
        'action': action,
        'message': ?message,
        'attachment_edits': ?attachmentEdits,
        'confirmed_replay_unsafe': false,
        'confirmed_drop_steers': false,
      },
    );
  }

  test(
    'production boundary: stage -> admit -> replay edit with retained PNG/JPEG -> buildTools -> AgentRunner verification',
    () async {
      // 1. Stage original PNG and JPEG attachments
      final origPng = await stageAndCommitAttachment(
        sessionId: sessionId,
        admissionId: 'req-orig-1',
        name: 'sample.png',
        bytes: validPngBytes,
      );
      final origJpeg = await stageAndCommitAttachment(
        sessionId: sessionId,
        admissionId: 'req-orig-1',
        name: 'sample.jpg',
        bytes: validJpegBytes,
      );

      // 2. Normal admission into initial message history
      final admittedList = <UserAttachment>[];
      attachmentStore.claimAdmissionAndPersist(
        sessionId: sessionId,
        admissionId: 'req-orig-1',
        attachmentIds: [origPng.id, origJpeg.id],
        persist: (transaction, admitted) {
          admittedList.addAll(admitted);
          final userMsg = Message(
            role: MessageRole.user,
            content: 'Original prompt with photos',
            attachments: admitted,
            metadata: {
              'request_id': 'req-orig-1',
              'message_id': 'msg-orig-1',
              'turn_id': 'turn-orig-1',
              'input_kind': 'root_turn',
              'history_status': 'active',
            },
          );
          final assistantMsg = Message(
            role: MessageRole.assistant,
            content: 'Original answer',
            metadata: {
              'request_id': 'req-orig-1',
              'message_id': 'msg-asst-1',
              'turn_id': 'turn-orig-1',
              'history_status': 'active',
            },
          );
          return sessions.saveSessionHistoryInTransaction(
            sessionId,
            [userMsg, assistantMsg],
            transaction,
          );
        },
      );

      // Verify initial state
      final initialMessages = sessions.getMessages(sessionId);
      expect(initialMessages, hasLength(2));
      expect(initialMessages.first.attachments, hasLength(2));

      // 3. Prepare + commit edit with retained attachments
      final envelopes = <Map<String, dynamic>>[];
      await handler.handle(
        replayCommand(
          requestId: 'cmd-edit-1',
          targetRequestId: 'req-orig-1',
          targetMessageId: 'msg-orig-1',
          targetTurnId: 'turn-orig-1',
          action: 'edit',
          message: 'Updated edit prompt retaining both photos',
          // Omitted attachment_edits means retain all original attachments
        ),
        (envelope) async => envelopes.add(envelope),
      );

      // Outcome is accepted
      expect(envelopes, hasLength(1));
      expect(envelopes.single['payload']['outcome'], 'accepted');
      final replacementMsgId =
          envelopes.single['payload']['replacement_message_id'] as String;
      expect(replacementMsgId, isNotEmpty);

      // 4. Verify message history: exactly 1 active replacement message, original superseded
      final currentActive = sessions.getMessages(sessionId);
      expect(currentActive, hasLength(1));
      final replacementMsg = currentActive.single;
      expect(replacementMsg.role, MessageRole.user);
      expect(replacementMsg.content, 'Updated edit prompt retaining both photos');
      expect(replacementMsg.metadata?['request_id'], 'cmd-edit-1');
      expect(replacementMsg.metadata?['message_id'], replacementMsgId);
      expect(replacementMsg.attachments, hasLength(2));

      // Verify user_attachments has status 'attached' and message_id updated
      final replayedPng = replacementMsg.attachments.firstWhere(
        (a) => a.safeName == 'sample.png',
      );
      final replayedJpeg = replacementMsg.attachments.firstWhere(
        (a) => a.safeName == 'sample.jpg',
      );
      final attRows = state.db.select(
        'SELECT attachment_id, status, message_id FROM user_attachments WHERE admission_id = ?',
        ['cmd-edit-1'],
      );
      expect(attRows, hasLength(2));
      for (final row in attRows) {
        expect(row['status'], 'attached');
        expect(row['message_id'], replacementMsgId);
      }

      // 5. REAL queued executor boundary: LocalRuntimeCatalog.buildTools resolves paths
      final resolvedTools = await runtimeCatalog.buildTools(
        registry: ToolsRegistry(),
        request: AgentTurnRequest(
          sessionId: sessionId,
          requestId: 'cmd-edit-1',
          message: replacementMsg.content ?? '',
        ),
        pendingAttachmentIds: [replayedPng.id, replayedJpeg.id],
      );
      expect(resolvedTools, isNotEmpty);

      // Verify files resolved through AttachmentStore exist on disk
      final diskPaths = await attachmentStore.resolveAdmissionPaths(
        sessionId: sessionId,
        admissionId: 'cmd-edit-1',
        attachmentIds: [replayedPng.id, replayedJpeg.id],
      );
      expect(diskPaths, hasLength(2));
      for (final p in diskPaths) {
        expect(File(p).existsSync(), isTrue);
      }

      // 6. Verify AgentRunner attachment verification & exact pixels
      final verifiedPngBytes = await attachmentStore.readVerifiedAttachment(replayedPng);
      final verifiedJpegBytes = await attachmentStore.readVerifiedAttachment(replayedJpeg);
      expect(verifiedPngBytes, equals(validPngBytes));
      expect(verifiedJpegBytes, equals(validJpegBytes));
      expect(replayedPng.mimeType, 'image/png');
      expect(replayedJpeg.mimeType, 'image/jpeg');

      // 7. Verify replay handler emitted exactly 1 GatewayEvent to orchestrator
      expect(orchestrator.dispatchedEvents, hasLength(1));
      final dispatched = orchestrator.dispatchedEvents.single;
      expect(dispatched.sessionId, sessionId);
      expect(dispatched.message.attachments, hasLength(2));
      expect(
        (dispatched.turnRequest!.metadata['attachment_ids'] as List),
        containsAll([replayedPng.id, replayedJpeg.id]),
      );

      // 8. REAL EXECUTION: Enqueue work item and run through SessionTurnExecutor -> production AgentRunner -> BaseOpenAIAdapter -> injected MockClient
      runtime.workItems.enqueueWorkItem(
        workItemId: 'work-replay-1',
        sessionId: sessionId,
        requestId: 'cmd-edit-1',
        state: SessionWorkState.running,
        providerInstanceId: 'prov-haiku-relay-1',
        payload: {'message': replacementMsg.content},
      );

      final outgoingRequests = <Map<String, dynamic>>[];
      final adapter = BaseOpenAIAdapter(
        config,
        ProviderRegistry.findByNameOrAlias(kCustomProviderTemplateId)!,
        providerInstanceId: 'prov-haiku-relay-1',
        defaultModelOverride: 'claude-haiku-4.5',
        apiKeyOverride: 'test-api-key',
        baseUrlOverride: 'http://127.0.0.1:8088/v1',
        modelsDevService: modelsDev,
        requestClientFactory: () => MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          outgoingRequests.add(body);
          if (body['stream'] == true) {
            return http.Response(
              'data: {"choices":[{"delta":{"content":"Replay response received"},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n',
              200,
              headers: {'content-type': 'text/event-stream'},
            );
          }
          return http.Response(
            '{"choices":[{"message":{"role":"assistant","content":"Replay response received"},"finish_reason":"stop"}]}',
            200,
          );
        }),
      );

      final runner = AgentRunner(
        adapter,
        ToolsRegistry(),
        sessions,
        existingSessionId: sessionId,
        attachmentStore: attachmentStore,
      );

      final emittedResponses = <GatewayResponse>[];
      final executor = SessionTurnExecutor(
        emitResponse: (response) => emittedResponses.add(response),
        getPersistedState: () => runtime,
      );

      await executor.runTurn(
        event: dispatched,
        turnRequest: dispatched.turnRequest!,
        agentRunner: runner,
        workItemId: 'work-replay-1',
        onRecoveryRequired: (evt, req, r, wid) {},
        onTurnComplete: () async {},
      );

      // 9. Assert exact wire serialization and single dispatch
      expect(outgoingRequests, hasLength(1), reason: 'Exactly one outgoing HTTP request dispatched');
      final requestBody = outgoingRequests.single;
      expect(requestBody['model'], 'claude-haiku-4.5', reason: 'Wire request preserves exact model identity');

      final wireMessages = requestBody['messages'] as List<dynamic>;
      final emittedUserMsg = wireMessages.firstWhere(
        (m) =>
            m['role'] == 'user' &&
            m['content'] is List &&
            (m['content'] as List).any(
              (p) => p['type'] == 'text' && p['text'] == 'Updated edit prompt retaining both photos',
            ),
      );
      final userParts = emittedUserMsg['content'] as List<dynamic>;

      // Assert PNG part: exact data URL prefix, MIME, and decoded byte equality
      final pngPart = userParts.firstWhere(
        (p) =>
            p['type'] == 'image_url' &&
            p['image_url']?['url'] != null &&
            (p['image_url']['url'] as String).startsWith('data:image/png;base64,'),
      );
      final pngDataUrl = pngPart['image_url']['url'] as String;
      final pngBase64 = pngDataUrl.substring('data:image/png;base64,'.length);
      expect(base64Decode(pngBase64), equals(validPngBytes));

      // Assert JPEG part: exact data URL prefix, MIME, and decoded byte equality
      final jpegPart = userParts.firstWhere(
        (p) =>
            p['type'] == 'image_url' &&
            p['image_url']?['url'] != null &&
            (p['image_url']['url'] as String).startsWith('data:image/jpeg;base64,'),
      );
      final jpegDataUrl = jpegPart['image_url']['url'] as String;
      final jpegBase64 = jpegDataUrl.substring('data:image/jpeg;base64,'.length);
      expect(base64Decode(jpegBase64), equals(validJpegBytes));

      // 10. Assert work item completed cleanly in persisted state
      final completedItem = runtime.findWorkItem('work-replay-1');
      expect(completedItem?.state, SessionWorkState.completed);

      // 11. Assert original files on disk were preserved and unmodified
      for (final p in diskPaths) {
        expect(File(p).existsSync(), isTrue);
      }
      expect(File(diskPaths[0]).readAsBytesSync(), equals(validPngBytes));
      expect(File(diskPaths[1]).readAsBytesSync(), equals(validJpegBytes));
    },
  );

  test(
    'production boundary: replay retry retains attachments through same execution boundary',
    () async {
      final orig = await stageAndCommitAttachment(
        sessionId: sessionId,
        admissionId: 'req-orig-2',
        name: 'sample.png',
        bytes: validPngBytes,
      );

      attachmentStore.claimAdmissionAndPersist(
        sessionId: sessionId,
        admissionId: 'req-orig-2',
        attachmentIds: [orig.id],
        persist: (transaction, admitted) {
          final userMsg = Message(
            role: MessageRole.user,
            content: 'Original prompt',
            attachments: admitted,
            metadata: {
              'request_id': 'req-orig-2',
              'message_id': 'msg-orig-2',
              'turn_id': 'turn-orig-2',
              'input_kind': 'root_turn',
              'history_status': 'active',
            },
          );
          return sessions.saveSessionHistoryInTransaction(
            sessionId,
            [userMsg],
            transaction,
          );
        },
      );

      final envelopes = <Map<String, dynamic>>[];
      await handler.handle(
        replayCommand(
          requestId: 'cmd-retry-2',
          targetRequestId: 'req-orig-2',
          targetMessageId: 'msg-orig-2',
          targetTurnId: 'turn-orig-2',
          action: 'retry',
        ),
        (envelope) async => envelopes.add(envelope),
      );

      expect(envelopes.single['payload']['outcome'], 'accepted');
      final active = sessions.getMessages(sessionId);
      expect(active, hasLength(1));
      expect(active.single.attachments, hasLength(1));

      final replayedId = active.single.attachments.single.id;
      final paths = await attachmentStore.resolveAdmissionPaths(
        sessionId: sessionId,
        admissionId: 'cmd-retry-2',
        attachmentIds: [replayedId],
      );
      expect(paths, hasLength(1));
      expect(File(paths.single).existsSync(), isTrue);

      // Verify orchestrator received exactly 1 retry event
      expect(orchestrator.dispatchedEvents, hasLength(1));
      final retryDispatched = orchestrator.dispatchedEvents.single;
      expect(retryDispatched.sessionId, sessionId);
      expect(retryDispatched.message.attachments, hasLength(1));

      // REAL EXECUTION: Enqueue work item and run through SessionTurnExecutor -> production AgentRunner -> BaseOpenAIAdapter -> MockClient
      runtime.workItems.enqueueWorkItem(
        workItemId: 'work-retry-2',
        sessionId: sessionId,
        requestId: 'cmd-retry-2',
        state: SessionWorkState.running,
        providerInstanceId: 'prov-haiku-relay-1',
        payload: {'message': active.single.content},
      );

      final retryOutgoing = <Map<String, dynamic>>[];
      final retryAdapter = BaseOpenAIAdapter(
        config,
        ProviderRegistry.findByNameOrAlias(kCustomProviderTemplateId)!,
        providerInstanceId: 'prov-haiku-relay-1',
        defaultModelOverride: 'claude-haiku-4.5',
        apiKeyOverride: 'test-api-key',
        baseUrlOverride: 'http://127.0.0.1:8088/v1',
        modelsDevService: modelsDev,
        requestClientFactory: () => MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          retryOutgoing.add(body);
          return http.Response(
            'data: {"choices":[{"delta":{"content":"Retry response received"},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n',
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        }),
      );

      final retryRunner = AgentRunner(
        retryAdapter,
        ToolsRegistry(),
        sessions,
        existingSessionId: sessionId,
        attachmentStore: attachmentStore,
      );

      final retryExecutor = SessionTurnExecutor(
        emitResponse: (_) {},
        getPersistedState: () => runtime,
      );

      await retryExecutor.runTurn(
        event: retryDispatched,
        turnRequest: retryDispatched.turnRequest!,
        agentRunner: retryRunner,
        workItemId: 'work-retry-2',
        onRecoveryRequired: (evt, req, r, wid) {},
        onTurnComplete: () async {},
      );

      // Assert single dispatch and wire serialization
      expect(retryOutgoing, hasLength(1), reason: 'Exactly one retry HTTP request dispatched');
      final retryBody = retryOutgoing.single;
      expect(retryBody['model'], 'claude-haiku-4.5');
      final retryWireMessages = retryBody['messages'] as List<dynamic>;
      final retryUserMsg = retryWireMessages.firstWhere((m) => m['role'] == 'user');
      final retryParts = retryUserMsg['content'] as List<dynamic>;
      final retryImg = retryParts.firstWhere((p) => p['type'] == 'image_url');
      final retryUrl = retryImg['image_url']['url'] as String;
      expect(retryUrl.startsWith('data:image/png;base64,'), isTrue);
      expect(base64Decode(retryUrl.substring('data:image/png;base64,'.length)), equals(validPngBytes));

      expect(runtime.findWorkItem('work-retry-2')?.state, SessionWorkState.completed);
      expect(File(paths.single).existsSync(), isTrue);
      expect(File(paths.single).readAsBytesSync(), equals(validPngBytes));
    },
  );

  test('early known failure retains editing/draft/source and does not autosubmit', () async {
    final orig = await stageAndCommitAttachment(
      sessionId: sessionId,
      admissionId: 'req-orig-3',
      name: 'sample.png',
      bytes: validPngBytes,
    );

    attachmentStore.claimAdmissionAndPersist(
      sessionId: sessionId,
      admissionId: 'req-orig-3',
      attachmentIds: [orig.id],
      persist: (transaction, admitted) {
        final userMsg = Message(
          role: MessageRole.user,
          content: 'Keep me intact',
          attachments: admitted,
          metadata: {
            'request_id': 'req-orig-3',
            'message_id': 'msg-orig-3',
            'turn_id': 'turn-orig-3',
            'input_kind': 'root_turn',
            'history_status': 'active',
          },
        );
        return sessions.saveSessionHistoryInTransaction(
          sessionId,
          [userMsg],
          transaction,
        );
      },
    );

    final envelopes = <Map<String, dynamic>>[];
    await handler.handle(
      replayCommand(
        requestId: 'cmd-fail-3',
        targetRequestId: 'req-orig-3',
        targetMessageId: 'msg-orig-3',
        targetTurnId: 'turn-orig-3',
        action: 'edit',
        message: 'New text with bad upload',
        attachmentEdits: [
          {
            'name': 'corrupted.png',
            'size_bytes': 100,
            'sha256': '0000000000000000000000000000000000000000000000000000000000000000',
            'data_base64': base64Encode([1, 2, 3]), // size mismatch
          },
        ],
      ),
      (envelope) async => envelopes.add(envelope),
    );

    expect(envelopes.single['payload']['outcome'], 'attachment_admission_failed');
    // Original message and attachments completely preserved
    final active = sessions.getMessages(sessionId);
    expect(active, hasLength(1));
    expect(active.single.content, 'Keep me intact');
    expect(active.single.metadata?['request_id'], 'req-orig-3');
    expect(active.single.attachments, hasLength(1));
    expect(active.single.attachments.single.id, orig.id);
  });

  test('early turn failure notifies RuntimeRecoveryService and blocks work item', () async {
    // Register active work item in running state
    runtime.workItems.enqueueWorkItem(
      workItemId: 'work-fail-4',
      sessionId: sessionId,
      requestId: 'req-fail-4',
      state: SessionWorkState.running,
      providerInstanceId: 'prov-test',
      payload: const {'message': 'test'},
    );

    final executor = SessionTurnExecutor(
      emitResponse: (_) {},
      getPersistedState: () => runtime,
    );

    final event = GatewayEvent(
      sessionId: sessionId,
      platformId: 'sanad_client',
      message: Message(role: MessageRole.user, content: 'test'),
      metadata: const {},
    );

    final turnRequest = AgentTurnRequest(
      sessionId: sessionId,
      requestId: 'req-fail-4',
      message: 'test',
    );

    // AgentRunner with throwing adapter to simulate unhandled turn failure
    final failingRunner = AgentRunner(
      _ThrowingLLMAdapter(),
      ToolsRegistry(),
      sessions,
      existingSessionId: sessionId,
    );

    await executor.runTurn(
      event: event,
      turnRequest: turnRequest,
      agentRunner: failingRunner,
      workItemId: 'work-fail-4',
      onRecoveryRequired: (evt, req, runner, wid) {},
      onTurnComplete: () async {},
    );

    // Assert work item transitioned to blocked
    final item = runtime.findWorkItem('work-fail-4');
    expect(item, isNotNull);
    expect(item!.state, SessionWorkState.blocked);

    // Assert failure was reported to RuntimeRecoveryService and notice persisted
    expect(recoveryService.hasActiveNotice(sessionId), isTrue);
    final notice = recoveryService.activeNotice(sessionId);
    expect(notice?.status, RuntimeNoticeStatus.blocked);
    expect(notice?.requestId, 'req-fail-4');

    // Verify written through to SQLite table session_runtime_notices
    final dbRows = state.db.select(
      'SELECT * FROM session_runtime_notices WHERE session_id = ?',
      [sessionId],
    );
    expect(dbRows, hasLength(1));
    expect(dbRows.single['status'], 'blocked');
  });

  test('negative: cross-request, cross-session, superseded status, and wrong hash fail closed', () async {
    final att = await stageAndCommitAttachment(
      sessionId: sessionId,
      admissionId: 'req-valid',
      name: 'valid.png',
      bytes: validPngBytes,
    );

    // 1. Cross-request admission ID fails closed
    expect(
      () => attachmentStore.resolveAdmissionPaths(
        sessionId: sessionId,
        admissionId: 'req-different',
        attachmentIds: [att.id],
      ),
      throwsA(isA<AttachmentStoreException>()),
    );

    // 2. Cross-session ID fails closed
    expect(
      () => attachmentStore.resolveAdmissionPaths(
        sessionId: 'session-other',
        admissionId: 'req-valid',
        attachmentIds: [att.id],
      ),
      throwsA(isA<AttachmentStoreException>()),
    );

    // 3. Superseded message attached status fails closed
    state.db.execute(
      '''
      INSERT INTO messages (session_id, message_id, request_id, history_status, data)
      VALUES (?, 'msg-superseded', 'req-valid', 'superseded', '{"role":"user","content":"old"}')
      ''',
      [sessionId],
    );
    state.db.execute(
      "UPDATE user_attachments SET status = 'attached', message_id = 'msg-superseded' WHERE attachment_id = ?",
      [att.id],
    );

    expect(
      () => attachmentStore.resolveAdmissionPaths(
        sessionId: sessionId,
        admissionId: 'req-valid',
        attachmentIds: [att.id],
      ),
      throwsA(isA<AttachmentStoreException>()),
    );

    // 4. Corrupted hash fails read verification
    final resolvedPath = await attachmentStore.resolvePath(
      sessionId: sessionId,
      attachmentId: att.id,
    );
    // Overwrite file with wrong bytes
    File(resolvedPath).writeAsBytesSync([0x00, 0x00, 0x00]);
    final verified = await attachmentStore.readVerifiedAttachment(att);
    expect(verified, isNull);

    // 5. Queued execution with superseded attachment fails closed before HTTP dispatch
    runtime.workItems.enqueueWorkItem(
      workItemId: 'work-fail-5',
      sessionId: sessionId,
      requestId: 'req-valid',
      state: SessionWorkState.running,
      providerInstanceId: 'prov-haiku-relay-1',
      payload: const {'message': 'test'},
    );

    var httpDispatchedCount = 0;
    final negativeAdapter = BaseOpenAIAdapter(
      config,
      ProviderRegistry.findByNameOrAlias(kCustomProviderTemplateId)!,
      providerInstanceId: 'prov-haiku-relay-1',
      defaultModelOverride: 'claude-haiku-4.5',
      apiKeyOverride: 'test-api-key',
      baseUrlOverride: 'http://127.0.0.1:8088/v1',
      modelsDevService: modelsDev,
      client: MockClient((request) async {
        httpDispatchedCount++;
        return http.Response('{}', 200);
      }),
    );

    final negativeRunner = AgentRunner(
      negativeAdapter,
      ToolsRegistry(),
      sessions,
      existingSessionId: sessionId,
      attachmentStore: attachmentStore,
    );

    final negativeExecutor = SessionTurnExecutor(
      emitResponse: (_) {},
      getPersistedState: () => runtime,
    );

    final invalidTurnRequest = AgentTurnRequest(
      sessionId: sessionId,
      requestId: 'req-valid',
      message: 'test',
      metadata: {'attachment_ids': [att.id]}, // att is attached to superseded message!
    );

    await negativeExecutor.runTurn(
      event: GatewayEvent(
        sessionId: sessionId,
        platformId: 'sanad_client',
        message: Message(role: MessageRole.user, content: 'test'),
        metadata: const {},
      ),
      turnRequest: invalidTurnRequest,
      agentRunner: negativeRunner,
      workItemId: 'work-fail-5',
      onRecoveryRequired: (evt, req, r, wid) {},
      onTurnComplete: () async {},
    );

    expect(httpDispatchedCount, 0, reason: 'Zero HTTP requests dispatched on invalid attachment admission');
    // A failed admission is a typed terminal outcome, not a blocked owner
    // that would hold the session queue with no resumable checkpoint
    // (Task 125).
    expect(
      runtime.findWorkItem('work-fail-5')?.state,
      SessionWorkState.cancelled,
    );
  });
}

class _TestEnvelopeBridge extends SanadProtocolBridge {
  @override
  Map<String, dynamic> buildAgentEventEnvelope(CanonicalEvent canonicalEvent) {
    return {
      'event': canonicalEvent.type,
      'payload': canonicalEvent.payload,
      'session_id': canonicalEvent.sessionId,
    };
  }
}

class _TestOrchestrator extends SessionRunOrchestrator {
  final dispatchedEvents = <GatewayEvent>[];

  @override
  Future<void> handleEvent(GatewayEvent event) async {
    dispatchedEvents.add(event);
  }

  @override
  Future<void> requestStop(
    String sessionId, {
    bool forceEmitStopped = false,
    String? stopRequestId,
    String? recoveryOwnerToken,
    bool preserveInteractiveWait = false,
  }) async {}
}

class _ThrowingLLMAdapter implements LLMAdapter {
  @override
  Future<int> getContextLimit([String? modelOverride]) async => 4096;

  @override
  Future<List<ModelOption>> getAvailableModels() async => [
    ModelOption(value: 'claude-haiku-4.5', label: 'Claude Haiku 4.5', provider: 'test'),
  ];

  @override
  Future<AgentResponse> generateResponse(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async {
    throw StateError('Simulated early failure in turn execution');
  }

  @override
  Stream<AgentResponse> generateStream(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) {
    throw StateError('Simulated early failure in turn execution');
  }
}
