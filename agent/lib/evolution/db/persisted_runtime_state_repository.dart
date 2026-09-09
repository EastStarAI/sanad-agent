import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../core/models/message.dart';
import 'message_history_identity.dart';
import '../models/session_execution_snapshot.dart';
import 'agent_state_database.dart';
import 'runtime/legacy_runtime_state_migrator.dart';
import 'runtime/pending_input_repository.dart';
import 'runtime/runtime_notice_repository.dart';
import 'runtime/runtime_state_cleanup.dart';
import 'runtime/session_execution_snapshot_repository.dart';
import 'runtime/session_execution_state_coordinator.dart';
import 'runtime/session_work_item_repository.dart';

/// Persisted runtime state for a session — the durable mirror of
/// `SessionRunOrchestrator`'s in-memory `_suspendedEvents`/`_pendingEvents`
/// and the active `RuntimeNotice` from `RuntimeRecoveryService`.
///
/// All write paths are fire-and-forget write-through from the orchestrator so
/// that restarting the daemon can rebuild the work queues from SQLite.
/// Secrets never live here: only message text, request ids, provider/model
/// route ids, and the already-redacted notice message.
//
// Gate E — this class is a transitional facade over the new per-aggregate
// repositories in `lib/evolution/db/runtime/`. Each method delegates to the
// matching repository so callers (orchestrator, recovery service, queue
// coordinator, turn executor, coordinators) keep the existing public API
// while the responsibility split is verified. No parallel state map lives
// in the facade: every table is owned by exactly one repository and the
// facade only re-dispatches. Cleanup is composition-based via
// `RuntimeStateCleanup`.
class PersistedRuntimeStateRepository {
  final Database _db;
  late final SessionWorkItemRepository _workItems;
  late final SessionExecutionSnapshotRepository _executionSnapshots;
  late final SessionExecutionStateCoordinator _executionState;
  late final RuntimeNoticeRepository _notices;
  late final PendingInputRepository _pendingInputs;
  late final LegacyRuntimeStateMigrator _legacy;
  late final RuntimeStateCleanup _cleanup;

  PersistedRuntimeStateRepository(Database db)
    : this.fromState(AgentStateDatabase.attached(db));

  PersistedRuntimeStateRepository.fromState(AgentStateDatabase state)
    : _db = state.db {
    _workItems = SessionWorkItemRepository(state);
    _executionSnapshots = SessionExecutionSnapshotRepository(state);
    _pendingInputs = PendingInputRepository(state);
    _executionState = SessionExecutionStateCoordinator(
      state: state,
      workItems: _workItems,
      snapshots: _executionSnapshots,
      pendingInputs: _pendingInputs,
    );
    _notices = RuntimeNoticeRepository(_db);
    _legacy = LegacyRuntimeStateMigrator(_db);
    _cleanup = RuntimeStateCleanup(
      noticeRepository: _notices,
      executionStateCoordinator: _executionState,
      legacyMigrator: _legacy,
    );
  }

  @visibleForTesting
  Database get db => _db;

  /// Direct access to the work-item repository (Gate E composition).
  /// Use this when a caller needs only work-item operations and wants
  /// the focused single-responsibility interface.
  SessionWorkItemRepository get workItems => _workItems;

  SessionExecutionSnapshotRepository get executionSnapshots =>
      _executionSnapshots;

  SessionExecutionStateCoordinator get executionState => _executionState;

  /// Direct access to the notice repository (Gate E composition).
  RuntimeNoticeRepository get notices => _notices;

  PendingInputRepository get pendingInputs => _pendingInputs;

  /// Direct access to the legacy runtime-state migrator (Gate E composition).
  /// Use only for reading or purging pre-Gate-C rows.
  LegacyRuntimeStateMigrator get legacy => _legacy;

  /// Direct access to the central cleanup path used by `Stop` and
  /// session deletion.
  RuntimeStateCleanup get cleanup => _cleanup;

  // ── Suspended runs (legacy facade) ──────────────────────────────────────

  /// Inserts or replaces the suspended run for [sessionId]. Legacy
  /// compatibility API. Do not call from new code — use
  /// `session_work_items` via `enqueueWorkItem` and the transition API.
  @Deprecated(
    'session_suspended_runs is legacy. Use session_work_items (Gate C) as the single source of truth.',
  )
  void upsertSuspendedRun({
    required String sessionId,
    String? requestId,
    String? runId,
    String? message,
    Map<String, dynamic>? eventMetadata,
    String? workspaceId,
    String? providerInstanceId,
    String? modelId,
    String? thinkingMode,
  }) => _legacy.upsertSuspendedRun(
    sessionId: sessionId,
    requestId: requestId,
    runId: runId,
    message: message,
    eventMetadata: eventMetadata,
    workspaceId: workspaceId,
    providerInstanceId: providerInstanceId,
    modelId: modelId,
    thinkingMode: thinkingMode,
  );

