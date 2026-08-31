import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';

import '../models/session_query.dart';
import '../models/session_state.dart';
import '../models/suspended_checkpoint.dart';
import '../../core/models/message.dart';
import 'agent_state_database.dart';
import 'session_history_revision_repository.dart';
import '../compaction/model_context_projection.dart';
import 'message_history_identity.dart';
import 'session_fork_copy.dart';

/// Result of an atomic soft-rewind plus replacement-user commit.
class SoftRewindAdmissionCommit {
  final int historyRevision;
  final String replacementMessageId;
  final String replacementTurnId;

  const SoftRewindAdmissionCommit({
    required this.historyRevision,
    required this.replacementMessageId,
    required this.replacementTurnId,
  });
}

/// Persistent storage for sessions, messages, scheduled tasks, and suspended
/// checkpoints.
///
/// The SQLite connection and the full schema (including the Plan 29 provider
/// tables) are owned by a single [`AgentStateDatabase`](agent_state_database.dart)
/// shared with `ProviderInstanceRepository`, so the runtime never opens
/// `state.db` twice. The default constructor creates its own owner (for
/// standalone/test use); production code injects the shared owner via
/// [SessionDB.fromState].
class SessionDB {
  late Database _db;

  /// The owner this instance is responsible for disposing. Non-null only for
  /// the default constructor (standalone); `null` when sharing an injected
  /// [AgentStateDatabase] via [SessionDB.fromState].
  final AgentStateDatabase? _disposeOwnedState;

  SessionDB() : _disposeOwnedState = AgentStateDatabase() {
    _db = _disposeOwnedState!.db;
  }

  /// Shares a single [AgentStateDatabase] connection without taking
  /// ownership. The caller disposes [state]; this [SessionDB] will not close
  /// it. Used by the DI production path so `SessionDB` and
  /// `ProviderInstanceRepository` share one `state.db` connection.
  SessionDB.fromState(AgentStateDatabase state) : _disposeOwnedState = null {
    _db = state.db;
  }

  void dispose() {
    _disposeOwnedState?.dispose();
  }

  void saveWorkspace({
    required String path,
    required String source,
    String? updatedAt,
  }) {
    createOrGetWorkspace(path: path, source: source, updatedAt: updatedAt);
  }

  Map<String, dynamic> createOrGetWorkspace({
    String? id,
    String? displayName,
    required String path,
    required String source,
    String? updatedAt,
  }) {
    final resolvedUpdatedAt =
        updatedAt ?? DateTime.now().toUtc().toIso8601String();
    final resolvedId = id ?? const Uuid().v4();
    final resolvedName = _workspaceDisplayName(displayName, path);
    _db.execute(
      '''
      INSERT INTO workspaces (
        id, display_name, path, source, created_at, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT(path) DO UPDATE SET
        source = excluded.source,
        updated_at = excluded.updated_at
      ''',
      [
        resolvedId,
        resolvedName,
        path,
        source,
        resolvedUpdatedAt,
        resolvedUpdatedAt,
      ],
    );
    return getWorkspaceByPath(path)!;
  }

  List<Map<String, dynamic>> getStoredWorkspaces() {
    final results = _db.select(
      'SELECT id, display_name, path, source, created_at, updated_at '
      'FROM workspaces ORDER BY updated_at DESC',
    );
    return results.map(_workspaceFromRow).toList(growable: false);
  }

  Map<String, dynamic>? getWorkspaceById(String id) {
    final results = _db.select(
      'SELECT id, display_name, path, source, created_at, updated_at '
      'FROM workspaces WHERE id = ? LIMIT 1',
      [id],
    );
    return results.isEmpty ? null : _workspaceFromRow(results.first);
  }

  Map<String, dynamic>? getWorkspaceByPath(String path) {
    final results = _db.select(
      'SELECT id, display_name, path, source, created_at, updated_at '
      'FROM workspaces WHERE path = ? LIMIT 1',
      [path],
    );
    return results.isEmpty ? null : _workspaceFromRow(results.first);
  }

