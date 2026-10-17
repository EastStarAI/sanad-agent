import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/core/navigation/conversation_destination.dart';
import 'package:sanad_client/features/conversations/domain/models/conversation_draft.dart';
import 'package:sanad_client/features/conversations/domain/models/conversation_resource_state.dart';
import 'package:sanad_client/features/conversations/domain/models/device_workspace.dart';
import 'package:sanad_client/features/conversations/domain/models/session.dart';
import 'package:sanad_client/features/conversations/domain/stores/cache_generation_guard.dart';
import 'package:sanad_client/features/conversations/domain/stores/conversation_draft_cache.dart';
import 'package:sanad_client/features/conversations/domain/stores/session_section_cache.dart';

void main() {
  late CacheGenerationGuard guard;
  late ConversationDraftCache draftCache;
  late SessionSectionCache sectionCache;
  var notifyCount = 0;

  setUp(() {
    notifyCount = 0;
    guard = CacheGenerationGuard();
    draftCache = ConversationDraftCache(
      getContext: (id) => sectionCache.contextFor(id),
      updateContext: (id, ctx) => sectionCache.updateContext(id, ctx),
      ensureDeviceContext: (id) => sectionCache.ensureDeviceContext(id),
      notify: () => notifyCount++,
    );
    sectionCache = SessionSectionCache(
      generationGuard: guard,
      draftCache: draftCache,
      notify: () => notifyCount++,
    );
  });

  Session makeSession({
    required String id,
    String deviceId = 'dev-1',
    String? workspaceId,
    DateTime? lastMessageAt,
    DateTime? updatedAt,
  }) {
    return Session(
      id: id,
      title: 'Session $id',
      deviceId: deviceId,
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: updatedAt ?? DateTime.utc(2026, 1, 1),
      lastMessageAt: lastMessageAt,
      workspaceId: workspaceId,
    );
  }

  group('SessionSectionCache', () {
    test('applySectionRefreshed rejects stale and accepts current generation', () {
      final gen1 = guard.advanceGeneration('dev-1', null);
      final gen2 = guard.advanceGeneration('dev-1', null);

      final s1 = makeSession(id: 's1');
      sectionCache.applySectionRefreshed(
        'dev-1',
        null,
        [s1],
        nextCursor: null,
        hasMore: false,
        generation: gen1,
      );

      // Stale refresh rejected
      expect(sectionCache.contextFor('dev-1').unscopedConversations.sessions, isEmpty);
      expect(notifyCount, 0);

      // Current refresh accepted
      sectionCache.applySectionRefreshed(
        'dev-1',
        null,
        [s1],
        nextCursor: null,
        hasMore: false,
        generation: gen2,
      );

      expect(sectionCache.contextFor('dev-1').unscopedConversations.sessions, [s1]);
      expect(notifyCount, 1);
    });

    test('applySectionPageAppended appends and deduplicates sessions', () {
      final gen = guard.advanceGeneration('dev-1', null);
      final s1 = makeSession(id: 's1', updatedAt: DateTime.utc(2026, 1, 2));
      final s2 = makeSession(id: 's2', updatedAt: DateTime.utc(2026, 1, 1));
      sectionCache.applySectionRefreshed(
        'dev-1',
        null,
        [s1],
        nextCursor: 'c1',
        hasMore: true,
        generation: gen,
      );
      notifyCount = 0;

      sectionCache.applySectionPageAppended(
        'dev-1',
        null,
        [s1, s2], // s1 duplicate should be deduplicated
        nextCursor: null,
        hasMore: false,
        generation: gen,
      );

      final sessions = sectionCache.contextFor('dev-1').unscopedConversations.sessions;
      expect(sessions.map((s) => s.id), ['s1', 's2']);
      expect(notifyCount, 1);
    });

    test('applySessionCreated inserts session sorted and notifies', () {
      final s1 = makeSession(id: 's1', updatedAt: DateTime.utc(2026, 1, 1));
      final s2 = makeSession(id: 's2', updatedAt: DateTime.utc(2026, 1, 2));
      sectionCache.applySessionCreated('dev-1', s1);
      sectionCache.applySessionCreated('dev-1', s2);

      final sessions = sectionCache.contextFor('dev-1').unscopedConversations.sessions;
      expect(sessions.first.id, 's2');
      expect(notifyCount, 2);
    });

    test('applySessionDeleted cleans up sections, draft, destination, and viewport anchor', () {
      final s1 = makeSession(id: 's1');
      sectionCache.applySessionCreated('dev-1', s1);
      draftCache.setSessionDraft('dev-1', 's1', ConversationDraft.empty().copyWith(text: 'text'));
      sectionCache.recordSessionViewportAnchor('dev-1', 's1', 'evt-1');
      sectionCache.recordLastDestination(
        const ConversationDestination.session(deviceId: 'dev-1', sessionId: 's1'),
      );
      notifyCount = 0;

      sectionCache.applySessionDeleted('dev-1', 's1');

      expect(sectionCache.contextFor('dev-1').unscopedConversations.sessions, isEmpty);
      expect(draftCache.sessionDraft('dev-1', 's1'), isNull);
      expect(sectionCache.sessionViewportAnchor('dev-1', 's1'), isNull);
      expect(sectionCache.contextFor('dev-1').lastDestination, isNull);
      expect(sectionCache.contextFor('dev-1').lastSelectedSessionId, isNull);
      expect(notifyCount, 1);
    });

    test('applyUserMessageAccepted bumps timestamp, clears matching pending draft and anchor', () {
      final s1 = makeSession(id: 's1', lastMessageAt: DateTime.utc(2026, 1, 1));
      sectionCache.applySessionCreated('dev-1', s1);
      draftCache.setSessionDraft(
        'dev-1',
        's1',
        ConversationDraft.empty().copyWith(text: 'text', pendingRequestId: 'req-msg'),
      );
      sectionCache.recordSessionViewportAnchor('dev-1', 's1', 'evt-anchor');
      notifyCount = 0;

      final now = DateTime.utc(2026, 2, 1);
      sectionCache.applyUserMessageAccepted(
        'dev-1',
        's1',
        timestamp: now,
        requestId: 'req-msg',
      );

      final session = sectionCache.contextFor('dev-1').unscopedConversations.sessions.single;
      expect(session.lastMessageAt, now);
      expect(draftCache.sessionDraft('dev-1', 's1'), isNull);
      expect(sectionCache.sessionViewportAnchor('dev-1', 's1'), isNull);
      expect(notifyCount, 1);
    });

    test('sidebarSnapshotFor builds workspace and unscoped groups', () {
      final ctx = sectionCache.contextFor('dev-1');
      sectionCache.updateContext(
        'dev-1',
        ctx.copyWith(
          workspaces: ctx.workspaces.copyWith(
            workspaces: const [DeviceWorkspace(id: 'ws-1', name: 'Ws 1', path: '/path/1')],
            state: ConversationResourceState.ready,
          ),
        ),
      );

      final snapshot = sectionCache.sidebarSnapshotFor('dev-1');
      expect(snapshot, isNotNull);
      expect(snapshot!.workspaces.length, 1);
      expect(snapshot.conversationGroups.length, 2); // 1 workspace + 1 unscoped
    });

    test('sessionsForDevice returns all sessions flat and sorted', () {
      final s1 = makeSession(id: 's1', updatedAt: DateTime.utc(2026, 1, 1));
      final s2 = makeSession(
        id: 's2',
        workspaceId: 'ws-1',
        updatedAt: DateTime.utc(2026, 1, 2),
      );
      sectionCache.applySessionCreated('dev-1', s1);
      sectionCache.applySessionCreated('dev-1', s2);

      final flat = sectionCache.sessionsForDevice('dev-1');
      expect(flat.map((s) => s.id), ['s2', 's1']);
    });
  });
}
