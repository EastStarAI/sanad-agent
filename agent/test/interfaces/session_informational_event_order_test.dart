import 'dart:io';

import 'package:sanad_agent/capabilities/mcp/mcp_runtime_manager.dart';
import 'package:sanad_agent/capabilities/runtime/local_runtime_catalog.dart';
import 'package:sanad_agent/core/auth/auth_manager.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/models/tool_call.dart';
import 'package:sanad_agent/core/provider_runtime/env_file_service.dart';
import 'package:sanad_agent/core/provider_runtime/model_options_service.dart';
import 'package:sanad_agent/core/provider_runtime/model_selection_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_auth_session_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_catalog_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_config_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_credential_resolver.dart';
import 'package:sanad_agent/core/provider_runtime/provider_credential_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_credential_store.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_model_cache_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_rate_limiter.dart';
import 'package:sanad_agent/core/provider_runtime/provider_readiness_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_state_service.dart';
import 'package:sanad_agent/core/provider_runtime/recent_model_selection_service.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_recovery_service.dart';
import 'package:sanad_agent/core/provider_runtime/secret_store.dart';
import 'package:sanad_agent/core/provider_runtime/secure_file_secret_store.dart';
import 'package:sanad_agent/core/provider_thinking/provider_thinking_di.dart';
import 'package:sanad_agent/core/agent_runtime_service.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/runtime/session_route_transition_repository.dart';
import 'package:sanad_agent/evolution/models/session_route_transition.dart';
import 'package:sanad_agent/evolution/models/session_state.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/sanad_protocol_bridge.dart';
import 'package:sanad_agent/interfaces/runtime/local_workspace_runtime_service.dart';
import 'package:test/test.dart';

class _NoopMcpRuntimeManager implements McpRuntimeManager {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory tempDir;
  late EnvFileService env;

  setUp(() async {
    getIt.allowReassignment = true;
    tempDir = await Directory.systemTemp.createTemp('sanad-info-order-test');
    setSanadHomeOverride(tempDir.path);
    SessionManager.resetForTesting();
    getIt.registerSingleton<AuthManager>(AuthManager());
    getIt.registerSingleton<SessionManager>(SessionManager());
    getIt.registerSingleton<LocalWorkspaceRuntimeService>(
      LocalWorkspaceRuntimeService(
        sanadHomePath: tempDir.path,
        currentWorkingDirectory: tempDir.path,
      ),
    );
    getIt.registerSingleton<LocalRuntimeCatalog>(
      LocalRuntimeCatalog(
        workspaceRuntimeService: getIt<LocalWorkspaceRuntimeService>(),
        mcpRuntimeManager: _NoopMcpRuntimeManager(),
      ),
    );

    env = EnvFileService(envPath: '${tempDir.path}/.env');
    final credStore = ProviderCredentialStore(
      storePath: '${tempDir.path}/provider_auth.json',
    );
    getIt.registerSingleton<EnvFileService>(env);
    getIt.registerSingleton<ProviderCredentialStore>(credStore);
    getIt.registerSingleton<ProviderCatalogService>(ProviderCatalogService());
    getIt.registerSingleton<ProviderStateService>(
      ProviderStateService(env, credStore),
    );
    getIt.registerSingleton<ProviderCredentialResolver>(
      ProviderCredentialResolver(env, credStore),
    );
    getIt.registerSingleton<ProviderAuthSessionService>(
      ProviderAuthSessionService(credStore),
    );
    getIt.registerSingleton<ProviderConfigService>(
      ProviderConfigService(env, credStore),
    );
    getIt.registerSingleton<ModelOptionsService>(
      ModelOptionsService(env, getIt<ProviderCredentialResolver>()),
    );
    getIt.registerSingleton<ModelSelectionService>(ModelSelectionService(env));

    final db = AgentStateDatabase.inMemory();
    final repo = ProviderInstanceRepository.fromDatabase(db.db);
    final secretStore = SecureFileSecretStore();
    final credService = ProviderCredentialService(repo, secretStore);
    final instanceService = ProviderInstanceService(repo);
    final configObj = Config();

    getIt.registerSingleton<AgentStateDatabase>(db);
    getIt.registerSingleton<ProviderInstanceRepository>(repo);
    getIt.registerSingleton<SecretStore>(secretStore);
    getIt.registerSingleton<ProviderCredentialService>(credService);
    getIt.registerSingleton<ProviderInstanceService>(instanceService);
    getIt.registerSingleton<Config>(configObj);

    getIt.registerSingleton<ProviderReadinessService>(
      ProviderReadinessService(
        getIt<ProviderInstanceRepository>(),
        getIt<SecretStore>(),
      ),
    );

    final runtimeService = AgentRuntimeService(
      configObj,
      repo,
      credentialResolver: getIt<ProviderCredentialResolver>(),
      credService: credService,
    );
    getIt.registerSingleton<AgentRuntimeService>(runtimeService);

    final cacheService = ProviderModelCacheService(
      repo,
      runtimeService,
      buildDefaultThinkingCapabilityAssembler(),
    );
    getIt.registerSingleton<ProviderModelCacheService>(cacheService);
    final recentService = RecentModelSelectionService(repo);
    getIt.registerSingleton<RecentModelSelectionService>(recentService);
    getIt.registerSingleton<ProviderRateLimiter>(ProviderRateLimiter());
    getIt.registerSingleton<RuntimeRecoveryService>(
      RuntimeRecoveryService(
        getIt<ProviderInstanceRepository>(),
        getIt<ProviderRateLimiter>(),
      ),
    );
    getIt.registerSingleton<SessionRouteTransitionRepository>(
      SessionRouteTransitionRepository(db),
    );
    getIt.registerSingleton<SanadProtocolBridge>(SanadProtocolBridge());
  });

