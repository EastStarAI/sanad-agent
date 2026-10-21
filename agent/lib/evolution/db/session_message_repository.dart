import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import '../../core/models/message.dart';
import '../../core/models/tool_call.dart';
import '../compaction/model_context_projection.dart';
import '../models/session_history_page.dart';
import 'agent_state_database.dart';
import 'message_history_identity.dart';
import 'session_history_revision_repository.dart';
import 'terminal_assistant_classifier.dart';

/// Originating tool-call context resolved from persisted session history.
class OriginatingToolCallContext {
  final ToolCall toolCall;
  final String? runId;
  final String? modelStepId;

  const OriginatingToolCallContext({
    required this.toolCall,
    this.runId,
    this.modelStepId,
  });
}

/// Persistent storage for session messages, history projections, and tool results.
class SessionMessageRepository {
  final AgentStateDatabase _state;

  SessionMessageRepository(this._state);

  Database get _db => _state.db;

  void replaceMessages(String sessionId, List<Message> messages) {
    _db.execute('BEGIN TRANSACTION');
    try {
      _replaceMessagesInDatabase(_db, sessionId, messages);
      _db.execute('COMMIT');
    } catch (e) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Persists history inside an aggregate transaction owned by the caller.
  /// This is used when history and another session-owned lifecycle row must
  /// become authoritative at the same commit boundary.
  List<Message> replaceMessagesInTransaction(
    String sessionId,
    List<Message> messages,
    AgentStateTransaction transaction,
  ) => _replaceMessagesInDatabase(transaction.db, sessionId, messages);

  /// Rewrites the active history of [sessionId] to [messages].
  ///
  /// Rows are aligned by `message_id`, never by content: every aligned row is
  /// updated in place (keeping `messages.id`) when its data differs, so
  /// content transforms such as image pruning, provider-state clearing, steer
  /// stamping, and metadata edits keep every row id and therefore every
  /// compaction boundary endpoint. Only the first structural divergence (an
  /// insertion, removal, reorder, or identity change) re-inserts the remaining
  /// suffix, because `messages.id` is the only ordering key. The suffix delete
  /// is scoped to the replaced active rows, so superseded audit rows survive.
  /// A replacement with the same `message_id` as a stored row that carries the
  /// terminal stamp keeps that stamp (see
  /// [TerminalAssistantClassifier.carryForwardStamp]); only the terminal
  /// commit writes it, and a rewrite from an older copy must not erase it.
  /// Duplicate `message_id`s fail with [StateError] before any write.
  List<Message> _replaceMessagesInDatabase(
    Database db,
    String sessionId,
    List<Message> messages,
  ) {
    final existing = getPersistedMessages(sessionId);
    final existingIdentities = existing
        .map((entry) => MessageHistoryIdentity.read(entry.message))
        .toList(growable: false);
    final stampedById = <String, Message>{
      for (var i = 0; i < existing.length; i++)
        if (existingIdentities[i].messageId.isNotEmpty &&
            TerminalAssistantClassifier.hasStamp(existing[i].message))
          existingIdentities[i].messageId: existing[i].message,
    };
    final assigned = [
      for (final message in MessageHistoryIdentity.assignIdentities(
        messages,
        existingActive: existingIdentities,
      ))
        switch (stampedById[MessageHistoryIdentity.read(message).messageId]) {
          final stored? => TerminalAssistantClassifier.carryForwardStamp(
            stored: stored,
            replacement: message,
          ),
          null => message,
        },
    ];
    MessageHistoryIdentity.requireUniqueMessageIds(assigned);
    var alignedLength = 0;
    final comparableLength = existing.length < assigned.length
        ? existing.length
        : assigned.length;
    while (alignedLength < comparableLength) {
      final existingId = existingIdentities[alignedLength].messageId;
      final replacement = assigned[alignedLength];
      final aligned = existingId.isEmpty
          // A legacy row without durable identity aligns only by position
          // with a message that carried no explicit identity of its own.
          ? MessageHistoryIdentity.read(
              messages[alignedLength],
            ).messageId.isEmpty
          : existingId == MessageHistoryIdentity.read(replacement).messageId;
      if (!aligned) break;
      final current = existing[alignedLength];
      if (jsonEncode(current.message.toJson()) !=
          jsonEncode(replacement.toJson())) {
        MessageHistoryIdentity.persist(
          db,
          sessionId,
          replacement,
          sqliteId: current.rowId,
        );
      }
      alignedLength++;
    }
    if (alignedLength < existing.length) {
      // Exactly the active rows being replaced: `existing` is the ordered
      // active set, so every active row from the divergence onward.
      db.execute(
        '''
        DELETE FROM messages
        WHERE session_id = ?
          AND id >= ?
          AND (history_status = 'active' OR history_status IS NULL)
        ''',
        [sessionId, existing[alignedLength].rowId],
      );
    }
    for (final message in assigned.skip(alignedLength)) {
      MessageHistoryIdentity.persist(db, sessionId, message);
    }
    SessionHistoryRevisionRepository.bumpDatabase(db, sessionId);
    return getPersistedMessages(
      sessionId,
    ).map((entry) => entry.message).toList(growable: false);
  }

  void upsertMessageList(String sessionId, List<Message> messages) {
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
    return result.map(persistedMessageFromRow).toList(growable: false);
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
        '''SELECT * FROM messages
           WHERE session_id = ? AND id = ?
             AND (history_status = 'active' OR history_status IS NULL)''',
        [sessionId, decodedCursor.beforeRowId],
      );
      if (boundaryRows.isEmpty) {
        throw const SessionHistoryCursorStaleException(
          'cursor_boundary_missing',
        );
      }
      final boundary = persistedMessageFromRow(boundaryRows.first);
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
        '''SELECT 1 FROM messages
           WHERE session_id = ? AND id = ?
             AND (history_status = 'active' OR history_status IS NULL)''',
        [sessionId, anchorRowId],
      );
      if (anchorRows.isEmpty) {
        throw const SessionHistoryAnchorNotFoundException();
      }
    }

    final isAnchoredPage = anchorRowId != null;
    final isNewerPage =
        decodedCursor?.direction == SessionHistoryCursorDirection.newer;
    final boundaryRowId = decodedCursor?.beforeRowId;
    final readsForward = isAnchoredPage || isNewerPage;
    final rows = _db.select(
      isAnchoredPage
          ? '''
            SELECT * FROM messages
            WHERE session_id = ? AND id >= ?
              AND (history_status = 'active' OR history_status IS NULL)
            ORDER BY id ASC
            LIMIT ?
            '''
          : isNewerPage
          ? '''
            SELECT * FROM messages
            WHERE session_id = ? AND id > ?
              AND (history_status = 'active' OR history_status IS NULL)
            ORDER BY id ASC
            LIMIT ?
            '''
          : boundaryRowId == null
          ? '''
            SELECT * FROM messages
            WHERE session_id = ?
              AND (history_status = 'active' OR history_status IS NULL)
            ORDER BY id DESC
            LIMIT ?
            '''
          : '''
            SELECT * FROM messages
            WHERE session_id = ? AND id < ?
              AND (history_status = 'active' OR history_status IS NULL)
            ORDER BY id DESC
            LIMIT ?
            ''',
      isAnchoredPage
          ? [sessionId, anchorRowId, limit + 1]
          : boundaryRowId == null
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
    final hasMore = isAnchoredPage
        ? _db
              .select(
                '''SELECT 1 FROM messages
               WHERE session_id = ? AND id < ?
                 AND (history_status = 'active' OR history_status IS NULL)
               LIMIT 1''',
                [sessionId, anchorRowId],
              )
              .isNotEmpty
        : !isNewerPage && rows.length > selectedRows.length;
    final hasNewer = readsForward && rows.length > selectedRows.length;
    final chronologicalRows = readsForward
        ? selectedRows
        : selectedRows.reversed;
    final messages = chronologicalRows
        .map(persistedMessageFromRow)
        .toList(growable: false);
    final oldest = messages.firstOrNull;
    final newest = messages.lastOrNull;
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
    final nextNewerCursor = hasNewer && newest != null
        ? SessionHistoryCursor(
            sessionId: sessionId,
            beforeRowId: newest.rowId,
            historyRevision: historyRevision,
            boundaryFingerprint: SessionHistoryCursor.fingerprint(
              newest.message,
            ),
            direction: SessionHistoryCursorDirection.newer,
          ).encode()
        : null;
    return SessionHistoryPage(
      messages: messages,
      hasMore: hasMore,
      nextCursor: nextCursor,
      hasNewer: hasNewer,
      nextNewerCursor: nextNewerCursor,
      historyRevision: historyRevision,
      persistedBytes: persistedBytes,
      followingMessage: newest == null
          ? null
          : _firstActiveMessageAfter(sessionId, newest.rowId),
    );
  }

  Message? _firstActiveMessageAfter(String sessionId, int rowId) {
    final rows = _db.select(
      '''
      SELECT * FROM messages
      WHERE session_id = ? AND id > ?
        AND (history_status = 'active' OR history_status IS NULL)
      ORDER BY id ASC
      LIMIT 1
      ''',
      [sessionId, rowId],
    );
    return rows.isEmpty ? null : persistedMessageFromRow(rows.first).message;
  }

  PersistedMessage persistedMessageFromRow(Row row) {
    return PersistedMessage(
      rowId: row['id'] as int,
      message: MessageHistoryIdentity.fromRow(row),
    );
  }

  /// Resolves the originating assistant [ToolCall] and execution context for a
  /// specific tool call ID from persisted session history without loading the
  /// full timeline or tool output bytes.
  OriginatingToolCallContext? findOriginatingToolCall(
    String sessionId, {
    required String toolCallId,
    String? turnId,
  }) {
    if (sessionId.isEmpty || toolCallId.isEmpty) return null;

    final hasTurn = turnId != null && turnId.isNotEmpty;
    final sql = '''
      SELECT
        m.id AS message_row_id,
        m.session_id,
        m.turn_id,
        m.run_id,
        json_extract(m.data, '\$.metadata.run_id') AS metadata_run_id,
        json_extract(m.data, '\$.metadata.model_step_id') AS metadata_model_step_id,
        tc.value AS tool_call_json
      FROM messages m,
           json_each(json_extract(m.data, '\$.toolCalls')) tc
      WHERE m.session_id = ?
        ${hasTurn ? 'AND m.turn_id = ?' : ''}
        AND (m.history_status = 'active' OR m.history_status IS NULL)
        AND json_extract(m.data, '\$.role') = 'assistant'
        AND json_extract(tc.value, '\$.id') = ?
      ORDER BY m.id DESC
      LIMIT 2
    ''';

    final params = <Object?>[
      sessionId,
      if (hasTurn) turnId,
      toolCallId,
    ];

    final rows = _db.select(sql, params);
    if (rows.isEmpty) return null;

    // Enforce honest ambiguity handling: if multiple active origins exist,
    // do not guess which one owns the call.
    if (rows.length > 1) {
      return null;
    }

    final row = rows.first;
    final toolCallJsonRaw = row['tool_call_json'];
    if (toolCallJsonRaw == null || toolCallJsonRaw is! String) return null;

    try {
      final parsed = jsonDecode(toolCallJsonRaw);
      if (parsed is! Map) return null;
      final toolCall = ToolCall.fromJson(
        Map<String, dynamic>.from(parsed),
      );
      return OriginatingToolCallContext(
        toolCall: toolCall,
        runId: row['run_id']?.toString() ??
            row['metadata_run_id']?.toString(),
        modelStepId: row['metadata_model_step_id']?.toString(),
      );
    } catch (_) {
      return null;
    }
  }
}