  /// Returns the suspended run for [sessionId], or null.
  @Deprecated(
    'session_suspended_runs is legacy. Use session_work_items (Gate C) as the single source of truth.',
  )
  PersistedSuspendedRun? findSuspendedRun(String sessionId) =>
      _legacy.findSuspendedRun(sessionId);

  /// Returns all persisted suspended runs (used at daemon bootstrap).
  @Deprecated(
    'session_suspended_runs is legacy. Use session_work_items (Gate C) as the single source of truth.',
  )
  List<PersistedSuspendedRun> findAllSuspendedRuns() =>
      _legacy.findAllSuspendedRuns();

  @Deprecated(
    'session_suspended_runs is legacy. Use session_work_items (Gate C) as the single source of truth.',
  )
  void deleteSuspendedRun(String sessionId) =>
      _legacy.deleteSuspendedRun(sessionId);

  // ── Pending runs (queued messages) — legacy facade ──────────────────────

  /// Appends a pending run to the end of [sessionId]'s queue. Legacy
  /// compatibility API — do not call from new code.
  @Deprecated(
    'session_pending_runs is legacy. Use session_work_items (Gate C) as the single source of truth.',
  )
  void appendPendingRun({
    required String sessionId,
    String? requestId,
    String? message,
    Map<String, dynamic>? eventMetadata,
    String? workspaceId,
    String? providerInstanceId,
    String? modelId,
    String? thinkingMode,
    String? runId,
    String eventType = 'message',
  }) => _legacy.appendPendingRun(
    sessionId: sessionId,
    requestId: requestId,
    message: message,
    eventMetadata: eventMetadata,
    workspaceId: workspaceId,
    providerInstanceId: providerInstanceId,
    modelId: modelId,
    thinkingMode: thinkingMode,
    runId: runId,
    eventType: eventType,
  );

  /// Returns the pending runs for [sessionId] in FIFO order (by `seq`).
  @Deprecated(
    'session_pending_runs is legacy. Use session_work_items (Gate C) as the single source of truth.',
  )
  List<PersistedPendingRun> findPendingRuns(String sessionId) =>
      _legacy.findPendingRuns(sessionId);

  /// Returns all pending runs grouped by session (used at daemon bootstrap).
  @Deprecated(
    'session_pending_runs is legacy. Use session_work_items (Gate C) as the single source of truth.',
  )
  Map<String, List<PersistedPendingRun>> findAllPendingRuns() =>
      _legacy.findAllPendingRuns();

  /// Removes and returns the first pending run for [sessionId] (FIFO), or null.
  @Deprecated(
    'session_pending_runs is legacy. Use session_work_items (Gate C) as the single source of truth.',
  )
  PersistedPendingRun? popFirstPendingRun(String sessionId) =>
      _legacy.popFirstPendingRun(sessionId);

  /// Removes all pending runs for [sessionId].
  @Deprecated(
    'session_pending_runs is legacy. Use session_work_items (Gate C) as the single source of truth.',
  )
  void deleteAllPendingRuns(String sessionId) =>
      _legacy.deleteAllPendingRuns(sessionId);

  /// Updates the provider/model route on all pending runs for [sessionId].
  @Deprecated(
    'session_pending_runs is legacy. Use session_work_items (Gate C) as the single source of truth.',
  )
  void rewritePendingRoute(
    String sessionId, {
    String? providerInstanceId,
    String? modelId,
  }) => _legacy.rewritePendingRoute(
    sessionId,
    providerInstanceId: providerInstanceId,
    modelId: modelId,
  );

  // ── Runtime notices ─────────────────────────────────────────────────────

  /// Inserts or replaces the active runtime notice for [sessionId].
  void upsertNotice({
    required String sessionId,
    String? requestId,
    String? runId,
    required String status,
    required String reason,
    String severity = 'warning',
    required String title,
    required String message,
    String? providerInstanceId,
    String? providerDisplayName,
    int? retryAfterMs,
    String? resumeAt,
    int? limitRpm,
    List<String> actions = const [],
    DateTime? createdAt,
  }) => _notices.upsertNotice(
    sessionId: sessionId,
    requestId: requestId,
    runId: runId,
    status: status,
    reason: reason,
    severity: severity,
    title: title,
    message: message,
    providerInstanceId: providerInstanceId,
    providerDisplayName: providerDisplayName,
    retryAfterMs: retryAfterMs,
    resumeAt: resumeAt,
    limitRpm: limitRpm,
    actions: actions,
    createdAt: createdAt,
  );

