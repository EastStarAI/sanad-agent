-- Legacy agent-state shape from before Task 112 expanded `scheduled_tasks`.
--
-- The pre-112 table has no `kind`, recurrence, zone, `next_run_at`, `enabled`,
-- or `updated_at` columns and `run_at` is NOT NULL. An older agent on the same
-- Home still runs `INSERT (id, task, run_at, session_id, created_at)`,
-- `ON CONFLICT(id) DO UPDATE SET task, run_at, session_id`, and
-- `SELECT ... ORDER BY run_at` against this table, so the migration must stay
-- additive and keep `run_at` NOT NULL.
--
-- No secrets, tokens, or real user data: the task texts and timestamps below are
-- synthetic placeholders owned by this fixture.

CREATE TABLE sessions (
  session_id TEXT PRIMARY KEY,
  model TEXT NOT NULL,
  title TEXT,
  workspace_id TEXT,
  metadata TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE scheduled_tasks (
  id TEXT PRIMARY KEY,
  task TEXT NOT NULL,
  run_at TEXT NOT NULL,
  session_id TEXT NOT NULL,
  created_at TEXT NOT NULL
);

INSERT INTO sessions (
  session_id, model, title, workspace_id, metadata, created_at, updated_at
)
VALUES
  (
    'legacy_session_schedule',
    'legacy-model',
    'Legacy schedule thread',
    NULL,
    NULL,
    '2026-10-18T09:00:00.000Z',
    '2026-10-18T09:00:00.000Z'
  );

INSERT INTO scheduled_tasks (id, task, run_at, session_id, created_at)
VALUES
  (
    'legacy_task_once',
    'Legacy one-shot task',
    '2026-10-25T14:30:00.000Z',
    'legacy_session_schedule',
    '2026-10-18T10:00:00.000Z'
  ),
  (
    'legacy_task_recurring',
    'Legacy recurring task',
    '2026-10-30T10:00:00.000Z',
    'legacy_session_schedule',
    '2026-10-18T10:05:00.000Z'
  );
