import 'package:meta/meta.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/config.dart';
import 'db/agent_state_database.dart';
import 'db/session_db.dart';
import 'models/session_query.dart';
import 'models/session_state.dart';
import 'models/suspended_checkpoint.dart';
import '../core/models/message.dart';

class SessionManager {
  static SessionManager? _instance;
  late final SessionDB _db;
  final Map<String, Map<String, dynamic>> _inFlightSnapshots = {};

  SessionDB get db => _db;

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
    final sessionId = DateTime.now().millisecondsSinceEpoch.toString();

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

  SessionState? getSession(String sessionId) {
    return _db.getSession(sessionId);
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
    final session = _db.getSession(sessionId);
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
        messages: session.messages,
      );
      _db.saveSession(updatedSession);
    }
  }

  void saveSessionHistory(String sessionId, List<Message> messages) {
    var session = _db.getSession(sessionId);
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
        messages: messages,
      );
      _db.saveSession(updatedSession);
      _db.replaceMessages(sessionId, messages);
    }
  }

  void recordCanonicalUserMessageAccepted(
    String sessionId,
    DateTime receivedAt,
  ) {
    _db.updateSessionLastUserMessageAt(sessionId, receivedAt);
  }

  List<Message> getMessages(String sessionId) {
    return _db.getMessages(sessionId);
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
}
