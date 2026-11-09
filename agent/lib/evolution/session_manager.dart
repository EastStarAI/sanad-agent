import 'dart:collection';

import 'package:meta/meta.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:uuid/uuid.dart';

import 'attachments/attachment_store.dart';
import 'cron_scheduler.dart';
import 'db/agent_state_database.dart';
import 'db/session_db.dart';
import 'models/session_query.dart';
import 'models/session_search.dart';
import 'models/session_history_page.dart';
import 'models/session_state.dart';
import 'models/suspended_checkpoint.dart';
import 'compaction/model_context_projection.dart';
import '../core/models/message.dart';

class SessionManager {
  static SessionManager? _instance;
  static const int _maxHistorySnapshots = 8;

  /// Retained-text budget for the whole history snapshot cache.
  ///
  /// Eight ordinary sessions fit comfortably; a pathological history is evicted
  /// rather than pinning the daemon's heap, because a miss re-reads state.db.
  static const int _maxHistorySnapshotChars = 32 * 1024 * 1024;

  late final SessionDB _db;
  final Map<String, Map<String, dynamic>> _inFlightSnapshots = {};
  final Map<String, _InFlightStream> _inFlightStreams = {};
  final LinkedHashMap<String, _SessionHistorySnapshot> _historySnapshots =
      LinkedHashMap<String, _SessionHistorySnapshot>();
  int _historySnapshotChars = 0;

  SessionDB get db => _db;

  @visibleForTesting
  int get historySnapshotCount => _historySnapshots.length;

  @visibleForTesting
  bool hasHistorySnapshot(String sessionId) =>
      _historySnapshots.containsKey(sessionId);

  /// Approximate retained characters of every cached history snapshot.
  @visibleForTesting
  int get historySnapshotChars => _historySnapshotChars;

  /// Inserts one history into the cache exactly as a read would, so the cache's
  /// count and retained-text bounds are testable without a database round trip.
  @visibleForTesting
  void cacheHistoryForTesting(
    String sessionId,
    int historyRevision,
    List<Message> messages,
  ) => _cacheHistory(sessionId, historyRevision, messages);

  void saveInFlightSnapshot(String sessionId, Map<String, dynamic> snapshot) {
    _inFlightStreams.remove(sessionId);
    _inFlightSnapshots[sessionId] = snapshot;
  }

  /// Appends one streamed delta to the session's in-memory in-flight
  /// projection, starting a new projection whenever the run, turn, model step,
  /// or stream type changes.
  ///
  /// The projection keeps the whole partial answer so a reconnecting Client can
  /// restore it, but the text lives in a growable buffer that is materialized
  /// only when [getInFlightSnapshot] reads it. Rebuilding the accumulated
  /// string on every delta would copy the entire prefix per token.
  void appendInFlightDelta({
    required String sessionId,
    required String runId,
    required String? turnId,
    required String? modelStepId,
    required String type,
    required String delta,
  }) {
    final existing = _inFlightStreams[sessionId];
    if (existing != null &&
        existing.matches(
          type: type,
          runId: runId,
          turnId: turnId,
          modelStepId: modelStepId,
        )) {
      existing.append(delta);
      return;
    }
    // A snapshot written whole by a caller is the seed for this stream only
    // when it names the same run identity; otherwise it is superseded.
    final seeded = _inFlightSnapshots.remove(sessionId);
    final seedContent = seeded != null &&
            seeded['type'] == type &&
            seeded['run_id'] == runId &&
            seeded['turn_id'] == turnId &&
            seeded['model_step_id'] == modelStepId &&
            seeded['content'] is String
        ? seeded['content'] as String
        : '';
    _inFlightStreams[sessionId] = _InFlightStream(
      sessionId: sessionId,
      type: type,
      runId: runId,
      turnId: turnId,
      modelStepId: modelStepId,
      seed: seedContent,
    )..append(delta);
  }

  Map<String, dynamic>? getInFlightSnapshot(String sessionId) {
    final stream = _inFlightStreams[sessionId];
    if (stream != null) {
      return stream.toSnapshot();
    }
    return _inFlightSnapshots[sessionId];
  }

  /// Whether the session has an in-memory in-flight projection, without
  /// materializing its accumulated text.
  bool hasInFlightSnapshot(String sessionId) =>
      _inFlightStreams.containsKey(sessionId) ||
      _inFlightSnapshots.containsKey(sessionId);

  /// Run id of the session's in-memory in-flight projection, without
  /// materializing its accumulated text.
  String? inFlightRunId(String sessionId) =>
      _inFlightStreams[sessionId]?.runId ??
      _inFlightSnapshots[sessionId]?['run_id']?.toString();

  void clearInFlightSnapshot(String sessionId) {
    _inFlightStreams.remove(sessionId);
    _inFlightSnapshots.remove(sessionId);
  }