  PersistedRuntimeNotice? findNotice(String sessionId) =>
      _notices.findNotice(sessionId);

  Map<String, PersistedRuntimeNotice> findAllNotices() =>
      _notices.findAllNotices();

  /// Deletes the active notice for [sessionId].
  void deleteNotice(String sessionId) => _notices.deleteNotice(sessionId);

  // ── Central cleanup path ────────────────────────────────────────────────

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
  }) => _cleanup.clearAllForSession(
    sessionId,
    publishExecutionChange: publishExecutionChange,
  );

  // ── Work Items (Gate C.1) — facade delegation ───────────────────────────

  /// Inserts a new work item into the database.
  void insertWorkItem(SessionWorkItem item) => _workItems.insertWorkItem(item);

  /// Inserts a work item while assigning the next FIFO sequence atomically
  /// inside the same transaction.
  SessionWorkItem enqueueWorkItem({
    required String workItemId,
    required String sessionId,
    String? requestId,
    String? providerInstanceId,
    String? modelId,
    String? workspaceId,
    Map<String, dynamic> payload = const {},
    int attempt = 0,
    SessionWorkState state = SessionWorkState.queued,
    Map<String, dynamic> continuationMetadata = const {},
  }) => _executionState
      .enqueueWorkItem(
        workItemId: workItemId,
        sessionId: sessionId,
        requestId: requestId,
        providerInstanceId: providerInstanceId,
        modelId: modelId,
        workspaceId: workspaceId,
        payload: payload,
        attempt: attempt,
        state: state,
        continuationMetadata: continuationMetadata,
      )
      .value;

  /// Atomically admits a newly accepted message as either the active running
  /// item or a queued item behind durable active work.
  SessionWorkItem admitWorkItem({
    required String workItemId,
    required String sessionId,
    String? requestId,
    String? providerInstanceId,
    String? modelId,
    String? workspaceId,
    Map<String, dynamic> payload = const {},
    int attempt = 0,
  }) => _executionState
      .admitWorkItem(
        workItemId: workItemId,
        sessionId: sessionId,
        requestId: requestId,
        providerInstanceId: providerInstanceId,
        modelId: modelId,
        workspaceId: workspaceId,
        payload: payload,
        attempt: attempt,
      )
      .value;

  /// Finds a work item by ID.
  SessionWorkItem? findWorkItem(String workItemId) =>
      _workItems.findWorkItem(workItemId);

  /// Finds the single active (non-terminal) work item for a session, or null.
  SessionWorkItem? findActiveWorkItem(String sessionId) =>
      _workItems.findActiveWorkItem(sessionId);

  /// Finds all queued work items in FIFO order.
  List<SessionWorkItem> findQueuedWorkItems(String sessionId) =>
      _workItems.findQueuedWorkItems(sessionId);

  /// Atomically claims the oldest queued work item for a session by moving it
  /// to [toState]. Returns the claimed item after transition, or null when no
  /// queued item exists.
  SessionWorkItem? claimNextQueuedWorkItem(
    String sessionId, {
    SessionWorkState toState = SessionWorkState.running,
  }) => _executionState
      .claimNext(
        sessionId,
        isResume: toState == SessionWorkState.resuming,
        toState: toState,
      )
      .value;

  /// Rewrites the route for every non-terminal queued item atomically.
  void rewriteQueuedWorkItemRoute(
    String sessionId, {
    String? providerInstanceId,
    String? modelId,
  }) => _workItems.rewriteQueuedWorkItemRoute(
    sessionId,
    providerInstanceId: providerInstanceId,
    modelId: modelId,
  );

  /// Gate E.2: rewrites the provider/model route for every non-terminal work
  /// item (queued, running, waiting, blocked, resuming) atomically.
  void rewriteAllNonTerminalWorkItemRoute(
    String sessionId, {
    String? providerInstanceId,
    String? modelId,
  }) => _workItems.rewriteAllNonTerminalWorkItemRoute(
    sessionId,
    providerInstanceId: providerInstanceId,
    modelId: modelId,
  );

  /// Finds all work items for a session.
  List<SessionWorkItem> findAllWorkItems(String sessionId) =>
      _workItems.findAllWorkItems(sessionId);

  /// Finds only queued and active work relevant to startup reconstruction.
  List<SessionWorkItem> findRestorableWorkItems(String sessionId) =>
      _workItems.findRestorableWorkItems(sessionId);

  /// Finds all distinct session IDs that have work items.
  List<String> findAllSessionIdsWithWorkItems() =>
      _workItems.findAllSessionIdsWithWorkItems();

  /// Finds sessions with queued or active work relevant to startup recovery.
  List<String> findSessionIdsWithRestorableWorkItems() =>
      _workItems.findSessionIdsWithRestorableWorkItems();

  /// Cancels all active and queued work items for a session.
  void cancelAllActiveAndQueuedWorkItems(String sessionId) =>
      _executionState.cancelAll(sessionId);

  void markSessionStopping(String sessionId, {String? expectedWorkItemId}) =>
      _executionState.markStopping(
        sessionId,
        expectedWorkItemId: expectedWorkItemId,
      );

  SessionExecutionSnapshotChange cancelWorkItems(
    String sessionId,
    Iterable<String> workItemIds, {
    bool publishExecutionChange = true,
  }) => _executionState.cancelWorkItems(
    sessionId,
    workItemIds,
    publish: publishExecutionChange,
  );

  bool transitionOwnedWorkItem({
    required String sessionId,
    required String workItemId,
    required SessionWorkState toState,
  }) => _executionState
      .transitionOwnedWorkItem(
        sessionId: sessionId,
        workItemId: workItemId,
        toState: toState,
      )
      .applied;

  bool bindRunOwnership({
    required String sessionId,
    required String workItemId,
    required String runId,
    required int generation,
  }) => _executionState.bindRunOwnership(
    sessionId: sessionId,
    workItemId: workItemId,
    runId: runId,
    generation: generation,
  );

  bool claimOwnedAutomaticRetry({
    required String sessionId,
    required String workItemId,
    required String runId,
    required int generation,
    String? requestId,
  }) => _executionState
      .claimOwnedAutomaticRetry(
        sessionId: sessionId,
        workItemId: workItemId,
        runId: runId,
        generation: generation,
        requestId: requestId,
      )
      .applied;

  /// Returns the authoritative active conversation rows, including identity
  /// columns that may not yet be mirrored by an in-memory session snapshot.
  List<Message> findActiveMessages(String sessionId) {
    final rows = _db.select(
      '''
      SELECT data, message_id, turn_id, history_status, input_kind,
             request_id, run_id, superseded_by_turn_id, origin_message_id
      FROM messages
      WHERE session_id = ?
        AND (history_status = 'active' OR history_status IS NULL)
      ORDER BY id ASC
      ''',
      [sessionId],
    );
    return [
      for (final row in rows)
        MessageHistoryIdentity.overlayFromRow(
          Message.fromJson(
            Map<String, dynamic>.from(jsonDecode(row['data'] as String) as Map),
          ),
          row,
        ),
    ];
  }

  TerminalCommitOutcome commitTerminal({
    required String sessionId,
    required String workItemId,
    required String runId,
    required int generation,
    required Message assistantResult,
  }) => _executionState.commitTerminal(
    sessionId: sessionId,
    workItemId: workItemId,
    runId: runId,
    generation: generation,
    assistantResult: assistantResult,
  );

  /// Performs an atomic state transition with validation.
  void transitionWorkItemState({
    required String workItemId,
    required SessionWorkState fromState,
    required SessionWorkState toState,
    int? attempt,
    Map<String, dynamic>? continuationMetadata,
    String? providerInstanceId,
    String? modelId,
  }) => _executionState.transitionWorkItem(
    workItemId: workItemId,
    fromState: fromState,
    toState: toState,
    attempt: attempt,
    continuationMetadata: continuationMetadata,
    providerInstanceId: providerInstanceId,
    modelId: modelId,
  );

  /// Directly updates other mutable fields of a work item.
  void updateWorkItem(SessionWorkItem item) => _workItems.updateWorkItem(item);

  /// Deletes a specific work item.
  void deleteWorkItem(String workItemId) =>
      _workItems.deleteWorkItem(workItemId);

  /// Deletes all work items for a session.
  void deleteAllWorkItemsForSession(String sessionId) =>
      _workItems.deleteAllWorkItemsForSession(sessionId);

  /// Returns the next sequence number for a session.
  int nextWorkItemSeq(String sessionId) =>
      _workItems.nextWorkItemSeq(sessionId);

  /// Deletes rows whose `session_id` no longer exists in `sessions`.
  int cleanupOrphanedWorkItems() => _workItems.cleanupOrphanedWorkItems();
}

