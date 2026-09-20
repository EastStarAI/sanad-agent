import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/domain/models/device_suspended_request.dart';
import 'package:sanad_client/features/conversations/domain/models/runtime_notice.dart';
import 'package:sanad_client/features/conversations/domain/models/session_attention_state.dart';
import 'package:sanad_client/features/conversations/domain/models/session_execution_snapshot.dart';
import 'package:sanad_client/features/conversations/domain/stores/device_conversation_store.dart';
import 'package:sanad_client/features/conversations/domain/stores/session_execution_registry.dart';

void main() {
  late DeviceConversationStore store;

  setUp(() => store = DeviceConversationStore());
  tearDown(() => store.dispose());

  test(
    'projects processing only from authoritative running or resuming snapshots',
    () {
      store.updateProcessingState('thought_stream', 'session-a');
      expect(store.isSessionProcessing('session-a'), isFalse);

      final running = store.applyExecutionPayload(
        _executionPayload('session-a', 'running', 1),
      );
      expect(running.disposition, SessionExecutionApplyDisposition.applied);
      expect(store.isSessionProcessing('session-a'), isTrue);

      store.updateProcessingState('final_answer', 'session-a');
      expect(store.isSessionProcessing('session-a'), isTrue);

      store.applyExecutionPayload(_executionPayload('session-a', 'waiting', 2));
      expect(store.isSessionProcessing('session-a'), isFalse);
      expect(
        store.attentionStateFor('session-a').executionSnapshot.isWaiting,
        isTrue,
      );
    },
  );

  test('keeps runtime notices and permissions isolated by session', () {
    store.setRuntimeNotice(
      const RuntimeNotice(
        sessionId: 'session-a',
        status: 'waiting',
        reason: 'rate_limit',
        title: 'Waiting A',
      ),
    );
    store.setPendingSuspendedRequest(_permission('session-b', 'permission-b'));

    store.activateSession('session-a');
    expect(store.currentRuntimeNotice?.title, 'Waiting A');
    expect(store.currentPendingSuspendedRequest, isNull);

    store.activateSession('session-b');
    expect(store.currentRuntimeNotice, isNull);
    expect(store.currentPendingSuspendedRequest?.requestId, 'permission-b');
    expect(
      store.attentionStateFor('session-a').visualState,
      SessionAttentionVisualState.waiting,
    );
    expect(
      store.attentionStateFor('session-b').visualState,
      SessionAttentionVisualState.userQuestionOrPermission,
    );
  });

  test('identity-guarded clear cannot remove another permission request', () {
    store.activateSession('session-a');
    store.setPendingSuspendedRequest(
      _permission('session-a', 'permission-new'),
    );

    store.clearPendingSuspendedRequestForSession(
      'session-a',
      requestId: 'permission-old',
    );
    expect(store.currentPendingSuspendedRequest?.requestId, 'permission-new');

    store.clearPendingSuspendedRequestForSession(
      'session-a',
      requestId: 'permission-new',
    );
    expect(store.currentPendingSuspendedRequest, isNull);
  });

  test('identity-guarded clear cannot remove a newer runtime notice', () {
    store.activateSession('session-a');
    store.setRuntimeNotice(
      const RuntimeNotice(
        sessionId: 'session-a',
        requestId: 'notice-new',
        status: 'waiting',
        reason: 'rate_limit',
        title: 'Waiting',
      ),
    );

    store.clearRuntimeNotice(sessionId: 'session-a', requestId: 'notice-old');
    expect(store.currentRuntimeNotice?.requestId, 'notice-new');

    store.clearRuntimeNotice(sessionId: 'session-a', requestId: 'notice-new');
    expect(store.currentRuntimeNotice, isNull);
  });

  test('retry replaces the error attention with running then normal', () {
    store.activateSession('session-a');
    store.applyExecutionPayload(_executionPayload('session-a', 'blocked', 1));
    store.setRuntimeNotice(
      const RuntimeNotice(
        sessionId: 'session-a',
        requestId: 'request-a',
        status: 'blocked',
        reason: 'network_error',
        title: 'Connection failed',
      ),
    );
    expect(
      store.attentionStateFor('session-a').visualState,
      SessionAttentionVisualState.blockedOrFatal,
    );

    store.applyExecutionPayload(_executionPayload('session-a', 'resuming', 2));
    store.clearRuntimeNotice(sessionId: 'session-a', requestId: 'request-a');
    expect(
      store.attentionStateFor('session-a').visualState,
      SessionAttentionVisualState.runningOrResuming,
    );

    store.applyExecutionPayload(_executionPayload('session-a', 'idle', 3));
    expect(
      store.attentionStateFor('session-a').visualState,
      SessionAttentionVisualState.normal,
    );
  });

  test('newer execution revision rejects a stale blocked notice', () {
    store.activateSession('session-a');
    store.applyExecutionPayload(_executionPayload('session-a', 'blocked', 4));
    store.setRuntimeNotice(
      const RuntimeNotice(
        sessionId: 'session-a',
        requestId: 'request-session-a',
        status: 'blocked',
        reason: 'unknown',
        title: 'Old block',
        executionRevision: 4,
      ),
    );
    expect(store.currentRuntimeNotice, isNotNull);

    store.applyExecutionPayload(_executionPayload('session-a', 'idle', 5));
    expect(store.currentRuntimeNotice, isNull);

    store.setRuntimeNotice(
      const RuntimeNotice(
        sessionId: 'session-a',
        requestId: 'request-session-a',
        status: 'blocked',
        reason: 'unknown',
        title: 'Delayed stale block',
        executionRevision: 4,
      ),
    );
    expect(store.currentRuntimeNotice, isNull);
    expect(
      store.attentionStateFor('session-a').visualState,
      SessionAttentionVisualState.normal,
    );
  });

  test('hydrates list/history shapes through the same execution reducer', () {
    store.hydrateSessionState({
      'session_id': 'session-a',
      'execution_snapshot': _executionPayload('session-a', 'running', 3),
    }, sessionId: 'session-a');
    store.hydrateSessionState({
      'session_id': 'session-a',
      'execution_snapshot': _executionPayload('session-a', 'queued', 2),
    }, sessionId: 'session-a');

    expect(store.attentionStateFor('session-a').executionSnapshot.revision, 3);
    expect(
      store.attentionStateFor('session-a').executionSnapshot.state,
      SessionExecutionState.running,
    );
  });
}

Map<String, dynamic> _executionPayload(
  String sessionId,
  String state,
  int revision,
) => {
  'session_id': sessionId,
  'state': state,
  'work_item_id': state == 'idle' ? null : 'work-$sessionId',
  'request_id': state == 'idle' ? null : 'request-$sessionId',
  'revision': revision,
  'updated_at': '2026-07-15T10:30:00Z',
};

DeviceSuspendedRequest _permission(String sessionId, String requestId) => DeviceSuspendedRequest.fromJson({
  'request_id': requestId,
  'session_id': sessionId,
  'tool_name': 'shell_execute',
});
