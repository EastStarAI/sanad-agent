import 'legacy_runtime_state_migrator.dart';
import 'runtime_notice_repository.dart';
import 'session_execution_state_coordinator.dart';
import '../../models/session_execution_snapshot.dart';

/// Central runtime-state cleanup for a session and orphaned work items.
///
/// Owns the cross-table `clearAllForSession` path used by `Stop` and
/// session-deletion flows. Delegates to the per-aggregate repositories to
/// preserve atomic semantics: notice deletion, work-item cancellation and
/// legacy-row purge all run against the same `AgentStateDatabase`
/// transactional boundaries. No parallel state map is created here — the
/// class is pure delegation over the durable single source of truth.
class RuntimeStateCleanup {
  final RuntimeNoticeRepository _noticeRepository;
  final SessionExecutionStateCoordinator _executionStateCoordinator;
  final LegacyRuntimeStateMigrator _legacyMigrator;

  RuntimeStateCleanup({
    required RuntimeNoticeRepository noticeRepository,
    required SessionExecutionStateCoordinator executionStateCoordinator,
    required LegacyRuntimeStateMigrator legacyMigrator,
  }) : _noticeRepository = noticeRepository,
       _executionStateCoordinator = executionStateCoordinator,
       _legacyMigrator = legacyMigrator;

  /// Clears all persisted runtime state for [sessionId] (suspended + pending
  /// + notice + work items). Used by `stop` and when a session is deleted.
  ///
  /// The legacy `session_suspended_runs` and `session_pending_runs` rows are
  /// purged with raw SQL (not via the deprecated helpers) so the central
  /// cleanup path stays free of internal `@Deprecated` calls. In production
  /// those tables are empty because `session_work_items` is the single
  /// source of truth (Gate C.1).
  SessionExecutionSnapshotChange clearAllForSession(
    String sessionId, {
    bool publishExecutionChange = true,
  }) {
    _noticeRepository.deleteNotice(sessionId);
    final executionChange = _executionStateCoordinator.cancelAll(
      sessionId,
      publish: publishExecutionChange,
    );

    // Legacy tables (Gate C.1) — empty in production but may still hold
    // stale rows in databases that predate the Gate C migration. Purge them
    // with raw SQL to avoid invoking the deprecated helpers internally.
    // This cleanup is best-effort: a transient lock on a legacy row must not
    // prevent the authoritative notice/work-item cleanup required by Stop.
    _legacyMigrator.purgeLegacySuspendedRunsForSession(sessionId);
    _legacyMigrator.purgeLegacyPendingRunsForSession(sessionId);
    return executionChange;
  }
}