enum SessionWorkState {
  queued,
  running,
  waiting,
  blocked,
  resuming,
  completed,
  cancelled,
}

class SessionWorkItem {
  final String workItemId;
  final String sessionId;
  final String? requestId;
  final int sequence;
  final String? providerInstanceId;
  final String? modelId;
  final String? workspaceId;
  final Map<String, dynamic> payload;
  final int attempt;
  final SessionWorkState state;
  final Map<String, dynamic> continuationMetadata;
  final DateTime createdAt;
  final DateTime updatedAt;

  const SessionWorkItem({
    required this.workItemId,
    required this.sessionId,
    this.requestId,
    required this.sequence,
    this.providerInstanceId,
    this.modelId,
    this.workspaceId,
    this.payload = const {},
    required this.attempt,
    required this.state,
    this.continuationMetadata = const {},
    required this.createdAt,
    required this.updatedAt,
  });

  SessionWorkItem copyWith({
    String? workItemId,
    String? sessionId,
    String? requestId,
    int? sequence,
    String? providerInstanceId,
    String? modelId,
    String? workspaceId,
    Map<String, dynamic>? payload,
    int? attempt,
    SessionWorkState? state,
    Map<String, dynamic>? continuationMetadata,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return SessionWorkItem(
      workItemId: workItemId ?? this.workItemId,
      sessionId: sessionId ?? this.sessionId,
      requestId: requestId ?? this.requestId,
      sequence: sequence ?? this.sequence,
      providerInstanceId: providerInstanceId ?? this.providerInstanceId,
      modelId: modelId ?? this.modelId,
      workspaceId: workspaceId ?? this.workspaceId,
      payload: payload ?? this.payload,
      attempt: attempt ?? this.attempt,
      state: state ?? this.state,
      continuationMetadata: continuationMetadata ?? this.continuationMetadata,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? DateTime.now(),
    );
  }

  factory SessionWorkItem.fromRow(Map<String, dynamic> row) {
    final stateStr = row['state'] as String;
    final stateVal = SessionWorkState.values.firstWhere(
      (s) => s.name == stateStr,
      orElse: () => SessionWorkState.queued,
    );
    return SessionWorkItem(
      workItemId: row['work_item_id'] as String,
      sessionId: row['session_id'] as String,
      requestId: row['request_id'] as String?,
      sequence: row['sequence'] as int,
      providerInstanceId: row['provider_instance_id'] as String?,
      modelId: row['model_id'] as String?,
      workspaceId: row['workspace_id'] as String?,
      payload: _decodeJsonMap(row['payload_json'] as String? ?? '{}'),
      attempt: row['attempt'] as int,
      state: stateVal,
      continuationMetadata: _decodeJsonMap(
        row['continuation_metadata'] as String? ?? '{}',
      ),
      createdAt: DateTime.parse(row['created_at'] as String),
      updatedAt: DateTime.parse(row['updated_at'] as String),
    );
  }
}

/// DTO representing a persisted suspended run (mirror of `_SuspendedRun`).
class PersistedSuspendedRun {
  final String sessionId;
  final String? requestId;
  final String? runId;
  final String? message;
  final Map<String, dynamic> eventMetadata;
  final String? workspaceId;
  final String? providerInstanceId;
  final String? modelId;
  final String? thinkingMode;

