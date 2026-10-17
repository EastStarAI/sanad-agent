import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';

import '../models/session_query.dart';
import '../models/session_search.dart';
import '../models/session_state.dart';
import 'agent_state_database.dart';
import 'session_message_repository.dart';

/// Persistent storage for workspaces and sessions (lifecycle, metadata, titles).
class SessionRepository {
  final AgentStateDatabase _state;
  final SessionMessageRepository _messages;

  SessionRepository(this._state, [SessionMessageRepository? messages])
      : _messages = messages ?? SessionMessageRepository(_state);

  Database get _db => _state.db;

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
        thinking_mode = excluded.thinking_mode,
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

  SessionSearchResult searchSessions(SessionSearchRequest request) {
    final cursor = request.cursor == null
        ? null
        : _decodeSearchCursor(request.cursor!, request.fingerprint);
    final params = <Object?>[request.query];
    final cursorClause = cursor == null
        ? ''
        : '''
          WHERE match_rank > ?
             OR (match_rank = ? AND order_at < ?)
             OR (match_rank = ? AND order_at = ? AND session_id < ?)
          ''';
    if (cursor != null) {
      params.addAll([
        cursor.rank,
        cursor.rank,
        cursor.orderAt,
        cursor.rank,
        cursor.orderAt,
        cursor.sessionId,
      ]);
    }
    params.add(request.limit + 1);

    final rows = _db.select(
      '''
      WITH base_messages AS (
        SELECT m.id, m.session_id,
               json_extract(m.data, '\$.role') AS role,
               json_extract(m.data, '\$.content') AS content,
               json_extract(m.data, '\$.thought') AS thought,
               json_extract(m.data, '\$.reasoning') AS reasoning,
               COALESCE(json_array_length(json_extract(m.data, '\$.toolCalls')), 0) AS tool_count,
               CASE
                 WHEN json_extract(m.data, '\$.metadata.terminal_work_item_id') IS NOT NULL THEN 1
                 WHEN json_extract(m.data, '\$.role') = 'assistant'
                      AND COALESCE(json_array_length(json_extract(m.data, '\$.toolCalls')), 0) = 0
                      AND m.id = (
                        SELECT MAX(m2.id)
                        FROM messages m2
                        WHERE m2.session_id = m.session_id
                          AND (m2.history_status = 'active' OR m2.history_status IS NULL)
                          AND json_extract(m2.data, '\$.role') = 'assistant'
                          AND COALESCE(json_array_length(json_extract(m2.data, '\$.toolCalls')), 0) = 0
                          AND COALESCE(json_extract(m2.data, '\$.metadata.superseded_by_steer'), 0) != 1
                      ) THEN 1
                 ELSE 0
               END AS is_terminal
        FROM messages m
        WHERE (m.history_status = 'active' OR m.history_status IS NULL)
          AND COALESCE(json_extract(m.data, '\$.metadata.superseded_by_steer'), 0) != 1
      ),
      visible_texts AS (
        SELECT id, session_id, content, 'user_message' AS anchor_kind,
               0 AS anchor_ordinal, 1 AS candidate_priority
        FROM base_messages
        WHERE role = 'user' AND NULLIF(TRIM(content), '') IS NOT NULL
        UNION ALL
        SELECT id, session_id, content, 'final_answer', 0, 0
        FROM base_messages
        WHERE role = 'assistant' AND tool_count = 0 AND is_terminal = 1
          AND NULLIF(TRIM(content), '') IS NOT NULL
        UNION ALL
        SELECT id, session_id, thought, 'thought', 0, 2
        FROM base_messages
        WHERE role = 'assistant' AND tool_count = 0
          AND NULLIF(TRIM(thought), '') IS NOT NULL
          AND (NULLIF(TRIM(reasoning), '') IS NULL OR thought != reasoning)
        UNION ALL
        SELECT id, session_id, content, 'thought',
               CASE
                 WHEN NULLIF(TRIM(thought), '') IS NOT NULL
                      AND (NULLIF(TRIM(reasoning), '') IS NULL OR thought != reasoning)
                 THEN 1 ELSE 0
               END,
               3
        FROM base_messages
        WHERE role = 'assistant' AND tool_count = 0 AND is_terminal = 0
          AND NULLIF(TRIM(content), '') IS NOT NULL
          AND (NULLIF(TRIM(reasoning), '') IS NULL OR content != reasoning)
          AND (NULLIF(TRIM(thought), '') IS NULL OR content != thought)
        UNION ALL
        SELECT id, session_id,
               CASE WHEN NULLIF(TRIM(thought), '') IS NOT NULL THEN thought ELSE content END,
               'thought', 0, 2
        FROM base_messages
        WHERE role = 'assistant' AND tool_count > 0
          AND COALESCE(NULLIF(TRIM(thought), ''), NULLIF(TRIM(content), '')) IS NOT NULL
          AND (
            NULLIF(TRIM(reasoning), '') IS NULL
            OR COALESCE(NULLIF(TRIM(thought), ''), NULLIF(TRIM(content), '')) != reasoning
          )
      ),
      eligible_matches AS (
        SELECT *, ROW_NUMBER() OVER (
          PARTITION BY session_id
          ORDER BY id DESC, candidate_priority ASC
        ) AS match_order
        FROM visible_texts
        WHERE instr(sanad_search_normalize(content), ?) > 0
      ),
      latest_match AS (
        SELECT * FROM eligible_matches WHERE match_order = 1
      ),
      ranked AS (
        SELECT s.*,
               COALESCE(s.last_user_message_at, s.created_at) AS order_at,
               lm.id AS match_row_id,
               lm.content AS match_content,
               lm.anchor_kind AS match_anchor_kind,
               lm.anchor_ordinal AS match_anchor_ordinal,
               CASE
                 WHEN instr(sanad_search_normalize(COALESCE(s.title, '')), ?) > 0
                      AND lm.id IS NOT NULL THEN 0
                 WHEN instr(sanad_search_normalize(COALESCE(s.title, '')), ?) > 0 THEN 1
                 ELSE 2
               END AS match_rank
        FROM sessions s
        LEFT JOIN latest_match lm ON lm.session_id = s.session_id
        WHERE instr(sanad_search_normalize(COALESCE(s.title, '')), ?) > 0
           OR lm.id IS NOT NULL
      )
      SELECT * FROM ranked
      $cursorClause
      ORDER BY match_rank ASC, order_at DESC, session_id DESC
      LIMIT ?
      ''',
      [request.query, request.query, request.query, ...params],
    );

    final hits = <SessionSearchHit>[];
    for (final row in rows.take(request.limit)) {
      final rank = row['match_rank'] as int;
      final rowId = row['match_row_id'] as int?;
      final anchorKind = row['match_anchor_kind'] as String?;
      final anchorOrdinal = row['match_anchor_ordinal'] as int?;
      hits.add(
        SessionSearchHit(
          session: SessionState.fromMap(row, const []),
          matchKind: switch (rank) {
            0 => SessionSearchMatchKind.titleAndContent,
            1 => SessionSearchMatchKind.title,
            _ => SessionSearchMatchKind.content,
          },
          snippet: _searchSnippet(
            row['match_content'] as String?,
            request.query,
          ),
          anchorEventId:
              rowId == null || anchorKind == null || anchorOrdinal == null
              ? null
              : 'history:${row['session_id']}:$rowId:$anchorKind:$anchorOrdinal',
        ),
      );
    }
    final hasMore = rows.length > request.limit;
    final last = hits.lastOrNull;
    return SessionSearchResult(
      hits: hits,
      hasMore: hasMore,
      nextCursor: hasMore && last != null
          ? _encodeSearchCursor(
              fingerprint: request.fingerprint,
              rank: rows[request.limit - 1]['match_rank'] as int,
              orderAt: rows[request.limit - 1]['order_at'] as String,
              sessionId: last.session.sessionId,
            )
          : null,
    );
  }

