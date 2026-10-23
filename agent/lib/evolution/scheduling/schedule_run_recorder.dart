import 'dart:async';

import 'package:logging/logging.dart';

import '../../core/secrets_redactor.dart';
import '../db/message_history_identity.dart';
import '../db/persisted_runtime_state_repository.dart';
import '../db/session_db.dart';
import '../models/session_execution_snapshot.dart';

/// Bounds on the failure text a run row may carry (Task 139 S16, A3).
///
/// The stored value is passed through [SecretsRedactor] first and then cut to
/// [maxErrorLength]; nothing here ever copies command output, file content, or
/// timeline text into the row.
abstract final class ScheduleRunErrorPolicy {
  static const int maxErrorLength = 500;
}

/// The observation a `schedule.run_failed` notice is published from
/// (Task 139 S16, S22).
///
/// The observer reports the failure it just terminalized together with the
/// schedule's current streak, so the publisher never recounts the streak and can
/// never disagree with the run row that caused it. `error` is the same bounded,
/// redacted text the row carries.
typedef ScheduleRunFailureSink = void Function({
  required String scheduleId,
  required String runId,
  required String sessionId,
  required int consecutiveFailures,
  required bool suggestPause,
  String? error,
});

/// The single write seam for `scheduled_task_runs` above the repository
/// (Task 139 A3, D9).
///
/// A run row is created as `running` before the dispatch event leaves the
/// scheduler, anchored on its user message when that message commits, and moved
/// to exactly one terminal state by the owner that observes the turn ending.
/// Retention is applied here on write, never on read (D2).
///
/// `CronScheduler` is still the only caller (112a D7): this owner decides *when*
/// and *with what* a run row is written, never *who* may write.
class ScheduleRunRecorder {
  static final Logger _logger = Logger('ScheduleRunRecorder');

  final SessionDB _db;
  final SecretsRedactor _redactor;
  final DateTime Function() _clock;

  ScheduleRunRecorder({
    required SessionDB db,
    SecretsRedactor redactor = const SecretsRedactor(),
    DateTime Function()? clock,
  }) : _db = db,
       _redactor = redactor,
       _clock = clock ?? DateTime.now;

  ScheduledTaskRunRepository get _runs => _db.scheduledTaskRuns;

  /// Writes the `running` row every dispatch must persist first, and returns
  /// its identity.
  ///
  /// The row and the retention prune share one transaction, so a reader never
  /// observes a dispatch that is neither recorded nor pruned.
  String startRun({
    String? id,
    required String scheduleId,
    required DateTime runAt,
    required ScheduledTaskRunTrigger trigger,
  }) {
    final now = _clock();
    late final String runId;
    _db.state.transaction((_) {
      runId = _runs.startRun(
        id: id,
        scheduleId: scheduleId,
        runAt: runAt,
        trigger: trigger,
        createdAt: now,
      );
      _runs.pruneRetainedRuns(scheduleId, now: now);
    });
    return runId;
  }

  /// Records a missed occurrence that never dispatched (A3).
  ///
  /// The row is created and terminalized in one transaction so no reader ever
  /// sees a skipped occurrence briefly reported as in flight.
  String recordSkipped({
    String? id,
    required String scheduleId,
    required DateTime runAt,
  }) {
    final now = _clock();
    late final String runId;
    _db.state.transaction((_) {
      runId = _runs.startRun(
        id: id,
        scheduleId: scheduleId,
        runAt: runAt,
        trigger: ScheduledTaskRunTrigger.recovery,
        createdAt: now,
      );
      _runs.completeRun(
        runId,
        status: ScheduledTaskRunStatus.skipped,
        durationMs: 0,
      );
      _runs.pruneRetainedRuns(scheduleId, now: now);
    });
    return runId;
  }

  /// Anchors a run on its user message (S9, S20).
  ///
  /// The conversation is written together with the message identity because
  /// the run repository has exactly one writer for that pair: a `new_each_run`
  /// run's conversation is otherwise unreachable from history.
  bool attachUserMessage(
    String runId, {
    required String sessionId,
    required String messageId,
  }) {
    if (sessionId.trim().isEmpty || messageId.trim().isEmpty) return false;
    return _runs.attachMessage(
      runId,
      sessionId: sessionId,
      messageId: messageId,
    );
  }

