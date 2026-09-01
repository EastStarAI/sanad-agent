import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';

import '../models/session_query.dart';
import '../models/session_history_page.dart';
import '../models/session_state.dart';
import '../models/suspended_checkpoint.dart';
import '../../core/models/message.dart';
import 'agent_state_database.dart';
import 'session_history_revision_repository.dart';
import '../compaction/model_context_projection.dart';

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
        route_updated_at
      )
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, COALESCE(?, ?), ?, ?)
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
    _db.execute('DELETE FROM sessions WHERE session_id = ?', [sessionId]);
    // Foreign key with ON DELETE CASCADE will handle messages
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
      final encodedMessages = [
        for (final message in messages) jsonEncode(message.toJson()),
      ];
      final existing = _db.select(
        'SELECT id, data FROM messages WHERE session_id = ? ORDER BY id ASC',
        [sessionId],
      );
      var unchangedPrefixLength = 0;
      final comparableLength = existing.length < encodedMessages.length
          ? existing.length
          : encodedMessages.length;
      while (unchangedPrefixLength < comparableLength &&
          existing[unchangedPrefixLength]['data'] ==
              encodedMessages[unchangedPrefixLength]) {
        unchangedPrefixLength++;
      }

      if (unchangedPrefixLength < existing.length) {
        _db.execute('DELETE FROM messages WHERE session_id = ? AND id >= ?', [
          sessionId,
          existing[unchangedPrefixLength]['id'],
        ]);
      }

      final stmt = _db.prepare('''
        INSERT INTO messages (session_id, data)
        VALUES (?, ?)
      ''');

      for (
        var index = unchangedPrefixLength;
        index < encodedMessages.length;
        index++
      ) {
        stmt.execute([sessionId, encodedMessages[index]]);
      }
      stmt.dispose();
      SessionHistoryRevisionRepository.bumpDatabase(_db, sessionId);
      _db.execute('COMMIT');
    } catch (e) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  List<Message> getMessages(String sessionId) {
    return getPersistedMessages(
      sessionId,
    ).map((entry) => entry.message).toList(growable: false);
  }

  List<PersistedMessage> getPersistedMessages(String sessionId) {
    final result = _db.select(
      'SELECT * FROM messages WHERE session_id = ? ORDER BY id ASC',
      [sessionId],
    );
    return result.map(_persistedMessageFromRow).toList(growable: false);
  }

  SessionHistoryPage getPersistedMessagePage(
    String sessionId, {
    int limit = defaultSessionHistoryPageSize,
    String? cursor,
    int? anchorRowId,
    int maxPersistedBytes = defaultSessionHistoryPageBytes,
  }) {
    if (limit <= 0 || limit > maxSessionHistoryPageSize) {
      throw RangeError.range(limit, 1, maxSessionHistoryPageSize, 'limit');
    }

    final revisionRows = _db.select(
      'SELECT history_revision FROM sessions WHERE session_id = ?',
      [sessionId],
    );
    final historyRevision = revisionRows.isEmpty
        ? 0
        : revisionRows.first['history_revision'] as int;
    SessionHistoryCursor? decodedCursor;
    if (cursor != null) {
      decodedCursor = SessionHistoryCursor.decode(cursor);
      if (decodedCursor.sessionId != sessionId) {
        throw const SessionHistoryCursorStaleException(
          'cursor_session_mismatch',
        );
      }
      final boundaryRows = _db.select(
        'SELECT id, data FROM messages WHERE session_id = ? AND id = ?',
        [sessionId, decodedCursor.beforeRowId],
      );
      if (boundaryRows.isEmpty) {
        throw const SessionHistoryCursorStaleException(
          'cursor_boundary_missing',
        );
      }
      final boundary = _persistedMessageFromRow(boundaryRows.first);
      if (SessionHistoryCursor.fingerprint(boundary.message) !=
          decodedCursor.boundaryFingerprint) {
        throw const SessionHistoryCursorStaleException(
          'cursor_boundary_changed',
        );
      }
    }

    if (decodedCursor != null && anchorRowId != null) {
      throw ArgumentError('cursor and anchorRowId are mutually exclusive');
    }
    if (anchorRowId != null) {
      final anchorRows = _db.select(
        'SELECT 1 FROM messages WHERE session_id = ? AND id = ?',
        [sessionId, anchorRowId],
      );
      if (anchorRows.isEmpty) {
        throw const SessionHistoryAnchorNotFoundException();
      }
    }

    final boundaryRowId = decodedCursor?.beforeRowId ?? anchorRowId;
    final boundaryOperator = decodedCursor == null && anchorRowId != null
        ? '<='
        : '<';
    final rows = _db.select(
      boundaryRowId == null
          ? '''
            SELECT id, data FROM messages
            WHERE session_id = ?
            ORDER BY id DESC
            LIMIT ?
            '''
          : '''
            SELECT id, data FROM messages
            WHERE session_id = ? AND id $boundaryOperator ?
            ORDER BY id DESC
            LIMIT ?
            ''',
      boundaryRowId == null
          ? [sessionId, limit + 1]
          : [sessionId, boundaryRowId, limit + 1],
    );
    final selectedRows = <Row>[];
    var persistedBytes = 0;
    for (final row in rows) {
      if (selectedRows.length >= limit) break;
      final rowBytes = utf8.encode(row['data'] as String).length;
      if (selectedRows.isNotEmpty &&
          persistedBytes + rowBytes > maxPersistedBytes) {
        break;
      }
      selectedRows.add(row);
      persistedBytes += rowBytes;
    }
    final hasMore = rows.length > selectedRows.length;
    final messages = selectedRows.reversed
        .map(_persistedMessageFromRow)
        .toList(growable: false);
    final oldest = messages.firstOrNull;
    final nextCursor = hasMore && oldest != null
        ? SessionHistoryCursor(
            sessionId: sessionId,
            beforeRowId: oldest.rowId,
            historyRevision: historyRevision,
            boundaryFingerprint: SessionHistoryCursor.fingerprint(
              oldest.message,
            ),
          ).encode()
        : null;
    return SessionHistoryPage(
      messages: messages,
      hasMore: hasMore,
      nextCursor: nextCursor,
      historyRevision: historyRevision,
      persistedBytes: persistedBytes,
    );
  }

  PersistedMessage _persistedMessageFromRow(Row row) {
    final data = jsonDecode(row['data'] as String);
    return PersistedMessage(
      rowId: row['id'] as int,
      message: Message.fromJson(data),
    );
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
}
