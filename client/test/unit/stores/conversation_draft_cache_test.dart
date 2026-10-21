import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/domain/models/conversation_draft.dart';
import 'package:sanad_client/features/conversations/domain/models/device_conversation_context.dart';
import 'package:sanad_client/features/conversations/domain/stores/conversation_draft_cache.dart';

void main() {
  late ConversationDraftCache draftCache;
  late Map<String, DeviceConversationContext> contexts;
  var notifyCount = 0;

  setUp(() {
    notifyCount = 0;
    contexts = {};
    draftCache = ConversationDraftCache(
      getContext: (id) => contexts[id] ?? DeviceConversationContext.empty(),
      updateContext: (id, ctx) => contexts[id] = ctx,
      ensureDeviceContext: (id) => contexts.putIfAbsent(id, () => DeviceConversationContext.empty()),
      notify: () => notifyCount++,
    );
  });

  group('ConversationDraftCache', () {
    test('setSessionDraft stores draft and calls notify', () {
      final draft = ConversationDraft.empty().copyWith(text: 'hello');
      draftCache.setSessionDraft('dev-1', 'sess-1', draft);

      expect(draftCache.sessionDraft('dev-1', 'sess-1'), draft);
      expect(notifyCount, 1);
    });

    test('markSessionDraftAwaitingAcceptance sets pendingRequestId', () {
      final draft = ConversationDraft.empty().copyWith(text: 'draft');
      draftCache.setSessionDraft('dev-1', 'sess-1', draft);
      notifyCount = 0;

      draftCache.markSessionDraftAwaitingAcceptance('dev-1', 'sess-1', 'req-123');

      expect(draftCache.sessionDraft('dev-1', 'sess-1')?.pendingRequestId, 'req-123');
      expect(notifyCount, 1);
    });

    test('clearSessionDraft removes draft and calls notify only when present', () {
      final draft = ConversationDraft.empty().copyWith(text: 'draft');
      draftCache.setSessionDraft('dev-1', 'sess-1', draft);
      notifyCount = 0;

      draftCache.clearSessionDraft('dev-1', 'sess-1');
      expect(draftCache.sessionDraft('dev-1', 'sess-1'), isNull);
      expect(notifyCount, 1);

      // Repeated clear on non-existent draft does not notify
      draftCache.clearSessionDraft('dev-1', 'sess-1');
      expect(notifyCount, 1);
    });

    test('prependStopRecovery deduplicates by stopRequestId', () {
      final success1 = draftCache.prependStopRecovery(
        'dev-1',
        'sess-1',
        stopRequestId: 'stop-1',
        texts: ['recovered text'],
      );
      expect(success1, isTrue);
      expect(notifyCount, 1);
      expect(draftCache.sessionDraft('dev-1', 'sess-1')?.text, 'recovered text');
      expect(draftCache.sessionDraft('dev-1', 'sess-1')?.appliedStopRecoveryIds, contains('stop-1'));

      final success2 = draftCache.prependStopRecovery(
        'dev-1',
        'sess-1',
        stopRequestId: 'stop-1',
        texts: ['different text'],
      );
      expect(success2, isFalse);
      expect(notifyCount, 1); // No extra notify on rejected recovery
    });

    test('new conversation draft lifecycle and transfer', () {
      draftCache.setNewConversationDraft(
        'dev-1',
        text: 'new draft',
        workspaceId: 'ws-1',
        providerId: 'prov-1',
        model: 'model-1',
      );

      expect(contexts['dev-1']?.newConversationDraftText, 'new draft');
      expect(contexts['dev-1']?.newConversationDraftWorkspaceId, 'ws-1');
      expect(notifyCount, 1);

      draftCache.transferNewConversationDraftToSession('dev-1', 'sess-created');
      expect(contexts['dev-1']?.newConversationDraftText, isEmpty);
      expect(contexts['dev-1']?.newConversationDraftWorkspaceId, isNull);
      expect(draftCache.sessionDraft('dev-1', 'sess-created')?.text, 'new draft');
      expect(draftCache.sessionDraft('dev-1', 'sess-created')?.workspaceId, 'ws-1');
    });

    test('clearMatchingPendingDraft clears matching session or new conversation draft', () {
      draftCache.setSessionDraft(
        'dev-1',
        'sess-1',
        ConversationDraft.empty().copyWith(
          text: 'draft',
          pendingRequestId: 'req-pending',
        ),
      );

      final cleared = draftCache.clearMatchingPendingDraft('dev-1', 'sess-1', 'req-pending');
      expect(cleared, isTrue);
      expect(draftCache.sessionDraft('dev-1', 'sess-1'), isNull);

      final notCleared = draftCache.clearMatchingPendingDraft('dev-1', 'sess-1', 'other-req');
      expect(notCleared, isFalse);
    });

    test('clearDevice removes only target device session drafts', () {
      draftCache.setSessionDraft('dev-A', 'sess-1', ConversationDraft.empty());
      draftCache.setSessionDraft('dev-B', 'sess-1', ConversationDraft.empty());

      draftCache.clearDevice('dev-A');
      expect(draftCache.sessionDraft('dev-A', 'sess-1'), isNull);
      expect(draftCache.sessionDraft('dev-B', 'sess-1'), isNotNull);
    });
  });
}