  /// Moves a run to its one terminal state (D9).
  ///
  /// The duration is measured from dispatch acceptance — the row's own creation
  /// instant — to now, so no caller can report a duration it did not observe.
  /// A repeated or late observation changes nothing and returns `false`.
  bool completeRun(
    String runId, {
    required ScheduledTaskRunStatus status,
    String? error,
  }) {
    if (!status.isTerminal) {
      throw ArgumentError.value(
        status,
        'status',
        'completeRun requires a terminal status',
      );
    }
    final run = _runs.getRun(runId);
    if (run == null || run.status.isTerminal) return false;
    final now = _clock();
    final elapsed = now.toUtc().difference(run.createdAt.toUtc());
    final durationMs = elapsed.isNegative ? 0 : elapsed.inMilliseconds;
    final applied = _runs.completeRun(
      runId,
      status: status,
      durationMs: durationMs,
      error: status == ScheduledTaskRunStatus.failed
          ? boundError(error)
          : null,
    );
    if (applied) {
      _runs.pruneRetainedRuns(run.scheduleId, now: now);
    }
    return applied;
  }

  /// Applies the bounded, redacted failure-text policy (S16).
  ///
  /// Returns null for an absent or blank reason: a failed run with no
  /// observable cause carries no invented explanation.
  String? boundError(String? error) {
    final redacted = _redactor.redact(error ?? '').trim();
    if (redacted.isEmpty) return null;
    if (redacted.length <= ScheduleRunErrorPolicy.maxErrorLength) {
      return redacted;
    }
    return '${redacted.substring(0, ScheduleRunErrorPolicy.maxErrorLength)}…';
  }

  /// Resolves the run's durable user-message identity (S9, S20).
  ///
  /// The engine commits the run's user message with the run identity as its
  /// request identity, so the anchor is a read of durable history rather than a
  /// scheduler-side correlation. Returns null until that message exists.
  String? resolveUserMessageId(String sessionId, String requestId) {
    if (sessionId.isEmpty || requestId.isEmpty) return null;
    try {
      final rowId = _db.messageRepository.activeRootRowIdForRequest(
        sessionId,
        requestId,
      );
      if (rowId == null) return null;
      final page = _db.getPersistedMessagePage(
        sessionId,
        limit: 1,
        anchorRowId: rowId,
      );
      if (page.messages.isEmpty) return null;
      final messageId = MessageHistoryIdentity.read(
        page.messages.first.message,
      ).messageId;
      return messageId.isEmpty ? null : messageId;
    } catch (error) {
      // A history that moved under the anchor (rewrite, fork, delete) simply
      // has no position yet; the next observation retries.
      _logger.fine('Run anchor not resolvable yet: $error');
      return null;
    }
  }

  /// Completes every run row that is still `running` but no longer owned by
  /// active work, so a restart never leaves a run reported as in flight.
  ///
  /// Runs whose work item is still active keep running: startup recovery
  /// resumes them and the observer finishes them normally. Idempotent — a
  /// second pass over the same rows writes nothing.
  int recoverInterruptedRuns({
    required bool Function(String sessionId, String runId) isRunActive,
  }) {
    final now = _clock();
    var recovered = 0;
    for (final row in _db.scheduledTasks.getAllScheduledTasks()) {
      final scheduleId = row['id'] as String;
      final page = _runs.listRuns(
        scheduleId,
        limit: ScheduledTaskRunRetention.maxRunsPerSchedule,
      );
      for (final run in page.runs) {
        if (run.status.isTerminal) continue;
        final sessionId = run.sessionId;
        if (sessionId != null && isRunActive(sessionId, run.id)) continue;
        final elapsed = now.toUtc().difference(run.createdAt.toUtc());
        final durationMs = elapsed.isNegative ? 0 : elapsed.inMilliseconds;
        final applied = _runs.completeRun(
          run.id,
          status: ScheduledTaskRunStatus.failed,
          durationMs: durationMs,
          error: boundError(interruptedRunError),
        );
        if (applied) recovered++;
      }
    }
    if (recovered > 0) {
      _logger.info('Completed $recovered interrupted schedule run(s)');
    }
    return recovered;
  }

