import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/devices/domain/stores/device_capabilities_store.dart';
import 'package:sanad_client/features/conversations/data/clients/socket_conversation_client.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';
import 'package:sanad_client/features/conversations/domain/models/device_suspended_request.dart';
import 'package:sanad_client/features/conversations/domain/models/session_query.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fake_socket.dart';

void main() {
  late FakeSanadSocketService socket;
  late SocketConversationClient client;

  setUp(() {
    socket = FakeSanadSocketService()..setConnected(true);
    final resolver = createTestResolver(cloudSocket: socket, localSocket: socket);
    client = SocketConversationClient(
      config: DeviceConfig(id: 'agent-1', name: 'SanadAgent', isOnline: true),
      socketService: socket,
      capabilitiesStore: DeviceCapabilitiesStore(resolver),
    );
    client.activateSession('session-1');
  });

  tearDown(() {
    client.dispose();
    socket.dispose();
  });

  test('sendMessage waits for the daemon user event and sends think command', () async {
    await client.sendMessage('hello', sessionId: 'session-1', workspaceId: 'workspace-1');

    expect(client.currentMessages, isEmpty);
    final thinkCommand = socket.capturedCommands.where((entry) => entry['command'] == 'think').single;
    expect(thinkCommand['command'], 'think');
    expect((thinkCommand['payload'] as Map)['workspace_id'], 'workspace-1');
  });

  test('daemon user events move a queued message into the main conversation', () async {
    await client.sendMessage('follow up', sessionId: 'session-1');
    final thinkCommand = socket.capturedCommands.where((entry) => entry['command'] == 'think').single;
    final requestId = (thinkCommand['payload'] as Map<String, dynamic>)['request_id'] as String;

    socket.eventRouter.routeEvent({
      'device_id': 'agent-1',
      'event': 'user_message',
      'session_id': 'session-1',
      'request_id': requestId,
      'payload': {
        'content': 'follow up',
        'request_id': requestId,
        'metadata': {
          'queued': true,
          'request_id': requestId,
        },
      },
    });
    await Future<void>.delayed(Duration.zero);

    expect(client.currentMessages, isEmpty);
    expect(client.currentQueuedMessages.single.text, 'follow up');

    socket.eventRouter.routeEvent({
      'device_id': 'agent-1',
      'event': 'user_message',
      'session_id': 'session-1',
      'request_id': requestId,
      'payload': {
        'content': 'follow up',
        'request_id': requestId,
        'metadata': {
          'request_id': requestId,
        },
      },
    });
    await Future<void>.delayed(Duration.zero);

    expect(client.currentQueuedMessages, isEmpty);
    expect(client.currentMessages.single.kind, EventKind.userMessage);
    expect(client.currentMessages.single.text, 'follow up');
  });

  test('socket events update the conversation store', () async {
    socket.eventRouter.routeEvent({
      'device_id': 'agent-1',
      'event': 'final_answer',
      'payload': {
        'content': 'done',
        'session_id': 'session-1',
      },
    });
    await Future<void>.delayed(Duration.zero);

    expect(client.currentMessages.single.kind, EventKind.finalAnswer);
    expect(client.currentMessages.single.text, 'done');
  });

  test('tool_permission_request updates pending suspended state', () async {
    DeviceSuspendedRequest? latest;
    final sub = client.pendingSuspendedRequest.listen((value) => latest = value);

    socket.eventRouter.routeEvent({
      'device_id': 'agent-1',
      'event': 'tool_permission_request',
      'session_id': 'session-1',
      'payload': {
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
    });
    await Future<void>.delayed(Duration.zero);

    expect(client.currentPendingSuspendedRequest?.requestId, 'permission-1');
    expect(latest?.toolName, 'shell_execute');
    await sub.cancel();
  });

  test('reuses the hydrated sessions snapshot instead of refetching immediately', () async {
    final first = client.getSessions();
    await Future<void>.delayed(Duration.zero);

    final request = socket.capturedCommands.where((entry) => entry['command'] == 'get_sessions').single;
    final requestId = (request['payload'] as Map)['request_id'] as String;

    socket.eventRouter.routeEvent({
      'device_id': 'agent-1',
      'event': 'sessions_list',
      'request_id': requestId,
      'payload': {
        'request_id': requestId,
        'sessions': [
          {
            'id': 'session-1',
            'device_id': 'agent-1',
            'title': 'Cached session',
          },
        ],
      },
    });

    await first;

    final second = await client.getSessions();

    expect(second.sessions, hasLength(1));
    expect(second.sessions.single.id, 'session-1');
    expect(socket.capturedCommands.where((entry) => entry['command'] == 'get_sessions'), hasLength(1));
  });

  test('updates the sessions stream on successful fetch', () async {
    final sessionsFuture = client.getSessions();
    await Future<void>.delayed(Duration.zero);

    final request = socket.capturedCommands.where((entry) => entry['command'] == 'get_sessions').single;
    final requestId = (request['payload'] as Map)['request_id'] as String;

    final streamFuture = client.sessions.first;

    socket.eventRouter.routeEvent({
      'device_id': 'agent-1',
      'event': 'sessions_list',
      'request_id': requestId,
      'payload': {
        'request_id': requestId,
        'sessions': [
          {
            'id': 'session-1',
            'device_id': 'agent-1',
            'title': 'Stream session',
          },
        ],
      },
    });

    await sessionsFuture;
    final streamResult = await streamFuture;

    expect(streamResult, hasLength(1));
    expect(streamResult.single.title, 'Stream session');
  });

  test('successful fetch emits sessions list only once', () async {
    var emissionCount = 0;
    final sub = client.sessions.listen((_) => emissionCount += 1);

    final sessionsFuture = client.getSessions();
    await Future<void>.delayed(Duration.zero);

    final request = socket.capturedCommands.where((entry) => entry['command'] == 'get_sessions').single;
    final requestId = (request['payload'] as Map)['request_id'] as String;

    socket.eventRouter.routeEvent({
      'device_id': 'agent-1',
      'event': 'sessions_list',
      'request_id': requestId,
      'payload': {
        'request_id': requestId,
        'sessions': [
          {
            'id': 'session-1',
            'device_id': 'agent-1',
            'title': 'Single emission session',
          },
        ],
      },
    });

    await sessionsFuture;
    await Future<void>.delayed(Duration.zero);

    expect(emissionCount, 1);
    await sub.cancel();
  });

  test(
    'reconnect replaces stale cached sessions with the authoritative daemon snapshot and hydrates active history',
    () async {
      final initial = client.getSessions();
      await Future<void>.delayed(Duration.zero);
      final initialCommand = socket.capturedCommands.where((entry) => entry['command'] == 'get_sessions').single;
      final initialRequestId = (initialCommand['payload'] as Map)['request_id'] as String;
      socket.eventRouter.routeEvent({
        'device_id': 'agent-1',
        'event': 'sessions_list',
        'request_id': initialRequestId,
        'payload': {
          'request_id': initialRequestId,
          'sessions': [
            {
              'id': 'session-1',
              'device_id': 'agent-1',
              'title': 'Visible before restart',
            },
          ],
        },
      });
      await initial;
      socket.clearCaptured();

      socket.setConnected(false);
      await Future<void>.delayed(Duration.zero);
      socket.setConnected(true);
      await Future<void>.delayed(Duration.zero);
      final synchronization = client.synchronizeAfterReconnect();
      await Future<void>.delayed(Duration.zero);

      final sessionsCommand = socket.capturedCommands.where((entry) => entry['command'] == 'get_sessions').single;
      final sessionsRequestId = (sessionsCommand['payload'] as Map)['request_id'] as String;
      final sessionsEmission = client.sessions.first;
      socket.eventRouter.routeEvent({
        'device_id': 'agent-1',
        'event': 'sessions_list',
        'request_id': sessionsRequestId,
        'payload': {
          'request_id': sessionsRequestId,
          'sessions': [
            {
              'id': 'session-2',
              'device_id': 'agent-1',
              'title': 'Authoritative after reconnect',
            },
          ],
        },
      });

      final reconciledSessions = await sessionsEmission;
      expect(reconciledSessions, hasLength(1));
      expect(reconciledSessions.single.id, 'session-2');
      await Future<void>.delayed(Duration.zero);

      final historyCommand = socket.capturedCommands.where((entry) => entry['command'] == 'get_session_history').single;
      final historyRequestId = (historyCommand['payload'] as Map)['request_id'] as String;
      socket.eventRouter.routeEvent({
        'device_id': 'agent-1',
        'event': 'session_history',
        'request_id': historyRequestId,
        'payload': {
          'request_id': historyRequestId,
          'messages': [
            {
              'id': 1,
              'sender': 'ai',
              'type': 'final_answer',
              'content': 'Completed while disconnected',
              'created_at': '2026-07-12T04:48:25Z',
            },
          ],
        },
      });

      await synchronization;
      expect(client.currentMessages.single.text, 'Completed while disconnected');
    },
  );

  test(
    'default getSessions keeps legacy access to sessions beyond the first page limit',
    () async {
      final fetch = client.getSessions();
      await Future<void>.delayed(Duration.zero);

      final firstRequest = socket.capturedCommands.where((entry) => entry['command'] == 'get_sessions').first;
      final firstRequestId = (firstRequest['payload'] as Map)['request_id'] as String;
      socket.eventRouter.routeEvent({
        'device_id': 'agent-1',
        'event': 'sessions_list',
        'request_id': firstRequestId,
        'payload': {
          'request_id': firstRequestId,
          'sessions': List.generate(
            2,
            (index) => {
              'id': 'session-page1-$index',
              'device_id': 'agent-1',
              'title': 'Page 1 - $index',
            },
          ),
          'has_more': true,
          'next_cursor': 'cursor-2',
        },
      });
      await Future<void>.delayed(Duration.zero);

      final secondRequest = socket.capturedCommands.where((entry) => entry['command'] == 'get_sessions').last;
      final secondPayload = secondRequest['payload'] as Map<String, dynamic>;
      expect(secondPayload['cursor'], 'cursor-2');
      final secondRequestId = secondPayload['request_id'] as String;
      socket.eventRouter.routeEvent({
        'device_id': 'agent-1',
        'event': 'sessions_list',
        'request_id': secondRequestId,
        'payload': {
          'request_id': secondRequestId,
          'sessions': [
            {
              'id': 'session-page2-0',
              'device_id': 'agent-1',
              'title': 'Page 2 - 0',
            },
          ],
          'has_more': false,
        },
      });

      final result = await fetch;
      expect(result.sessions.map((session) => session.id), [
        'session-page1-0',
        'session-page1-1',
        'session-page2-0',
      ]);
      expect(result.hasMore, isFalse);
      expect(result.nextCursor, isNull);
    },
  );

  test('returns cached sessions when getSessions request fails', () async {
    // 1. Hydrate cache first
    final first = client.getSessions();
    await Future<void>.delayed(Duration.zero);

    final request1 = socket.capturedCommands.where((entry) => entry['command'] == 'get_sessions').first;
    final requestId1 = (request1['payload'] as Map)['request_id'] as String;

    socket.eventRouter.routeEvent({
      'device_id': 'agent-1',
      'event': 'sessions_list',
      'request_id': requestId1,
      'payload': {
        'request_id': requestId1,
        'sessions': [
          {
            'id': 'session-1',
            'device_id': 'agent-1',
            'title': 'Cached session',
          },
        ],
      },
    });
    await first;

    socket.clearCaptured();

    // 2. Start a new request
    final second = client.refreshSessions();
    await Future<void>.delayed(Duration.zero);

    // 3. Replace the transport so disposing the old gateway fails the pending
    // request immediately. Rebinding the identical socket is intentionally a
    // no-op and would make this test wait for the production request timeout.
    final replacementSocket = FakeSanadSocketService()..setConnected(true);
    addTearDown(replacementSocket.dispose);
    client.updateSocketService(replacementSocket);

    // 4. Await the second future, it should return the cached list
    final secondResult = await second;
    expect(secondResult.sessions, hasLength(1));
    expect(secondResult.sessions.single.title, 'Cached session');
  });

  test('filtered workspace queries do not replace the default sessions stream', () async {
    final globalFetch = client.getSessions();
    await Future<void>.delayed(Duration.zero);
    final globalRequest = socket.capturedCommands.where((entry) => entry['command'] == 'get_sessions').single;
    final globalRequestId = (globalRequest['payload'] as Map)['request_id'] as String;
    socket.eventRouter.routeEvent({
      'device_id': 'agent-1',
      'event': 'sessions_list',
      'request_id': globalRequestId,
      'payload': {
        'request_id': globalRequestId,
        'sessions': [
          {
            'id': 'session-global',
            'device_id': 'agent-1',
            'title': 'Global session',
          },
        ],
      },
    });
    await globalFetch;

    socket.clearCaptured();

    final streamResultFuture = client.sessions.first;
    final filteredResult = client.getSessions(
      query: SessionQueryRequest(workspaceId: 'workspace-a', limit: 2),
    );
    await Future<void>.delayed(Duration.zero);
    final filteredRequest = socket.capturedCommands.where((entry) => entry['command'] == 'get_sessions').single;
    final filteredRequestId = (filteredRequest['payload'] as Map)['request_id'] as String;
    socket.eventRouter.routeEvent({
      'device_id': 'agent-1',
      'event': 'sessions_list',
      'request_id': filteredRequestId,
      'payload': {
        'request_id': filteredRequestId,
        'sessions': [
          {
            'id': 'session-workspace',
            'device_id': 'agent-1',
            'title': 'Workspace session',
          },
        ],
        'has_more': true,
        'next_cursor': 'cursor-2',
      },
    });

    final filtered = await filteredResult;
    expect(filtered.sessions.single.id, 'session-workspace');
    expect(filtered.hasMore, isTrue);
    expect(filtered.nextCursor, 'cursor-2');

    socket.eventRouter.routeEvent({
      'device_id': 'agent-1',
      'event': 'sessions_list',
      'payload': {
        'sessions': [
          {
            'id': 'session-global',
            'device_id': 'agent-1',
            'title': 'Global session',
          },
        ],
      },
    });
    final streamResult = await streamResultFuture;
    expect(streamResult.single.id, 'session-global');
  });

  test('different query identities do not reuse the default cache', () async {
    final hydrated = client.getSessions();
    await Future<void>.delayed(Duration.zero);
    final request = socket.capturedCommands.where((entry) => entry['command'] == 'get_sessions').single;
    final requestId = (request['payload'] as Map)['request_id'] as String;
    socket.eventRouter.routeEvent({
      'device_id': 'agent-1',
      'event': 'sessions_list',
      'request_id': requestId,
      'payload': {
        'request_id': requestId,
        'sessions': [
          {
            'id': 'session-default',
            'device_id': 'agent-1',
            'title': 'Default session',
          },
        ],
      },
    });
    await hydrated;

    final filtered = client.getSessions(
      query: SessionQueryRequest(unscopedOnly: true),
    );
    await Future<void>.delayed(Duration.zero);
    final filteredRequest = socket.capturedCommands.where((entry) => entry['command'] == 'get_sessions').last;
    final filteredPayload = filteredRequest['payload'] as Map<String, dynamic>;
    expect(filteredPayload['unscoped_only'], isTrue);

    final filteredRequestId = filteredPayload['request_id'] as String;
    socket.eventRouter.routeEvent({
      'device_id': 'agent-1',
      'event': 'sessions_list',
      'request_id': filteredRequestId,
      'payload': {
        'request_id': filteredRequestId,
        'sessions': const [],
      },
    });

    final filteredResult = await filtered;
    expect(filteredResult.sessions, isEmpty);
  });

  test(
    'an explicit unfiltered page never poisons the legacy all-sessions cache',
    () async {
      final paged = client.getSessions(
        query: SessionQueryRequest(limit: 1),
      );
      await Future<void>.delayed(Duration.zero);
      final pagedCommand = socket.capturedCommands.where((entry) => entry['command'] == 'get_sessions').single;
      final pagedRequestId = (pagedCommand['payload'] as Map)['request_id'] as String;
      socket.eventRouter.routeEvent({
        'device_id': 'agent-1',
        'event': 'sessions_list',
        'request_id': pagedRequestId,
        'payload': {
          'request_id': pagedRequestId,
          'sessions': [
            {
              'id': 'session-first-page',
              'device_id': 'agent-1',
              'title': 'First page only',
            },
          ],
          'has_more': true,
          'next_cursor': 'legacy-must-not-reuse-this',
        },
      });
      expect((await paged).hasMore, isTrue);

      socket.clearCaptured();
      final legacy = client.getSessions();
      await Future<void>.delayed(Duration.zero);
      final legacyCommand = socket.capturedCommands.where((entry) => entry['command'] == 'get_sessions').single;
      final legacyRequestId = (legacyCommand['payload'] as Map)['request_id'] as String;
      socket.eventRouter.routeEvent({
        'device_id': 'agent-1',
        'event': 'sessions_list',
        'request_id': legacyRequestId,
        'payload': {
          'request_id': legacyRequestId,
          'sessions': [
            {
              'id': 'session-authoritative-legacy',
              'device_id': 'agent-1',
              'title': 'Authoritative legacy result',
            },
          ],
          'has_more': false,
        },
      });

      final result = await legacy;
      expect(result.sessions.single.id, 'session-authoritative-legacy');
    },
  );

  test('identical concurrent session queries share one transport request', () async {
    final query = SessionQueryRequest(workspaceId: 'workspace-a', limit: 6);
    final first = client.getSessions(query: query);
    final second = client.getSessions(query: query);
    await Future<void>.delayed(Duration.zero);

    final commands = socket.capturedCommands.where((entry) => entry['command'] == 'get_sessions').toList();
    expect(commands, hasLength(1));
    final requestId = (commands.single['payload'] as Map)['request_id'] as String;
    socket.eventRouter.routeEvent({
      'device_id': 'agent-1',
      'event': 'sessions_list',
      'request_id': requestId,
      'payload': {
        'request_id': requestId,
        'sessions': [
          {
            'id': 'session-shared-request',
            'device_id': 'agent-1',
            'title': 'Shared request',
          },
        ],
        'has_more': false,
      },
    });

    expect((await first).sessions.single.id, 'session-shared-request');
    expect((await second).sessions.single.id, 'session-shared-request');
  });
}
