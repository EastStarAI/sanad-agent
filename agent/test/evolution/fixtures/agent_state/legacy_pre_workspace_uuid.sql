-- Legacy agent-state shape from before workspaces carried an immutable UUID.
--
-- `workspaces.path` is the primary key and every workspace reference
-- (`sessions.workspace_id`) stores a filesystem path. Columns that later
-- shipments added to `sessions` and `messages` are omitted on purpose so the
-- additive migrations in `AgentStateDatabase` have to supply them; tables that
-- did not exist in this era are left to the current `CREATE TABLE IF NOT EXISTS`
-- statements.
--
-- No secrets, tokens, or real user data: the paths and payloads below are
-- synthetic placeholders owned by this fixture.

CREATE TABLE workspaces (
  path TEXT PRIMARY KEY,
  display_name TEXT NOT NULL,
  source TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

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
  FOREIGN KEY (session_id) REFERENCES sessions (session_id) ON DELETE CASCADE
);

INSERT INTO workspaces (path, display_name, source, created_at, updated_at)
VALUES
  (
    '/legacy/workspaces/alpha',
    'Renamed Alpha',
    'existing',
    '2026-09-01T08:00:00.000Z',
    '2026-09-02T08:00:00.000Z'
  ),
  (
    '/legacy/workspaces/beta',
    'Beta',
    'created',
    '2026-09-03T08:00:00.000Z',
    '2026-09-04T08:00:00.000Z'
  );

-- alpha is registered; gamma is referenced only by a session; the third
-- session carries a blank path that must normalize to NULL.
INSERT INTO sessions (
  session_id, model, title, workspace_id, metadata, created_at, updated_at
)
VALUES
  (
    'legacy_session_alpha',
    'legacy-model',
    'Legacy alpha thread',
    '/legacy/workspaces/alpha',
    NULL,
    '2026-09-05T10:00:00.000Z',
    '2026-09-05T10:00:00.000Z'
  ),
  (
    'legacy_session_gamma',
    'legacy-model',
    'Legacy gamma thread',
    '/legacy/workspaces/gamma',
    NULL,
    '2026-09-06T10:00:00.000Z',
    '2026-09-06T10:00:00.000Z'
  ),
  (
    'legacy_session_unscoped',
    'legacy-model',
    'Legacy unscoped thread',
    '   ',
    NULL,
    '2026-09-07T10:00:00.000Z',
    '2026-09-07T10:00:00+02:00'
  );

INSERT INTO messages (session_id, data)
VALUES
  (
    'legacy_session_alpha',
    '{"role":"user","content":"Legacy question","metadata":{"received_at":"2026-09-05T11:30:00.000Z"}}'
  ),
  (
    'legacy_session_alpha',
    '{"role":"assistant","content":"Legacy answer"}'
  );