  Map<String, dynamic>? renameWorkspace(String id, String displayName) {
    _db.execute(
      'UPDATE workspaces SET display_name = ?, updated_at = ? WHERE id = ?',
      [displayName, DateTime.now().toUtc().toIso8601String(), id],
    );
    return getWorkspaceById(id);
  }

  Map<String, dynamic>? relocateWorkspace(String id, String path) {
    _db.execute('UPDATE workspaces SET path = ?, updated_at = ? WHERE id = ?', [
      path,
      DateTime.now().toUtc().toIso8601String(),
      id,
    ]);
    return getWorkspaceById(id);
  }

  bool removeWorkspace(String id) {
    _db.execute('DELETE FROM workspaces WHERE id = ?', [id]);
    return _db.updatedRows == 1;
  }

  static String _workspaceDisplayName(String? displayName, String path) {
    final trimmed = displayName?.trim();
    if (trimmed != null && trimmed.isNotEmpty) return trimmed;
    final withoutTrailingSeparators = path.replaceAll(RegExp(r'[\\/]+$'), '');
    final basename = p.basename(withoutTrailingSeparators).trim();
    return basename.isEmpty ? path : basename;
  }

  static Map<String, dynamic> _workspaceFromRow(Row row) {
    return {
      'id': row['id'] as String,
      'display_name': row['display_name'] as String,
      'path': row['path'] as String,
      'source': row['source'] as String,
      'created_at': row['created_at'] as String,
      'updated_at': row['updated_at'] as String,
    };
  }

  void saveSession(SessionState session) {
    final normalizedWorkspaceId = _normalizeWorkspaceId(session.workspaceId);
    final normalizedCreatedAt = _normalizeDateTime(session.createdAt);
    final normalizedUpdatedAt = _normalizeDateTime(session.updatedAt);
    final normalizedLastUserMessageAt = session.lastUserMessageAt == null
        ? null
        : _normalizeDateTime(session.lastUserMessageAt!);
    final stmt = _db.prepare('''
      INSERT INTO sessions (
        session_id,
        model,
        provider_id,
        thinking_mode,
        title,
        title_status,
        workspace_id,
        created_at,
        updated_at,
        last_user_message_at,
        route_revision,
        route_updated_at,
        history_revision,
        lineage_id,
        parent_session_id,
        forked_from_message_id,
        forked_from_turn_id,
        fork_sequence,
        lineage_base_title,
        fork_request_id
      )
      VALUES (
        ?, ?, ?, ?, ?, ?, ?, ?, ?, COALESCE(?, ?), ?, ?, COALESCE(?, 0),
        ?, ?, ?, ?, COALESCE(?, 0), ?, ?
      )
      ON CONFLICT(session_id) DO UPDATE SET
        model = excluded.model,
        provider_id = COALESCE(excluded.provider_id, sessions.provider_id),
        thinking_mode = COALESCE(excluded.thinking_mode, sessions.thinking_mode),
        title = COALESCE(excluded.title, sessions.title),
        title_status = excluded.title_status,
        workspace_id = excluded.workspace_id,
        updated_at = excluded.updated_at,
        last_user_message_at = COALESCE(?, sessions.last_user_message_at);
    ''');
    stmt.execute([
      session.sessionId,
      session.model,
      session.providerId,
      session.thinkingMode,
      session.title,
      session.titleStatus.wireValue,
      normalizedWorkspaceId,
      normalizedCreatedAt,
      normalizedUpdatedAt,
      normalizedLastUserMessageAt,
      normalizedCreatedAt,
      session.routeRevision,
      _normalizeDateTime(session.routeUpdatedAt),
      session.historyRevision,
      session.lineageId,
      session.parentSessionId,
      session.forkedFromMessageId,
      session.forkedFromTurnId,
      session.forkSequence,
      session.lineageBaseTitle,
      session.forkRequestId,
      normalizedLastUserMessageAt,
    ]);
    stmt.dispose();
  }

  void updateSessionLastUserMessageAt(String sessionId, DateTime timestamp) {
    _db.execute(
      'UPDATE sessions SET last_user_message_at = ?, updated_at = ? WHERE session_id = ?',
      [
        _normalizeDateTime(timestamp),
        _normalizeDateTime(DateTime.now()),
        sessionId,
      ],
    );
  }

