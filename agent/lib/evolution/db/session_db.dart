import '../../core/models/message.dart';
import '../compaction/model_context_projection.dart';
import '../models/session_history_page.dart';
import '../models/session_query.dart';
import '../models/session_search.dart';
import '../models/session_state.dart';
import '../models/suspended_checkpoint.dart';
import 'agent_state_database.dart';
import 'scheduled_task_repository.dart';
import 'session_fork_commit_repository.dart';
import 'session_message_repository.dart';
import 'session_repository.dart';
import 'suspended_checkpoint_repository.dart';

export 'scheduled_task_repository.dart';
export 'session_fork_commit_repository.dart';
export 'session_message_repository.dart';
export 'session_repository.dart';
export 'suspended_checkpoint_repository.dart';

/// Facade for session storage, message persistence, scheduled tasks, and
/// suspended checkpoints.
///
/// Delegates all operations to cohesive repository owners:
/// - [SessionRepository]: session lifecycle, metadata, titles, and workspaces.
/// - [SessionMessageRepository]: message append/read, history projection, tool results.
/// - [ScheduledTaskRepository]: scheduled task persistence.
/// - [SuspendedCheckpointRepository]: suspended checkpoints and work-item state.
/// - [SessionForkCommitRepository]: fork, soft-rewind, and root-user commit records.
class SessionDB {
  final AgentStateDatabase? _disposeOwnedState;

  final SessionRepository _sessionRepository;
  final SessionMessageRepository _messageRepository;
  final ScheduledTaskRepository _scheduledTaskRepository;
  final SuspendedCheckpointRepository _suspendedCheckpointRepository;
  final SessionForkCommitRepository _forkCommitRepository;

  SessionDB() : this._owned(AgentStateDatabase());

  SessionDB._owned(AgentStateDatabase state) : this._create(state, state);

  /// Shares a single [AgentStateDatabase] connection without taking
  /// ownership. The caller disposes [state]; this [SessionDB] will not close
  /// it. Used by the DI production path so `SessionDB` and
  /// `ProviderInstanceRepository` share one `state.db` connection.
  SessionDB.fromState(AgentStateDatabase state) : this._create(state, null);

  SessionDB._create(
    AgentStateDatabase state,
    AgentStateDatabase? disposeOwnedState,
  ) : this._wire(
          state,
          disposeOwnedState,
          SessionMessageRepository(state),
        );

  SessionDB._wire(
    AgentStateDatabase state,
    AgentStateDatabase? disposeOwnedState,
    SessionMessageRepository messages,
  ) : this._wireWithSessions(
          state,
          disposeOwnedState,
          messages,
          SessionRepository(state, messages),
        );

  SessionDB._wireWithSessions(
    AgentStateDatabase state,
    AgentStateDatabase? disposeOwnedState,
    SessionMessageRepository messages,
    SessionRepository sessions,
  ) : this._internal(
          disposeOwnedState: disposeOwnedState,
          sessionRepository: sessions,
          messageRepository: messages,
          scheduledTaskRepository: ScheduledTaskRepository(state),
          suspendedCheckpointRepository: SuspendedCheckpointRepository(state),
          forkCommitRepository: SessionForkCommitRepository(
            state: state,
            sessions: sessions,
            messages: messages,
          ),
        );

  SessionDB._internal({
    required AgentStateDatabase? disposeOwnedState,
    required SessionRepository sessionRepository,
    required SessionMessageRepository messageRepository,
    required ScheduledTaskRepository scheduledTaskRepository,
    required SuspendedCheckpointRepository suspendedCheckpointRepository,
    required SessionForkCommitRepository forkCommitRepository,
  })  : _disposeOwnedState = disposeOwnedState,
        _sessionRepository = sessionRepository,
        _messageRepository = messageRepository,
        _scheduledTaskRepository = scheduledTaskRepository,
        _suspendedCheckpointRepository = suspendedCheckpointRepository,
        _forkCommitRepository = forkCommitRepository;

  SessionRepository get sessionRepository => _sessionRepository;
  SessionMessageRepository get messageRepository => _messageRepository;
  ScheduledTaskRepository get scheduledTaskRepository =>
      _scheduledTaskRepository;
  SuspendedCheckpointRepository get suspendedCheckpointRepository =>
      _suspendedCheckpointRepository;
  SessionForkCommitRepository get forkCommitRepository =>
      _forkCommitRepository;

  SessionRepository get sessions => _sessionRepository;
  SessionMessageRepository get messages => _messageRepository;
  ScheduledTaskRepository get scheduledTasks => _scheduledTaskRepository;
  SuspendedCheckpointRepository get suspendedCheckpoints =>
      _suspendedCheckpointRepository;
  SessionForkCommitRepository get forkCommits => _forkCommitRepository;

