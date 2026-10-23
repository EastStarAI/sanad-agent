import 'package:sqlite3/sqlite3.dart';

import 'schema_migration_support.dart';

/// Plan 29 provider routing tables: instances, the model cache, and recent
/// model selections.
///
/// `AgentStateDatabase` calls [apply] at the pinned schema position this
/// module occupied before the SRP 138-11 split.
class ProviderSchema {
  const ProviderSchema._();

  /// Creates the provider tables, adds the Plan 30 and Task 57 columns, and
  /// normalizes dormant legacy rate limits.
  static void apply(Database db) {
    // ── Plan 29: provider_instances ───────────────────────────────────────
    db.execute('''
      CREATE TABLE IF NOT EXISTS provider_instances (
        id TEXT PRIMARY KEY,
        template_id TEXT NOT NULL,
        display_name TEXT NOT NULL,
        display_name_lower TEXT NOT NULL,
        protocol TEXT NOT NULL,
        auth_method TEXT NOT NULL,
        base_url TEXT,
        default_model TEXT,
        status TEXT NOT NULL DEFAULT 'draft',
        is_default INTEGER NOT NULL DEFAULT 0,
        config_revision INTEGER NOT NULL DEFAULT 1,
        credential_revision INTEGER NOT NULL DEFAULT 1,
        requests_per_minute INTEGER NOT NULL DEFAULT 0,
        allow_auto_failover INTEGER NOT NULL DEFAULT 1,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );
    ''');
    // Plan 30: add rate-limit + auto-failover columns to pre-existing tables.
    safeAddColumn(
      db,
      'ALTER TABLE provider_instances ADD COLUMN requests_per_minute INTEGER NOT NULL DEFAULT 0',
    );
    safeAddColumn(
      db,
      'ALTER TABLE provider_instances ADD COLUMN allow_auto_failover INTEGER NOT NULL DEFAULT 1',
    );
    // Task 57 keeps the rate-limit schema for compatibility but makes it
    // dormant. Normalize legacy configured limits on every idempotent upgrade.
    db.execute('''
      UPDATE provider_instances
      SET requests_per_minute = 0
      WHERE requests_per_minute <> 0;
    ''');
    db.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_instances_name_lower '
      'ON provider_instances(display_name_lower);',
    );
    // Enforce at most ONE default instance via a partial unique index on the
    // single row where is_default = 1. The DB rejects a second default even if
    // a writer bypasses setDefault().
    db.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_provider_single_default '
      'ON provider_instances(is_default) WHERE is_default = 1;',
    );

    // ── Plan 29: provider_model_cache ─────────────────────────────────────
    db.execute('''
      CREATE TABLE IF NOT EXISTS provider_model_cache (
        instance_id TEXT NOT NULL,
        cache_key TEXT NOT NULL,
        models_json TEXT NOT NULL,
        fetched_at TEXT NOT NULL,
        source TEXT NOT NULL DEFAULT 'live',
        endpoint_fingerprint TEXT,
        config_revision INTEGER NOT NULL,
        credential_revision INTEGER NOT NULL,
        last_error TEXT,
        PRIMARY KEY (instance_id, cache_key),
        FOREIGN KEY (instance_id) REFERENCES provider_instances (id) ON DELETE CASCADE
      );
    ''');

    // ── Plan 29: recent_model_selections ──────────────────────────────────
    db.execute('''
      CREATE TABLE IF NOT EXISTS recent_model_selections (
        instance_id TEXT NOT NULL,
        model_id TEXT NOT NULL,
        selected_at TEXT NOT NULL,
        PRIMARY KEY (instance_id, model_id),
        FOREIGN KEY (instance_id) REFERENCES provider_instances (id) ON DELETE CASCADE
      );
    ''');
  }
}