  SessionQueryResult getSessions(SessionQueryRequest query) {
    final limit = query.limit.clamp(1, SessionQueryRequest.maxLimit);

    String? cursorLastUserMessageAt;
    String? cursorSessionId;
    if (query.cursor != null) {
      final decoded = _decodeCursor(query.cursor!);
      if (decoded == null) {
        throw ArgumentError('Invalid pagination cursor');
      }
      cursorLastUserMessageAt = decoded['last_user_message_at'];
      cursorSessionId = decoded['session_id'];
    }

    final sql = StringBuffer('SELECT * FROM sessions WHERE 1=1');
    final params = [];

    final normalizedWorkspaceId = _normalizeWorkspaceId(query.workspaceId);
    if (query.unscopedOnly) {
      sql.write(' AND workspace_id IS NULL');
    } else if (normalizedWorkspaceId != null) {
      sql.write(' AND workspace_id = ?');
      params.add(normalizedWorkspaceId);
    }

    if (cursorLastUserMessageAt != null && cursorSessionId != null) {
      sql.write(
        ' AND (last_user_message_at < ? OR (last_user_message_at = ? AND session_id < ?))',
      );
      params.addAll([
        cursorLastUserMessageAt,
        cursorLastUserMessageAt,
        cursorSessionId,
      ]);
    }

    sql.write(' ORDER BY last_user_message_at DESC, session_id DESC LIMIT ?');
    params.add(limit + 1);

    final results = _db.select(sql.toString(), params);

    final sessions = <SessionState>[];
    for (final row in results) {
      sessions.add(SessionState.fromMap(row, []));
    }

    final hasMore = sessions.length > limit;
    if (hasMore) {
      sessions.removeLast();
    }

    String? nextCursor;
    if (sessions.isNotEmpty && hasMore) {
      final lastSession = sessions.last;
      final lastUserMsgAt =
          lastSession.lastUserMessageAt ?? lastSession.createdAt;
      nextCursor = _encodeCursor(lastUserMsgAt, lastSession.sessionId);
    }

    return SessionQueryResult(
      sessions: sessions,
      nextCursor: nextCursor,
      hasMore: hasMore,
    );
  }

  String _encodeCursor(DateTime lastUserMessageAt, String sessionId) {
    final jsonStr = jsonEncode({
      'last_user_message_at': _normalizeDateTime(lastUserMessageAt),
      'session_id': sessionId,
    });
    return base64Url.encode(utf8.encode(jsonStr));
  }

  Map<String, String>? _decodeCursor(String cursor) {
    try {
      final decodedStr = utf8.decode(base64Url.decode(cursor));
      final decodedMap = jsonDecode(decodedStr);
      if (decodedMap is Map &&
          decodedMap['last_user_message_at'] is String &&
          decodedMap['session_id'] is String) {
        final normalizedTimestamp = _normalizeTimestampString(
          decodedMap['last_user_message_at'] as String,
        );
        if (normalizedTimestamp == null) {
          return null;
        }
        return {
          'last_user_message_at': normalizedTimestamp,
          'session_id': decodedMap['session_id'] as String,
        };
      }
    } catch (_) {}
    return null;
  }

  SessionState? getSession(String sessionId) {
    final result = _db.select('SELECT * FROM sessions WHERE session_id = ?', [
      sessionId,
    ]);
    if (result.isEmpty) return null;

    final row = result.first;
    final messages = getMessages(sessionId);
    return SessionState.fromMap(row, messages);
  }

  List<SessionState> getAllSessions() {
    final result = _db.select(
      'SELECT * FROM sessions ORDER BY last_user_message_at DESC, session_id DESC',
    );
    return result.map((row) {
      // We don't load all messages for the list to keep it light
      return SessionState.fromMap(row, []);
    }).toList();
  }

  void updateSessionTitle(String sessionId, String title) {
    _db.execute(
      "UPDATE sessions SET title = ?, title_status = 'final', updated_at = ? WHERE session_id = ?",
      [title, _normalizeDateTime(DateTime.now()), sessionId],
    );
  }