  factory SessionManager() {
    _instance ??= SessionManager._internal();
    return _instance!;
  }

  SessionManager._internal() {
    // Share the single AgentStateDatabase connection with
    // ProviderInstanceRepository so state.db is never opened twice. Falls back
    // to a standalone SessionDB when DI is not initialized (isolated tests).
    if (getIt.isRegistered<AgentStateDatabase>()) {
      _db = SessionDB.fromState(getIt<AgentStateDatabase>());
    } else {
      _db = SessionDB();
    }
  }

  @visibleForTesting
  static void resetForTesting() {
    _instance?._db.dispose();
    _instance = null;
  }

  SessionState createSession(
    String model, {
    String? providerId,
    String? thinkingMode,
  }) {
    final sessionId = const Uuid().v4();

    var resolvedProviderId = providerId;
    if (resolvedProviderId == null || resolvedProviderId.isEmpty) {
      if (getIt.isRegistered<Config>()) {
        resolvedProviderId = getIt<Config>().activeProvider;
      }
    }

    final session = SessionState(
      sessionId: sessionId,
      model: model,
      providerId: resolvedProviderId,
      thinkingMode: thinkingMode,
      titleStatus: SessionTitleStatus.pending,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
    _db.saveSession(session);
    return session;
  }

  /// Reads session metadata without querying or decoding history rows.
  SessionState? getSessionRecord(String sessionId) {
    return _db.getSessionRecord(sessionId);
  }

  SessionState? getSession(String sessionId) {
    final record = _db.getSessionRecord(sessionId);
    if (record == null) {
      _historySnapshots.remove(sessionId);
      return null;
    }
    final cached = _historySnapshots.remove(sessionId);
    if (cached != null && cached.historyRevision == record.historyRevision) {
      _historySnapshots[sessionId] = cached;
      return _withMessages(record, cached.messages);
    }
    final messages = _db.getMessages(sessionId);
    _cacheHistory(sessionId, record.historyRevision, messages);
    return _withMessages(record, messages);
  }

  List<SessionState> getAllSessions() {
    return _db.getAllSessions();
  }

  SessionQueryResult getSessions(SessionQueryRequest query) {
    return _db.getSessions(query);
  }

  SessionSearchResult searchSessions(SessionSearchRequest request) {
    return _db.searchSessions(request);
  }

  void updateSessionTitle(String sessionId, String title) {
    _db.updateSessionTitle(sessionId, title);
  }

  bool updateSessionTitleIfCurrent(
    String sessionId, {
    required String? expectedTitle,
    required String title,
  }) {
    return _db.finalizePendingSessionTitle(
      sessionId,
      expectedTitle: expectedTitle,
      title: title,
    );
  }

  List<SessionState> getPendingTitleSessions() {
    return _db.getPendingTitleSessions();
  }

  void deleteSession(String sessionId) {
    if (getIt.isRegistered<CronScheduler>()) {
      getIt<CronScheduler>().pauseForDeletedSession(sessionId);
    }
    if (getIt.isRegistered<AttachmentStore>()) {
      getIt<AttachmentStore>().deleteSessionSync(sessionId);
      _historySnapshots.remove(sessionId);
      return;
    }
    _db.deleteSession(sessionId);
    _historySnapshots.remove(sessionId);
  }

  void updateSessionModel(String sessionId, String model) {
    updateSessionModeling(sessionId, model: model);
  }

  /// Plan 30: updates the persisted provider instance id for a session (used
  /// by `session.runtime_continue_with_provider`). The model is preserved.
  void updateSessionProviderId(String sessionId, String providerInstanceId) {
    updateSessionModeling(sessionId, providerId: providerInstanceId);
  }

  /// Updates the persisted provider/model/thinking-mode for a session. Any
  /// field left null is preserved (partial update). These are the last values
  /// the user used in this session, restored when the session is reopened.
  void updateSessionModeling(
    String sessionId, {
    String? providerId,
    String? model,
    String? thinkingMode,
    bool clearThinkingMode = false,
  }) {
    final session = _db.getSessionRecord(sessionId);
    if (session != null) {
      final updatedSession = SessionState(
        sessionId: session.sessionId,
        model: model ?? session.model,
        providerId: providerId ?? session.providerId,
        thinkingMode: clearThinkingMode
            ? null
            : (thinkingMode ?? session.thinkingMode),
        title: session.title,
        titleStatus: session.titleStatus,
        workspaceId: session.workspaceId,
        createdAt: session.createdAt,
        updatedAt: DateTime.now(),
        lastUserMessageAt: session.lastUserMessageAt,
        routeRevision: session.routeRevision,
        routeUpdatedAt: session.routeUpdatedAt,
        historyRevision: session.historyRevision,
        messages: session.messages,
      );
      _db.saveSession(updatedSession);
    }
  }

  void saveSessionHistory(String sessionId, List<Message> messages) {
    final session = _db.getSessionRecord(sessionId);
    if (session != null) {
      final updatedSession = SessionState(
        sessionId: session.sessionId,
        model: session.model,
        providerId: session.providerId,
        thinkingMode: session.thinkingMode,
        title: session.title,
        titleStatus: session.titleStatus,
        workspaceId: session.workspaceId,
        createdAt: session.createdAt,
        updatedAt: DateTime.now(),
        lastUserMessageAt: session.lastUserMessageAt,
        routeRevision: session.routeRevision,
        routeUpdatedAt: session.routeUpdatedAt,
        historyRevision: session.historyRevision,
        messages: messages,
      );
      _db.saveSession(updatedSession);
      _db.replaceMessages(sessionId, messages);
      final persisted = _db.getMessages(sessionId);
      final revision = _db.getSessionRecord(sessionId)?.historyRevision;
      if (revision == null) {
        _historySnapshots.remove(sessionId);
      } else {
        _cacheHistory(sessionId, revision, persisted);
      }
    }
  }

  RootUserMessageCommit appendRootUserMessage(
    String sessionId,
    Message message,
  ) {
    final commit = _db.appendRootUserMessage(sessionId, message);
    final cached = _historySnapshots.remove(sessionId);
    if (commit.inserted &&
        cached != null &&
        cached.historyRevision + 1 == commit.historyRevision) {
      _cacheHistory(sessionId, commit.historyRevision, [
        ...cached.messages,
        commit.message,
      ]);
    } else if (!commit.inserted &&
        cached != null &&
        cached.historyRevision == commit.historyRevision) {
      _cacheHistory(sessionId, cached.historyRevision, cached.messages);
    }
    return commit;
  }

  List<Message> saveSessionHistoryInTransaction(
    String sessionId,
    List<Message> messages,
    AgentStateTransaction transaction,
  ) {
    _historySnapshots.remove(sessionId);
    return _db.replaceMessagesInTransaction(sessionId, messages, transaction);
  }

  SoftRewindAdmissionCommit? commitSoftRewindAdmission({
    required String sessionId,
    required int expectedHistoryRevision,
    required String targetMessageId,
    required String targetTurnId,
    required String targetRequestId,
    required Message replacement,
  }) {
    return _db.commitSoftRewindAdmission(
      sessionId: sessionId,
      expectedHistoryRevision: expectedHistoryRevision,
      targetMessageId: targetMessageId,
      targetTurnId: targetTurnId,
      targetRequestId: targetRequestId,
      replacement: replacement,
    );
  }

  SessionForkCommit commitFork({
    required String sourceSessionId,
    required String requestId,
    required String targetMessageId,
    required String targetTurnId,
  }) {
    return _db.commitFork(
      sourceSessionId: sourceSessionId,
      requestId: requestId,
      targetMessageId: targetMessageId,
      targetTurnId: targetTurnId,
    );
  }

  void recordCanonicalUserMessageAccepted(
    String sessionId,
    DateTime receivedAt,
  ) {
    _db.updateSessionLastUserMessageAt(sessionId, receivedAt);
  }

  List<Message> getMessages(
    String sessionId, {
    bool includeSuperseded = false,
  }) {
    return _db.getMessages(sessionId, includeSuperseded: includeSuperseded);
  }

  List<PersistedMessage> getPersistedMessages(String sessionId) {
    return _db.getPersistedMessages(sessionId);
  }

  SessionHistoryPage getPersistedMessagePage(
    String sessionId, {
    int limit = defaultSessionHistoryPageSize,
    String? cursor,
    int? anchorRowId,
  }) {
    return _db.getPersistedMessagePage(
      sessionId,
      limit: limit,
      cursor: cursor,
      anchorRowId: anchorRowId,
    );
  }

  String? latestActiveMessageId(String sessionId) =>
      _db.latestActiveMessageId(sessionId);

  int? activeRowIdForMessageId(String sessionId, String messageId) =>
      _db.activeRowIdForMessageId(sessionId, messageId);

  int? legacyRouteNoticeAnchorRowId(
    String sessionId,
    String requestId,
    DateTime at,
  ) => _db.legacyRouteNoticeAnchorRowId(sessionId, requestId, at);

  int? lastActiveForkCopiedRowId(String sessionId) =>
      _db.lastActiveForkCopiedRowId(sessionId);

  /// Persists last-turn metrics (usage, model, context_tokens, etc.) alongside
  /// the session so they are returned with thread history.
  void saveSessionMetadata(String sessionId, Map<String, dynamic> metadata) {
    _db.saveSessionMetadata(sessionId, metadata);
  }

  Map<String, dynamic>? getSessionMetadata(String sessionId) {
    return _db.getSessionMetadata(sessionId);
  }

  void saveSuspendedCheckpoint(SuspendedCheckpoint checkpoint) {
    _db.saveSuspendedCheckpoint(checkpoint);
  }

  SuspendedCheckpoint? getSuspendedCheckpointByRequestId(String requestId) {
    return _db.getSuspendedCheckpointByRequestId(requestId);
  }

  List<SuspendedCheckpoint> listSuspendedCheckpoints({String? status}) {
    return _db.listSuspendedCheckpoints(status: status);
  }

  void updateSuspendedCheckpointStatus({
    required String requestId,
    required String status,
  }) {
    _db.updateSuspendedCheckpointStatus(requestId: requestId, status: status);
  }

  bool claimSuspendedCheckpointDecision({
    required String requestId,
    required String status,
  }) {
    return _db.claimSuspendedCheckpointDecision(
      requestId: requestId,
      status: status,
    );
  }

  void deleteSuspendedCheckpointByRequestId(String requestId) {
    _db.deleteSuspendedCheckpointByRequestId(requestId);
  }

  void deleteSuspendedCheckpointByToolCallId(String toolCallId) {
    _db.deleteSuspendedCheckpointByToolCallId(toolCallId);
  }

  SessionState _withMessages(SessionState record, List<Message> messages) {
    return SessionState.fromMap(
      record.toMap(),
      messages.toList(growable: false),
    );
  }

  void _cacheHistory(
    String sessionId,
    int historyRevision,
    List<Message> messages,
  ) {
    final previous = _historySnapshots.remove(sessionId);
    if (previous != null) {
      _historySnapshotChars -= previous.retainedChars;
    }
    final snapshot = _SessionHistorySnapshot(
      historyRevision: historyRevision,
      messages: List<Message>.unmodifiable(messages),
    );
    _historySnapshots[sessionId] = snapshot;
    _historySnapshotChars += snapshot.retainedChars;
    // The cache is bounded by retained text as well as by session count: one
    // long session's history can be tens of megabytes, so a count-only bound
    // would let eight of them pin hundreds of megabytes for the life of the
    // daemon. Evicting a snapshot only costs a re-read from state.db.
    while (_historySnapshots.length > _maxHistorySnapshots ||
        (_historySnapshotChars > _maxHistorySnapshotChars &&
            _historySnapshots.length > 1)) {
      final evicted = _historySnapshots.remove(_historySnapshots.keys.first);
      if (evicted == null) break;
      _historySnapshotChars -= evicted.retainedChars;
    }
  }
}

/// The in-memory in-flight projection of one streaming model step.
///
/// The accumulated text is kept in a growable buffer and materialized only when
/// a reader asks for the snapshot, so appending a delta is amortized O(1)
/// instead of a full copy of the answer so far.
class _InFlightStream {
  _InFlightStream({
    required this.sessionId,
    required this.type,
    required this.runId,
    required this.turnId,
    required this.modelStepId,
    required String seed,
  }) : _buffer = StringBuffer(seed);

