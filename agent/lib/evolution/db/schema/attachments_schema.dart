import 'package:sqlite3/sqlite3.dart';

/// Session-owned attachment metadata, including the v2 rebuild and the
/// message-ownership trigger that guards attachment promotion.
///
/// `AgentStateDatabase` calls [apply] at the pinned schema position this
/// module occupied before the SRP 138-11 split.
class AttachmentsSchema {
  const AttachmentsSchema._();

  /// Creates and migrates `user_attachments`.
  static void apply(Database db) {
    // ── session-owned attachments ───────────────────────────────────────
    db.execute('''
      CREATE TABLE IF NOT EXISTS user_attachments (
        attachment_id TEXT PRIMARY KEY,
        media_id TEXT NOT NULL UNIQUE,
        session_id TEXT NOT NULL,
        admission_id TEXT NOT NULL,
        message_id TEXT,
        status TEXT NOT NULL DEFAULT 'staged'
          CHECK (status IN ('staged', 'attached')),
        safe_name TEXT NOT NULL,
        mime_type TEXT NOT NULL,
        byte_size INTEGER NOT NULL CHECK (byte_size >= 0),
        sha256 TEXT NOT NULL,
        kind TEXT NOT NULL CHECK (kind IN ('image', 'file')),
        relative_path TEXT NOT NULL UNIQUE,
        created_at TEXT NOT NULL,
        FOREIGN KEY (session_id) REFERENCES sessions (session_id)
          ON DELETE CASCADE
      );
    ''');
    _migrateUserAttachmentsV2(db);
    db.execute('DROP TRIGGER IF EXISTS user_attachments_message_owner_insert');
    db.execute('''
      CREATE INDEX IF NOT EXISTS idx_user_attachments_session_admission
      ON user_attachments(session_id, admission_id, status);
    ''');
    db.execute('''
      CREATE INDEX IF NOT EXISTS idx_user_attachments_session_message
      ON user_attachments(session_id, message_id);
    ''');
    db.execute('''
      CREATE TRIGGER IF NOT EXISTS user_attachments_message_owner_update
      BEFORE UPDATE OF message_id, status ON user_attachments
      WHEN NEW.status = 'attached' AND (
        NEW.message_id IS NULL OR NOT EXISTS (
          SELECT 1 FROM messages
          WHERE message_id = NEW.message_id AND session_id = NEW.session_id
        )
      )
      BEGIN
        SELECT RAISE(ABORT, 'attachment message/session ownership mismatch');
      END;
    ''');
  }

  static void _migrateUserAttachmentsV2(Database db) {
    final columns = db.select('PRAGMA table_info(user_attachments)');
    final hasAdmission = columns.any((row) => row['name'] == 'admission_id');
    final messageColumn = columns.where((row) => row['name'] == 'message_id');
    final messageIsNullable =
        messageColumn.isNotEmpty && messageColumn.single['notnull'] == 0;
    if (hasAdmission && messageIsNullable) return;

    db.execute('DROP TRIGGER IF EXISTS user_attachments_message_owner_insert');
    db.execute('ALTER TABLE user_attachments RENAME TO user_attachments_v1');
    db.execute('''
      CREATE TABLE user_attachments (
        attachment_id TEXT PRIMARY KEY,
        media_id TEXT NOT NULL UNIQUE,
        session_id TEXT NOT NULL,
        admission_id TEXT NOT NULL,
        message_id TEXT,
        status TEXT NOT NULL DEFAULT 'staged'
          CHECK (status IN ('staged', 'attached')),
        safe_name TEXT NOT NULL,
        mime_type TEXT NOT NULL,
        byte_size INTEGER NOT NULL CHECK (byte_size >= 0),
        sha256 TEXT NOT NULL,
        kind TEXT NOT NULL CHECK (kind IN ('image', 'file')),
        relative_path TEXT NOT NULL UNIQUE,
        created_at TEXT NOT NULL,
        FOREIGN KEY (session_id) REFERENCES sessions (session_id)
          ON DELETE CASCADE
      );
    ''');
    db.execute('''
      INSERT INTO user_attachments (
        attachment_id, media_id, session_id, admission_id, message_id,
        status, safe_name, mime_type, byte_size, sha256, kind,
        relative_path, created_at
      )
      SELECT attachment_id, media_id, session_id,
        'legacy:' || attachment_id, message_id, 'attached', safe_name,
        mime_type, byte_size, sha256, kind, relative_path, created_at
      FROM user_attachments_v1;
    ''');
    db.execute('DROP TABLE user_attachments_v1');
  }
}