  void dispose() {
    _disposeOwnedState?.dispose();
  }

  void saveWorkspace({
    required String path,
    required String source,
    String? updatedAt,
  }) => _sessionRepository.saveWorkspace(
    path: path,
    source: source,
    updatedAt: updatedAt,
  );

  Map<String, dynamic> createOrGetWorkspace({
    String? id,
    String? displayName,
    required String path,
    required String source,
    String? updatedAt,
  }) => _sessionRepository.createOrGetWorkspace(
    id: id,
    displayName: displayName,
    path: path,
    source: source,
    updatedAt: updatedAt,
  );

  List<Map<String, dynamic>> getStoredWorkspaces() =>
      _sessionRepository.getStoredWorkspaces();

  Map<String, dynamic>? getWorkspaceById(String id) =>
      _sessionRepository.getWorkspaceById(id);

  Map<String, dynamic>? getWorkspaceByPath(String path) =>
      _sessionRepository.getWorkspaceByPath(path);

  Map<String, dynamic>? renameWorkspace(String id, String displayName) =>
      _sessionRepository.renameWorkspace(id, displayName);

  Map<String, dynamic>? relocateWorkspace(String id, String path) =>
      _sessionRepository.relocateWorkspace(id, path);

  bool removeWorkspace(String id) => _sessionRepository.removeWorkspace(id);

  void saveSession(SessionState session) =>
      _sessionRepository.saveSession(session);

  void updateSessionLastUserMessageAt(String sessionId, DateTime timestamp) =>
      _sessionRepository.updateSessionLastUserMessageAt(sessionId, timestamp);

  SessionQueryResult getSessions(SessionQueryRequest query) =>
      _sessionRepository.getSessions(query);

  SessionSearchResult searchSessions(SessionSearchRequest request) =>
      _sessionRepository.searchSessions(request);

  SessionState? getSessionRecord(String sessionId) =>
      _sessionRepository.getSessionRecord(sessionId);

  SessionState? getSession(String sessionId) =>
      _sessionRepository.getSession(sessionId);

  List<SessionState> getAllSessions() => _sessionRepository.getAllSessions();

  void updateSessionTitle(String sessionId, String title) =>
      _sessionRepository.updateSessionTitle(sessionId, title);

  bool updateSessionTitleIfCurrent(
    String sessionId, {
    required String? expectedTitle,
    required String title,
  }) => _sessionRepository.updateSessionTitleIfCurrent(
    sessionId,
    expectedTitle: expectedTitle,
    title: title,
  );

  bool finalizePendingSessionTitle(
    String sessionId, {
    required String? expectedTitle,
    required String title,
  }) => _sessionRepository.finalizePendingSessionTitle(
    sessionId,
    expectedTitle: expectedTitle,
    title: title,
  );

  List<SessionState> getPendingTitleSessions() =>
      _sessionRepository.getPendingTitleSessions();

  void deleteSession(String sessionId) =>
      _sessionRepository.deleteSession(sessionId);

  void saveSessionMetadata(String sessionId, Map<String, dynamic> metadata) =>
      _sessionRepository.saveSessionMetadata(sessionId, metadata);

  Map<String, dynamic>? getSessionMetadata(String sessionId) =>
      _sessionRepository.getSessionMetadata(sessionId);

  RootUserMessageCommit appendRootUserMessage(
    String sessionId,
    Message message,
  ) => _forkCommitRepository.appendRootUserMessage(sessionId, message);

  void replaceMessages(String sessionId, List<Message> messages) =>
      _messageRepository.replaceMessages(sessionId, messages);

  List<Message> replaceMessagesInTransaction(
    String sessionId,
    List<Message> messages,
    AgentStateTransaction transaction,
  ) => _messageRepository.replaceMessagesInTransaction(
    sessionId,
    messages,
    transaction,
  );

  SoftRewindAdmissionCommit? commitSoftRewindAdmission({
    required String sessionId,
    required int expectedHistoryRevision,
    required String targetMessageId,
    required String targetTurnId,
    required String targetRequestId,
    required Message replacement,
  }) => _forkCommitRepository.commitSoftRewindAdmission(
    sessionId: sessionId,
    expectedHistoryRevision: expectedHistoryRevision,
    targetMessageId: targetMessageId,
    targetTurnId: targetTurnId,
    targetRequestId: targetRequestId,
    replacement: replacement,
  );

  List<Message> getMessages(
    String sessionId, {
    bool includeSuperseded = false,
  }) => _messageRepository.getMessages(
    sessionId,
    includeSuperseded: includeSuperseded,
  );

