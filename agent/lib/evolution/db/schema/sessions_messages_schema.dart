import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import '../session_lineage.dart';
import 'schema_migration_support.dart';

/// Session and message tables, their additive columns, and the ordering
/// indexes history pagination depends on.
///
/// `AgentStateDatabase` calls [apply] at the pinned schema position this
/// module occupied before the SRP 138-11 split; [migrateLastUserMessageAt] is
/// also exposed because the same backfill runs a second time, after workspace
/// identity migration, and that position is not adjacent to this module.
class SessionsMessagesSchema {
  const SessionsMessagesSchema._();

  /// Creates and migrates `sessions` and `messages`.
  static void apply(Database db) {
    // ── sessions ──────────────────────────────────────────────────────────
    db.execute('''
      CREATE TABLE IF NOT EXISTS sessions (
        session_id TEXT PRIMARY KEY,
        model TEXT NOT NULL,
        title TEXT,
        title_status TEXT NOT NULL DEFAULT 'final'
          CHECK (title_status IN ('pending', 'final')),
        workspace_id TEXT,
        metadata TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        last_user_message_at TEXT
      );
    ''');
    // Backward-compatible migrations.
    safeAddColumn(db, 'ALTER TABLE sessions ADD COLUMN workspace_id TEXT');
    safeAddColumn(db, 'ALTER TABLE sessions ADD COLUMN metadata TEXT');
    safeAddColumn(
      db,
      "ALTER TABLE sessions ADD COLUMN title_status TEXT NOT NULL DEFAULT 'final' CHECK (title_status IN ('pending', 'final'))",
    );
    safeAddColumn(db, 'ALTER TABLE sessions ADD COLUMN provider_id TEXT');
    safeAddColumn(db, 'ALTER TABLE sessions ADD COLUMN thinking_mode TEXT');
    safeAddColumn(
      db,
      'ALTER TABLE sessions ADD COLUMN last_user_message_at TEXT',
    );
    safeAddColumn(
      db,
      'ALTER TABLE sessions ADD COLUMN route_revision INTEGER NOT NULL DEFAULT 1 CHECK (route_revision > 0)',
    );
    safeAddColumn(db, 'ALTER TABLE sessions ADD COLUMN route_updated_at TEXT');
    safeAddColumn(
      db,
      'ALTER TABLE sessions ADD COLUMN history_revision INTEGER NOT NULL DEFAULT 0',
    );
    safeAddColumn(db, 'ALTER TABLE sessions ADD COLUMN lineage_id TEXT');
    safeAddColumn(
      db,
      'ALTER TABLE sessions ADD COLUMN parent_session_id TEXT',
    );
    safeAddColumn(
      db,
      'ALTER TABLE sessions ADD COLUMN forked_from_message_id TEXT',
    );
    safeAddColumn(
      db,
      'ALTER TABLE sessions ADD COLUMN forked_from_turn_id TEXT',
    );
    safeAddColumn(
      db,
      'ALTER TABLE sessions ADD COLUMN fork_sequence INTEGER NOT NULL DEFAULT 0',
    );
    safeAddColumn(
      db,
      'ALTER TABLE sessions ADD COLUMN lineage_base_title TEXT',
    );
    safeAddColumn(db, 'ALTER TABLE sessions ADD COLUMN fork_request_id TEXT');
    SessionLineage.backfill(db);
    db.execute('''
      UPDATE sessions
      SET route_updated_at = updated_at
      WHERE route_updated_at IS NULL OR TRIM(route_updated_at) = '';
    ''');

    // ── messages ──────────────────────────────────────────────────────────
    db.execute('''
      CREATE TABLE IF NOT EXISTS messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id TEXT NOT NULL,
        data TEXT NOT NULL,
        message_id TEXT,
        turn_id TEXT,
        history_status TEXT NOT NULL DEFAULT 'active'
          CHECK (history_status IN ('active', 'superseded')),
        superseded_by_turn_id TEXT,
        input_kind TEXT
          CHECK (input_kind IS NULL OR input_kind IN ('root_turn', 'steer')),
        request_id TEXT,
        run_id TEXT,
        FOREIGN KEY (session_id) REFERENCES sessions (session_id) ON DELETE CASCADE
      );
    ''');
    safeAddColumn(db, 'ALTER TABLE messages ADD COLUMN message_id TEXT');
    safeAddColumn(db, 'ALTER TABLE messages ADD COLUMN turn_id TEXT');
    safeAddColumn(
      db,
      "ALTER TABLE messages ADD COLUMN history_status TEXT NOT NULL DEFAULT 'active'",
    );
    safeAddColumn(
      db,
      'ALTER TABLE messages ADD COLUMN superseded_by_turn_id TEXT',
    );
    safeAddColumn(db, 'ALTER TABLE messages ADD COLUMN input_kind TEXT');
    safeAddColumn(db, 'ALTER TABLE messages ADD COLUMN request_id TEXT');
    safeAddColumn(db, 'ALTER TABLE messages ADD COLUMN run_id TEXT');
    safeAddColumn(
      db,
      'ALTER TABLE messages ADD COLUMN origin_message_id TEXT',
    );
    migrateLastUserMessageAt(db);
    db.execute('''
      CREATE UNIQUE INDEX IF NOT EXISTS idx_messages_message_id
      ON messages(message_id);
    ''');
    db.execute('''
      CREATE UNIQUE INDEX IF NOT EXISTS idx_sessions_lineage_sequence
      ON sessions(lineage_id, fork_sequence);
    ''');
    db.execute('''
      CREATE UNIQUE INDEX IF NOT EXISTS idx_sessions_fork_request_id
      ON sessions(fork_request_id)
      WHERE fork_request_id IS NOT NULL;
    ''');
    db.execute('''
      CREATE INDEX IF NOT EXISTS idx_sessions_parent
      ON sessions(parent_session_id);
    ''');
    db.execute('''
      CREATE INDEX IF NOT EXISTS idx_messages_origin
      ON messages(origin_message_id);
    ''');
    db.execute('''
      CREATE INDEX IF NOT EXISTS idx_messages_session_active_id
      ON messages(session_id, history_status, id);
    ''');
    db.execute('''
      CREATE INDEX IF NOT EXISTS idx_messages_session_turn
      ON messages(session_id, turn_id, id);
    ''');
    db.execute('''
      CREATE INDEX IF NOT EXISTS idx_messages_session_id
      ON messages(session_id, id DESC);
    ''');
    db.execute('''
      CREATE INDEX IF NOT EXISTS idx_sessions_ordering
      ON sessions(last_user_message_at DESC, session_id DESC);
    ''');
    db.execute('''
      CREATE INDEX IF NOT EXISTS idx_sessions_workspace_ordering
      ON sessions(workspace_id, last_user_message_at DESC, session_id DESC);
    ''');
  }