  /// Returns the number of consecutive failed runs for [scheduleId].
  ///
  /// A successful run resets the streak to 0. A manual failure counts the same
  /// as a scheduled failure (S16, S22).
  int consecutiveFailures(String scheduleId) {
    final page = _runs.listRuns(scheduleId, limit: 10);
    var count = 0;
    for (final run in page.runs) {
      if (run.status == ScheduledTaskRunStatus.running) continue;
      if (run.status == ScheduledTaskRunStatus.failed) {
        count++;
      } else {
        break;
      }
    }
    return count;
  }

  /// Whether the UI or notice should suggest pausing the schedule (S16, S22).
  bool suggestPause(String scheduleId) => consecutiveFailures(scheduleId) >= 3;

  /// The bounded reason recorded for a run whose turn never reached this
  /// process.
  static const String interruptedRunError =
      'The run was interrupted before it finished.';
}

/// How the run-history owner can classify a run's turn from durable state.
enum ScheduleRunTurnOutcome {
  /// The turn is still owned by durable work.
  active,

  /// The turn committed its terminal answer.
  completed,

  /// The turn was cancelled, stopped, or failed.
  failed,

  /// Nothing durable is known about the turn any more.
  unknown,
}

/// Ends schedule runs by observing the conversation they dispatched into
/// (Task 139 A3, D9).
///
/// The scheduler cannot see turn responses: they are delivered to the Sanad
/// client family, not to the cron platform. The run's turn is therefore
/// correlated through durable runtime state — the run identity is the turn's
/// request identity — and this observer only ever calls
/// [ScheduleRunRecorder]; it never writes a row itself.
class ScheduleRunObserver {
  static final Logger _logger = Logger('ScheduleRunObserver');

  final ScheduleRunRecorder _recorder;
  final ScheduleRunTurnOutcome Function(String sessionId, String runId)
  _lookupOutcome;
  final String? Function(String sessionId, String runId)? _lookupError;
  final ScheduleRunFailureSink? _onRunFailed;

  /// The run whose turn a conversation is currently executing.
  final Map<String, String> _activeRunBySession = {};
  final Map<String, _PendingScheduleRun> _pending = {};
  StreamSubscription<SessionExecutionSnapshot>? _subscription;

  ScheduleRunObserver({
    required ScheduleRunRecorder recorder,
    required ScheduleRunTurnOutcome Function(String sessionId, String runId)
    lookupOutcome,
    String? Function(String sessionId, String runId)? lookupError,
    ScheduleRunFailureSink? onRunFailed,
  }) : _recorder = recorder,
       _lookupOutcome = lookupOutcome,
       _lookupError = lookupError,
       _onRunFailed = onRunFailed;

  /// Default outcome classifier based on durable runtime state.
  static ScheduleRunTurnOutcome defaultLookupOutcome(
    PersistedRuntimeStateRepository? persistedState,
    String sessionId,
    String runId,
  ) {
    if (persistedState == null) return ScheduleRunTurnOutcome.completed;
    final item = persistedState.workItems.findByRequestId(sessionId, runId);
    if (item != null) {
      if (item.state == SessionWorkState.completed) {
        return ScheduleRunTurnOutcome.completed;
      }
      if (item.state == SessionWorkState.cancelled) {
        return ScheduleRunTurnOutcome.failed;
      }
      return ScheduleRunTurnOutcome.active;
    }
    final notice = persistedState.notices.findNotice(sessionId);
    if (notice != null && (notice.requestId == runId || notice.runId == runId)) {
      return ScheduleRunTurnOutcome.failed;
    }
    return ScheduleRunTurnOutcome.completed;
  }

  /// Runs started and not yet resolved.
  Iterable<String> get pendingRunIds => _pending.keys;

