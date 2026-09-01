import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/conversations/data/mappers/unified_device_mapper.dart';
import 'package:sanad_client/features/conversations/data/transport/conversation_command_gateway.dart';
import 'package:sanad_client/features/conversations/data/transport/conversation_commands.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';
import 'package:sanad_client/features/conversations/domain/models/message_delivery_intent.dart';
import 'package:sanad_client/features/conversations/domain/models/device_suspended_request.dart';
import 'package:sanad_client/features/conversations/domain/models/runtime_notice.dart';
import 'package:sanad_client/features/conversations/domain/models/turn_replay_result.dart';
import 'package:sanad_client/features/conversations/domain/models/session_query.dart';
import 'package:sanad_client/features/conversations/domain/models/slash_command_entry.dart';
import 'package:sanad_client/features/conversations/domain/stores/device_conversation_store.dart';
import 'package:sanad_client/features/conversations/domain/models/workspace_tree_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../mocks/mock_socket_service.dart';

void main() {
  late FakeSanadSocketService socket;
  late SocketConversationCommandGateway gateway;
  late DeviceConversationStore store;
  late ConversationCommands commands;

  setUp(() {
    socket = FakeSanadSocketService()..setConnected(true);
    gateway = SocketConversationCommandGateway(
      config: DeviceConfig(id: 'agent-1', name: 'SanadAgent'),
      controller: socket,
    );
    store = DeviceConversationStore();
    commands = ConversationCommands(gateway: gateway, conversationStore: store, mapper: UnifiedDeviceMapper());
  });

  tearDown(() {
    gateway.dispose();
    store.dispose();
    socket.dispose();
  });

  test('sendMessage waits for the daemon user event and sends think command', () async {
    await commands.sendMessage('hello', sessionId: 'session-1');

    expect(store.currentMessages, isEmpty);
    expect(store.currentQueuedMessages, isEmpty);
    expect(store.isSessionProcessing('session-1'), isFalse);
    expect(socket.capturedCommands.single['command'], 'think');
    expect((socket.capturedCommands.single['payload'] as Map)['message'], 'hello');
  });

  test('deleteSession fails when the daemon does not confirm deletion', () async {
    socket.setConnected(false);

    await expectLater(
      commands.deleteSession('session-1'),
      throwsA(isA<StateError>()),
    );
  });

  test('sendMessage includes explicit message-scoped preferences when provided', () async {
    await commands.sendMessage(
      'hello',
      sessionId: 'session-1',
      workspaceId: 'workspace-1',
      context: '# Workspace context\n - Working directory: /repo',
      model: 'gpt-4o',
      thinkingMode: 'precise',
    );

    final payload = socket.capturedCommands.single['payload'] as Map<String, dynamic>;
    expect(payload['workspace_id'], 'workspace-1');
    expect(payload['context'], contains('Working directory'));
    expect(payload['model'], 'gpt-4o');
    expect(payload['thinking_mode'], 'precise');
  });

  test('replayTurn sends the current route and explicit safety confirmation', () async {
    final future = commands.replayTurn(
      sessionId: 'session-1',
      targetRequestId: 'target-1',
      targetMessageId: 'message-1',
      targetTurnId: 'turn-1',
      expectedHistoryRevision: 4,
      action: TurnReplayAction.edit,
      message: 'edited text',
      providerInstanceId: 'provider-current',
      modelId: 'model-current',
      thinkingMode: 'deep',
      confirmedReplayUnsafe: true,
    );

    final command = socket.capturedCommands.single;
    final payload = command['payload'] as Map<String, dynamic>;
    expect(command['command'], 'session.turn_replay');
    expect(payload['target_request_id'], 'target-1');
    expect(payload['target_message_id'], 'message-1');
    expect(payload['target_turn_id'], 'turn-1');
    expect(payload['expected_history_revision'], 4);
    expect(payload['provider_instance_id'], 'provider-current');
    expect(payload['model_id'], 'model-current');
    expect(payload['thinking_mode'], 'deep');
    expect(payload['confirmed_replay_unsafe'], isTrue);
    expect(payload['confirmed_drop_steers'], isFalse);

    socket.eventRouter.routeEvent({
      'device_id': 'agent-1',
      'event': 'session.turn_replay_result',
      'payload': {
        'request_id': payload['request_id'],
        'outcome': 'accepted',
        'replay_safety': 'unsafe',
        'requires_confirmation': false,
      },
    });

    final result = await future;
    expect(result.isAccepted, isTrue);
    expect(result.safety, TurnReplaySafety.unsafe);
  });

  test('forkSession sends target identity only and returns the child', () async {
    final future = commands.forkSession(
      sessionId: 'session-1',
      targetMessageId: 'm-final',
      targetTurnId: 'turn-2',
    );

    final command = socket.capturedCommands.single;
    final payload = command['payload'] as Map<String, dynamic>;
    expect(command['command'], 'session.fork');
    expect(payload['session_id'], 'session-1');
    expect(payload['target_message_id'], 'm-final');
    expect(payload['target_turn_id'], 'turn-2');
    expect(payload.containsKey('messages'), isFalse);

    socket.eventRouter.routeEvent({
      'device_id': 'agent-1',
      'event': 'session.fork_result',
      'payload': {
        'request_id': payload['request_id'],
        'outcome': 'accepted',
        'child': {
          'session_id': 'child-1',
          'title': '(1) Refactor auth',
          'created_at': '2026-08-30T00:00:00Z',
          'updated_at': '2026-08-30T00:00:00Z',
        },
      },
    });

    final result = await future;
    expect(result.isAccepted, isTrue);
    expect(result.child?.id, 'child-1');
    expect(result.child?.title, '(1) Refactor auth');
    expect(result.child?.deviceId, 'agent-1');
  });

  test('getWorkspaces requests available workspaces', () async {
    final future = commands.getWorkspaces();

    expect(socket.capturedCommands.single['command'], 'list_workspaces');
    final payload = socket.capturedCommands.single['payload'] as Map<String, dynamic>;
    socket.eventRouter.routeEvent({
      'device_id': 'agent-1',
      'event': 'workspaces_list',
      'payload': {
        'request_id': payload['request_id'],
        'workspaces': [
          {
            'id': 'workspace-1',
            'name': 'desktop-agent',
            'path': '/repo',
            'trust_state': 'trusted',
          },
        ],
      },
    });

    final workspaces = await future;

    expect(workspaces, hasLength(1));
    expect(workspaces.single.id, 'workspace-1');
    expect(workspaces.single.path, '/repo');
  });

  test('concurrent session queries use unique ids and match out-of-order responses', () async {
    final futures = [
      commands.getSessions(
        query: SessionQueryRequest(workspaceId: 'workspace-1', limit: 6),
      ),
      commands.getSessions(
        query: SessionQueryRequest(workspaceId: 'workspace-2', limit: 6),
      ),
      commands.getSessions(
        query: SessionQueryRequest(unscopedOnly: true, limit: 6),
      ),
    ];

    expect(socket.capturedCommands, hasLength(3));
    final requestIds = socket.capturedCommands
        .map((command) => (command['payload'] as Map<String, dynamic>)['request_id'] as String)
        .toList(growable: false);
    expect(requestIds.toSet(), hasLength(requestIds.length));

    for (final command in socket.capturedCommands.reversed) {
      final payload = command['payload'] as Map<String, dynamic>;
      final workspaceId = payload['workspace_id'] as String?;
      final sectionId = workspaceId ?? 'unscoped';
      socket.eventRouter.routeEvent({
        'device_id': 'agent-1',
        'event': 'sessions_list',
        'payload': {
          'request_id': payload['request_id'],
          'sessions': [
            {
              'id': 'session-$sectionId',
              'title': sectionId,
              if (workspaceId != null) 'workspace_id': workspaceId,
            },
          ],
        },
      });
    }

    final results = await Future.wait(futures);
    expect(results[0].sessions.single.id, 'session-workspace-1');
    expect(results[1].sessions.single.id, 'session-workspace-2');
    expect(results[2].sessions.single.id, 'session-unscoped');
  });

  test('searchSlashCommands requests runtime-owned slash suggestions', () async {
    final future = commands.searchSlashCommands(query: 'tes', workspaceId: 'workspace-1');

    expect(socket.capturedCommands.single['command'], 'search_slash_commands');
    final payload = socket.capturedCommands.single['payload'] as Map<String, dynamic>;
    expect(payload['query'], 'tes');
    expect(payload['workspace_id'], 'workspace-1');
    socket.eventRouter.routeEvent({
      'device_id': 'agent-1',
      'event': 'slash_commands_list',
      'payload': {
        'request_id': payload['request_id'],
        'commands': [
          {
            'command': 'test-sanad-plugin',
            'description': 'Prompts the model to test a plugin',
            'source': 'skill',
            'type': 'skill',
          },
          {
            'command': 'compact',
            'description': 'Compact conversation context',
            'source': 'sanad-agent',
            'type': 'runtime_action',
          },
          {
            'command': 'future-command',
            'source': 'sanad-agent',
            'type': 'unknown_future_type',
          },
        ],
      },
    });

    final commandsList = await future;

    expect(commandsList, hasLength(2));
    expect(commandsList.first.command, 'test-sanad-plugin');
    expect(commandsList.first.sourceId, 'skill');
    expect(commandsList.last.type, SlashCommandType.runtimeAction);
    expect(commandsList.last.invocationText, '/compact');
  });

  test('browseWorkspaceTree requests runtime-owned file tree data', () async {
    final future = commands.browseWorkspaceTree(path: '/repo/apps');

    expect(socket.capturedCommands.single['command'], 'browse_workspace_tree');
    final payload = socket.capturedCommands.single['payload'] as Map<String, dynamic>;
    expect(payload['path'], '/repo/apps');
    socket.eventRouter.routeEvent({
      'device_id': 'agent-1',
      'event': 'workspace_tree',
      'payload': {
        'request_id': payload['request_id'],
        'workspace_id': '/repo',
        'root_path': '/repo',
        'path': '/repo/apps',
        'parent_path': '/repo',
        'entries': [
          {
            'name': 'sanad-client',
            'path': '/repo/apps/sanad-client',
            'relative_path': 'apps/sanad-client',
            'type': 'directory',
            'size': 0,
          },
        ],
        'truncated': false,
      },
    });

    final snapshot = await future;

    expect(snapshot, isA<WorkspaceTreeSnapshot>());
    expect(snapshot.path, '/repo/apps');
    expect(snapshot.parentPath, '/repo');
    expect(snapshot.entries.single.name, 'sanad-client');
    expect(snapshot.entries.single.isDirectory, isTrue);
  });

  test('createWorkspace sends a name without a path for managed remote create', () async {
    final future = commands.createWorkspace(name: 'remote-notes');

    expect(socket.capturedCommands.single['command'], 'create_workspace');
    final payload = socket.capturedCommands.single['payload'] as Map<String, dynamic>;
    expect(payload.containsKey('path'), isFalse);
    expect(payload['name'], 'remote-notes');
    socket.eventRouter.routeEvent({
      'device_id': 'agent-1',
      'event': 'workspace_created',
      'payload': {
        'request_id': payload['request_id'],
        'workspace': {
          'id': 'workspace-2',
          'name': 'remote-notes',
          'path': '/home/sanad/workspaces/remote-notes',
          'trust_state': 'trusted',
        },
      },
    });

    final workspace = await future;
    expect(workspace.id, 'workspace-2');
    expect(workspace.name, 'remote-notes');
  });

  test('createWorkspace sends path and returns the created workspace', () async {
    final future = commands.createWorkspace(path: '/repo', name: 'desktop-agent');

    expect(socket.capturedCommands.single['command'], 'create_workspace');
    final payload = socket.capturedCommands.single['payload'] as Map<String, dynamic>;
    expect(payload['path'], '/repo');
    expect(payload['name'], 'desktop-agent');
    socket.eventRouter.routeEvent({
      'device_id': 'agent-1',
      'event': 'workspace_created',
      'payload': {
        'request_id': payload['request_id'],
        'workspace': {
          'id': 'workspace-1',
          'name': 'desktop-agent',
          'path': '/repo',
          'trust_state': 'trusted',
        },
      },
    });

    final workspace = await future;

    expect(workspace.id, 'workspace-1');
    expect(workspace.name, 'desktop-agent');
  });

  test('workspace relocation surfaces the correlated daemon error', () async {
    final future = commands.relocateWorkspace(
      workspaceId: 'workspace-1',
      newPath: '/repo/already-connected',
    );
    final payload = socket.capturedCommands.single['payload'] as Map<String, dynamic>;
    socket.eventRouter.routeEvent({
      'device_id': 'agent-1',
      'event': 'error',
      'payload': {
        'request_id': payload['request_id'],
        'message': 'That folder is already connected to another workspace.',
      },
    });

    await expectLater(
      future,
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'That folder is already connected to another workspace.',
        ),
      ),
    );
  });

  test('folder mutations send exact payloads and require matching acknowledgments', () async {
    final createFuture = commands.createFolder(
      parentPath: ' /repo ',
      name: ' child ',
    );
    var command = socket.capturedCommands.single;
    var payload = command['payload'] as Map<String, dynamic>;
    expect(command['command'], 'workspace.create_folder');
    expect(payload['parent_path'], '/repo');
    expect(payload['name'], 'child');
    socket.eventRouter.routeEvent({
      'device_id': 'agent-1',
      'event': 'workspace.folder_created',
      'payload': {
        'request_id': payload['request_id'],
        'path': '/repo/child',
      },
    });
    await createFuture;

    socket.clearCaptured();
    final renameFuture = commands.renameFolder(
      path: '/repo/child',
      newName: 'renamed',
    );
    command = socket.capturedCommands.single;
    payload = command['payload'] as Map<String, dynamic>;
    expect(command['command'], 'workspace.rename_folder');
    expect(payload['path'], '/repo/child');
    expect(payload['new_name'], 'renamed');
    socket.eventRouter.routeEvent({
      'device_id': 'agent-1',
      'event': 'workspace.folder_renamed',
      'payload': {
        'request_id': payload['request_id'],
        'path': '/repo/renamed',
      },
    });
    await renameFuture;

    socket.clearCaptured();
    final deleteFuture = commands.deleteFolder(path: '/repo/renamed');
    command = socket.capturedCommands.single;
    payload = command['payload'] as Map<String, dynamic>;
    expect(command['command'], 'workspace.delete_folder');
    expect(payload['path'], '/repo/renamed');
    socket.eventRouter.routeEvent({
      'device_id': 'agent-1',
      'event': 'workspace.folder_deleted',
      'payload': {
        'request_id': payload['request_id'],
        'path': '/repo/renamed',
      },
    });
    await deleteFuture;
  });

  test('workspace removal requires the matching record-only acknowledgment', () async {
    final future = commands.removeWorkspace(workspaceId: ' workspace-1 ');
    final command = socket.capturedCommands.single;
    final payload = command['payload'] as Map<String, dynamic>;
    expect(command['command'], 'workspace.remove');
    expect(payload['workspace_id'], 'workspace-1');

    socket.eventRouter.routeEvent({
      'device_id': 'agent-1',
      'event': 'workspace.removed',
      'payload': {
        'request_id': payload['request_id'],
        'workspace_id': 'workspace-1',
      },
    });

    await future;
  });

  test('folder mutation surfaces daemon errors and disconnected requests', () async {
    final future = commands.createFolder(parentPath: '/repo', name: 'taken');
    final payload = socket.capturedCommands.single['payload'] as Map<String, dynamic>;
    socket.eventRouter.routeEvent({
      'device_id': 'agent-1',
      'event': 'error',
      'payload': {
        'request_id': payload['request_id'],
        'message': 'A folder with that name already exists.',
      },
    });

    await expectLater(
      future,
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('already exists'),
        ),
      ),
    );

    socket.setConnected(false);
    await expectLater(
      commands.deleteFolder(path: '/repo/taken'),
      throwsA(isA<StateError>()),
    );
  });

  test('createSession sends placeholder ownership and returns the created session', () async {
    final future = commands.createSession(
      title: 'Created',
      isTitlePlaceholder: true,
      workspaceId: 'workspace-1',
    );

    expect(socket.capturedCommands.single['command'], 'create_session');
    final payload = socket.capturedCommands.single['payload'] as Map<String, dynamic>;
    expect(payload['title'], 'Created');
    expect(payload['title_is_placeholder'], isTrue);
    expect(payload['workspace_id'], 'workspace-1');
    socket.eventRouter.routeEvent({
      'device_id': 'agent-1',
      'event': 'session_created',
      'payload': {
        'request_id': payload['request_id'],
        'session_id': 'session-1',
        'title': 'Created',
        'device_id': 'agent-1',
        'workspace_id': 'workspace-1',
        'workspace_name': 'desktop-agent',
        'workspace_path': '/repo',
        'created_at': '2026-01-01T00:00:00Z',
      },
    });

    final session = await future;

    expect(session.id, 'session-1');
    expect(session.workspaceId, 'workspace-1');
  });

  test('sendMessage creates a stable session id for a new conversation', () async {
    await commands.sendMessage('first draft message');

    final firstPayload = socket.capturedCommands.single['payload'] as Map<String, dynamic>;
    final generatedSessionId = firstPayload['session_id'] as String?;

    expect(generatedSessionId, isNotNull);
    expect(generatedSessionId, isNotEmpty);
    expect(store.currentMessages, isEmpty);
    expect(store.currentSessionId, generatedSessionId);
  });

  test('sendMessage reuses generated session id until server confirms the session', () async {
    await commands.sendMessage('first draft message');
    final firstPayload = socket.capturedCommands.single['payload'] as Map<String, dynamic>;
    final generatedSessionId = firstPayload['session_id'] as String;

    await commands.sendMessage('second draft message');

    final secondPayload = socket.capturedCommands.last['payload'] as Map<String, dynamic>;
    expect(secondPayload['session_id'], generatedSessionId);
    expect(store.currentMessages, isEmpty);
  });

  test('sendMessage leaves busy-session classification to the daemon', () async {
    await commands.sendMessage('first message', sessionId: 'session-1');
    socket.clearCaptured();

    await commands.sendMessage('second message while busy', sessionId: 'session-1');

    expect(store.currentMessages, isEmpty);
    expect(store.currentQueuedMessages, isEmpty);
    final payload = socket.capturedCommands.single['payload'] as Map<String, dynamic>;
    expect(payload, isNot(contains('mode')));
  });

  test('sendMessage sends explicit queue intent while session is busy', () async {
    await commands.sendMessage('first message', sessionId: 'session-1');
    socket.clearCaptured();

    await commands.sendMessage(
      'queued follow-up message',
      sessionId: 'session-1',
      intent: MessageDeliveryIntent.queue,
    );

    expect(store.currentMessages, isEmpty);
    expect(store.currentQueuedMessages, isEmpty);
    final payload = socket.capturedCommands.single['payload'] as Map<String, dynamic>;
    expect(payload['delivery_intent'], 'queue');
  });

  test('stop uses generated session id for a new conversation', () async {
    await commands.sendMessage('first draft message');
    final thinkPayload = socket.capturedCommands.single['payload'] as Map<String, dynamic>;
    final generatedSessionId = thinkPayload['session_id'] as String;

    await commands.stop();

    expect(socket.capturedCommands.last['command'], 'stop');
    expect((socket.capturedCommands.last['payload'] as Map<String, dynamic>)['session_id'], generatedSessionId);
    expect(store.isCurrentConversationProcessing, isTrue);
  });

  test('loadSessionHistory requests history and updates the conversation store', () async {
    final future = commands.loadSessionHistory('session-1');

    expect(socket.capturedCommands.single['command'], 'get_session_history');
    final payload = socket.capturedCommands.single['payload'] as Map<String, dynamic>;
    socket.eventRouter.routeEvent({
      'device_id': 'agent-1',
      'event': 'session_history',
      'payload': {
        'request_id': payload['request_id'],
        'messages': [
          {
            'id': 1,
            'sender': 'ai',
            'type': 'final_answer',
            'content': 'done',
            'created_at': '2026-01-01T00:00:00Z',
          },
        ],
      },
    });

    final history = await future;

    expect(history, hasLength(1));
    expect(store.currentMessages.single.kind, EventKind.finalAnswer);
    expect(store.currentMessages.single.text, 'done');
  });

  test('loadOlderSessionHistory coalesces and prepends stable unique events', () async {
    final initial = commands.loadSessionHistory('session-1');
    final initialPayload = socket.capturedCommands.single['payload'] as Map<String, dynamic>;
    socket.eventRouter.routeEvent({
      'device_id': 'agent-1',
      'event': 'session_history',
      'payload': {
        'request_id': initialPayload['request_id'],
        'has_more': true,
        'next_cursor': 'cursor-1',
        'messages': [
          {
            'id': 'history:session-1:2:user_message:0',
            'event_id': 'history:session-1:2:user_message:0',
            'type': 'user_message',
            'content': 'newer',
            'created_at': '2026-01-02T00:00:00Z',
          },
        ],
      },
    });
    await initial;
    socket.clearCaptured();

    final first = commands.loadOlderSessionHistory('session-1');
    final second = commands.loadOlderSessionHistory('session-1');

    expect(socket.capturedCommands, hasLength(1));
    final olderPayload = socket.capturedCommands.single['payload'] as Map<String, dynamic>;
    expect(olderPayload['cursor'], 'cursor-1');
    socket.eventRouter.routeEvent({
      'device_id': 'agent-1',
      'event': 'session_history',
      'payload': {
        'request_id': olderPayload['request_id'],
        'has_more': false,
        'messages': [
          {
            'id': 'history:session-1:1:user_message:0',
            'event_id': 'history:session-1:1:user_message:0',
            'type': 'user_message',
            'content': 'older',
            'created_at': '2026-01-01T00:00:00Z',
          },
          {
            'id': 'history:session-1:2:user_message:0',
            'event_id': 'history:session-1:2:user_message:0',
            'type': 'user_message',
            'content': 'newer duplicate',
            'created_at': '2026-01-02T00:00:00Z',
          },
        ],
      },
    });
    await Future.wait([first, second]);

    expect(store.currentMessages.map((event) => event.text), ['older', 'newer']);
    expect(store.historyHasMore, isFalse);
    expect(store.historyNextCursor, isNull);
  });

  test('anchored history sends the stable event id and replaces only on success', () async {
    final tail = commands.loadSessionHistory('session-1');
    var payload = socket.capturedCommands.single['payload'] as Map<String, dynamic>;
    socket.eventRouter.routeEvent({
      'device_id': 'agent-1',
      'event': 'session_history',
      'payload': {
        'request_id': payload['request_id'],
        'messages': [_historyRow('tail', 'tail')],
      },
    });
    await tail;
    socket.clearCaptured();

    final anchored = commands.loadAnchoredSessionHistory(
      'session-1',
      'history:session-1:42:user_message:0',
    );
    payload = socket.capturedCommands.single['payload'] as Map<String, dynamic>;
    expect(payload['anchor_event_id'], 'history:session-1:42:user_message:0');
    socket.eventRouter.routeEvent({
      'device_id': 'agent-1',
      'event': 'session_history',
      'payload': {
        'request_id': payload['request_id'],
        'page_kind': 'anchor',
        'messages': [_historyRow('anchor', 'anchored')],
      },
    });
    await anchored;

    expect(store.currentMessages.single.text, 'anchored');
  });

  test('older no-progress cursor exhausts pagination without a request loop', () async {
    final initial = commands.loadSessionHistory('session-1');
    var payload = socket.capturedCommands.single['payload'] as Map<String, dynamic>;
    socket.eventRouter.routeEvent({
      'device_id': 'agent-1',
      'event': 'session_history',
      'payload': {
        'request_id': payload['request_id'],
        'has_more': true,
        'next_cursor': 'same-cursor',
        'messages': [_historyRow('new', 'new')],
      },
    });
    await initial;
    socket.clearCaptured();

    final older = commands.loadOlderSessionHistory('session-1');
    payload = socket.capturedCommands.single['payload'] as Map<String, dynamic>;
    socket.eventRouter.routeEvent({
      'device_id': 'agent-1',
      'event': 'session_history',
      'payload': {
        'request_id': payload['request_id'],
        'has_more': true,
        'next_cursor': 'same-cursor',
        'messages': const [],
      },
    });
    await older;

    expect(store.historyHasMore, isFalse);
    socket.clearCaptured();
    await commands.loadOlderSessionHistory('session-1');
    expect(socket.capturedCommands, isEmpty);
  });

  test('loadSessionHistory restores in-flight snapshot and preserves newer live chunks', () async {
    final future = commands.loadSessionHistory('session-1');

    final payload = socket.capturedCommands.single['payload'] as Map<String, dynamic>;

    store.apply(
      CanonicalEvent(
        id: 'thinking_run-1',
        kind: EventKind.thinking,
        text: ' world',
        status: EventStatus.running,
        timestamp: DateTime.now(),
        sessionId: 'session-1',
        runId: 'run-1',
      ),
    );

    socket.eventRouter.routeEvent({
      'device_id': 'agent-1',
      'event': 'session_history',
      'payload': {
        'request_id': payload['request_id'],
        'messages': [],
        'execution_snapshot': {
          'session_id': 'session-1',
          'state': 'running',
          'work_item_id': 'work-1',
          'request_id': 'request-1',
          'revision': 1,
          'updated_at': '2026-07-15T10:30:00Z',
        },
        'in_flight': {
          'type': 'thought_stream',
          'session_id': 'session-1',
          'run_id': 'run-1',
          'content': 'Hello',
          'timestamp': '2026-01-01T00:00:00Z',
        },
      },
    });

    await future;

    expect(store.currentMessages.single.kind, EventKind.thinking);
    expect(store.currentMessages.single.status, EventStatus.running);
    expect(store.currentMessages.single.text, 'Hello world');
    expect(store.isCurrentConversationProcessing, isTrue);
  });

  test('loadSessionHistory preserves a live terminal tool over stale running history', () async {
    final future = commands.loadSessionHistory('session-1');
    final payload = socket.capturedCommands.single['payload'] as Map<String, dynamic>;

    store.apply(
      CanonicalEvent(
        id: 'tool_call-1',
        kind: EventKind.toolCall,
        status: EventStatus.done,
        tool: const {
          'name': 'file_read',
          'output': 'fresh completed output',
        },
        timestamp: DateTime.parse('2026-08-14T12:00:01Z'),
        sessionId: 'session-1',
        runId: 'run-1',
        toolCallId: 'call-1',
      ),
    );

    socket.eventRouter.routeEvent({
      'device_id': 'agent-1',
      'event': 'session_history',
      'payload': {
        'request_id': payload['request_id'],
        'messages': [
          {
            'id': 1,
            'type': 'tool_call',
            'status': 'running',
            'tool_call_id': 'call-1',
            'run_id': 'run-1',
            'session_id': 'session-1',
            'tool': {
              'name': 'file_read',
              'input': {'path': 'README.md'},
            },
            'created_at': '2026-08-14T12:00:00Z',
          },
        ],
      },
    });

    await future;

    expect(store.currentMessages, hasLength(1));
    final tool = store.currentMessages.single;
    expect(tool.status, EventStatus.done);
    expect(tool.toolInput, {'path': 'README.md'});
    expect(tool.toolOutput, 'fresh completed output');
  });

  test('loadSessionHistory hydrates the durable cancelled projection', () async {
    final future = commands.loadSessionHistory('session-1');
    final payload = socket.capturedCommands.single['payload'] as Map<String, dynamic>;

    socket.eventRouter.routeEvent({
      'device_id': 'agent-1',
      'event': 'session_history',
      'payload': {
        'request_id': payload['request_id'],
        'messages': [
          {
            'id': 1,
            'type': 'tool_use',
            'tool': 'shell_execute',
            'input': {'command': 'sleep 30'},
            'tool_call_id': 'call-cancelled',
            'model_step_id': 'step-1',
            'run_id': 'run-1',
            'session_id': 'session-1',
            'created_at': '2026-08-29T00:00:00Z',
          },
          {
            'id': 2,
            'type': 'tool_result',
            'tool': 'shell_execute',
            'output': 'Command cancelled by user.',
            'status': 'cancelled',
            'tool_call_id': 'call-cancelled',
            'model_step_id': 'step-1',
            'run_id': 'run-1',
            'session_id': 'session-1',
            'generation': 6,
            'revision': 60,
            'reason': 'user_stop',
            'started_at': '2026-08-29T00:00:00Z',
            'terminal_at': '2026-08-29T00:00:01Z',
            'cleanup_outcome': 'completed',
            'created_at': '2026-08-29T00:00:01Z',
          },
        ],
      },
    });

    final history = await future;
    final tool = history.single;
    expect(tool.status, EventStatus.cancelled);
    expect(tool.toolInput, {'command': 'sleep 30'});
    expect(tool.toolOutput, 'Command cancelled by user.');
    expect(tool.generation, 6);
    expect(tool.revision, 60);
    expect(tool.metadata, containsPair('reason', 'user_stop'));
    expect(tool.metadata, containsPair('cleanup_outcome', 'completed'));
  });

  test('loadSessionHistory reapplies a newer live terminal revision', () async {
    final future = commands.loadSessionHistory('session-1');
    final payload = socket.capturedCommands.single['payload'] as Map<String, dynamic>;

    store.apply(
      CanonicalEvent(
        id: 'tool_call-1',
        kind: EventKind.toolCall,
        status: EventStatus.cancelled,
        tool: const {
          'name': 'shell_execute',
          'output': 'Command cancelled by user.',
        },
        timestamp: DateTime.parse('2026-08-29T00:00:02Z'),
        sessionId: 'session-1',
        runId: 'run-1',
        toolCallId: 'call-1',
        metadata: const {'generation': 3, 'revision': 30},
      ),
    );

    socket.eventRouter.routeEvent({
      'device_id': 'agent-1',
      'event': 'session_history',
      'payload': {
        'request_id': payload['request_id'],
        'messages': [
          {
            'id': 1,
            'type': 'tool_result',
            'tool': 'shell_execute',
            'output': 'older timeout',
            'status': 'error',
            'tool_call_id': 'call-1',
            'run_id': 'run-1',
            'session_id': 'session-1',
            'generation': 3,
            'revision': 29,
            'created_at': '2026-08-29T00:00:01Z',
          },
        ],
      },
    });

    final history = await future;
    expect(history.single.status, EventStatus.cancelled);
    expect(history.single.toolOutput, 'Command cancelled by user.');
    expect(history.single.revision, 30);
  });

  test('loadSessionHistory does not duplicate a live user message already persisted', () async {
    final sentAt = DateTime.parse('2026-07-12T04:48:20Z');
    store.activateSession('session-1');
    store.apply(
      CanonicalEvent(
        id: 'user_request-2',
        kind: EventKind.userMessage,
        text: 'Restart the agent',
        timestamp: sentAt,
        sessionId: 'session-1',
        metadata: const {'request_id': 'request-2'},
      ),
    );

    final future = commands.loadSessionHistory('session-1');
    final payload = socket.capturedCommands.single['payload'] as Map<String, dynamic>;
    socket.eventRouter.routeEvent({
      'device_id': 'agent-1',
      'event': 'session_history',
      'payload': {
        'request_id': payload['request_id'],
        'messages': [
          {
            'id': 2,
            'sender': 'user',
            'type': 'user_message',
            'content': 'Restart the agent',
            'created_at': sentAt.toIso8601String(),
          },
        ],
      },
    });

    await future;

    expect(
      store.currentMessages.where(
        (event) => event.kind == EventKind.userMessage,
      ),
      hasLength(1),
    );
  });

  test('stop sends the active session id for the current conversation only', () async {
    await commands.sendMessage('hello', sessionId: 'session-1');
    store.applyExecutionPayload({
      'session_id': 'session-1',
      'state': 'running',
      'work_item_id': 'work-1',
      'request_id': 'request-1',
      'revision': 1,
      'updated_at': '2026-07-15T10:30:00Z',
    });
    await commands.stop(sessionId: 'session-1');

    expect(socket.capturedCommands.last['command'], 'stop');
    expect((socket.capturedCommands.last['payload'] as Map<String, dynamic>)['session_id'], 'session-1');
    expect(store.isCurrentConversationProcessing, isTrue);
  });

  test('stop and recovery ack keep user ownership token separate from request identity', () async {
    store.applyExecutionPayload({
      'session_id': 'session-1',
      'state': 'running',
      'work_item_id': 'work-1',
      'request_id': 'request-1',
      'revision': 1,
      'updated_at': '2026-07-15T10:30:00Z',
    });
    await commands.stop(
      sessionId: 'session-1',
      requestId: 'stop-1',
      recoveryOwnerToken: 'owner-secret-1',
    );
    await commands.acknowledgeStopRecovery(
      sessionId: 'session-1',
      stopRequestId: 'stop-1',
      recoveryOwnerToken: 'owner-secret-1',
    );

    expect((socket.capturedCommands.first['payload'] as Map)['request_id'], 'stop-1');
    expect(
      (socket.capturedCommands.first['payload'] as Map)['recovery_owner_token'],
      'owner-secret-1',
    );
    final ack = socket.capturedCommands.last;
    expect(ack['command'], 'session.stop_recovery_ack');
    expect(ack['payload'], {
      'session_id': 'session-1',
      'stop_request_id': 'stop-1',
      'recovery_owner_token': 'owner-secret-1',
    });
  });

  test('daemon restart recovery ack sends claimant_id without a user owner token', () async {
    await commands.acknowledgeStopRecovery(
      sessionId: 'session-1',
      stopRequestId: 'restart-stop-1',
      claimantId: 'claim-1',
    );

    final ack = socket.capturedCommands.single;
    expect(ack['command'], 'session.stop_recovery_ack');
    expect(ack['payload'], {
      'session_id': 'session-1',
      'stop_request_id': 'restart-stop-1',
      'claimant_id': 'claim-1',
    });
  });

  test('stop remains available during runtime waiting even when processing is already false', () async {
    store.activateSession('session-1');
    store.setRuntimeNotice(
      const RuntimeNotice(
        sessionId: 'session-1',
        requestId: 'req-wait',
        status: 'waiting',
        reason: 'provider_rate_limit',
        title: 'Rate limit reached',
        actions: ['stop'],
      ),
    );

    await commands.stop(sessionId: 'session-1');

    expect(socket.capturedCommands.last['command'], 'stop');
    expect((socket.capturedCommands.last['payload'] as Map<String, dynamic>)['session_id'], 'session-1');
    expect(store.currentRuntimeNotice?.status, 'waiting');
  });

  test('claimStopRecovery sends the stable stop id and returns the claim owner id', () async {
    final claimId = await commands.claimStopRecovery(
      sessionId: 'session-1',
      stopRequestId: 'restart-stop-1',
      commandRequestId: 'claim-owner-1',
    );

    expect(claimId, 'claim-owner-1');
    final command = socket.capturedCommands.single;
    expect(command['command'], 'session.stop_recovery_claim');
    expect(command['payload'], {
      'session_id': 'session-1',
      'stop_request_id': 'restart-stop-1',
      'command_request_id': claimId,
    });
  });

  test('retryRuntimeNotice sends provider_instance_id and model_id when present', () async {
    await commands.retryRuntimeNotice(
      sessionId: 'session-1',
      requestId: 'req-1',
      providerInstanceId: 'provider-2',
      modelId: 'glm-5.2',
    );

    final envelope = socket.capturedCommands.single;
    expect(envelope['device_id'], 'agent-1');
    expect(envelope['command'], 'session.runtime_retry');
    expect(envelope['payload'], {
      'session_id': 'session-1',
      'request_id': 'req-1',
      'provider_instance_id': 'provider-2',
      'model_id': 'glm-5.2',
    });
  });

  test('continueWithProvider sends provider_instance_id and model_id atomically', () async {
    await commands.continueWithProvider(
      sessionId: 'session-1',
      providerInstanceId: 'provider-2',
      requestId: 'req-2',
      modelId: 'glm-5.2',
    );

    final envelope = socket.capturedCommands.single;
    expect(envelope['device_id'], 'agent-1');
    expect(envelope['command'], 'session.runtime_continue_with_provider');
    expect(envelope['payload'], {
      'session_id': 'session-1',
      'provider_instance_id': 'provider-2',
      'request_id': 'req-2',
      'model_id': 'glm-5.2',
    });
  });

  test('loadSessionHistory restores a pending permission request', () async {
    final future = commands.loadSessionHistory('session-1');

    final payload = socket.capturedCommands.single['payload'] as Map<String, dynamic>;
    socket.eventRouter.routeEvent({
      'device_id': 'agent-1',
      'event': 'session_history',
      'payload': {
        'request_id': payload['request_id'],
        'messages': const [],
        'pending_permission_request': {
          'request_id': 'permission-1',
          'session_id': 'session-1',
          'tool_name': 'shell_execute',
          'permission_class': 'shell_execution',
          'scope': 'workspace',
          'workspace_id': 'workspace-1',
          'workspace_name': 'desktop-agent',
          'workspace_path': '/repo',
          'tool_input': {'command': 'echo hello'},
          'tool': {'name': 'shell_execute'},
        },
      },
    });

    await future;

    expect(store.currentPendingSuspendedRequest, isNotNull);
    expect(store.currentPendingSuspendedRequest?.requestId, 'permission-1');
  });

  test('loadSessionHistory restores runtime_notice and queued_messages from the daemon snapshot', () async {
    final future = commands.loadSessionHistory('session-1');

    final payload = socket.capturedCommands.single['payload'] as Map<String, dynamic>;
    socket.eventRouter.routeEvent({
      'device_id': 'agent-1',
      'event': 'session_history',
      'payload': {
        'request_id': payload['request_id'],
        'messages': const [],
        'queued_messages': [
          {
            'type': 'user_message',
            'content': 'Queued after wait',
            'session_id': 'session-1',
            'metadata': {
              'queued': true,
              'request_id': 'req-queued',
            },
            'timestamp': '2026-01-01T00:00:00Z',
          },
        ],
        'runtime_notice': {
          'session_id': 'session-1',
          'request_id': 'req-wait',
          'status': 'waiting',
          'reason': 'provider_rate_limit',
          'title': 'NVIDIA NIM rate limit reached',
          'retry_after_ms': 24000,
          'actions': ['stop', 'continue_with_provider'],
        },
      },
    });

    await future;

    expect(store.currentRuntimeNotice?.title, 'NVIDIA NIM rate limit reached');
    expect(store.currentRuntimeNotice?.status, 'waiting');
    expect(store.currentQueuedMessages, hasLength(1));
    expect(store.currentQueuedMessages.single.metadata?['request_id'], 'req-queued');
  });

  test('loadSessionHistory ignores a stale response after the user switches to another session', () async {
    final futureA = commands.loadSessionHistory('session-a');
    final requestA = socket.capturedCommands.last['payload'] as Map<String, dynamic>;

    final futureB = commands.loadSessionHistory('session-b');
    final requestB = socket.capturedCommands.last['payload'] as Map<String, dynamic>;

    socket.eventRouter.routeEvent({
      'device_id': 'agent-1',
      'event': 'session_history',
      'payload': {
        'request_id': requestB['request_id'],
        'messages': [
          {
            'id': 1,
            'sender': 'ai',
            'type': 'final_answer',
            'content': 'session B',
            'created_at': '2026-01-01T00:00:00Z',
            'session_id': 'session-b',
          },
        ],
        'queued_messages': [
          {
            'type': 'user_message',
            'content': 'queued B',
            'session_id': 'session-b',
            'metadata': {'queued': true, 'request_id': 'req-b'},
          },
        ],
        'runtime_notice': {
          'session_id': 'session-b',
          'request_id': 'notice-b',
          'status': 'waiting',
          'reason': 'provider_rate_limit',
          'title': 'Waiting B',
          'actions': ['stop'],
        },
      },
    });
    await futureB;

    socket.eventRouter.routeEvent({
      'device_id': 'agent-1',
      'event': 'session_history',
      'payload': {
        'request_id': requestA['request_id'],
        'messages': [
          {
            'id': 1,
            'sender': 'ai',
            'type': 'final_answer',
            'content': 'stale A',
            'created_at': '2026-01-01T00:00:00Z',
            'session_id': 'session-a',
          },
        ],
        'queued_messages': const [],
      },
    });
    await futureA;

    expect(store.currentSessionId, 'session-b');
    expect(store.currentMessages.single.text, 'session B');
    expect(store.currentQueuedMessages.single.text, 'queued B');
    expect(store.currentRuntimeNotice?.title, 'Waiting B');
  });

  test('loadSessionHistory rejects an older generation for the same session', () async {
    final olderFuture = commands.loadSessionHistory('session-1');
    final olderRequest = socket.capturedCommands.last['payload'] as Map<String, dynamic>;
    final newerFuture = commands.loadSessionHistory('session-1');
    final newerRequest = socket.capturedCommands.last['payload'] as Map<String, dynamic>;

    socket.eventRouter.routeEvent({
      'device_id': 'agent-1',
      'event': 'session_history',
      'payload': {
        'request_id': newerRequest['request_id'],
        'messages': [
          {
            'id': 2,
            'sender': 'ai',
            'type': 'final_answer',
            'content': 'new snapshot',
            'created_at': '2026-01-01T00:00:02Z',
            'session_id': 'session-1',
          },
        ],
      },
    });
    await newerFuture;

    socket.eventRouter.routeEvent({
      'device_id': 'agent-1',
      'event': 'session_history',
      'payload': {
        'request_id': olderRequest['request_id'],
        'messages': [
          {
            'id': 1,
            'sender': 'ai',
            'type': 'final_answer',
            'content': 'old snapshot',
            'created_at': '2026-01-01T00:00:01Z',
            'session_id': 'session-1',
          },
        ],
      },
    });
    await olderFuture;

    expect(store.currentMessages.single.text, 'new snapshot');
  });

  test('loadSessionHistory keeps the newest active session when responses arrive out of order', () async {
    final futureA = commands.loadSessionHistory('session-a');
    final requestA = socket.capturedCommands[socket.capturedCommands.length - 1]['payload'] as Map<String, dynamic>;
    final futureB = commands.loadSessionHistory('session-b');
    final requestB = socket.capturedCommands[socket.capturedCommands.length - 1]['payload'] as Map<String, dynamic>;

    socket.eventRouter.routeEvent({
      'device_id': 'agent-1',
      'event': 'session_history',
      'payload': {
        'request_id': requestA['request_id'],
        'messages': [
          {
            'id': 1,
            'sender': 'ai',
            'type': 'final_answer',
            'content': 'old A',
            'created_at': '2026-01-01T00:00:00Z',
            'session_id': 'session-a',
          },
        ],
      },
    });
    await futureA;

    socket.eventRouter.routeEvent({
      'device_id': 'agent-1',
      'event': 'session_history',
      'payload': {
        'request_id': requestB['request_id'],
        'messages': [
          {
            'id': 1,
            'sender': 'ai',
            'type': 'final_answer',
            'content': 'new B',
            'created_at': '2026-01-01T00:00:00Z',
            'session_id': 'session-b',
          },
        ],
      },
    });
    await futureB;

    expect(store.currentSessionId, 'session-b');
    expect(store.currentMessages.single.text, 'new B');
  });

  test('respondToSuspendedRequest uses device_command and waits for authoritative clear', () async {
    store.activateSession('session-1');
    store.setPendingSuspendedRequest(
      const DeviceSuspendedRequest(
        requestId: 'permission-1',
        sessionId: 'session-1',
        toolName: 'shell_execute',
        permissionClass: 'shell_execution',
        scope: 'workspace',
        workspaceId: 'workspace-1',
        workspaceName: 'desktop-agent',
        workspacePath: '/repo',
        toolInput: {'command': 'echo hello'},
        tool: {'name': 'shell_execute'},
      ),
    );

    await commands.respondToSuspendedRequest(
      store.currentPendingSuspendedRequest!,
      allow: false,
      scope: 'workspace',
      comment: 'Use ls instead',
    );

    final emitted = socket.capturedCommands.last;
    expect(emitted['device_id'], 'agent-1');
    expect(emitted['command'], 'tool_permission_response');
    expect(emitted['payload'], {
      'session_id': 'session-1',
      'request_id': 'permission-1',
      'allowed': false,
      'scope': 'workspace',
      'comment': 'Use ls instead',
    });
    expect(store.currentPendingSuspendedRequest, isNotNull);
  });
}

Map<String, dynamic> _historyRow(String id, String content) => {
  'id': id,
  'event_id': id,
  'sender': 'user',
  'type': 'user_message',
  'content': content,
  'created_at': '2026-01-01T00:00:00Z',
  'session_id': 'session-1',
};