  const PersistedSuspendedRun({
    required this.sessionId,
    this.requestId,
    this.runId,
    this.message,
    this.eventMetadata = const {},
    this.workspaceId,
    this.providerInstanceId,
    this.modelId,
    this.thinkingMode,
  });

  factory PersistedSuspendedRun.fromRow(Map<String, dynamic> row) {
    return PersistedSuspendedRun(
      sessionId: row['session_id'] as String,
      requestId: row['request_id'] as String?,
      runId: row['run_id'] as String?,
      message: row['message'] as String?,
      eventMetadata: _decodeJsonMap(row['event_metadata'] as String? ?? '{}'),
      workspaceId: row['workspace_id'] as String?,
      providerInstanceId: row['provider_instance_id'] as String?,
      modelId: row['model_id'] as String?,
      thinkingMode: row['thinking_mode'] as String?,
    );
  }
}

/// DTO representing a persisted queued/pending message.
class PersistedPendingRun {
  final int id;
  final String sessionId;
  final String? requestId;
  final String? message;
  final Map<String, dynamic> eventMetadata;
  final String? workspaceId;
  final String? providerInstanceId;
  final String? modelId;
  final String? thinkingMode;
  final String? runId;
  final String eventType;

  const PersistedPendingRun({
    required this.id,
    required this.sessionId,
    this.requestId,
    this.message,
    this.eventMetadata = const {},
    this.workspaceId,
    this.providerInstanceId,
    this.modelId,
    this.thinkingMode,
    this.runId,
    this.eventType = 'message',
  });

