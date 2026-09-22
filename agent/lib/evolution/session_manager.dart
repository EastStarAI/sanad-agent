import 'dart:collection';

import 'package:meta/meta.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:uuid/uuid.dart';

import 'db/agent_state_database.dart';
import 'db/session_db.dart';
import 'models/session_query.dart';
import 'models/session_history_page.dart';
import 'models/session_state.dart';
import 'models/suspended_checkpoint.dart';
import 'compaction/model_context_projection.dart';
import '../core/models/message.dart';

class SessionManager {
  static SessionManager? _instance;
  static const int _maxHistorySnapshots = 8;

  late final SessionDB _db;
  final Map<String, Map<String, dynamic>> _inFlightSnapshots = {};
  final LinkedHashMap<String, _SessionHistorySnapshot> _historySnapshots =
      LinkedHashMap<String, _SessionHistorySnapshot>();

  SessionDB get db => _db;

  @visibleForTesting
  int get historySnapshotCount => _historySnapshots.length;

  @visibleForTesting
  bool hasHistorySnapshot(String sessionId) =>
      _historySnapshots.containsKey(sessionId);

  void saveInFlightSnapshot(String sessionId, Map<String, dynamic> snapshot) {
    _inFlightSnapshots[sessionId] = snapshot;
  }

  Map<String, dynamic>? getInFlightSnapshot(String sessionId) {
    return _inFlightSnapshots[sessionId];
  }

  void clearInFlightSnapshot(String sessionId) {
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
  }) {
    final session = _db.getSessionRecord(sessionId);
    if (session != null) {
      final updatedSession = SessionState(
        sessionId: session.sessionId,
        model: model ?? session.model,
        providerId: providerId ?? session.providerId,
        thinkingMode: thinkingMode ?? session.thinkingMode,
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
    _historySnapshots.remove(sessionId);
    _historySnapshots[sessionId] = _SessionHistorySnapshot(
      historyRevision: historyRevision,
      messages: List<Message>.unmodifiable(messages),
    );
    while (_historySnapshots.length > _maxHistorySnapshots) {
      _historySnapshots.remove(_historySnapshots.keys.first);
    }
  }
}

class _SessionHistorySnapshot {
  final int historyRevision;
  final List<Message> messages;

  const _SessionHistorySnapshot({
    required this.historyRevision,
    required this.messages,
  });
}