  /// Backfills `sessions.last_user_message_at` and normalizes the legacy
  /// workspace reference stored in the same row.
  ///
  /// Runs inside [apply] and again after workspace identity migration, so the
  /// ordering timestamp and the workspace id are always derived from the same
  /// durable session columns.
  static void migrateLastUserMessageAt(Database db) {
    final sessionsResult = db.select(
      'SELECT session_id, created_at, updated_at, last_user_message_at, workspace_id FROM sessions',
    );
    if (sessionsResult.isEmpty) {
      return;
    }

    final sessionFallbacks = <String, String>{};
    final pendingMigrationSessionIds = <String>[];
    final resolvedFromSession = <String, String?>{};
    final originalLastUserMessageAt = <String, String?>{};
    final originalWorkspaceIds = <String, String?>{};
    for (final sessionRow in sessionsResult) {
      final sessionId = sessionRow['session_id'] as String;
      final createdAt = sessionRow['created_at'] as String;
      final updatedAt = sessionRow['updated_at'] as String;
      final rawLastUserMessageAt =
          sessionRow['last_user_message_at'] as String?;
      final rawWorkspaceId = sessionRow['workspace_id'] as String?;
      sessionFallbacks[sessionId] =
          _normalizeTimestampString(updatedAt) ??
          _normalizeTimestampString(createdAt) ??
          createdAt;
      final normalizedExisting = _normalizeTimestampString(
        rawLastUserMessageAt,
      );
      originalLastUserMessageAt[sessionId] = rawLastUserMessageAt;
      originalWorkspaceIds[sessionId] = rawWorkspaceId;
      if (normalizedExisting == null) {
        pendingMigrationSessionIds.add(sessionId);
      }
      resolvedFromSession[sessionId] = normalizedExisting;
    }

    final resolvedFromMessages = <String, String>{};
    for (
      var start = 0;
      start < pendingMigrationSessionIds.length;
      start += 200
    ) {
      final batch = pendingMigrationSessionIds.skip(start).take(200).toList();
      if (batch.isEmpty) {
        continue;
      }
      final placeholders = List.filled(batch.length, '?').join(', ');
      final messagesResult = db.select(
        'SELECT session_id, data FROM messages '
        'WHERE session_id IN ($placeholders) '
        'ORDER BY session_id ASC, id DESC',
        batch,
      );

      for (final msgRow in messagesResult) {
        final sessionId = msgRow['session_id'] as String;
        if (resolvedFromMessages.containsKey(sessionId)) {
          continue;
        }
        final dataStr = msgRow['data'] as String?;
        if (dataStr == null) {
          continue;
        }
        try {
          final data = jsonDecode(dataStr);
          if (data is! Map || data['role'] != 'user') {
            continue;
          }
          final metadata = data['metadata'];
          final normalized =
              _normalizeTimestampString(
                metadata is Map
                    ? metadata['received_at']?.toString() ??
                          metadata['timestamp']?.toString()
                    : null,
              ) ??
              _normalizeTimestampString(data['timestamp']?.toString());
          if (normalized != null) {
            resolvedFromMessages[sessionId] = normalized;
          }
        } catch (_) {
          // Ignore a malformed legacy message row and continue migration.
        }
      }
    }

    final stmt = db.prepare(
      'UPDATE sessions '
      'SET last_user_message_at = ?, workspace_id = ? '
      'WHERE session_id = ?',
    );
    try {
      for (final entry in sessionFallbacks.entries) {
        final sessionId = entry.key;
        final resolvedTimestamp =
            resolvedFromSession[sessionId] ??
            resolvedFromMessages[sessionId] ??
            entry.value;
        final rawWorkspaceId = originalWorkspaceIds[sessionId];
        final normalizedWorkspaceId = (() {
          final trimmed = rawWorkspaceId?.trim();
          if (trimmed == null || trimmed.isEmpty) {
            return null;
          }
          return trimmed;
        })();
        final rawLastUserMessageAt = originalLastUserMessageAt[sessionId];
        final shouldUpdateTimestamp = rawLastUserMessageAt != resolvedTimestamp;
        final shouldUpdateWorkspace = rawWorkspaceId != normalizedWorkspaceId;
        if (!shouldUpdateTimestamp && !shouldUpdateWorkspace) {
          continue;
        }
        stmt.execute([resolvedTimestamp, normalizedWorkspaceId, sessionId]);
      }
    } finally {
      stmt.dispose();
    }
  }

  static String? _normalizeTimestampString(String? value) {
    if (value == null) {
      return null;
    }
    final parsed = DateTime.tryParse(value);
    if (parsed == null) {
      return null;
    }
    return parsed.toUtc().toIso8601String();
  }
}