  final String sessionId;
  final String type;
  final String runId;
  final String? turnId;
  final String? modelStepId;
  final StringBuffer _buffer;
  String? _materialized;
  int _materializedLength = -1;
  DateTime _updatedAt = DateTime.now();

  bool matches({
    required String type,
    required String runId,
    required String? turnId,
    required String? modelStepId,
  }) =>
      this.type == type &&
      this.runId == runId &&
      this.turnId == turnId &&
      this.modelStepId == modelStepId;

  void append(String delta) {
    if (delta.isEmpty) return;
    _buffer.write(delta);
    _updatedAt = DateTime.now();
  }

  Map<String, dynamic> toSnapshot() {
    final length = _buffer.length;
    if (_materialized == null || _materializedLength != length) {
      _materialized = _buffer.toString();
      _materializedLength = length;
    }
    final timestamp = _updatedAt.millisecondsSinceEpoch;
    return {
      'type': type,
      'status': 'running',
      'session_id': sessionId,
      'run_id': runId,
      'turn_id': ?turnId,
      'model_step_id': modelStepId,
      'content': _materialized!,
      'timestamp': timestamp,
      'updated_at': timestamp,
    };
  }
}

class _SessionHistorySnapshot {
  final int historyRevision;
  final List<Message> messages;

  /// Dominant retained size of this snapshot: the message text it pins.
  ///
  /// Tool results and answers are message content, so this is the term that
  /// grows with a long session; tool-call arguments and metadata are small in
  /// comparison and are deliberately not walked here.
  final int retainedChars;

  _SessionHistorySnapshot({
    required this.historyRevision,
    required this.messages,
  }) : retainedChars = _retainedCharsOf(messages);

  static int _retainedCharsOf(List<Message> messages) {
    var total = 0;
    for (final message in messages) {
      total += message.content?.length ?? 0;
    }
    return total;
  }
}
