import 'package:sanad_client/core/navigation/conversation_destination.dart';
import 'package:sanad_client/features/conversations/data/persistence/conversation_cache_codec.dart';
import 'package:sanad_client/features/conversations/domain/models/cached_workspace_section.dart';
import 'package:sanad_client/features/conversations/domain/models/conversation_draft.dart';
import 'package:sanad_client/features/conversations/domain/models/conversation_resource_state.dart';
import 'package:sanad_client/features/conversations/domain/models/conversation_section_page.dart';
import 'package:sanad_client/features/conversations/domain/models/device_conversation_cache_snapshot.dart';
import 'package:sanad_client/features/conversations/domain/models/device_conversation_context.dart';
import 'package:sanad_client/features/conversations/domain/models/device_workspace.dart';
import 'package:sanad_client/features/conversations/domain/models/session.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const codec = ConversationCacheCodec();

  group('ConversationCacheCodec', () {
    test('session decoding reads canonical thinking_mode', () {
      final session = Session.fromJson({
        'id': 'canonical',
        'thinking_mode': 'deep',
      });

      expect(session.thinkingMode, 'deep');
    });
    test('empty snapshot round-trips', () {
      const snapshot = DeviceConversationCacheSnapshot(
        activeDeviceId: null,
        contexts: {},
        sessionDrafts: {},
      );
      final encoded = codec.encode(snapshot);
      final decoded = codec.decode(encoded);
      expect(decoded.activeDeviceId, isNull);
      expect(decoded.contexts, isEmpty);
      expect(decoded.sessionDrafts, isEmpty);
    });

    test('session viewport anchors round-trip and older schemas default empty', () {
      const snapshot = DeviceConversationCacheSnapshot(
        activeDeviceId: 'device-1',
        contexts: {},
        sessionDrafts: {},
        sessionViewportAnchors: {
          'device-1|session-1': 'event-10',
        },
      );

      final decoded = codec.decode(codec.encode(snapshot));
      expect(decoded.sessionViewportAnchors, {
        'device-1|session-1': 'event-10',
      });

      final older = codec.decode(
        '{"v":3,"activeDeviceId":null,"contexts":{},"sessionDrafts":{}}',
      );
      expect(older.sessionViewportAnchors, isEmpty);
    });

    test('typed restart destinations round-trip exactly', () {
      const destinations = [
        ConversationDestination.session(
          deviceId: 'device-1',
          sessionId: 'session-1',
        ),
        ConversationDestination.newConversation(deviceId: 'device-1'),
        ConversationDestination.newConversation(
          deviceId: 'device-1',
          workspaceId: 'workspace-1',
        ),
      ];

      for (final destination in destinations) {
        final snapshot = DeviceConversationCacheSnapshot(
          activeDeviceId: 'device-1',
          contexts: {
            'device-1': DeviceConversationContext.empty().copyWith(
              lastDestination: destination,
            ),
          },
          sessionDrafts: const {},
        );

        final decoded = codec.decode(codec.encode(snapshot));
        expect(decoded.contexts['device-1']?.lastDestination, destination);
      }
    });

    test('missing typed destination remains unset', () {
      final decoded = codec.decode(
        '{"v":3,"activeDeviceId":"device-1","contexts":{"device-1":{}},"sessionDrafts":{}}',
      );
      expect(decoded.contexts['device-1']?.lastDestination, isNull);
    });

    test('null and blank payloads invalidate to empty snapshot', () {
      expect(codec.decode(null).contexts, isEmpty);
      expect(codec.decode('').contexts, isEmpty);
      expect(codec.decode('   ').contexts, isEmpty);
    });

    test('corrupt JSON invalidates safely without throwing', () {
      expect(codec.decode('{ broken json').contexts, isEmpty);
    });

    test('future schema version invalidates safely', () {
      final futurePayload = '{"v":99999,"activeDeviceId":null,"contexts":{},"sessionDrafts":{}}';
      expect(codec.decode(futurePayload).contexts, isEmpty);
    });

    test('restart normalizes transient loading states', () {
      final context = DeviceConversationContext.empty().copyWith(
        workspaces: CachedWorkspaceSection(
          workspaces: const [],
          state: ConversationResourceState.loading,
          lastRefreshedAt: null,
          lastErrorAt: null,
          lastError: null,
        ),
        unscopedConversations: ConversationSectionPage(
          sessions: [
            Session(
              id: 's-1',
              title: 'Cached',
              deviceId: 'device-1',
              createdAt: DateTime.utc(2026, 7, 13),
              updatedAt: DateTime.utc(2026, 7, 13),
            ),
          ],
          nextCursor: null,
          hasMore: false,
          state: ConversationResourceState.refreshing,
          lastRefreshedAt: null,
          lastErrorAt: null,
          lastError: null,
        ),
      );

      final decoded = codec.decode(
        codec.encode(
          DeviceConversationCacheSnapshot(
            activeDeviceId: 'device-1',
            contexts: {'device-1': context},
            sessionDrafts: const {},
          ),
        ),
      );

      expect(
        decoded.contexts['device-1']!.workspaces.state,
        ConversationResourceState.notLoaded,
      );
      expect(
        decoded.contexts['device-1']!.unscopedConversations.state,
        ConversationResourceState.ready,
      );
    });

    test('full snapshot with workspaces, pages, drafts, expansion round-trips', () {
      final workspace = DeviceWorkspace(
        id: 'ws-1',
        name: 'Project A',
        path: '/home/user/project-a',
        trustState: 'trusted',
      );
      final session = Session(
        id: 's-1',
        title: 'My chat',
        deviceId: 'device-1',
        createdAt: DateTime.utc(2026, 7, 13, 10, 0),
        updatedAt: DateTime.utc(2026, 7, 13, 11, 0),
        lastMessageAt: DateTime.utc(2026, 7, 13, 11, 30),
        workspaceId: 'ws-1',
        workspaceName: 'Project A',
        model: 'gpt-5.2',
        thinkingMode: 'deep',
      );
      final context = DeviceConversationContext(
        lastDestination: const ConversationDestination.newConversation(
          deviceId: 'device-1',
          workspaceId: 'ws-1',
        ),
        lastSelectedSessionId: 's-1',
        workspaces: CachedWorkspaceSection(
          workspaces: [workspace],
          state: ConversationResourceState.ready,
          lastRefreshedAt: DateTime.utc(2026, 7, 13, 10, 0),
          lastErrorAt: null,
          lastError: null,
        ),
        unscopedConversations: ConversationSectionPage(
          sessions: const [],
          nextCursor: null,
          hasMore: false,
          state: ConversationResourceState.notLoaded,
          lastRefreshedAt: null,
          lastErrorAt: null,
          lastError: null,
        ),
        workspaceConversationPages: {
          'ws-1': ConversationSectionPage(
            sessions: [session],
            nextCursor: 'cursor-abc',
            hasMore: true,
            state: ConversationResourceState.ready,
            lastRefreshedAt: DateTime.utc(2026, 7, 13, 11, 30),
            lastErrorAt: null,
            lastError: null,
          ),
        },
        workspaceExpansion: {'ws-1': true},
        newConversationDraftText: 'Hello world',
        newConversationDraftWorkspaceId: 'ws-1',
        newConversationDraftProviderId: 'provider-1',
        newConversationDraftModel: 'gpt-5.2',
        newConversationDraftThinkingMode: 'high',
        newConversationDraftPermissionMode: 'auto',
        newConversationDraftPendingRequestId: 'request-new',
        newConversationDraftUpdatedAt: DateTime.utc(2026, 7, 13, 11, 45),
      );
      final draft = ConversationDraft(
        text: 'Draft text',
        workspaceId: null,
        providerId: 'provider-1',
        model: 'gpt-5.2',
        thinkingMode: null,
        permissionMode: null,
        updatedAt: DateTime.utc(2026, 7, 13, 12, 0),
      );
      final snapshot = DeviceConversationCacheSnapshot(
        activeDeviceId: 'device-1',
        contexts: {'device-1': context},
        sessionDrafts: {
          DeviceConversationCacheSnapshot.sessionDraftKey('device-1', 's-1'): draft,
        },
      );

      final encoded = codec.encode(snapshot);
      expect(encoded, contains('"thinking_mode":"deep"'));
      final decoded = codec.decode(encoded);

      expect(decoded.activeDeviceId, 'device-1');
      expect(decoded.contexts.keys, contains('device-1'));
      final decodedCtx = decoded.contexts['device-1']!;
      expect(
        decodedCtx.lastDestination,
        const ConversationDestination.newConversation(
          deviceId: 'device-1',
          workspaceId: 'ws-1',
        ),
      );
      expect(decodedCtx.lastSelectedSessionId, 's-1');
      expect(decodedCtx.workspaces.workspaces.single.id, 'ws-1');
      expect(decodedCtx.workspaces.state, ConversationResourceState.ready);
      expect(decodedCtx.workspaceExpansion, {'ws-1': true});
      final decodedSession = decodedCtx.workspaceConversationPages['ws-1']!.sessions.single;
      expect(decodedSession.id, 's-1');
      expect(decodedSession.deviceId, 'device-1');
      expect(decodedSession.workspaceId, 'ws-1');
      expect(decodedSession.lastMessageAt, DateTime.utc(2026, 7, 13, 11, 30));
      expect(decodedSession.model, 'gpt-5.2');
      expect(decodedSession.thinkingMode, 'deep');
      expect(decodedCtx.workspaceConversationPages['ws-1']!.nextCursor, 'cursor-abc');
      expect(decodedCtx.workspaceConversationPages['ws-1']!.hasMore, isTrue);
      expect(decodedCtx.newConversationDraftText, 'Hello world');
      expect(decodedCtx.newConversationDraftWorkspaceId, 'ws-1');
      expect(decodedCtx.newConversationDraftModel, 'gpt-5.2');
      expect(
        decodedCtx.newConversationDraftUpdatedAt,
        DateTime.utc(2026, 7, 13, 11, 45),
      );

      final draftKey = DeviceConversationCacheSnapshot.sessionDraftKey('device-1', 's-1');
      expect(decoded.sessionDrafts[draftKey]!.text, 'Draft text');
      expect(decoded.sessionDrafts[draftKey]!.providerId, 'provider-1');
    });

    test('cached session provider survives the persistence round-trip', () {
      final session = Session(
        id: 's-provider',
        title: 'Routed',
        deviceId: 'device-1',
        createdAt: DateTime.utc(2026, 10, 21),
        updatedAt: DateTime.utc(2026, 10, 21),
        modelProvider: 'provider-go',
        model: 'deepseek-v4.1-flash',
        thinkingMode: 'low',
      );
      final context = DeviceConversationContext.empty().copyWith(
        unscopedConversations: ConversationSectionPage(
          sessions: [session],
          nextCursor: null,
          hasMore: false,
          state: ConversationResourceState.ready,
          lastRefreshedAt: DateTime.utc(2026, 10, 21),
          lastErrorAt: null,
          lastError: null,
        ),
      );

      final decoded = codec.decode(
        codec.encode(
          DeviceConversationCacheSnapshot(
            activeDeviceId: 'device-1',
            contexts: {'device-1': context},
            sessionDrafts: const {},
          ),
        ),
      );
      final restored = decoded.contexts['device-1']!.unscopedConversations.sessions.single;
      expect(restored.modelProvider, 'provider-go');
      expect(restored.model, 'deepseek-v4.1-flash');
      expect(restored.thinkingMode, 'low');
    });

    test('already-persisted legacy model_provider cache still restores the provider', () {
      final decoded = codec.decode(
        '{"v":4,"activeDeviceId":"device-1","contexts":{"device-1":{'
        '"unscoped":{"sessions":[{"id":"s-legacy","title":"Legacy",'
        '"device_id":"device-1","model":"glm-5.2","model_provider":"provider-go",'
        '"thinking_mode":"max"}],"state":"ready"}}},"sessionDrafts":{}}',
      );
      final restored = decoded.contexts['device-1']!.unscopedConversations.sessions.single;
      expect(restored.modelProvider, 'provider-go');
      expect(restored.model, 'glm-5.2');
    });

    test('an already-persisted half-route draft heals on load', () {
      final decoded = codec.decode(
        '{"v":4,"activeDeviceId":"device-1","contexts":{"device-1":{'
        '"newDraft":{"text":"keep me","workspaceId":"ws-1","providerId":null,'
        '"model":"deepseek-v4.1-flash","thinkingMode":"low",'
        '"updatedAt":"2026-10-21T06:55:06.793Z"}}},'
        '"sessionDrafts":{"device-1|s-1":{"text":"session text","providerId":"",'
        '"model":"deepseek-v4.1-flash","thinkingMode":"low",'
        '"updatedAt":"2026-10-21T06:55:06.793Z"}}}',
      );
      final context = decoded.contexts['device-1']!;
      expect(context.newConversationDraftText, 'keep me');
      expect(context.newConversationDraftWorkspaceId, 'ws-1');
      expect(context.newConversationDraftProviderId, isNull);
      expect(context.newConversationDraftModel, isNull);
      expect(context.newConversationDraftThinkingMode, isNull);

      final sessionDraft = decoded.sessionDrafts['device-1|s-1']!;
      expect(sessionDraft.text, 'session text');
      expect(sessionDraft.providerId, isNull);
      expect(sessionDraft.model, isNull);
      expect(sessionDraft.thinkingMode, isNull);
    });

    test('persisted sections are capped without retaining a skipping cursor', () {
      final sessions = List.generate(
        ConversationCacheCodec.maxPersistedSessionsPerSection + 5,
        (index) => Session(
          id: 's-$index',
          title: 'Session $index',
          deviceId: 'device-1',
          createdAt: DateTime.utc(2026, 7, 13),
          updatedAt: DateTime.utc(2026, 7, 13),
        ),
      );
      final context = DeviceConversationContext.empty().copyWith(
        unscopedConversations: ConversationSectionPage(
          sessions: sessions,
          nextCursor: 'cursor-after-all-loaded-rows',
          hasMore: true,
          state: ConversationResourceState.ready,
          lastRefreshedAt: DateTime.utc(2026, 7, 13),
          lastErrorAt: null,
          lastError: null,
        ),
      );

      final decoded = codec.decode(
        codec.encode(
          DeviceConversationCacheSnapshot(
            activeDeviceId: 'device-1',
            contexts: {'device-1': context},
            sessionDrafts: const {},
          ),
        ),
      );
      final page = decoded.contexts['device-1']!.unscopedConversations;
      expect(
        page.sessions,
        hasLength(ConversationCacheCodec.maxPersistedSessionsPerSection),
      );
      expect(page.nextCursor, isNull);
      expect(page.hasMore, isTrue);
    });
  });
}
