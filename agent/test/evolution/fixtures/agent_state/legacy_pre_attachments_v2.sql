-- Legacy agent-state shape from before `user_attachments` carried an admission
-- id and before `message_id` became nullable.
--
-- The table below is the v1 shape that `_migrateUserAttachmentsV2` rebuilds:
-- `message_id` is NOT NULL, there is no `admission_id`, and a
-- `user_attachments_message_owner_insert` trigger enforces message ownership.
-- `sessions` and `messages` are kept in their old shape so the additive
-- migrations have to supply the columns the current indexes need.
--
-- No secrets, tokens, or real user data: the names, digests, and payloads below
-- are synthetic placeholders owned by this fixture.

CREATE TABLE sessions (
  session_id TEXT PRIMARY KEY,
  model TEXT NOT NULL,
  title TEXT,
  workspace_id TEXT,
  metadata TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE messages (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT NOT NULL,
  data TEXT NOT NULL,
  message_id TEXT,
  FOREIGN KEY (session_id) REFERENCES sessions (session_id) ON DELETE CASCADE
);

CREATE TABLE user_attachments (
  attachment_id TEXT PRIMARY KEY,
  media_id TEXT NOT NULL UNIQUE,
  session_id TEXT NOT NULL,
  message_id TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'staged'
    CHECK (status IN ('staged', 'attached')),
  safe_name TEXT NOT NULL,
  mime_type TEXT NOT NULL,
  byte_size INTEGER NOT NULL CHECK (byte_size >= 0),
  sha256 TEXT NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('image', 'file')),
  relative_path TEXT NOT NULL UNIQUE,
  created_at TEXT NOT NULL,
  FOREIGN KEY (session_id) REFERENCES sessions (session_id) ON DELETE CASCADE
);

CREATE TRIGGER user_attachments_message_owner_insert
BEFORE INSERT ON user_attachments
WHEN NEW.status = 'attached' AND (
  NEW.message_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM messages
    WHERE message_id = NEW.message_id AND session_id = NEW.session_id
  )
)
BEGIN
  SELECT RAISE(ABORT, 'attachment message/session ownership mismatch');
END;

INSERT INTO sessions (
  session_id, model, title, workspace_id, metadata, created_at, updated_at
)
VALUES
  (
    'legacy_session_attachments',
    'legacy-model',
    'Legacy attachments thread',
    NULL,
    NULL,
    '2026-09-10T09:00:00.000Z',
    '2026-09-10T09:00:00.000Z'
  );

INSERT INTO messages (session_id, data, message_id)
VALUES
  (
    'legacy_session_attachments',
    '{"role":"user","content":"Legacy attachment question"}',
    'legacy_message_attached'
  );

INSERT INTO user_attachments (
  attachment_id, media_id, session_id, message_id, status, safe_name,
  mime_type, byte_size, sha256, kind, relative_path, created_at
)
VALUES
  (
    'legacy_attachment_attached',
    'legacy_media_attached',
    'legacy_session_attachments',
    'legacy_message_attached',
    'attached',
    'legacy-note.txt',
    'text/plain',
    12,
    'legacy-sha256-placeholder-attached',
    'file',
    'legacy/attachments/attached/legacy-note.txt',
    '2026-09-10T09:05:00.000Z'
  ),
  (
    'legacy_attachment_staged',
    'legacy_media_staged',
    'legacy_session_attachments',
    'legacy_message_attached',
    'staged',
    'legacy-image.png',
    'image/png',
    34,
    'legacy-sha256-placeholder-staged',
    'image',
    'legacy/attachments/staged/legacy-image.png',
    '2026-09-10T09:06:00.000Z'
  );