  tearDown(() async {
    SessionManager.resetForTesting();
    setSanadHomeOverride(null);
    try {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    } catch (_) {}
    getIt.reset();
  });

  group('Gate A — Fork event ordering reproduction', () {
    test(
      'fork event must be causally anchored right after forkedFromMessageId, not appended to the tail of child history',
      () async {
        final sessionManager = getIt<SessionManager>();
        final bridge = getIt<SanadProtocolBridge>();

        const parentSessionId = 'session-parent-1';
        const childSessionId = 'session-child-1';

        // 1. Create parent session with 2 messages
        sessionManager.db.saveSession(
          SessionState(
            sessionId: parentSessionId,
            model: 'test-model',
            createdAt: DateTime.parse('2026-10-15T01:00:00Z'),
            updatedAt: DateTime.parse('2026-10-15T01:05:00Z'),
          ),
        );

        // 2. Create child forked session
        sessionManager.db.saveSession(
          SessionState(
            sessionId: childSessionId,
            model: 'test-model',
            createdAt: DateTime.parse('2026-10-15T01:06:00Z'),
            updatedAt: DateTime.parse('2026-10-15T01:10:00Z'),
            parentSessionId: parentSessionId,
            lineageId: 'lineage-1',
            forkSequence: 1,
            forkedFromMessageId: 'parent-msg-2',
            forkedFromTurnId: 'turn-1',
          ),
        );

        // Child session has:
        // - cloned prefix messages: parent-msg-1, parent-msg-2
        // - new subsequent messages: child-msg-3, child-msg-4
        sessionManager.saveSessionHistory(childSessionId, [
          Message(
            role: MessageRole.user,
            content: 'Parent request',
            metadata: {'message_id': 'parent-msg-1'},
          ),
          Message(
            role: MessageRole.assistant,
            content: 'Parent final answer',
            metadata: {'message_id': 'parent-msg-2'},
          ),
          Message(
            role: MessageRole.user,
            content: 'Subsequent user question in forked session',
            metadata: {'message_id': 'child-msg-3'},
          ),
          Message(
            role: MessageRole.assistant,
            content: 'Subsequent assistant answer in forked session',
            metadata: {'message_id': 'child-msg-4'},
          ),
        ]);

        final historyEnvelopes = <Map<String, dynamic>>[];
        await bridge.handleProtocolEvent(
          CanonicalEvent(
            type: CanonicalEventTypes.getSessionHistory,
            sessionId: childSessionId,
            payload: const {'request_id': 'req-check-fork-order'},
          ),
          (envelope) async => historyEnvelopes.add(envelope),
        );

        expect(historyEnvelopes, hasLength(1));
        final messages = (historyEnvelopes.single['payload']['messages'] as List)
            .cast<Map<String, dynamic>>();

        final messageTypes = messages.map((m) => m['type']).toList();

        // The fork event MUST appear between parent-msg-2 and child-msg-3
        final forkIndex = messageTypes.indexOf(CanonicalEventTypes.sessionForked);
        expect(forkIndex, isNot(-1), reason: 'session.forked event must be present in history');

        final forkEvent = messages[forkIndex];
        expect(forkEvent['metadata']['forked_from_message_id'], 'parent-msg-2');

        // CAUSAL ORDER: fork marker must appear right after the forked message (index 2), NOT after child messages!
        // In current bug, forkIndex is 4 (the last item after child-msg-3 and child-msg-4).
        expect(
          forkIndex,
          2,
          reason: 'Fork marker must be anchored at index 2 (right after parent-msg-2), but was placed at index $forkIndex (tail)',
        );
      },
    );

    test(
      'fork event must not appear in history pages that do not contain the forkedFromMessageId',
      () async {
        final sessionManager = getIt<SessionManager>();
        final bridge = getIt<SanadProtocolBridge>();
        const childSessionId = 'session-child-paginated';

        sessionManager.db.saveSession(
          SessionState(
            sessionId: childSessionId,
            model: 'test-model',
            createdAt: DateTime.parse('2026-10-15T01:06:00Z'),
            updatedAt: DateTime.parse('2026-10-15T01:10:00Z'),
            parentSessionId: 'parent',
            lineageId: 'lineage-1',
            forkSequence: 1,
            forkedFromMessageId: 'parent-msg-2',
            forkedFromTurnId: 'turn-1',
          ),
        );

        // 10 messages: first 2 are prefix, next 8 are subsequent
        final allMessages = <Message>[
          Message(role: MessageRole.user, content: 'User 1', metadata: {'message_id': 'parent-msg-1'}),
          Message(role: MessageRole.assistant, content: 'Answer 2', metadata: {'message_id': 'parent-msg-2'}),
          for (var i = 3; i <= 10; i++)
            Message(role: MessageRole.user, content: 'Child $i', metadata: {'message_id': 'child-msg-$i'}),
        ];
        sessionManager.saveSessionHistory(childSessionId, allMessages);

        // Query only the tail 4 messages (child-msg-7 to child-msg-10), which does NOT contain parent-msg-2
        final historyEnvelopes = <Map<String, dynamic>>[];
        await bridge.handleProtocolEvent(
          CanonicalEvent(
            type: CanonicalEventTypes.getSessionHistory,
            sessionId: childSessionId,
            payload: const {
              'request_id': 'req-check-paginated-fork',
              'limit': 4,
            },
          ),
          (envelope) async => historyEnvelopes.add(envelope),
        );

        final messages = (historyEnvelopes.single['payload']['messages'] as List)
            .cast<Map<String, dynamic>>();

        final containsFork = messages.any((m) => m['type'] == CanonicalEventTypes.sessionForked);
        expect(
          containsFork,
          isFalse,
          reason: 'Fork marker should not be injected into a page that does not include the fork target',
        );
      },
    );
  });