  bool updateSessionTitleIfCurrent(
    String sessionId, {
    required String? expectedTitle,
    required String title,
  }) {
    return finalizePendingSessionTitle(
      sessionId,
      expectedTitle: expectedTitle,
      title: title,
    );
  }

  bool finalizePendingSessionTitle(
    String sessionId, {
    required String? expectedTitle,
    required String title,
  }) {
    _db.execute(
      '''
      UPDATE sessions
      SET title = ?, title_status = 'final', updated_at = ?
      WHERE session_id = ? AND title IS ? AND title_status = 'pending'
      ''',
      [title, _normalizeDateTime(DateTime.now()), sessionId, expectedTitle],
    );
    return _db.updatedRows == 1;
  }

  List<SessionState> getPendingTitleSessions() {
    final result = _db.select(
      "SELECT * FROM sessions WHERE title_status = 'pending' ORDER BY created_at ASC",
    );
    return result
        .map(
          (row) => SessionState.fromMap(
            row,
            getMessages(row['session_id'] as String),
          ),
        )
        .toList(growable: false);
  }

  void deleteSession(String sessionId) {
    const savepoint = 'sanad_delete_session';
    _db.execute('SAVEPOINT $savepoint');
    try {
      _db.execute(
        'UPDATE sessions SET parent_session_id = NULL '
        'WHERE parent_session_id = ?',
        [sessionId],
      );
      _db.execute('DELETE FROM sessions WHERE session_id = ?', [sessionId]);
      _db.execute('RELEASE SAVEPOINT $savepoint');
    } catch (_) {
      _db.execute('ROLLBACK TO SAVEPOINT $savepoint');
      _db.execute('RELEASE SAVEPOINT $savepoint');
      rethrow;
    }
    // Foreign key with ON DELETE CASCADE handles this session's owned rows
    // only. Children survive and lose their parent link in the same commit.
  }

  /// Saves (upserts) arbitrary metrics metadata for the last completed turn
  /// of a session. This is stored as a JSON blob and returned with thread history.
  void saveSessionMetadata(String sessionId, Map<String, dynamic> metadata) {
    _db.execute(
      'UPDATE sessions SET metadata = ?, updated_at = ? WHERE session_id = ?',
      [jsonEncode(metadata), _normalizeDateTime(DateTime.now()), sessionId],
    );
  }