  String? _searchSnippet(String? content, String query) {
    if (content == null || content.trim().isEmpty) return null;
    final display = content.trim().replaceAll(RegExp(r'\s+'), ' ');
    final normalized = SessionSearchRequest.normalize(display);
    final index = normalized.indexOf(query);
    if (index < 0) return null;
    final start = (index - SessionSearchRequest.maxSnippetLength ~/ 2).clamp(
      0,
      display.length,
    );
    final end = (start + SessionSearchRequest.maxSnippetLength).clamp(
      0,
      display.length,
    );
    return '${start > 0 ? '…' : ''}${display.substring(start, end)}${end < display.length ? '…' : ''}';
  }

  ({int rank, String orderAt, String sessionId}) _decodeSearchCursor(
    String cursor,
    String fingerprint,
  ) {
    try {
      final decoded = jsonDecode(utf8.decode(base64Url.decode(cursor)));
      if (decoded is! Map ||
          decoded['v'] != 1 ||
          decoded['q'] != fingerprint ||
          decoded['r'] is! int ||
          decoded['t'] is! String ||
          decoded['s'] is! String) {
        throw const FormatException();
      }
      return (
        rank: decoded['r'] as int,
        orderAt: decoded['t'] as String,
        sessionId: decoded['s'] as String,
      );
    } catch (_) {
      throw ArgumentError('Invalid or stale search cursor');
    }
  }

  String _encodeSearchCursor({
    required String fingerprint,
    required int rank,
    required String orderAt,
    required String sessionId,
  }) => base64Url.encode(
    utf8.encode(
      jsonEncode({
        'v': 1,
        'q': fingerprint,
        'r': rank,
        't': orderAt,
        's': sessionId,
      }),
    ),
  );

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

  /// Reads only the session row. Message rows are never queried or decoded.
  SessionState? getSessionRecord(String sessionId) {
    final result = _db.select('SELECT * FROM sessions WHERE session_id = ?', [
      sessionId,
    ]);
    if (result.isEmpty) return null;
    return SessionState.fromMap(result.first);
  }

  SessionState? getSession(String sessionId) {
    final record = getSessionRecord(sessionId);
    if (record == null) return null;
    return SessionState.fromMap(record.toMap(), _messages.getMessages(sessionId));
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
            _messages.getMessages(row['session_id'] as String),
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
}
