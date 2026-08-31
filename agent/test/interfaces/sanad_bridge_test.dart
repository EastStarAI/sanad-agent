import 'dart:io';

import 'package:test/test.dart';
import 'package:sanad_agent/core/auth/auth_manager.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/persisted_runtime_state_repository.dart';
import 'package:sanad_agent/evolution/models/session_state.dart';
import 'package:sanad_agent/engine/agent_runner.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/translators/agent_to_canonical.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/translators/canonical_to_agent.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/capabilities.dart';
import 'package:sanad_agent/interfaces/models/gateway_event.dart';
import 'package:sanad_agent/interfaces/models/delivery/models.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/core/provider_runtime/provider_rate_limiter.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_failure_reason.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_notice.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_recovery_service.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/models/tool_call.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/sanad_protocol_bridge.dart';
import 'package:sanad_agent/interfaces/runtime/local_workspace_runtime_service.dart';
import 'package:sanad_agent/capabilities/permissions/workspace_policy.dart';
import 'package:sanad_agent/capabilities/permissions/workspace_policy_store.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    getIt.allowReassignment = true;
    tempDir = await Directory.systemTemp.createTemp('sanad-agent-bridge-test');
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
  });

  tearDown(() async {
    SessionManager.resetForTesting();
    setSanadHomeOverride(null);
    await tempDir.delete(recursive: true);
    await getIt.reset();
  });

  group('Sanad Bridge Translators', () {
    test(
      'canonical runtime metadata preserves event identity and delivery',
      () {
        final bridge = SanadProtocolBridge();
        final response = GatewayResponse(
          sessionId: 'session-execution-event',
          eventId: 'execution-event-id',
          delivery: DeliveryPolicy.platformFamily(PlatformFamily.sanadClient),
          message: Message(
            role: MessageRole.assistant,
            metadata: const {
              'canonical_event_type': 'session.execution_state_changed',
              'canonical_payload': {
                'session_id': 'session-execution-event',
                'state': 'running',
                'work_item_id': 'work-1',
                'request_id': 'request-1',
                'revision': 1,
                'updated_at': '2026-07-15T12:00:00.000Z',
              },
            },
          ),
        );

        final event = bridge.translateResponse(response);

        expect(event.type, 'session.execution_state_changed');
        expect(event.eventId, 'execution-event-id');
        expect(event.delivery?.scope, DeliveryScope.platformFamily);
        expect(event.delivery?.platformFamily, PlatformFamily.sanadClient);
        expect(event.payload['revision'], 1);
      },
    );

    test('reasoning deltas use their dedicated canonical stream type', () {
      final event = AgentToCanonical.translate(
        GatewayResponse(
          sessionId: 'session-reasoning-stream',
          message: Message(
            role: MessageRole.assistant,
            reasoning: 'Inspecting',
          ),
          isComplete: false,
          runId: 'run-reasoning-stream',
          modelStepId: 'step-reasoning-stream',
        ),
      );

      expect(event.type, CanonicalEventTypes.reasoningStream);
      expect(event.payload['content'], 'Inspecting');

      final thought = AgentToCanonical.translate(
        GatewayResponse(
          sessionId: 'session-thought-stream',
          message: Message(
            role: MessageRole.assistant,
            thought: 'I will inspect the implementation',
          ),
          isComplete: false,
        ),
      );
      expect(thought.type, CanonicalEventTypes.thoughtStream);
      expect(thought.payload['content'], 'I will inspect the implementation');

      final ordinary = AgentToCanonical.translate(
        GatewayResponse(
          sessionId: 'session-ordinary-stream',
          message: Message(
            role: MessageRole.assistant,
            reasoning: '   ',
            content: 'Visible answer',
          ),
          isComplete: false,
        ),
      );
      expect(ordinary.type, CanonicalEventTypes.thoughtStream);
      expect(ordinary.payload['content'], 'Visible answer');
    });

    test(
      'handleCommand accepts device-command runtime recovery payloads',
      () async {
        final bridge = SanadProtocolBridge();
        final emitted = <Map<String, dynamic>>[];

        final retryHandled = await bridge.handleCommand({
          'command': 'session.runtime_retry',
          'payload': {
            'session_id': 'session-1',
            'request_id': 'request-1',
            'provider_instance_id': 'provider-1',
            'model_id': 'model-1',
          },
        }, (envelope) async => emitted.add(envelope));
        final continueHandled = await bridge.handleCommand({
          'command': 'session.runtime_continue_with_provider',
          'payload': {
            'session_id': 'session-1',
            'request_id': 'request-2',
            'provider_instance_id': 'provider-2',
            'model_id': 'model-2',
          },
        }, (envelope) async => emitted.add(envelope));

        final replayHandled = await bridge.handleCommand({
          'command': 'session.turn_replay',
          'payload': {
            'session_id': 'session-1',
            'request_id': 'request-3',
            'target_request_id': 'request-1',
            'action': 'retry',
          },
        }, (envelope) async => emitted.add(envelope));

        expect(retryHandled, isTrue);
        expect(continueHandled, isTrue);
        expect(replayHandled, isTrue);
        expect(emitted, isEmpty);
      },
    );

    test('CanonicalToAgent translates think command correctly', () {
      final rawData = {
        'command': 'think',
        'payload': {
          'message': 'Hello SanadAgent!',
          'session_id': 'session_123',
          'workspace_id': '/tmp/workspace',
          'model': 'openai/gpt-5',
          'thinking_mode': 'deep',
          'permission_mode': 'full_access',
        },
        'device_id': 'dev_456',
      };

      final event = CanonicalToAgent.translate(rawData, 'sanad_gateway');

      expect(event, isNotNull);
      expect(event!.sessionId, equals('session_123'));
      expect(event.message.content, equals('Hello SanadAgent!'));
      expect(event.message.role, equals(MessageRole.user));
      expect(event.turnRequest?.workspaceId, equals('/tmp/workspace'));
      expect(event.turnRequest?.model, equals('openai/gpt-5'));
      expect(event.turnRequest?.thinkingMode, equals('deep'));
      expect(
        event.turnRequest?.metadata.containsKey('permission_mode'),
        isFalse,
      );
    });

    test('CanonicalToAgent discards permission_mode from steer', () {
      final event = CanonicalToAgent.translate({
        'command': 'steer',
        'payload': {
          'message': 'Adjust the active turn',
          'session_id': 'session_steer',
          'workspace_id': 'workspace-1',
          'permission_mode': 'full_access',
        },
      }, 'sanad_gateway');

      expect(event, isNotNull);
      expect(event?.type, 'steer');
      expect(
        event?.turnRequest?.metadata.containsKey('permission_mode'),
        isFalse,
      );
    });

    test(
      'CanonicalToAgent translates create_session without session_id to a new UUID sessionId',
      () {
        final rawData = {
          'command': 'create_session',
          'payload': {'title': 'New Session Title', 'request_id': 'req_999'},
          'device_id': 'dev_456',
        };

        final event = CanonicalToAgent.translate(rawData, 'sanad_gateway');

        expect(event, isNotNull);
        expect(event!.sessionId, isNot(equals('default')));
        expect(event.sessionId.length, equals(36)); // standard UUIDv4 length
        expect(event.runId, equals('req_999'));
        expect(event.type, equals('create_session'));
      },
    );

    test(
      'CanonicalToAgent translates create_session with model and preferences correctly',
      () {
        final rawData = {
          'command': 'create_session',
          'payload': {
            'title': 'New Session Title',
            'request_id': 'req_999',
            'workspace_id': '/tmp/workspace',
            'provider_id': 'ollama',
            'model': 'llama3',
            'thinking_mode': 'normal',
          },
          'device_id': 'dev_456',
        };

        final event = CanonicalToAgent.translate(rawData, 'sanad_gateway');

        expect(event, isNotNull);
        expect(event!.runId, equals('req_999'));
        expect(event.type, equals('create_session'));
        expect(event.turnRequest, isNotNull);
        expect(event.turnRequest?.workspaceId, equals('/tmp/workspace'));
        expect(event.turnRequest?.providerId, equals('ollama'));
        expect(event.turnRequest?.model, equals('llama3'));
        expect(event.turnRequest?.thinkingMode, equals('normal'));
      },
    );

    test('CanonicalToAgent returns null for unknown commands', () {
      final rawData = {
        'command': 'completely_unknown_command',
        'payload': {},
        'device_id': 'dev_456',
      };

      final event = CanonicalToAgent.translate(rawData, 'sanad_gateway');
      expect(event, isNull);
    });

    test(
      'AgentToCanonical translates session_created response and includes request_id in payload',
      () {
        final response = GatewayResponse(
          sessionId: 'session_new_uuid',
          message: Message(role: MessageRole.assistant, content: 'Chat Title'),
          isSessionCreated: true,
          isComplete: true,
          runId: 'req_999',
        );

        final canonical = AgentToCanonical.translate(response);

        expect(canonical.type, equals('session_created'));
        expect(canonical.payload['id'], equals('session_new_uuid'));
        expect(canonical.payload['session_id'], equals('session_new_uuid'));
        expect(canonical.payload['title'], equals('Chat Title'));
        expect(canonical.payload['request_id'], equals('req_999'));
        expect(canonical.payload['run_id'], equals('req_999'));
      },
    );

    test('AgentToCanonical translates streaming response', () {
      final response = GatewayResponse(
        sessionId: 'session_123',
        message: Message(role: MessageRole.assistant, content: 'Thinking...'),
        isComplete: false,
      );

      final canonical = AgentToCanonical.translate(response);

      expect(canonical.type, equals(CanonicalEventTypes.thoughtStream));
      expect(canonical.payload['content'], equals('Thinking...'));
      expect(canonical.payload['status'], equals('running'));
      expect(canonical.sessionId, equals('session_123'));
    });

    test(
      'AgentToCanonical keeps ownership and display identities separate',
      () {
        final thought = AgentToCanonical.translate(
          GatewayResponse(
            sessionId: 'session_123',
            message: Message(role: MessageRole.assistant, content: 'Thinking'),
            isComplete: false,
            runId: 'run-1',
            modelStepId: 'step-1',
          ),
        );
        final tool = AgentToCanonical.translate(
          GatewayResponse(
            sessionId: 'session_123',
            message: Message(role: MessageRole.tool, content: '{}'),
            isComplete: false,
            runId: 'run-1',
            modelStepId: 'step-1',
            toolCallId: 'call-1',
            toolName: 'lookup',
            isToolUse: true,
          ),
        );

        expect(thought.payload['run_id'], 'run-1');
        expect(thought.payload['model_step_id'], 'step-1');
        expect(tool.payload['run_id'], 'run-1');
        expect(tool.payload['model_step_id'], 'step-1');
        expect(tool.payload['tool_call_id'], 'call-1');
      },
    );

    test('AgentToCanonical translates tool use response', () {
      final response = GatewayResponse(
        sessionId: 'session_123',
        message: Message(role: MessageRole.tool, content: '{"arg": 1}'),
        isComplete: false,
        toolName: 'my_tool',
        isToolUse: true,
      );

      final canonical = AgentToCanonical.translate(response);

      expect(canonical.type, equals('tool_use'));
      expect(canonical.payload['tool'], equals('my_tool'));
      expect(canonical.payload['input'], equals('{"arg": 1}'));
      expect(canonical.payload, isNot(contains('content')));
      expect(canonical.payload['status'], equals('running'));
    });

    test('AgentToCanonical translates tool result response', () {
      final response = GatewayResponse(
        sessionId: 'session_123',
        message: Message(role: MessageRole.tool, content: 'success'),
        isComplete: false,
        toolName: 'my_tool',
        isToolResult: true,
        isToolError: false,
      );

      final canonical = AgentToCanonical.translate(response);

      expect(canonical.type, equals('tool_result'));
      expect(canonical.payload['tool'], equals('my_tool'));
      expect(canonical.payload['output'], equals('success'));
      expect(canonical.payload, isNot(contains('content')));
      expect(canonical.payload['isError'], isFalse);
    });

    test(
      'AgentToCanonical translates final answer with usage and model info',
      () {
        final response = GatewayResponse(
          sessionId: 'session_123',
          message: Message(role: MessageRole.assistant, content: 'Done!'),
          isComplete: true,
          model: 'model-a',
          modelDisplay: 'Model A',
          provider: 'ollama',
          usage: {'input': 10, 'output': 5},
          runtimeMs: 500,
        );

        final canonical = AgentToCanonical.translate(response);

        expect(canonical.type, equals(CanonicalEventTypes.finalAnswer));
        expect(canonical.payload['content'], equals('Done!'));
        expect(canonical.payload['status'], equals('done'));
        expect(canonical.payload['model'], equals('model-a'));
        expect(canonical.payload['usage']['input'], equals(10));
        expect(canonical.payload['runtime_ms'], equals(500));
        expect(canonical.payload['timestamp'], isNotNull);
      },
    );

    test(
      'AgentToCanonical translates user message response and preserves metadata & request_id',
      () {
        final response = GatewayResponse(
          sessionId: 'session_123',
          message: Message(
            role: MessageRole.user,
            content: 'Hello World',
            metadata: {'queued': true, 'request_id': 'req_456'},
          ),
          isComplete: true,
        );

        final canonical = AgentToCanonical.translate(response);

        expect(canonical.type, equals('user_message'));
        expect(canonical.payload['content'], equals('Hello World'));
        expect(canonical.payload['status'], equals('done'));
        expect(canonical.payload['metadata']['queued'], isTrue);
        expect(canonical.payload['metadata']['request_id'], equals('req_456'));
        expect(canonical.payload['request_id'], equals('req_456'));
      },
    );
  });

  group('Sanad Protocol Models', () {
    test('AgentCapabilities toJson follows Protocol v1 schema', () {
      final caps = AgentCapabilities(
        displayName: 'Test Agent',
        thinkingModes: ['fast'],
      );

      final json = caps.toJson();

      expect(json['display_name'], equals('Test Agent'));
      expect(json['protocol_version'], equals('v1'));
      expect(json['capabilities'].containsKey('models'), isFalse);
      expect(json['capabilities']['thinking_modes_list'], contains('fast'));
      expect(json['capabilities']['supports_stop'], isTrue);
      expect(json['capabilities']['supports_workspaces'], isTrue);
      expect(json['capabilities']['supports_local_tool_runtime'], isTrue);
      expect(
        json['capabilities'].containsKey('supports_remote_update'),
        isFalse,
      );
      expect(
        json['capabilities'].containsKey('supports_remote_restart'),
        isFalse,
      );
      expect(
        json['capabilities'].containsKey(
          'supports_remote_workspace_management',
        ),
        isFalse,
      );
      expect(
        json['capabilities'].containsKey('supports_remote_mcp_management'),
        isFalse,
      );
    });
    // ...

    test('CanonicalEvent fromJson/toJson roundtrip', () {
      final original = CanonicalEvent(
        type: 'test_event',
        payload: {'key': 'value'},
        sessionId: 't1',
      );

      final json = original.toJson();
      final fromJson = CanonicalEvent.fromJson(json);

      expect(fromJson.type, equals('test_event'));
      expect(fromJson.payload['key'], equals('value'));
      expect(fromJson.sessionId, equals('t1'));
    });

    test('CanonicalEvent normalizes legacy numeric event ids to strings', () {
      final event = CanonicalEvent.fromJson({
        'type': 'legacy_event',
        'payload': <String, dynamic>{},
        'event_id': 42,
      });

      expect(event.eventId, '42');
    });
  });

  group('Sanad Protocol Bridge Runtime Queries', () {
    test('handleCommand lists workspaces', () async {
      final sessionManager = getIt<SessionManager>();
      final wsPath = '${tempDir.path}/workspace-test';
      await Directory(wsPath).create(recursive: true);
      sessionManager.db.saveWorkspace(
        path: wsPath,
        source: 'created',
        updatedAt: DateTime.now().toIso8601String(),
      );
      final bridge = SanadProtocolBridge();
      Map<String, dynamic>? emitted;

      final handled = await bridge.handleCommand(
        {
          'command': 'list_workspaces',
          'payload': {'request_id': 'req-1'},
        },
        (envelope) async {
          emitted = envelope;
        },
      );

      expect(handled, isTrue);
      expect(emitted?['event'], equals(CanonicalEventTypes.workspacesList));
      expect((emitted?['payload']['workspaces'] as List).isNotEmpty, isTrue);
    });

    test(
      'handleCommand lists sessions with persisted workspace context',
      () async {
        final bridge = SanadProtocolBridge();
        final workspacePath = '${tempDir.path}/workspace-a';
        await Directory(workspacePath).create(recursive: true);
        final sessionManager = getIt<SessionManager>();
        sessionManager.db.saveSession(
          SessionState(
            sessionId: 'session-1',
            model: 'sanad-agent',
            title: 'Workspace Session',
            workspaceId: workspacePath,
            createdAt: DateTime.parse('2026-01-01T00:00:00Z'),
            updatedAt: DateTime.parse('2026-01-01T00:00:00Z'),
          ),
        );
        sessionManager.saveSessionMetadata('session-1', {
          'workspace_id': workspacePath,
          'workspace_name': 'workspace-a',
          'workspace_path': workspacePath,
        });

        Map<String, dynamic>? emitted;
        final handled = await bridge.handleCommand(
          {
            'command': 'get_sessions',
            'payload': {'request_id': 'req-sessions'},
          },
          (envelope) async {
            emitted = envelope;
          },
        );

        expect(handled, isTrue);
        final sessions = emitted?['payload']['sessions'] as List<dynamic>;
        final session = Map<String, dynamic>.from(sessions.single as Map);
        expect(session['workspace_id'], workspacePath);
        expect(session['workspace_name'], 'workspace-a');
        expect(session['workspace_path'], workspacePath);
      },
    );

    test(
      'handleCommand get_sessions marks sessions with visible runtime recovery notices',
      () async {
        final bridge = SanadProtocolBridge();
        final sessionManager = getIt<SessionManager>();
        final recovery = RuntimeRecoveryService(
          ProviderInstanceRepository.inMemory(),
          ProviderRateLimiter(),
        );
        getIt.registerSingleton<RuntimeRecoveryService>(recovery);
        sessionManager.db.saveSession(
          SessionState(
            sessionId: 'session-1',
            model: 'sanad-agent',
            title: 'Recovery Session',
            createdAt: DateTime.parse('2026-01-01T00:00:00Z'),
            updatedAt: DateTime.parse('2026-01-01T00:00:00Z'),
          ),
        );
        recovery.reportFailure(
          sessionId: 'session-1',
          reason: RuntimeFailureReason.rateLimit,
          title: 'Waiting for provider',
          message: 'The session is blocked until you retry or stop.',
          forceBlocked: true,
        );

        Map<String, dynamic>? emitted;
        final handled = await bridge.handleCommand(
          {
            'command': 'get_sessions',
            'payload': {'request_id': 'req-recovery-sessions'},
          },
          (envelope) async {
            emitted = envelope;
          },
        );

        expect(handled, isTrue);
        final sessions = emitted?['payload']['sessions'] as List<dynamic>;
        final session = Map<String, dynamic>.from(sessions.single as Map);
        final metadata = Map<String, dynamic>.from(session['metadata'] as Map);
        expect(metadata['has_runtime_recovery_notice'], isTrue);
        expect(
          metadata['runtime_recovery_status'],
          RuntimeNoticeStatus.blocked.name,
        );
      },
    );

    test('handleCommand creates workspace and returns tree queries', () async {
      final bridge = SanadProtocolBridge();
      Map<String, dynamic>? created;

      final createdPath = '${tempDir.path}/demo-workspace';
      await bridge.handleCommand(
        {
          'command': 'create_workspace',
          'payload': {
            'request_id': 'req-2',
            'name': 'demo-workspace',
            'path': createdPath,
          },
        },
        (envelope) async {
          created = envelope;
        },
      );

      expect(created?['event'], equals(CanonicalEventTypes.workspaceCreated));
      final createdWorkspace = Map<String, dynamic>.from(
        created?['payload']['workspace'] as Map,
      );
      final createdWorkspaceId = createdWorkspace['id'] as String;
      final createdWorkspacePath = createdWorkspace['path'] as String;
      expect(createdWorkspaceId, isNot(createdWorkspacePath));
      expect(Directory(createdWorkspacePath).existsSync(), isTrue);

      final workspaceRoot = Directory(createdWorkspacePath);
      await File('${workspaceRoot.path}/README.md').writeAsString('hello');

      Map<String, dynamic>? tree;
      await bridge.handleCommand(
        {
          'command': 'browse_workspace_tree',
          'payload': {
            'request_id': 'req-3',
            'workspace_id': createdWorkspaceId,
          },
        },
        (envelope) async {
          tree = envelope;
        },
      );

      expect(tree?['event'], equals(CanonicalEventTypes.workspaceTree));
      expect(tree?['payload']['workspace_id'], createdWorkspaceId);
      final entries = tree?['payload']['entries'] as List<dynamic>;
      expect(entries.any((entry) => entry['name'] == 'README.md'), isTrue);
      expect(tree?['payload']['parent_path'], isNull);
    });

    test(
      'handleCommand contains duplicate workspace relocation errors',
      () async {
        final service = getIt<LocalWorkspaceRuntimeService>();
        final firstDirectory = Directory('${tempDir.path}/first-workspace')
          ..createSync();
        final secondDirectory = Directory('${tempDir.path}/second-workspace')
          ..createSync();
        final firstWorkspace = await service.createWorkspace(
          path: firstDirectory.path,
        );
        await service.createWorkspace(path: secondDirectory.path);
        final bridge = SanadProtocolBridge();
        Map<String, dynamic>? emitted;

        final handled = await bridge.handleCommand({
          'command': 'workspace.relocate',
          'payload': {
            'request_id': 'workspace-relocate-error-1',
            'workspace_id': firstWorkspace['id'],
            'new_path': secondDirectory.path,
          },
        }, (envelope) async => emitted = envelope);

        expect(handled, isTrue);
        expect(emitted?['event'], 'error');
        expect(emitted?['request_id'], 'workspace-relocate-error-1');
        expect(
          emitted?['payload']['message'],
          'Failed to change workspace path: '
          'That folder is already connected to another workspace.',
        );
      },
    );

    test(
      'handleCommand removes a workspace record without deleting its folder',
      () async {
        final service = getIt<LocalWorkspaceRuntimeService>();
        final directory = Directory('${tempDir.path}/remove-workspace')
          ..createSync();
        final workspace = await service.createWorkspace(path: directory.path);
        Map<String, dynamic>? emitted;

        final handled = await SanadProtocolBridge().handleCommand({
          'command': CanonicalEventTypes.removeWorkspace,
          'payload': {
            'request_id': 'workspace-remove-1',
            'workspace_id': workspace['id'],
          },
        }, (envelope) async => emitted = envelope);

        expect(handled, isTrue);
        expect(emitted?['event'], CanonicalEventTypes.workspaceRemoved);
        expect(emitted?['request_id'], 'workspace-remove-1');
        expect(emitted?['payload']['workspace_id'], workspace['id']);
        expect(directory.existsSync(), isTrue);
        expect(await service.listWorkspaces(), isEmpty);
      },
    );

    test(
      'handleCommand mutates folders with correlated acknowledgments',
      () async {
        final bridge = SanadProtocolBridge();
        final parent = Directory('${tempDir.path}/folder-parent')..createSync();

        Future<Map<String, dynamic>> send(
          String command,
          Map<String, dynamic> payload,
        ) async {
          Map<String, dynamic>? emitted;
          final handled = await bridge.handleCommand({
            'command': command,
            'payload': payload,
          }, (envelope) async => emitted = envelope);
          expect(handled, isTrue);
          return emitted!;
        }

        final created = await send('workspace.create_folder', {
          'request_id': 'folder-create-1',
          'parent_path': parent.path,
          'name': 'created',
        });
        final createdPath = created['payload']['path'] as String;
        expect(created['event'], CanonicalEventTypes.folderCreated);
        expect(created['request_id'], 'folder-create-1');
        expect(Directory(createdPath).existsSync(), isTrue);

        final renamed = await send('workspace.rename_folder', {
          'request_id': 'folder-rename-1',
          'path': createdPath,
          'new_name': 'renamed',
        });
        final renamedPath = renamed['payload']['path'] as String;
        expect(renamed['event'], CanonicalEventTypes.folderRenamed);
        expect(renamed['request_id'], 'folder-rename-1');
        expect(Directory(renamedPath).existsSync(), isTrue);

        final deleted = await send('workspace.delete_folder', {
          'request_id': 'folder-delete-1',
          'path': renamedPath,
        });
        expect(deleted['event'], CanonicalEventTypes.folderDeleted);
        expect(deleted['request_id'], 'folder-delete-1');
        expect(Directory(renamedPath).existsSync(), isFalse);
      },
    );

    test('handleCommand returns correlated folder mutation errors', () async {
      final bridge = SanadProtocolBridge();
      Map<String, dynamic>? emitted;

      await bridge.handleCommand({
        'command': 'workspace.create_folder',
        'payload': {
          'request_id': 'folder-error-1',
          'parent_path': tempDir.path,
          'name': '../outside',
        },
      }, (envelope) async => emitted = envelope);

      expect(emitted?['event'], 'error');
      expect(emitted?['request_id'], 'folder-error-1');
      expect(emitted?['payload']['message'], contains('single path segment'));
    });

    test('handleCommand exposes mcp servers and slash commands', () async {
      final homeMcpConfig = File('${tempDir.path}/mcp_config.json');
      await homeMcpConfig.writeAsString('''
{
  "mcpServers": {
    "filesystem": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem"]
    }
  }
}
''');

      final bridge = SanadProtocolBridge();
      Map<String, dynamic>? mcpEnvelope;
      await bridge.handleCommand(
        {
          'command': 'list_mcp_servers',
          'payload': {'request_id': 'req-4'},
        },
        (envelope) async {
          mcpEnvelope = envelope;
        },
      );

      expect(mcpEnvelope?['event'], equals(CanonicalEventTypes.mcpServersList));
      expect(mcpEnvelope?['payload']['global']['scope'], equals('global'));
      expect(
        (mcpEnvelope?['payload']['effective']['servers'] as List).first['name'],
        equals('filesystem'),
      );
      expect(
        ((mcpEnvelope?['payload']['global']['document'] as Map)['mcpServers']
            as Map)['filesystem'],
        isNotNull,
      );

      Map<String, dynamic>? slashEnvelope;
      await bridge.handleCommand(
        {
          'command': 'search_slash_commands',
          'payload': {'request_id': 'req-5', 'query': 'compact'},
        },
        (envelope) async {
          slashEnvelope = envelope;
        },
      );

      expect(
        slashEnvelope?['event'],
        equals(CanonicalEventTypes.slashCommandsList),
      );
      final commands = slashEnvelope?['payload']['commands'] as List<dynamic>;
      expect(commands.any((entry) => entry['command'] == 'compact'), isTrue);
    });

    test(
      'handleCommand saves and deletes MCP servers through runtime',
      () async {
        final workspacePath = '${tempDir.path}/workspace-a';
        await Directory(workspacePath).create(recursive: true);
        final workspace = getIt<SessionManager>().db.createOrGetWorkspace(
          path: workspacePath,
          source: 'created',
        );
        final workspaceId = workspace['id'] as String;

        final bridge = SanadProtocolBridge();
        Map<String, dynamic>? savedEnvelope;
        await bridge.handleCommand(
          {
            'command': 'save_mcp_server',
            'payload': {
              'request_id': 'req-6',
              'scope': 'workspace',
              'workspace_id': workspaceId,
              'config': {
                'name': 'github',
                'command': 'npx',
                'args': ['-y', '@modelcontextprotocol/server-github'],
              },
            },
          },
          (envelope) async {
            savedEnvelope = envelope;
          },
        );

        expect(
          savedEnvelope?['event'],
          equals(CanonicalEventTypes.mcpServerSaved),
        );
        final workspaceServers =
            savedEnvelope?['payload']['workspace']['servers'] as List<dynamic>;
        expect(workspaceServers.single['name'], equals('github'));

        final savedFile = File('$workspacePath/.sanad/mcp_config.json');
        expect(savedFile.existsSync(), isTrue);

        Map<String, dynamic>? deletedEnvelope;
        await bridge.handleCommand(
          {
            'command': 'delete_mcp_server',
            'payload': {
              'request_id': 'req-7',
              'scope': 'workspace',
              'workspace_id': workspaceId,
              'server_name': 'github',
            },
          },
          (envelope) async {
            deletedEnvelope = envelope;
          },
        );

        expect(
          deletedEnvelope?['event'],
          equals(CanonicalEventTypes.mcpServerDeleted),
        );
        expect(
          (deletedEnvelope?['payload']['workspace']['servers']
              as List<dynamic>),
          isEmpty,
        );
      },
    );
  });

  group('In-Flight Thought Stream Snapshots', () {
    test('translateResponse is side-effect free across transport copies', () {
      final bridge = SanadProtocolBridge();
      final sessionManager = getIt<SessionManager>();
      const sessionId = 'session-stream-translation';
      sessionManager.saveInFlightSnapshot(sessionId, {
        'type': CanonicalEventTypes.thoughtStream,
        'status': 'running',
        'session_id': sessionId,
        'run_id': 'run-abc',
        'model_step_id': 'step-1',
        'content': 'Already projected',
      });
      final response = GatewayResponse(
        sessionId: sessionId,
        message: Message(role: MessageRole.assistant, content: ' chunk'),
        isComplete: false,
        runId: 'run-abc',
        modelStepId: 'step-1',
      );

      expect(bridge.translateResponse(response).type, 'thought_stream');
      expect(bridge.translateResponse(response).type, 'thought_stream');

      final snapshot = sessionManager.getInFlightSnapshot(sessionId);
      expect(snapshot?['content'], 'Already projected');
    });

    test('get_session_history injects in_flight snapshot if present', () async {
      final bridge = SanadProtocolBridge();
      final sessionManager = getIt<SessionManager>();

      sessionManager.saveInFlightSnapshot('session_history_session', {
        'type': 'thought_stream',
        'status': 'running',
        'session_id': 'session_history_session',
        'run_id': 'run_123',
        'content': 'Currently streaming thought content',
        'timestamp': 1234567,
        'updated_at': 1234567,
      });

      Map<String, dynamic>? emitted;
      await bridge.handleCommand(
        {
          'command': 'get_session_history',
          'payload': {
            'request_id': 'req-history',
            'session_id': 'session_history_session',
          },
        },
        (envelope) async {
          emitted = envelope;
        },
      );

      expect(emitted, isNotNull);
      expect(emitted?['event'], equals(CanonicalEventTypes.sessionHistory));
      final payload = emitted?['payload'];
      expect(payload, isNotNull);

      final inFlight = payload['in_flight'];
      expect(inFlight, isNotNull);
      expect(
        inFlight['content'],
        equals('Currently streaming thought content'),
      );
      expect(inFlight['run_id'], equals('run_123'));
      expect(payload['execution_snapshot'], {
        'session_id': 'session_history_session',
        'state': 'idle',
        'work_item_id': null,
        'request_id': null,
        'revision': 0,
        'updated_at': '1970-01-01T00:00:00.000Z',
      });
    });

    test(
      'get_session_history returns the latest persisted provider usage',
      () async {
        final bridge = SanadProtocolBridge();
        final sessionManager = getIt<SessionManager>();
        const sessionId = 'session-latest-usage';
        sessionManager.db.saveSession(
          SessionState(
            sessionId: sessionId,
            model: 'model-a',
            createdAt: DateTime.utc(2026, 7, 18),
            updatedAt: DateTime.utc(2026, 7, 18, 1),
          ),
        );
        sessionManager.saveSessionHistory(sessionId, [
          Message(role: MessageRole.user, content: 'First'),
          Message(
            role: MessageRole.assistant,
            content: 'First answer',
            metadata: const {
              'usage': {'input_tokens': 100, 'cached_tokens': 40},
              'context_tokens': 1000,
            },
          ),
          Message(role: MessageRole.user, content: 'Second'),
          Message(
            role: MessageRole.assistant,
            content: 'Second answer',
            metadata: const {
              'usage': {'input_tokens': 250, 'cached_tokens': 175},
              'context_tokens': 1000,
            },
          ),
        ]);

        Map<String, dynamic>? emitted;
        await bridge.handleCommand({
          'command': 'get_session_history',
          'payload': {
            'request_id': 'req-latest-usage',
            'session_id': sessionId,
          },
        }, (envelope) async => emitted = envelope);

        final usage = Map<String, dynamic>.from(
          emitted?['payload']['context_usage'] as Map,
        );
        expect(usage['input_tokens'], 250);
        expect(usage['cached_tokens'], 175);
        expect(usage['context_window_tokens'], 1000);
        final messages = emitted?['payload']['messages'] as List;
        expect(messages.last['context_usage'], usage);
      },
    );

    test(
      'session history keeps typed thought reasoning and final answer separate',
      () async {
        final bridge = SanadProtocolBridge();
        final sessionManager = getIt<SessionManager>();
        const sessionId = 'session-typed-thought-history';
        sessionManager.db.saveSession(
          SessionState(
            sessionId: sessionId,
            model: 'gpt-5.4',
            createdAt: DateTime.utc(2026, 7, 27),
            updatedAt: DateTime.utc(2026, 7, 27, 1),
          ),
        );
        sessionManager.saveSessionHistory(sessionId, [
          Message(role: MessageRole.user, content: 'Fix it'),
          Message(
            role: MessageRole.assistant,
            thought: 'I will update the implementation.',
            reasoning: '**Planning**\n\n**Refining**',
            content: 'The fix is complete.',
            metadata: const {
              'run_id': 'run-codex',
              'model_step_id': 'step-codex',
            },
          ),
        ]);

        Map<String, dynamic>? emitted;
        await bridge.handleCommand({
          'command': 'get_session_history',
          'payload': {
            'request_id': 'req-typed-thought-history',
            'session_id': sessionId,
          },
        }, (envelope) async => emitted = envelope);

        final messages = (emitted?['payload']['messages'] as List)
            .cast<Map<String, dynamic>>();
        expect(messages.map((row) => row['type']), [
          'user_message',
          'reasoning',
          'thought',
          'final_answer',
        ]);
        expect(messages[1]['content'], '**Planning**\n\n**Refining**');
        expect(messages[2]['content'], 'I will update the implementation.');
        expect(messages[3]['content'], 'The fix is complete.');
        expect(messages[3]['status'], 'done');
        expect(messages[3]['message_id'], isNotEmpty);
        expect(messages[3]['turn_id'], isNotEmpty);
      },
    );

    test(
      'sessions_list includes a virtual idle execution snapshot per row',
      () async {
        final bridge = SanadProtocolBridge();
        final sessionManager = getIt<SessionManager>();
        sessionManager.db.saveSession(
          SessionState(
            sessionId: 'session-list-snapshot',
            model: 'model-a',
            providerId: 'provider-a',
            createdAt: DateTime.utc(2026, 7, 15),
            updatedAt: DateTime.utc(2026, 7, 15),
            routeRevision: 3,
            routeUpdatedAt: DateTime.utc(2026, 7, 15, 1),
          ),
        );

        Map<String, dynamic>? emitted;
        await bridge.handleCommand({
          'command': 'get_sessions',
          'payload': {'request_id': 'req-list'},
        }, (envelope) async => emitted = envelope);

        final sessions = emitted?['payload']['sessions'] as List;
        final row = sessions.cast<Map<String, dynamic>>().singleWhere(
          (candidate) => candidate['session_id'] == 'session-list-snapshot',
        );
        expect(row['execution_snapshot']['state'], 'idle');
        expect(row['execution_snapshot']['revision'], 0);
        expect(
          row['execution_snapshot']['session_id'],
          'session-list-snapshot',
        );
        expect(row['route_revision'], 3);
        expect(row['route_updated_at'], '2026-07-15T01:00:00.000Z');
      },
    );

    test(
      'a second client history query receives the durable active snapshot',
      () async {
        const sessionId = 'session-second-client';
        final sessionManager = getIt<SessionManager>();
        sessionManager.db.saveSession(
          SessionState(
            sessionId: sessionId,
            model: 'model-a',
            providerId: 'provider-a',
            createdAt: DateTime.utc(2026, 7, 15),
            updatedAt: DateTime.utc(2026, 7, 15),
            routeRevision: 5,
            routeUpdatedAt: DateTime.utc(2026, 7, 15, 2),
          ),
        );
        final state = AgentStateDatabase.inMemory();
        addTearDown(state.dispose);
        state.db.execute(
          '''
          INSERT INTO sessions (session_id, model, created_at, updated_at)
          VALUES (?, ?, ?, ?)
          ''',
          [sessionId, 'model-a', '2026-07-15', '2026-07-15'],
        );
        final persistedState = PersistedRuntimeStateRepository.fromState(state);
        getIt.registerSingleton<PersistedRuntimeStateRepository>(
          persistedState,
        );
        persistedState.executionState.enqueueWorkItem(
          workItemId: 'work-second-client',
          sessionId: sessionId,
          requestId: 'request-second-client',
          state: SessionWorkState.running,
        );
        final bridge = SanadProtocolBridge();

        Map<String, dynamic>? emitted;
        await bridge.handleCommand({
          'command': 'get_session_history',
          'payload': {
            'session_id': sessionId,
            'request_id': 'history-client-2',
          },
        }, (envelope) async => emitted = envelope);

        final snapshot = emitted?['payload']['execution_snapshot'];
        expect(snapshot['state'], 'running');
        expect(snapshot['work_item_id'], 'work-second-client');
        expect(snapshot['request_id'], 'request-second-client');
        expect(snapshot['revision'], 1);
        expect(emitted?['payload']['route_revision'], 5);
        expect(
          emitted?['payload']['route_updated_at'],
          '2026-07-15T02:00:00.000Z',
        );
      },
    );

    test(
      'get_session_history restores persisted reasoning around tool turns and final answers',
      () async {
        final bridge = SanadProtocolBridge();
        final sessionManager = getIt<SessionManager>();
        const sessionId = 'session-reasoning-history';
        sessionManager.db.saveSession(
          SessionState(
            sessionId: sessionId,
            model: 'gpt-5.5',
            createdAt: DateTime.parse('2026-07-14T01:00:00Z'),
            updatedAt: DateTime.parse('2026-07-14T01:01:00Z'),
          ),
        );
        sessionManager.saveSessionHistory(sessionId, [
          Message(role: MessageRole.user, content: 'Inspect the project'),
          Message(
            role: MessageRole.assistant,
            reasoning: 'Planning the inspection',
            content: 'I will inspect the file.',
            toolCalls: [
              ToolCall(
                id: 'tool-reasoning-1',
                name: 'file_read',
                arguments: const {'path': 'lib/main.dart'},
              ),
            ],
            metadata: const {'run_id': 'run-reasoning'},
          ),
          Message(
            role: MessageRole.tool,
            toolCallId: 'tool-reasoning-1',
            content: 'file contents',
          ),
          Message(
            role: MessageRole.assistant,
            reasoning: 'Reviewing the result',
            content: 'Inspection complete',
            metadata: const {'run_id': 'run-reasoning'},
          ),
        ]);

        Map<String, dynamic>? emitted;
        await bridge.handleCommand({
          'command': 'get_session_history',
          'payload': {
            'request_id': 'req-reasoning-history',
            'session_id': sessionId,
          },
        }, (envelope) async => emitted = envelope);

        final messages = emitted?['payload']['messages'] as List;
        expect(messages.map((message) => message['type']), [
          'user_message',
          'reasoning',
          'thought',
          'tool_use',
          'tool_result',
          'reasoning',
          'final_answer',
        ]);
        expect(messages[1]['content'], 'Planning the inspection');
        expect(messages[2]['content'], 'I will inspect the file.');
        expect(messages[3]['input'], '{"path":"lib/main.dart"}');
        expect(messages[3], isNot(contains('content')));
        expect(messages[4]['output'], 'file contents');
        expect(messages[4], isNot(contains('content')));
        expect(messages[5]['content'], 'Reviewing the result');
        expect(messages[6]['content'], 'Inspection complete');

        final persisted = sessionManager.getMessages(sessionId);
        expect(persisted[1].reasoning, 'Planning the inspection');
        expect(persisted[3].reasoning, 'Reviewing the result');
      },
    );

    test(
      'get_session_history restores typed tool errors without relying on text prefixes',
      () async {
        final bridge = SanadProtocolBridge();
        final sessionManager = getIt<SessionManager>();
        const sessionId = 'session-tool-error-history';
        sessionManager.db.saveSession(
          SessionState(
            sessionId: sessionId,
            model: 'sanad-agent',
            createdAt: DateTime.parse('2026-07-02T10:00:00Z'),
            updatedAt: DateTime.parse('2026-07-02T10:01:00Z'),
          ),
        );
        sessionManager.saveSessionHistory(sessionId, [
          Message(role: MessageRole.user, content: 'Run the check'),
          Message(
            role: MessageRole.assistant,
            toolCalls: [
              ToolCall(
                id: 'tool-error-1',
                name: 'project_check',
                arguments: const {},
              ),
            ],
          ),
          Message(
            role: MessageRole.tool,
            toolCallId: 'tool-error-1',
            content: 'Validation failed for two files',
            metadata: const {'is_error': true},
          ),
          Message(role: MessageRole.assistant, content: 'The check failed.'),
        ]);

        Map<String, dynamic>? emitted;
        await bridge.handleCommand({
          'command': 'get_session_history',
          'payload': {
            'request_id': 'req-tool-error-history',
            'session_id': sessionId,
          },
        }, (envelope) async => emitted = envelope);

        final messages = emitted?['payload']['messages'] as List;
        final toolResult = messages.singleWhere(
          (message) => message['type'] == 'tool_result',
        );
        expect(toolResult['output'], 'Validation failed for two files');
        expect(toolResult['isError'], isTrue);
      },
    );

    test(
      'get_session_history restores the complete cancelled tool terminal',
      () async {
        final bridge = SanadProtocolBridge();
        final sessionManager = getIt<SessionManager>();
        const sessionId = 'session-cancelled-tool-history';
        sessionManager.db.saveSession(
          SessionState(
            sessionId: sessionId,
            model: 'sanad-agent',
            createdAt: DateTime.parse('2026-08-29T00:00:00Z'),
            updatedAt: DateTime.parse('2026-08-29T00:01:00Z'),
          ),
        );
        sessionManager.saveSessionHistory(sessionId, [
          Message(role: MessageRole.user, content: 'Run a command'),
          Message(
            role: MessageRole.assistant,
            toolCalls: [
              ToolCall(
                id: 'tool-cancelled-1',
                name: 'shell_execute',
                arguments: const {'command': 'sleep 10'},
              ),
            ],
            metadata: const {
              'run_id': 'run-cancelled-1',
              'model_step_id': 'step-cancelled-1',
            },
          ),
          Message(
            role: MessageRole.tool,
            toolCallId: 'tool-cancelled-1',
            content: 'Command cancelled by user.',
            metadata: const {
              'run_id': 'run-cancelled-1',
              'model_step_id': 'step-cancelled-1',
              'generation': 5,
              'revision': 23,
              'status': 'cancelled',
              'reason': 'user_stop',
              'is_error': true,
              'started_at': '2026-08-29T00:00:10.000Z',
              'terminal_at': '2026-08-29T00:00:11.000Z',
              'cleanup_outcome': 'cancelled',
            },
          ),
        ]);

        Map<String, dynamic>? emitted;
        await bridge.handleCommand({
          'command': 'get_session_history',
          'payload': {
            'request_id': 'req-cancelled-tool-history',
            'session_id': sessionId,
          },
        }, (envelope) async => emitted = envelope);

        final messages = emitted?['payload']['messages'] as List;
        final toolResult = messages.singleWhere(
          (message) => message['type'] == 'tool_result',
        );
        expect(toolResult['status'], 'cancelled');
        expect(toolResult['run_id'], 'run-cancelled-1');
        expect(toolResult['model_step_id'], 'step-cancelled-1');
        expect(toolResult['tool_call_id'], 'tool-cancelled-1');
        expect(toolResult['generation'], 5);
        expect(toolResult['revision'], 23);
        expect(toolResult['reason'], 'user_stop');
        expect(toolResult['started_at'], '2026-08-29T00:00:10.000Z');
        expect(toolResult['terminal_at'], '2026-08-29T00:00:11.000Z');
        expect(toolResult['cleanup_outcome'], 'cancelled');
      },
    );

    test(
      'get_session_history restores steer after its tool result without exposing markers',
      () async {
        final bridge = SanadProtocolBridge();
        final sessionManager = getIt<SessionManager>();
        const sessionId = 'session-steer-history';
        sessionManager.db.saveSession(
          SessionState(
            sessionId: sessionId,
            model: 'sanad-agent',
            createdAt: DateTime.parse('2026-07-02T10:00:00Z'),
            updatedAt: DateTime.parse('2026-07-02T10:06:00Z'),
          ),
        );
        sessionManager.saveSessionHistory(sessionId, [
          Message(role: MessageRole.user, content: 'Original request'),
          Message(
            role: MessageRole.assistant,
            toolCalls: [
              ToolCall(
                id: 'tool-call-1',
                name: 'test_tool',
                arguments: const {},
              ),
            ],
          ),
          Message(
            role: MessageRole.tool,
            toolCallId: 'tool-call-1',
            content:
                'tool result\n\n$steerMarkerOpen\nChange direction\n$steerMarkerClose',
            metadata: {
              'steer_original_content': 'tool result',
              'steer_messages': [
                {
                  'text': 'Change direction',
                  'request_id': 'steer-history-1',
                  'received_at': '2026-07-02T10:05:00.000Z',
                },
              ],
            },
          ),
          Message(role: MessageRole.assistant, content: 'Adjusted answer'),
        ]);

        Map<String, dynamic>? emitted;
        await bridge.handleCommand({
          'command': 'get_session_history',
          'payload': {
            'request_id': 'req-steer-history',
            'session_id': sessionId,
          },
        }, (envelope) async => emitted = envelope);

        final messages = emitted?['payload']['messages'] as List;
        expect(messages.map((message) => message['type']), [
          'user_message',
          'tool_use',
          'tool_result',
          'user_message',
          'final_answer',
        ]);
        expect(messages[2]['output'], 'tool result');
        expect(messages[2], isNot(contains('content')));
        expect(messages[3]['content'], 'Change direction');
        expect(messages[3]['request_id'], 'steer-history-1');
        expect(messages[3]['metadata']['steer'], isTrue);
      },
    );

    test(
      'get_session_history preserves assistant output superseded by late steer as a thought',
      () async {
        final bridge = SanadProtocolBridge();
        final sessionManager = getIt<SessionManager>();
        const sessionId = 'session-late-steer-history';
        sessionManager.db.saveSession(
          SessionState(
            sessionId: sessionId,
            model: 'sanad-agent',
            createdAt: DateTime.parse('2026-07-02T10:00:00Z'),
            updatedAt: DateTime.parse('2026-07-02T10:06:00Z'),
          ),
        );
        sessionManager.saveSessionHistory(sessionId, [
          Message(role: MessageRole.user, content: 'Original request'),
          Message(
            role: MessageRole.assistant,
            content: 'Answer before steer',
            metadata: {'superseded_by_steer': true},
          ),
          Message(
            role: MessageRole.user,
            content: 'Revise the answer',
            metadata: {
              'steer': true,
              'request_id': 'steer-late-history-1',
              'received_at': '2026-07-02T10:05:00.000Z',
            },
          ),
          Message(role: MessageRole.assistant, content: 'Adjusted answer'),
        ]);

        Map<String, dynamic>? emitted;
        await bridge.handleCommand({
          'command': 'get_session_history',
          'payload': {
            'request_id': 'req-late-steer-history',
            'session_id': sessionId,
          },
        }, (envelope) async => emitted = envelope);

        final messages = emitted?['payload']['messages'] as List;
        expect(messages.map((message) => message['content']), [
          'Original request',
          'Answer before steer',
          'Revise the answer',
          'Adjusted answer',
        ]);
        expect(messages[1]['type'], 'thought');
        expect(messages[2]['request_id'], 'steer-late-history-1');
      },
    );
  });

  group('Workspace Policy Commands', () {
    test(
      'workspace.get_policy returns policy from WorkspacePolicyStore',
      () async {
        final bridge = SanadProtocolBridge();
        final policyStore = WorkspacePolicyStore();
        getIt.registerSingleton<WorkspacePolicyStore>(policyStore);

        final workspacePath = '${tempDir.path}/test_workspace';
        Directory(workspacePath).createSync();
        await policyStore.savePolicy(
          workspacePath,
          const WorkspacePolicy(
            permissionMode: WorkspacePermissionMode.fullAccess,
          ),
        );

        Map<String, dynamic>? emitted;
        final handled = await bridge.handleCommand(
          {
            'command': 'workspace.get_policy',
            'payload': {'request_id': 'req-1', 'workspace_path': workspacePath},
          },
          (envelope) async {
            emitted = envelope;
          },
        );

        expect(handled, isTrue);
        expect(emitted, isNotNull);
        expect(
          emitted?['event'],
          equals(CanonicalEventTypes.workspaceGetPolicy),
        );
        expect(emitted?['payload']['request_id'], equals('req-1'));
        expect(emitted?['payload']['permissionMode'], equals('full_access'));
      },
    );

    test(
      'workspace.set_permission_mode resolves the registered id and supports both modes',
      () async {
        final bridge = SanadProtocolBridge();
        final policyStore = WorkspacePolicyStore();
        getIt.registerSingleton<WorkspacePolicyStore>(policyStore);

        final workspacePath = '${tempDir.path}/test_workspace_2';
        Directory(workspacePath).createSync();
        final workspace = await getIt<LocalWorkspaceRuntimeService>()
            .createWorkspace(path: workspacePath);
        final forgedPath = '${tempDir.path}/forged_workspace';
        Directory(forgedPath).createSync();

        final List<Map<String, dynamic>> emittedEnvelopes = [];
        final handled = await bridge.handleCommand(
          {
            'command': 'workspace.set_permission_mode',
            'payload': {
              'request_id': 'req-2',
              'workspace_id': workspace['id'],
              'workspace_path': forgedPath,
              'permission_mode': 'full_access',
            },
          },
          (envelope) async {
            emittedEnvelopes.add(envelope);
          },
        );

        expect(handled, isTrue);
        expect(emittedEnvelopes, hasLength(2));

        // Broadcast first
        final broadcast = emittedEnvelopes[0];
        expect(
          broadcast['event'],
          equals(CanonicalEventTypes.workspacePolicyChanged),
        );
        expect(broadcast['payload']['workspace_id'], equals(workspace['id']));
        expect(
          broadcast['payload']['policy']['permissionMode'],
          equals('full_access'),
        );

        // Response second
        final response = emittedEnvelopes[1];
        expect(
          response['event'],
          equals(CanonicalEventTypes.workspaceSetPermissionMode),
        );
        expect(response['payload']['request_id'], equals('req-2'));
        expect(response['payload']['permissionMode'], equals('full_access'));

        // Verify stored on disk
        final policy = await policyStore.readPolicy(workspacePath);
        expect(
          policy.permissionMode,
          equals(WorkspacePermissionMode.fullAccess),
        );
        expect(
          WorkspacePolicyStore.settingsFileForWorkspace(
            forgedPath,
          ).existsSync(),
          isFalse,
        );

        emittedEnvelopes.clear();
        await bridge.handleCommand({
          'command': 'workspace.set_permission_mode',
          'payload': {
            'request_id': 'req-3',
            'workspace_id': workspace['id'],
            'permission_mode': 'default',
          },
        }, (envelope) async => emittedEnvelopes.add(envelope));

        expect(emittedEnvelopes, hasLength(2));
        expect(
          emittedEnvelopes.last['payload']['permissionMode'],
          equals('default'),
        );
        expect(
          (await policyStore.readPolicy(workspacePath)).permissionMode,
          WorkspacePermissionMode.defaultMode,
        );
      },
    );

    test(
      'workspace.set_permission_mode rejects an unknown workspace id',
      () async {
        final bridge = SanadProtocolBridge();
        final policyStore = WorkspacePolicyStore();
        getIt.registerSingleton<WorkspacePolicyStore>(policyStore);
        final forgedPath = '${tempDir.path}/unregistered_workspace';
        Directory(forgedPath).createSync();

        Map<String, dynamic>? emitted;
        final handled = await bridge.handleCommand({
          'command': 'workspace.set_permission_mode',
          'payload': {
            'request_id': 'req-unknown-workspace',
            'workspace_id': 'unknown-workspace-id',
            'workspace_path': forgedPath,
            'permission_mode': 'full_access',
          },
        }, (envelope) async => emitted = envelope);

        expect(handled, isTrue);
        expect(emitted?['event'], 'error');
        expect(
          emitted?['payload']['message'],
          contains('Workspace not found.'),
        );
        expect(
          WorkspacePolicyStore.settingsFileForWorkspace(
            forgedPath,
          ).existsSync(),
          isFalse,
        );
      },
    );
  });
}