  /// Returns the persisted metadata JSON for a session, or null if none saved yet.
  Map<String, dynamic>? getSessionMetadata(String sessionId) {
    final result = _db.select(
      'SELECT metadata FROM sessions WHERE session_id = ?',
      [sessionId],
    );
    if (result.isEmpty) return null;
    final raw = result.first['metadata'] as String?;
    if (raw == null) return null;
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  void replaceMessages(String sessionId, List<Message> messages) {
    _db.execute('BEGIN TRANSACTION');
    try {
      final existing = getPersistedMessages(sessionId);
      final assigned = MessageHistoryIdentity.assignIdentities(
        messages,
        existingActive: existing
            .map((entry) => MessageHistoryIdentity.read(entry.message))
            .toList(growable: false),
      );
      var unchangedPrefixLength = 0;
      final comparableLength = existing.length < assigned.length
          ? existing.length
          : assigned.length;
      while (unchangedPrefixLength < comparableLength &&
          jsonEncode(existing[unchangedPrefixLength].message.toJson()) ==
              jsonEncode(assigned[unchangedPrefixLength].toJson())) {
        unchangedPrefixLength++;
      }
      if (unchangedPrefixLength < existing.length) {
        _db.execute('DELETE FROM messages WHERE session_id = ? AND id >= ?', [
          sessionId,
          existing[unchangedPrefixLength].rowId,
        ]);
      }
      for (final message in assigned.skip(unchangedPrefixLength)) {
        MessageHistoryIdentity.persist(_db, sessionId, message);
      }
      SessionHistoryRevisionRepository.bumpDatabase(_db, sessionId);
      _db.execute('COMMIT');
    } catch (e) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Compare-and-swaps [expectedHistoryRevision], revalidates the target as
  /// the latest active root turn, soft-rewinds that tail, and inserts
  /// [replacement] in one transaction. Returns `null` when the session is
  /// missing, the revision does not match, or the target is no longer the
  /// latest active root.
  SoftRewindAdmissionCommit? commitSoftRewindAdmission({
    required String sessionId,
    required int expectedHistoryRevision,
    required String targetMessageId,
    required String targetTurnId,
    required String targetRequestId,
    required Message replacement,
  }) {
    _db.execute('BEGIN IMMEDIATE TRANSACTION');
    try {
      final row = _db.select(
        'SELECT history_revision FROM sessions WHERE session_id = ? LIMIT 1',
        [sessionId],
      );
      if (row.isEmpty) {
        _db.execute('ROLLBACK');
        return null;
      }
      final current = (row.first['history_revision'] as num?)?.toInt() ?? 0;
      if (current != expectedHistoryRevision) {
        _db.execute('ROLLBACK');
        return null;
      }
      final active = getMessages(sessionId);
      final targetIndex = _latestReplayableRootIndex(
        active,
        targetMessageId: targetMessageId,
        targetTurnId: targetTurnId,
        targetRequestId: targetRequestId,
      );
      if (targetIndex < 0) {
        _db.execute('ROLLBACK');
        return null;
      }
      final assignedReplacement = MessageHistoryIdentity.assignIdentities([
        replacement,
      ]).single;
      final replacementIdentity = MessageHistoryIdentity.read(
        assignedReplacement,
      );
      final superseded = [
        for (final message in active.skip(targetIndex))
          MessageHistoryIdentity.markSuperseded(
            message,
            byTurnId: replacementIdentity.turnId,
          ),
      ];
      _upsertMessageList(sessionId, [
        ...active.take(targetIndex),
        assignedReplacement,
        ...superseded,
      ]);
      final next = current + 1;
      _db.execute(
        'UPDATE sessions SET history_revision = ?, updated_at = ? WHERE session_id = ?',
        [next, _normalizeDateTime(DateTime.now()), sessionId],
      );
      _db.execute('COMMIT');
      return SoftRewindAdmissionCommit(
        historyRevision: next,
        replacementMessageId: replacementIdentity.messageId,
        replacementTurnId: replacementIdentity.turnId,
      );
    } catch (e) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  static int _latestReplayableRootIndex(
    List<Message> messages, {
    required String targetMessageId,
    required String targetTurnId,
    required String targetRequestId,
  }) {
    final latestRootIndex = messages.lastIndexWhere(
      MessageHistoryIdentity.isRootUser,
    );
    if (latestRootIndex < 0) return -1;
    final target = messages[latestRootIndex];
    final identity = MessageHistoryIdentity.read(target);
    if (!identity.replayEligible ||
        identity.messageId != targetMessageId ||
        identity.turnId != targetTurnId ||
        identity.requestId != targetRequestId) {
      return -1;
    }
    return latestRootIndex;
  }

  void _upsertMessageList(String sessionId, List<Message> messages) {
    final existingActive = getMessages(
      sessionId,
    ).map(MessageHistoryIdentity.read).toList(growable: false);
    final assigned = MessageHistoryIdentity.assignIdentities(
      messages,
      existingActive: existingActive,
    );
    final incomingIds = <String>{};
    for (final message in assigned) {
      final persisted = MessageHistoryIdentity.persist(_db, sessionId, message);
      incomingIds.add(MessageHistoryIdentity.read(persisted).messageId);
    }
    if (incomingIds.isEmpty) {
      _db.execute(
        "DELETE FROM messages WHERE session_id = ? AND history_status = 'active'",
        [sessionId],
      );
      return;
    }
    final placeholders = List.filled(incomingIds.length, '?').join(', ');
    _db.execute(
      '''
      DELETE FROM messages
      WHERE session_id = ?
        AND history_status = 'active'
        AND message_id NOT IN ($placeholders)
      ''',
      [sessionId, ...incomingIds],
    );
  }

  List<Message> getMessages(
    String sessionId, {
    bool includeSuperseded = false,
  }) {
    return getPersistedMessages(
      sessionId,
      includeSuperseded: includeSuperseded,
    ).map((entry) => entry.message).toList(growable: false);
  }

  List<PersistedMessage> getPersistedMessages(
    String sessionId, {
    bool includeSuperseded = false,
  }) {
    final result = _db.select(
      includeSuperseded
          ? 'SELECT * FROM messages WHERE session_id = ? ORDER BY id ASC'
          : '''
            SELECT * FROM messages
            WHERE session_id = ?
              AND (history_status = 'active' OR history_status IS NULL)
            ORDER BY id ASC
            ''',
      [sessionId],
    );
    return result
        .map((row) {
          return PersistedMessage(
            rowId: row['id'] as int,
            message: MessageHistoryIdentity.fromRow(row),
          );
        })
        .toList(growable: false);
  }

  // Scheduled Tasks persistence
  void saveScheduledTask(
    String id,
    String task,
    DateTime runAt,
    String sessionId,
  ) {
    final stmt = _db.prepare('''
      INSERT INTO scheduled_tasks (id, task, run_at, session_id, created_at)
      VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        task = excluded.task,
        run_at = excluded.run_at,
        session_id = excluded.session_id;
    ''');
    stmt.execute([
      id,
      task,
      _normalizeDateTime(runAt),
      sessionId,
      _normalizeDateTime(DateTime.now()),
    ]);
    stmt.dispose();
  }

  List<Map<String, dynamic>> getAllScheduledTasks() {
    final result = _db.select(
      'SELECT * FROM scheduled_tasks ORDER BY run_at ASC',
    );
    return result
        .map(
          (row) => {
            'id': row['id'],
            'task': row['task'],
            'run_at': row['run_at'],
            'session_id': row['session_id'],
          },
        )
        .toList();
  }

  void deleteScheduledTask(String id) {
    _db.execute('DELETE FROM scheduled_tasks WHERE id = ?', [id]);
  }

  static String _normalizeDateTime(DateTime value) =>
      value.toUtc().toIso8601String();

  static String? _normalizeTimestampString(String? value) {
    if (value == null) {
      return null;
    }
    final parsed = DateTime.tryParse(value);
    if (parsed == null) {
      return null;
    }
    return _normalizeDateTime(parsed);
  }

  static String? _normalizeWorkspaceId(String? workspaceId) {
    if (workspaceId == null) {
      return null;
    }
    final trimmed = workspaceId.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  void saveSuspendedCheckpoint(SuspendedCheckpoint checkpoint) {
    final row = checkpoint.toRow();
    final stmt = _db.prepare('''
      INSERT INTO suspended_checkpoints (
        checkpoint_id,
        session_id,
        request_id,
        tool_call_id,
        tool_name,
        status,
        tool_arguments,
        permission_payload,
        created_at,
        updated_at
      )
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(request_id) DO UPDATE SET
        checkpoint_id = excluded.checkpoint_id,
        session_id = excluded.session_id,
        tool_call_id = excluded.tool_call_id,
        tool_name = excluded.tool_name,
        status = excluded.status,
        tool_arguments = excluded.tool_arguments,
        permission_payload = excluded.permission_payload,
        updated_at = excluded.updated_at;
    ''');
    stmt.execute([
      row['checkpoint_id'],
      row['session_id'],
      row['request_id'],
      row['tool_call_id'],
      row['tool_name'],
      row['status'],
      row['tool_arguments'],
      row['permission_payload'],
      row['created_at'],
      row['updated_at'],
    ]);
    stmt.dispose();
  }

  SuspendedCheckpoint? getSuspendedCheckpointByRequestId(String requestId) {
    final result = _db.select(
      'SELECT * FROM suspended_checkpoints WHERE request_id = ? LIMIT 1',
      [requestId],
    );
    if (result.isEmpty) {
      return null;
    }
    return SuspendedCheckpoint.fromRow(Map<String, Object?>.from(result.first));
  }

  List<SuspendedCheckpoint> listSuspendedCheckpoints({String? status}) {
    final result = status == null
        ? _db.select(
            'SELECT * FROM suspended_checkpoints ORDER BY created_at ASC',
          )
        : _db.select(
            'SELECT * FROM suspended_checkpoints WHERE status = ? ORDER BY created_at ASC',
            [status],
          );
    return result
        .map(
          (row) => SuspendedCheckpoint.fromRow(Map<String, Object?>.from(row)),
        )
        .toList(growable: false);
  }

  void updateSuspendedCheckpointStatus({
    required String requestId,
    required String status,
  }) {
    _db.execute(
      'UPDATE suspended_checkpoints SET status = ?, updated_at = ? WHERE request_id = ?',
      [status, DateTime.now().toIso8601String(), requestId],
    );
  }

  bool claimSuspendedCheckpointDecision({
    required String requestId,
    required String status,
  }) {
    _db.execute(
      '''
      UPDATE suspended_checkpoints
      SET status = ?, updated_at = ?
      WHERE request_id = ? AND status = 'awaiting_permission'
      ''',
      [status, DateTime.now().toIso8601String(), requestId],
    );
    return _db.updatedRows == 1;
  }

  void deleteSuspendedCheckpointByRequestId(String requestId) {
    _db.execute('DELETE FROM suspended_checkpoints WHERE request_id = ?', [
      requestId,
    ]);
  }

  void deleteSuspendedCheckpointByToolCallId(String toolCallId) {
    _db.execute('DELETE FROM suspended_checkpoints WHERE tool_call_id = ?', [
      toolCallId,
    ]);
  }

  /// Creates a child session and copies the active prefix through [targetTurnId]
  /// in one write transaction. Runtime work is not copied.
  SessionForkCommit commitFork({
    required String sourceSessionId,
    required String requestId,
    required String targetMessageId,
    required String targetTurnId,
  }) {
    if (sourceSessionId.isEmpty ||
        requestId.isEmpty ||
        targetMessageId.isEmpty ||
        targetTurnId.isEmpty) {
      return const SessionForkCommit(
        outcome: SessionForkOutcome.invalidRequest,
      );
    }

    const maxAttempts = 8;
    Object? lastError;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      _db.execute('BEGIN IMMEDIATE TRANSACTION');
      try {
        final existing = _db.select(
          '''
          SELECT session_id, parent_session_id,
                 forked_from_message_id, forked_from_turn_id
          FROM sessions
          WHERE fork_request_id = ?
          LIMIT 1
          ''',
          [requestId],
        );
        if (existing.isNotEmpty) {
          final row = existing.first;
          final matchesCommand =
              row['parent_session_id'] == sourceSessionId &&
              row['forked_from_message_id'] == targetMessageId &&
              row['forked_from_turn_id'] == targetTurnId;
          if (!matchesCommand) {
            _db.execute('ROLLBACK');
            return const SessionForkCommit(
              outcome: SessionForkOutcome.invalidRequest,
            );
          }
          final childId = row['session_id'] as String;
          _db.execute('COMMIT');
          return SessionForkCommit(
            outcome: SessionForkOutcome.alreadyExists,
            child: getSession(childId),
          );
        }

        final parent = getSession(sourceSessionId);
        if (parent == null) {
          _db.execute('ROLLBACK');
          return const SessionForkCommit(
            outcome: SessionForkOutcome.sessionNotFound,
          );
        }

        final active = getMessages(sourceSessionId);
        final target = _findActive(
          active,
          messageId: targetMessageId,
          turnId: targetTurnId,
        );
        if (target == null) {
          final stored = getMessages(sourceSessionId, includeSuperseded: true);
          final found = _findActive(
            stored,
            messageId: targetMessageId,
            turnId: targetTurnId,
            ignoreStatus: true,
          );
          _db.execute('ROLLBACK');
          return SessionForkCommit(
            outcome: found == null
                ? SessionForkOutcome.targetNotFound
                : SessionForkOutcome.targetNotForkable,
          );
        }
        if (!SessionForkCopy.isForkableFinalAnswer(target)) {
          _db.execute('ROLLBACK');
          return const SessionForkCommit(
            outcome: SessionForkOutcome.targetNotForkable,
          );
        }

        final prefix = SessionForkCopy.activePrefixThroughTurn(
          activeMessages: active,
          targetMessageId: targetMessageId,
          targetTurnId: targetTurnId,
        );
        if (prefix.isEmpty) {
          _db.execute('ROLLBACK');
          return const SessionForkCommit(
            outcome: SessionForkOutcome.targetNotFound,
          );
        }

        final lineageId = parent.lineageId;
        final sequence = _nextForkSequence(lineageId);
        final baseTitle = SessionForkCopy.baseTitleOf(
          parent.lineageBaseTitle,
          parent.title,
        );
        final now = DateTime.now().toUtc();
        final child = SessionState(
          sessionId: const Uuid().v4(),
          model: parent.model,
          providerId: parent.providerId,
          thinkingMode: parent.thinkingMode,
          title: SessionForkCopy.forkTitle(sequence, baseTitle),
          titleStatus: SessionTitleStatus.finalized,
          workspaceId: parent.workspaceId,
          createdAt: now,
          updatedAt: now,
          // Fork creation is new sidebar activity even though the materialized
          // user rows preserve their historical timestamps.
          lastUserMessageAt: now,
          routeRevision: parent.routeRevision,
          routeUpdatedAt: parent.routeUpdatedAt,
          historyRevision: 0,
          lineageId: lineageId,
          parentSessionId: parent.sessionId,
          forkedFromMessageId: targetMessageId,
          forkedFromTurnId: targetTurnId,
          forkSequence: sequence,
          lineageBaseTitle: baseTitle,
          forkRequestId: requestId,
        );
        saveSession(child);
        if (parent.lineageBaseTitle == null ||
            parent.lineageBaseTitle!.trim().isEmpty) {
          _db.execute(
            '''
            UPDATE sessions
            SET lineage_base_title = ?
            WHERE session_id = ?
              AND (lineage_base_title IS NULL OR TRIM(lineage_base_title) = '')
            ''',
            [baseTitle, parent.sessionId],
          );
        }
        for (final message in SessionForkCopy.rewritePrefix(prefix)) {
          MessageHistoryIdentity.persist(_db, child.sessionId, message);
        }
        _db.execute('COMMIT');
        return SessionForkCommit(
          outcome: SessionForkOutcome.accepted,
          child: getSession(child.sessionId),
        );
      } catch (error) {
        _db.execute('ROLLBACK');
        lastError = error;
        if (error is SqliteException && _isLineageSequenceConflict(error)) {
          continue;
        }
        return const SessionForkCommit(outcome: SessionForkOutcome.failed);
      }
    }
    if (lastError != null) {
      return const SessionForkCommit(outcome: SessionForkOutcome.failed);
    }
    return const SessionForkCommit(outcome: SessionForkOutcome.failed);
  }

  int _nextForkSequence(String lineageId) {
    final row = _db.select(
      'SELECT MAX(fork_sequence) AS max_seq FROM sessions WHERE lineage_id = ?',
      [lineageId],
    );
    final current = (row.first['max_seq'] as num?)?.toInt() ?? 0;
    return current + 1;
  }

  static Message? _findActive(
    List<Message> messages, {
    required String messageId,
    required String turnId,
    bool ignoreStatus = false,
  }) {
    for (final message in messages) {
      final identity = MessageHistoryIdentity.read(message);
      if (identity.messageId != messageId || identity.turnId != turnId) {
        continue;
      }
      if (!ignoreStatus &&
          identity.historyStatus != MessageHistoryIdentity.active) {
        continue;
      }
      return message;
    }
    return null;
  }

  static bool _isLineageSequenceConflict(SqliteException error) {
    final text = error.message;
    return text.contains('idx_sessions_lineage_sequence') ||
        text.contains('UNIQUE constraint failed');
  }
}

enum SessionForkOutcome {
  accepted,
  alreadyExists,
  targetNotFound,
  targetNotForkable,
  sessionNotFound,
  invalidRequest,
  failed,
}

class SessionForkCommit {
  final SessionForkOutcome outcome;
  final SessionState? child;

  const SessionForkCommit({required this.outcome, this.child});
}