  group('Gate A — Route transition ordering & source reproduction', () {
    test(
      'route transition with source: user must be preserved in history',
      () async {
        final sessionManager = getIt<SessionManager>();
        final state = getIt<AgentStateDatabase>();
        final transitions = getIt<SessionRouteTransitionRepository>();
        final bridge = getIt<SanadProtocolBridge>();
        const sessionId = 'session-user-switch';

        sessionManager.db.saveSession(
          SessionState(
            sessionId: sessionId,
            model: 'model-a',
            createdAt: DateTime.parse('2026-10-15T02:00:00Z'),
            updatedAt: DateTime.parse('2026-10-15T02:05:00Z'),
          ),
        );
        state.db.execute(
          '''
          INSERT INTO sessions (
            session_id, model, created_at, updated_at
          ) VALUES (?, ?, ?, ?)
          ''',
          [
            sessionId,
            'model-a',
            DateTime.now().toUtc().toIso8601String(),
            DateTime.now().toUtc().toIso8601String(),
          ],
        );

        sessionManager.saveSessionHistory(sessionId, [
          Message(role: MessageRole.user, content: 'Hello', metadata: {'message_id': 'msg-1'}),
          Message(role: MessageRole.assistant, content: 'Hi', metadata: {'message_id': 'msg-2'}),
        ]);

        transitions.insert(
          SessionRouteTransition(
            sessionId: sessionId,
            routeRevision: 2,
            eventId: 'trans-user-1',
            source: SessionRouteSource.user,
            previousProviderInstanceId: 'inst-1',
            providerInstanceId: 'inst-2',
            model: 'model-b',
            reason: 'user_selected',
            requestId: 'req-user-switch',
            createdAt: DateTime.parse('2026-10-15T02:02:00Z'),
          ),
        );

        final historyEnvelopes = <Map<String, dynamic>>[];
        await bridge.handleProtocolEvent(
          CanonicalEvent(
            type: CanonicalEventTypes.getSessionHistory,
            sessionId: sessionId,
            payload: const {'request_id': 'history-user-source'},
          ),
          (envelope) async => historyEnvelopes.add(envelope),
        );

        final messages = (historyEnvelopes.single['payload']['messages'] as List)
            .cast<Map<String, dynamic>>();

        final transitionRows = messages.where((m) => m['type'] == 'session_route_transition');
        expect(
          transitionRows,
          hasLength(1),
          reason: 'User-initiated route transitions must not be dropped from history',
        );
      },
    );

    test(
      'route transition during tool execution must be placed after tool_result and before final_answer',
      () async {
        final sessionManager = getIt<SessionManager>();
        final state = getIt<AgentStateDatabase>();
        final transitions = getIt<SessionRouteTransitionRepository>();
        final bridge = getIt<SanadProtocolBridge>();
        const sessionId = 'session-failover-turn';

        sessionManager.db.saveSession(
          SessionState(
            sessionId: sessionId,
            model: 'model-a',
            createdAt: DateTime.parse('2026-10-15T02:00:00Z'),
            updatedAt: DateTime.parse('2026-10-15T02:05:00Z'),
          ),
        );
        state.db.execute(
          '''
          INSERT INTO sessions (
            session_id, model, created_at, updated_at
          ) VALUES (?, ?, ?, ?)
          ''',
          [
            sessionId,
            'model-a',
            DateTime.now().toUtc().toIso8601String(),
            DateTime.now().toUtc().toIso8601String(),
          ],
        );

        // Turn messages:
        // 1. User message (requestId: req-failover-1, turnId: turn-1)
        // 2. Assistant message calling a tool (toolCalls: [toolCall(id: 'call-1', name: 'search')])
        // 3. Tool result message (toolCallId: 'call-1', isError: true)
        // 4. Assistant message with final answer (from model-b)
        sessionManager.saveSessionHistory(sessionId, [
          Message(
            role: MessageRole.user,
            content: 'Search for something',
            metadata: {
              'message_id': 'msg-user-1',
              'request_id': 'req-failover-1',
              'turn_id': 'turn-1',
            },
          ),
          Message(
            role: MessageRole.assistant,
            content: null,
            toolCalls: [
              ToolCall(
                id: 'call-1',
                name: 'search',
                arguments: {'q': 'test'},
              ),
            ],
            metadata: {
              'message_id': 'msg-assistant-tool',
              'turn_id': 'turn-1',
              'provider': 'inst-1',
            },
          ),
          Message(
            role: MessageRole.tool,
            toolCallId: 'call-1',
            content: 'Error: Provider rate limit exceeded',
            metadata: {
              'message_id': 'msg-tool-result',
              'turn_id': 'turn-1',
              'is_error': true,
              'terminal_at': '2026-10-15T02:01:30.000Z',
            },
          ),
          Message(
            role: MessageRole.assistant,
            content: 'I switched to model-b and found the answer.',
            metadata: {
              'message_id': 'msg-final-answer',
              'turn_id': 'turn-1',
              'provider': 'inst-2',
              'model': 'model-b',
            },
          ),
        ]);

        transitions.insert(
          SessionRouteTransition(
            sessionId: sessionId,
            routeRevision: 2,
            eventId: 'trans-failover-1',
            source: SessionRouteSource.autoFailover,
            previousProviderInstanceId: 'inst-1',
            providerInstanceId: 'inst-2',
            model: 'model-b',
            reason: 'rate_limit',
            requestId: 'req-failover-1',
            createdAt: DateTime.parse('2026-10-15T02:01:35.000Z'),
          ),
        );

        final historyEnvelopes = <Map<String, dynamic>>[];
        await bridge.handleProtocolEvent(
          CanonicalEvent(
            type: CanonicalEventTypes.getSessionHistory,
            sessionId: sessionId,
            payload: const {'request_id': 'history-check-failover-order'},
          ),
          (envelope) async => historyEnvelopes.add(envelope),
        );

        final messages = (historyEnvelopes.single['payload']['messages'] as List)
            .cast<Map<String, dynamic>>();

        final types = messages.map((m) => m['type']).toList();
        final transitionIndex = types.indexOf('session_route_transition');
        final toolResultIndex = types.indexOf('tool_result');
        final finalAnswerIndex = types.indexOf('final_answer');

        expect(transitionIndex, isNot(-1));
        expect(toolResultIndex, isNot(-1));
        expect(finalAnswerIndex, isNot(-1));

        // The route transition MUST appear AFTER the tool result and BEFORE the final answer!
        expect(
          transitionIndex > toolResultIndex,
          isTrue,
          reason: 'Route transition ($transitionIndex) must be placed after the tool result ($toolResultIndex)',
        );
        expect(
          transitionIndex < finalAnswerIndex,
          isTrue,
          reason: 'Route transition ($transitionIndex) must be placed before the final answer ($finalAnswerIndex)',
        );
      },
    );

    test(
      'route transition appears in older paginated page that contains its turn',
      () async {
        final sessionManager = getIt<SessionManager>();
        final state = getIt<AgentStateDatabase>();
        final transitions = getIt<SessionRouteTransitionRepository>();
        final bridge = getIt<SanadProtocolBridge>();
        const sessionId = 'session-paginated-failover';

        sessionManager.db.saveSession(
          SessionState(
            sessionId: sessionId,
            model: 'model-a',
            createdAt: DateTime.parse('2026-10-15T02:00:00Z'),
            updatedAt: DateTime.parse('2026-10-15T02:05:00Z'),
          ),
        );
        state.db.execute(
          '''
          INSERT INTO sessions (
            session_id, model, created_at, updated_at
          ) VALUES (?, ?, ?, ?)
          ''',
          [
            sessionId,
            'model-a',
            DateTime.now().toUtc().toIso8601String(),
            DateTime.now().toUtc().toIso8601String(),
          ],
        );

        // 8 messages:
        // Turn 1 (messages 1-2 with req-turn-1)
        // Transition happens in Turn 1
        // Turn 2, 3, 4 (messages 3-8)
        sessionManager.saveSessionHistory(sessionId, [
          Message(role: MessageRole.user, content: 'User Turn 1', metadata: {'message_id': 'm1', 'request_id': 'req-turn-1', 'turn_id': 't1'}),
          Message(role: MessageRole.assistant, content: 'Answer Turn 1', metadata: {'message_id': 'm2', 'turn_id': 't1'}),
          for (var i = 3; i <= 8; i++)
            Message(role: MessageRole.user, content: 'User $i', metadata: {'message_id': 'm$i'}),
        ]);

        transitions.insert(
          SessionRouteTransition(
            sessionId: sessionId,
            routeRevision: 2,
            eventId: 'trans-turn-1',
            source: SessionRouteSource.autoFailover,
            previousProviderInstanceId: 'inst-1',
            providerInstanceId: 'inst-2',
            model: 'model-b',
            reason: 'rate_limit',
            requestId: 'req-turn-1',
            createdAt: DateTime.parse('2026-10-15T02:01:00Z'),
          ),
        );

        // 1. Fetch tail page (messages 5 to 8) with limit: 4
        final tailEnvelopes = <Map<String, dynamic>>[];
        await bridge.handleProtocolEvent(
          CanonicalEvent(
            type: CanonicalEventTypes.getSessionHistory,
            sessionId: sessionId,
            payload: const {
              'request_id': 'check-tail-page',
              'limit': 4,
            },
          ),
          (envelope) async => tailEnvelopes.add(envelope),
        );
        final nextCursor = tailEnvelopes.single['payload']['next_cursor'] as String?;
        expect(nextCursor, isNotNull);

        // 2. Fetch older page (messages 1 to 4 containing Turn 1) using nextCursor
        final historyEnvelopes = <Map<String, dynamic>>[];
        await bridge.handleProtocolEvent(
          CanonicalEvent(
            type: CanonicalEventTypes.getSessionHistory,
            sessionId: sessionId,
            payload: {
              'request_id': 'check-older-page-transition',
              'limit': 4,
              'cursor': nextCursor,
            },
          ),
          (envelope) async => historyEnvelopes.add(envelope),
        );

        final messages = (historyEnvelopes.single['payload']['messages'] as List)
            .cast<Map<String, dynamic>>();

        final containsTransition = messages.any((m) => m['type'] == 'session_route_transition');
        expect(
          containsTransition,
          isTrue,
          reason: 'Route transition must appear in the older page containing its turn, not dropped',
        );
      },
    );
  });
}