  List<PersistedMessage> getPersistedMessages(
    String sessionId, {
    bool includeSuperseded = false,
  }) => _messageRepository.getPersistedMessages(
    sessionId,
    includeSuperseded: includeSuperseded,
  );

  SessionHistoryPage getPersistedMessagePage(
    String sessionId, {
    int limit = defaultSessionHistoryPageSize,
    String? cursor,
    int? anchorRowId,
    int maxPersistedBytes = defaultSessionHistoryPageBytes,
  }) => _messageRepository.getPersistedMessagePage(
    sessionId,
    limit: limit,
    cursor: cursor,
    anchorRowId: anchorRowId,
    maxPersistedBytes: maxPersistedBytes,
  );

  String? latestActiveMessageId(String sessionId) =>
      _messageRepository.latestActiveMessageId(sessionId);

  int? activeRowIdForMessageId(String sessionId, String messageId) =>
      _messageRepository.activeRowIdForMessageId(sessionId, messageId);

  int? legacyRouteNoticeAnchorRowId(
    String sessionId,
    String requestId,
    DateTime at,
  ) => _messageRepository.legacyRouteNoticeAnchorRowId(
    sessionId,
    requestId,
    at,
  );

  int? lastActiveForkCopiedRowId(String sessionId) =>
      _messageRepository.lastActiveForkCopiedRowId(sessionId);

  OriginatingToolCallContext? findOriginatingToolCall(
    String sessionId, {
    required String toolCallId,
    String? turnId,
  }) => _messageRepository.findOriginatingToolCall(
    sessionId,
    toolCallId: toolCallId,
    turnId: turnId,
  );

  void saveScheduledTask(
    String id,
    String task,
    DateTime nextRunAt,
    String sessionId, {
    String kind = 'once',
    int? intervalMinutes,
    String? atTime,
    String? weekdays,
    int? monthDay,
    String zone = 'local',
    DateTime? updatedAt,
    DateTime? lastRunAt,
    String? lastStatus,
    bool enabled = true,
  }) => _scheduledTaskRepository.saveScheduledTask(
    id,
    task,
    nextRunAt,
    sessionId,
    kind: kind,
    intervalMinutes: intervalMinutes,
    atTime: atTime,
    weekdays: weekdays,
    monthDay: monthDay,
    zone: zone,
    updatedAt: updatedAt,
    lastRunAt: lastRunAt,
    lastStatus: lastStatus,
    enabled: enabled,
  );

  Map<String, dynamic>? getScheduledTask(String id) =>
      _scheduledTaskRepository.getScheduledTask(id);

  List<Map<String, dynamic>> getAllScheduledTasks() =>
      _scheduledTaskRepository.getAllScheduledTasks();

  void deleteScheduledTask(String id) =>
      _scheduledTaskRepository.deleteScheduledTask(id);

  void saveSuspendedCheckpoint(SuspendedCheckpoint checkpoint) =>
      _suspendedCheckpointRepository.saveSuspendedCheckpoint(checkpoint);

  SuspendedCheckpoint? getSuspendedCheckpointByRequestId(String requestId) =>
      _suspendedCheckpointRepository.getSuspendedCheckpointByRequestId(
        requestId,
      );

  List<SuspendedCheckpoint> listSuspendedCheckpoints({String? status}) =>
      _suspendedCheckpointRepository.listSuspendedCheckpoints(status: status);

  void updateSuspendedCheckpointStatus({
    required String requestId,
    required String status,
  }) => _suspendedCheckpointRepository.updateSuspendedCheckpointStatus(
    requestId: requestId,
    status: status,
  );

  bool claimSuspendedCheckpointDecision({
    required String requestId,
    required String status,
  }) => _suspendedCheckpointRepository.claimSuspendedCheckpointDecision(
    requestId: requestId,
    status: status,
  );

  void deleteSuspendedCheckpointByRequestId(String requestId) =>
      _suspendedCheckpointRepository.deleteSuspendedCheckpointByRequestId(
        requestId,
      );

  void deleteSuspendedCheckpointByToolCallId(String toolCallId) =>
      _suspendedCheckpointRepository.deleteSuspendedCheckpointByToolCallId(
        toolCallId,
      );

  SessionForkCommit commitFork({
    required String sourceSessionId,
    required String requestId,
    required String targetMessageId,
    required String targetTurnId,
  }) => _forkCommitRepository.commitFork(
    sourceSessionId: sourceSessionId,
    requestId: requestId,
    targetMessageId: targetMessageId,
    targetTurnId: targetTurnId,
  );
}
