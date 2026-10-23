import 'package:sqlite3/sqlite3.dart';

import 'schema_migration_support.dart';

/// Plan 53b compaction lifecycle: the revision columns compaction claims
/// against and the `session_compaction_operations` table.
///
/// `AgentStateDatabase` calls [apply] at the pinned schema position this
/// module occupied before the SRP 138-11 split. Rows belong to
/// `CompactionBoundaryRepository`.
class CompactionSchema {
  const CompactionSchema._();

  /// Adds the session projection revisions and creates the compaction
  /// operations table with its additive diagnostic columns and indexes.
  static void apply(Database db) {
    safeAddColumn(
      db,
      'ALTER TABLE sessions ADD COLUMN history_revision INTEGER NOT NULL DEFAULT 0 CHECK (history_revision >= 0)',
    );
    safeAddColumn(
      db,
      'ALTER TABLE sessions ADD COLUMN projection_revision INTEGER NOT NULL DEFAULT 0 CHECK (projection_revision >= 0)',
    );

    db.execute('''
      CREATE TABLE IF NOT EXISTS session_compaction_operations (
        compaction_id TEXT PRIMARY KEY,
        session_id TEXT NOT NULL,
        trigger TEXT NOT NULL CHECK (trigger IN ('manual', 'auto', 'overflow')),
        status TEXT NOT NULL CHECK (status IN ('started', 'completed', 'failed')),
        source_history_revision INTEGER NOT NULL CHECK (source_history_revision >= 0),
        source_start_message_id INTEGER NOT NULL,
        source_end_message_id INTEGER NOT NULL,
        tail_start_message_id INTEGER NOT NULL,
        tail_end_message_id INTEGER NOT NULL,
        tail_end_anchor_fingerprint TEXT,
        tail_end_anchor_ordinal INTEGER CHECK (tail_end_anchor_ordinal > 0),
        provider_instance_id TEXT NOT NULL,
        model_id TEXT NOT NULL,
        template_id TEXT NOT NULL,
        protocol TEXT NOT NULL,
        normalized_base_url TEXT NOT NULL,
        config_revision INTEGER NOT NULL,
        credential_revision INTEGER NOT NULL,
        api_mode TEXT,
        context_window_tokens INTEGER,
        effective_input_budget_tokens INTEGER,
        auto_threshold_tokens INTEGER,
        estimated_request_tokens_before INTEGER,
        estimated_request_tokens_after INTEGER,
        before_measurement_kind TEXT NOT NULL DEFAULT 'estimated'
          CHECK (before_measurement_kind IN ('estimated', 'confirmed', 'mixed')),
        provider_confirmed_request_tokens_after INTEGER
          CHECK (provider_confirmed_request_tokens_after >= 0),
        retained_tail_tokens INTEGER,
        duration_ms INTEGER,
        summarization_input_tokens INTEGER,
        summarization_cached_input_tokens INTEGER,
        summarization_cache_write_tokens INTEGER,
        summarization_output_tokens INTEGER,
        summarization_reasoning_tokens INTEGER,
        summarization_attempts INTEGER NOT NULL DEFAULT 0,
        internal_summary_json TEXT,
        failure_reason TEXT,
        failure_detail_json TEXT,
        diagnostics_json TEXT,
        started_at TEXT NOT NULL,
        completed_at TEXT,
        FOREIGN KEY (session_id) REFERENCES sessions (session_id) ON DELETE CASCADE,
        CHECK (source_end_message_id < tail_start_message_id)
      );
    ''');

    safeAddColumn(
      db,
      "ALTER TABLE session_compaction_operations ADD COLUMN before_measurement_kind TEXT NOT NULL DEFAULT 'estimated' CHECK (before_measurement_kind IN ('estimated', 'confirmed', 'mixed'))",
    );
    safeAddColumn(
      db,
      'ALTER TABLE session_compaction_operations ADD COLUMN effective_input_budget_tokens INTEGER CHECK (effective_input_budget_tokens > 0)',
    );
    safeAddColumn(
      db,
      'ALTER TABLE session_compaction_operations ADD COLUMN auto_threshold_tokens INTEGER CHECK (auto_threshold_tokens > 0)',
    );
    safeAddColumn(
      db,
      'ALTER TABLE session_compaction_operations ADD COLUMN provider_confirmed_request_tokens_after INTEGER CHECK (provider_confirmed_request_tokens_after >= 0)',
    );
    safeAddColumn(
      db,
      'ALTER TABLE session_compaction_operations ADD COLUMN tail_end_anchor_fingerprint TEXT',
    );
    safeAddColumn(
      db,
      'ALTER TABLE session_compaction_operations ADD COLUMN tail_end_anchor_ordinal INTEGER CHECK (tail_end_anchor_ordinal > 0)',
    );
    for (final column in const [
      'summarization_input_tokens',
      'summarization_cached_input_tokens',
      'summarization_cache_write_tokens',
      'summarization_output_tokens',
      'summarization_reasoning_tokens',
    ]) {
      safeAddColumn(
        db,
        'ALTER TABLE session_compaction_operations ADD COLUMN $column INTEGER CHECK ($column >= 0)',
      );
    }
    safeAddColumn(
      db,
      'ALTER TABLE session_compaction_operations ADD COLUMN summarization_attempts INTEGER NOT NULL DEFAULT 0 CHECK (summarization_attempts >= 0)',
    );
    safeAddColumn(
      db,
      'ALTER TABLE session_compaction_operations ADD COLUMN diagnostics_json TEXT',
    );
    // Task 120: catalog-resolved per-model api mode of the route signature.
    safeAddColumn(
      db,
      'ALTER TABLE session_compaction_operations ADD COLUMN api_mode TEXT',
    );
    db.execute('''
      CREATE UNIQUE INDEX IF NOT EXISTS idx_session_compaction_one_started
      ON session_compaction_operations(session_id)
      WHERE status = 'started';
    ''');

    db.execute('''
      CREATE INDEX IF NOT EXISTS idx_session_compaction_completed
      ON session_compaction_operations(session_id, completed_at DESC)
      WHERE status = 'completed';
    ''');
  }
}
