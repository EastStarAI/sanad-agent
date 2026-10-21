import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/domain/models/conversation_draft.dart';
import 'package:sanad_client/features/conversations/domain/models/device_conversation_cache_snapshot.dart';
import 'package:sanad_client/features/conversations/domain/models/device_workspace.dart';
import 'package:sanad_client/features/conversations/domain/models/request_generation.dart';
import 'package:sanad_client/features/conversations/domain/models/session.dart';
import 'package:sanad_client/features/conversations/domain/stores/cache_generation_guard.dart';
import 'package:sanad_client/features/conversations/domain/stores/conversation_cache_store.dart';
import 'package:sanad_client/features/conversations/domain/stores/conversation_draft_cache.dart';
import 'package:sanad_client/features/conversations/domain/stores/session_section_cache.dart';
import 'package:sanad_client/features/conversations/domain/stores/workspace_cache_projection.dart';

class _BypassedGenerationGuard extends CacheGenerationGuard {
  @override
  bool isCurrent(RequestGeneration generation, String deviceId, String? workspaceId) => true;

  @override
  bool isCurrentWorkspaceGeneration(RequestGeneration generation, String deviceId) => true;
}

void main() {
  late ConversationCacheStore store;

  setUp(() {
    store = ConversationCacheStore();
  });

  tearDown(() {
    store.dispose();
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

  group('Hardening: Staleness rejection', () {
    test('stale section refresh is rejected by guard and accepted when current', () async {
      final gen1 = store.advanceGeneration('dev-1', null);
      final gen2 = store.advanceGeneration('dev-1', null);

      var emissions = 0;
      store.snapshotStream.listen((_) => emissions++);

      final staleSessions = [makeSession(id: 'stale-1')];
      store.applySectionRefreshed(
        'dev-1',
        null,
        staleSessions,
        nextCursor: null,
        hasMore: false,
        generation: gen1,
      );
      await pumpEventQueue();

      // Stale generation rejected: no emissions, sessions empty
      expect(emissions, 0);
      expect(store.snapshot.contexts['dev-1']?.unscopedConversations.sessions ?? const [], isEmpty);

      final currentSessions = [makeSession(id: 'current-1')];
      store.applySectionRefreshed(
        'dev-1',
        null,
        currentSessions,
        nextCursor: null,
        hasMore: false,
        generation: gen2,
      );
      await pumpEventQueue();

      // Current generation accepted: emitted and populated
      expect(emissions, 1);
      expect(store.snapshot.contexts['dev-1']!.unscopedConversations.sessions.single.id, 'current-1');
    });

    test('staleness test fails if generation guard is bypassed', () {
      final bypassedStore = ConversationCacheStore(
        generationGuard: _BypassedGenerationGuard(),
      );

      final gen1 = bypassedStore.advanceGeneration('dev-1', null);
      bypassedStore.advanceGeneration('dev-1', null); // advance so gen1 is logically stale

      final staleSessions = [makeSession(id: 'should-be-rejected')];
      bypassedStore.applySectionRefreshed(
        'dev-1',
        null,
        staleSessions,
        nextCursor: null,
        hasMore: false,
        generation: gen1,
      );

      // Because the guard was bypassed, the stale session was incorrectly accepted!
      // This confirms the guard is the sole authority guarding staleness rejection.
      expect(
        bypassedStore.snapshot.contexts['dev-1']!.unscopedConversations.sessions.single.id,
        'should-be-rejected',
      );
      bypassedStore.dispose();
    });

    test('stale workspace refresh is rejected by guard and accepted when current', () async {
      final gen1 = store.advanceWorkspacesGeneration('dev-1');
      final gen2 = store.advanceWorkspacesGeneration('dev-1');

      var emissions = 0;
      store.snapshotStream.listen((_) => emissions++);

      const staleWs = [DeviceWorkspace(id: 'ws-stale', name: 'Stale', path: '/stale')];
      store.applyWorkspacesRefreshed('dev-1', staleWs, generation: gen1);
      await pumpEventQueue();

      expect(emissions, 0);
      expect(store.snapshot.contexts['dev-1']?.workspaces.workspaces ?? const [], isEmpty);

      const currentWs = [DeviceWorkspace(id: 'ws-current', name: 'Current', path: '/current')];
      store.applyWorkspacesRefreshed('dev-1', currentWs, generation: gen2);
      await pumpEventQueue();

      expect(emissions, 1);
      expect(store.snapshot.contexts['dev-1']!.workspaces.workspaces, currentWs);
    });

    test('stale workspace error is rejected by guard and does not pollute state', () async {
      final gen1 = store.advanceWorkspacesGeneration('dev-1');
      final gen2 = store.advanceWorkspacesGeneration('dev-1');

      var emissions = 0;
      store.snapshotStream.listen((_) => emissions++);

      store.applyWorkspacesError('dev-1', 'stale error', generation: gen1);
      await pumpEventQueue();
      expect(emissions, 0);
      expect(store.snapshot.contexts['dev-1']?.workspaces.lastError, isNull);

      store.applyWorkspacesError('dev-1', 'current error', generation: gen2);
      await pumpEventQueue();
      expect(emissions, 1);
      expect(store.snapshot.contexts['dev-1']!.workspaces.lastError, 'current error');
    });
  });

  group('Hardening: Notification order and listener count', () {
    test('setActiveDevice emits snapshotStream then activeDeviceStream synchronously in order', () async {
      final events = <String>[];

      store.snapshotStream.listen((snapshot) {
        events.add('snapshot:${snapshot.activeDeviceId}');
      });
      store.activeDeviceStream.listen((activeId) {
        events.add('activeDevice:$activeId');
      });

      store.setActiveDevice('device-xyz');
      await pumpEventQueue();

      expect(events, [
        'snapshot:device-xyz',
        'activeDevice:device-xyz',
      ]);
    });

    test('restoreFromSnapshot emits snapshotStream then activeDeviceStream in order with 1 event each', () async {
      final events = <String>[];

      store.snapshotStream.listen((snapshot) {
        events.add('snapshot:${snapshot.activeDeviceId}');
      });
      store.activeDeviceStream.listen((activeId) {
        events.add('activeDevice:$activeId');
      });

      store.restoreFromSnapshot(
        const DeviceConversationCacheSnapshot(
          activeDeviceId: 'restored-device',
          contexts: {},
          sessionDrafts: {},
        ),
      );
      await pumpEventQueue();

      expect(events, [
        'snapshot:restored-device',
        'activeDevice:restored-device',
      ]);
    });

    test('clearDevice on active device emits snapshotStream then activeDeviceStream with null in order', () async {
      store.setActiveDevice('device-active');
      await pumpEventQueue();

      final events = <String>[];
      store.snapshotStream.listen((snapshot) {
        events.add('snapshot:${snapshot.activeDeviceId}');
      });
      store.activeDeviceStream.listen((activeId) {
        events.add('activeDevice:$activeId');
      });

      store.clearDevice('device-active');
      await pumpEventQueue();

      expect(events, [
        'snapshot:null',
        'activeDevice:null',
      ]);
    });

    test('applySessionDeleted emits exactly one snapshot event without intermediate emissions', () async {
      final s1 = makeSession(id: 'sess-1');
      store.applySessionCreated('dev-1', s1);
      store.setSessionDraft('dev-1', 'sess-1', ConversationDraft.empty().copyWith(text: 'draft'));
      await pumpEventQueue();

      var snapshotCount = 0;
      store.snapshotStream.listen((_) => snapshotCount++);

      store.applySessionDeleted('dev-1', 'sess-1');
      await pumpEventQueue();

      expect(snapshotCount, 1);
    });

    test('applyUserMessageAccepted emits exactly one snapshot event', () async {
      final s1 = makeSession(id: 'sess-1');
      store.applySessionCreated('dev-1', s1);
      store.setSessionDraft(
        'dev-1',
        'sess-1',
        ConversationDraft.empty().copyWith(text: 'draft', pendingRequestId: 'req-1'),
      );
      await pumpEventQueue();

      var snapshotCount = 0;
      store.snapshotStream.listen((_) => snapshotCount++);

      store.applyUserMessageAccepted('dev-1', 'sess-1', requestId: 'req-1');
      await pumpEventQueue();

      expect(snapshotCount, 1);
    });
  });

  group('Hardening: Owner modularity and one-way injection', () {
    test('store delegates to injected owners without shared mutable state', () {
      final guard = CacheGenerationGuard();
      late final SessionSectionCache sectionCache;
      final draftCache = ConversationDraftCache(
        getContext: (id) => sectionCache.contextFor(id),
        updateContext: (id, ctx) => sectionCache.updateContext(id, ctx),
        ensureDeviceContext: (id) => sectionCache.ensureDeviceContext(id),
        notify: () {},
      );
      sectionCache = SessionSectionCache(
        generationGuard: guard,
        draftCache: draftCache,
        notify: () {},
      );
      final workspaceProj = WorkspaceCacheProjection(
        generationGuard: guard,
        getContext: (id) => sectionCache.contextFor(id),
        updateContext: (id, ctx) => sectionCache.updateContext(id, ctx),
        ensureDeviceContext: (id) => sectionCache.ensureDeviceContext(id),
        notify: () {},
      );

      final customStore = ConversationCacheStore(
        generationGuard: guard,
        sessionSectionCache: sectionCache,
        workspaceProjection: workspaceProj,
        draftCache: draftCache,
      );

      // Facade operations must route through the injected owners, not private defaults.
      customStore.setWorkspaceExpansion('dev-1', 'ws-1', true);
      expect(sectionCache.contextFor('dev-1').workspaceExpansion['ws-1'], isTrue);

      final injectedGeneration = customStore.advanceGeneration('dev-1', null);
      expect(guard.isCurrent(injectedGeneration, 'dev-1', null), isTrue);

      customStore.setSessionDraft(
        'dev-1',
        'sess-1',
        ConversationDraft.empty().copyWith(text: 'delegated'),
      );
      expect(draftCache.sessionDraft('dev-1', 'sess-1')?.text, 'delegated');
      expect(customStore.sessionDraft('dev-1', 'sess-1')?.text, 'delegated');
      expect(customStore.snapshot.sessionDrafts['dev-1|sess-1']?.text, 'delegated');

      expect(customStore.snapshot, isA<DeviceConversationCacheSnapshot>());
      customStore.dispose();
    });
  });
}