  factory PersistedPendingRun.fromRow(Map<String, dynamic> row) {
    return PersistedPendingRun(
      id: row['id'] as int,
      sessionId: row['session_id'] as String,
      requestId: row['request_id'] as String?,
      message: row['message'] as String?,
      eventMetadata: _decodeJsonMap(row['event_metadata'] as String? ?? '{}'),
      workspaceId: row['workspace_id'] as String?,
      providerInstanceId: row['provider_instance_id'] as String?,
      modelId: row['model_id'] as String?,
      thinkingMode: row['thinking_mode'] as String?,
      runId: row['run_id'] as String?,
      eventType: row['event_type'] as String? ?? 'message',
    );
  }
}

/// DTO representing a persisted runtime notice.
class PersistedRuntimeNotice {
  final String sessionId;
  final String? requestId;
  final String? runId;
  final String status;
  final String reason;
  final String severity;
  final String title;
  final String message;
  final String? providerInstanceId;
  final String? providerDisplayName;
  final int? retryAfterMs;
  final String? resumeAt;
  final int? limitRpm;
  final List<String> actions;
  final String createdAt;
  final String updatedAt;

  const PersistedRuntimeNotice({
    required this.sessionId,
    this.requestId,
    this.runId,
    required this.status,
    required this.reason,
    this.severity = 'warning',
    required this.title,
    required this.message,
    this.providerInstanceId,
    this.providerDisplayName,
    this.retryAfterMs,
    this.resumeAt,
    this.limitRpm,
    this.actions = const [],
    required this.createdAt,
    required this.updatedAt,
  });

  factory PersistedRuntimeNotice.fromRow(Map<String, dynamic> row) {
    return PersistedRuntimeNotice(
      sessionId: row['session_id'] as String,
      requestId: row['request_id'] as String?,
      runId: row['run_id'] as String?,
      status: row['status'] as String,
      reason: row['reason'] as String,
      severity: row['severity'] as String? ?? 'warning',
      title: row['title'] as String,
      message: row['message'] as String,
      providerInstanceId: row['provider_instance_id'] as String?,
      providerDisplayName: row['provider_display_name'] as String?,
      retryAfterMs: row['retry_after_ms'] as int?,
      resumeAt: row['resume_at'] as String?,
      limitRpm: row['limit_rpm'] as int?,
      actions: _decodeJsonList(row['actions'] as String? ?? '[]'),
      createdAt:
          row['created_at'] as String? ??
          DateTime.now().toUtc().toIso8601String(),
      updatedAt:
          row['updated_at'] as String? ??
          DateTime.now().toUtc().toIso8601String(),
    );
  }

  /// Converts this persisted notice into a transport-safe payload matching
  /// `RuntimeNotice.toPayload()`.
  Map<String, dynamic> toPayload() => {
    'session_id': sessionId,
    if (requestId != null) 'request_id': requestId,
    if (runId != null) 'run_id': runId,
    'status': status,
    'reason': reason,
    'severity': severity,
    'title': title,
    'message': message,
    if (providerInstanceId != null) 'provider_instance_id': providerInstanceId,
    if (providerDisplayName != null)
      'provider_display_name': providerDisplayName,
    if (retryAfterMs != null) 'retry_after_ms': retryAfterMs,
    if (resumeAt != null) 'resume_at': resumeAt,
    if (limitRpm != null) 'limit': {'requests_per_minute': limitRpm},
    'actions': actions,
  };
}

Map<String, dynamic> _decodeJsonMap(String raw) {
  if (raw.isEmpty) return {};
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) return decoded;
  } catch (_) {}
  return {};
}

List<String> _decodeJsonList(String raw) {
  if (raw.isEmpty) return const [];
  try {
    final decoded = jsonDecode(raw);
    if (decoded is List) {
      return decoded.map((e) => e.toString()).toList(growable: false);
    }
  } catch (_) {}
  return const [];
}
