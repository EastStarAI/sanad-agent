import 'package:sanad_agent/engine/compaction/compaction.dart';
import 'package:sanad_agent/engine/runtime/compaction_failure_notice.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/persisted_runtime_state_repository.dart';
import 'package:test/test.dart';

/// A failed automatic compaction must be visible: the session keeps running
/// uncompacted, so the durable warning is the only record an operator or a
/// Client sees after the run.
void main() {
  late AgentStateDatabase state;
  late PersistedRuntimeStateRepository store;

  setUp(() {
    state = AgentStateDatabase.inMemory();
    store = PersistedRuntimeStateRepository.fromState(state);
  });

  tearDown(() {
    state.dispose();
  });

  test('a continuity failure records one visible warning notice', () {
    CompactionFailureNotice.report(
      store,
      sessionId: 'oneshot-338',
      reason: CompactionFailureReason.continuityValidationFailed,
      failureCause: CompactionFailureCause.continuityValidationFailed,
      requestId: 'turn-1',
    );

    final notice = store.findNotice('oneshot-338');
    expect(notice, isNotNull);
    expect(notice!.status, 'warning');
    expect(notice.severity, 'warning');
    expect(notice.reason, 'continuity_validation_failed');
    expect(notice.title, 'Automatic compaction failed');
    expect(notice.message, contains('continuity anchors'));
    expect(notice.message, contains('continuing without compacting'));
    expect(notice.actions, isEmpty);
    expect(notice.requestId, 'turn-1');
    expect(CompactionFailureNotice.isCompactionWarning(notice), isTrue);
  });

  test('a summarization failure records its own reason', () {
    CompactionFailureNotice.report(
      store,
      sessionId: 'oneshot-339',
      reason: CompactionFailureReason.summarizationFailed,
      failureCause: CompactionFailureCause.timeout,
    );

    final notice = store.findNotice('oneshot-339')!;
    expect(notice.reason, 'summarization_failed');
    expect(notice.message, contains('timed out'));
  });

  test('the message never carries provider text or conversation content', () {
    CompactionFailureNotice.report(
      store,
      sessionId: 'oneshot-340',
      reason: CompactionFailureReason.summarizationFailed,
      failureCause: 'sk-ant-api03-not-a-cause ${'x' * 200}',
    );

    final notice = store.findNotice('oneshot-340')!;
    expect(notice.message, isNot(contains('sk-ant')));
    expect(notice.message, isNot(contains('x' * 20)));
    expect(notice.message, contains('did not return a usable summary'));
  });

  test('an unknown cause still names a safe sentence for the reason', () {
    expect(
      CompactionFailureNotice.message(
        reason: CompactionFailureReason.continuityValidationFailed,
      ),
      contains('continuity anchors'),
    );
    expect(
      CompactionFailureNotice.message(
        reason: CompactionFailureReason.summarizationFailed,
      ),
      contains('did not return a usable summary'),
    );
  });

  test('a successful automatic compaction clears its own warning', () {
    CompactionFailureNotice.report(
      store,
      sessionId: 'oneshot-341',
      reason: CompactionFailureReason.continuityValidationFailed,
      failureCause: CompactionFailureCause.continuityValidationFailed,
    );
    expect(store.findNotice('oneshot-341'), isNotNull);

    CompactionFailureNotice.clear(store, sessionId: 'oneshot-341');

    expect(store.findNotice('oneshot-341'), isNull);
  });

  test('clearing a warning never deletes a recovery notice', () {
    store.upsertNotice(
      sessionId: 'session-recovery',
      status: 'blocked',
      reason: 'auth',
      title: 'Authentication failed',
      message: 'Choose a provider.',
      actions: const ['stop', 'retry', 'changeProvider'],
    );

    CompactionFailureNotice.clear(store, sessionId: 'session-recovery');

    final notice = store.findNotice('session-recovery');
    expect(notice, isNotNull);
    expect(notice!.status, 'blocked');
    expect(CompactionFailureNotice.isCompactionWarning(notice), isFalse);
  });
}