  bool get isListening => _subscription != null;

  /// Subscribes to the durable execution-state stream.
  ///
  /// A second call is a no-op, so a restart of the scheduler never
  /// double-subscribes.
  void listen(Stream<SessionExecutionSnapshot> changes) {
    if (_subscription != null) return;
    _subscription = changes.listen(observe);
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
    _activeRunBySession.clear();
    _pending.clear();
  }

  /// Registers a dispatched run so its turn ending is observed.
  void track({
    required String runId,
    required String sessionId,
    required String scheduleId,
  }) {
    if (runId.isEmpty || sessionId.isEmpty) return;
    _pending[runId] = _PendingScheduleRun(
      runId: runId,
      sessionId: sessionId,
      scheduleId: scheduleId,
    );
  }

  /// Stops observing a run whose row no longer exists (a fired one-shot
  /// schedule is removed with its run rows).
  void forget(String runId) {
    _pending.remove(runId);
    _activeRunBySession.removeWhere((_, value) => value == runId);
  }

  /// One durable execution-state observation.
  ///
  /// Visible for testing so the whole correlation is exercised without a live
  /// orchestrator.
  void observe(SessionExecutionSnapshot snapshot) {
    final sessionId = snapshot.sessionId;
    final requestId = snapshot.requestId;

    for (final pending in _pending.values.toList(growable: false)) {
      if (pending.sessionId != sessionId || pending.anchorAttempted) continue;
      _tryAttachAnchor(pending);
    }

    if (requestId != null && _pending.containsKey(requestId)) {
      _activeRunBySession[sessionId] = requestId;
    }

    final bound = _activeRunBySession[sessionId];
    if (bound == null) return;
    if (snapshot.state != SessionExecutionState.idle) return;

    // The conversation is idle again: the bound run's turn ended.
    final outcome = _lookupOutcome(sessionId, bound);
    if (outcome == ScheduleRunTurnOutcome.active) return;
    _activeRunBySession.remove(sessionId);
    _finish(bound, sessionId, outcome);
  }

  void _tryAttachAnchor(_PendingScheduleRun pending) {
    final messageId = _recorder.resolveUserMessageId(
      pending.sessionId,
      pending.runId,
    );
    if (messageId == null) return;
    pending.anchorAttempted = true;
    final attached = _recorder.attachUserMessage(
      pending.runId,
      sessionId: pending.sessionId,
      messageId: messageId,
    );
    if (!attached) {
      _logger.fine('Run ${pending.runId} row is gone; anchor not stored');
    }
  }

  void _finish(
    String runId,
    String sessionId,
    ScheduleRunTurnOutcome outcome,
  ) {
    final pending = _pending.remove(runId);
    if (pending == null) return;
    if (!pending.anchorAttempted) _tryAttachAnchor(pending);
    switch (outcome) {
      case ScheduleRunTurnOutcome.completed:
        _recorder.completeRun(runId, status: ScheduledTaskRunStatus.succeeded);
      case ScheduleRunTurnOutcome.failed:
      case ScheduleRunTurnOutcome.unknown:
        final rawError = _lookupError?.call(sessionId, runId) ??
            ScheduleRunRecorder.interruptedRunError;
        final errorText = _recorder.boundError(rawError);
        final applied = _recorder.completeRun(
          runId,
          status: ScheduledTaskRunStatus.failed,
          error: errorText,
        );
        if (applied) {
          final failures = _recorder.consecutiveFailures(pending.scheduleId);
          _onRunFailed?.call(
            scheduleId: pending.scheduleId,
            runId: runId,
            sessionId: sessionId,
            consecutiveFailures: failures,
            suggestPause: failures >= 3,
            error: errorText,
          );
        }
      case ScheduleRunTurnOutcome.active:
        _pending[runId] = pending;
    }
  }
}

class _PendingScheduleRun {
  final String runId;
  final String sessionId;
  final String scheduleId;
  bool anchorAttempted = false;

  _PendingScheduleRun({
    required this.runId,
    required this.sessionId,
    required this.scheduleId,
  });
}
