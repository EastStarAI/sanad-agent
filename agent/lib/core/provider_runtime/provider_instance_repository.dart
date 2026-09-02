import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../evolution/db/agent_state_database.dart';
import 'provider_instance.dart';

/// Persistent storage for provider instances, their model cache, and recent
/// model selections (Plan 29 §7.3).
///
/// Shares the single [`AgentStateDatabase`](../../evolution/db/agent_state_database.dart)
/// connection with `SessionDB`, so all Plan 29 tables live in `state.db` and
/// the runtime never opens a second SQLite file. The schema (including the
/// partial unique index enforcing at most one default instance) is created by
/// `AgentStateDatabase`.
///
/// Secrets never live here — they are stored in the `SecretStore`
/// (`provider_secrets.json`) keyed by instance UUID. This repository holds only
/// metadata, revisions, cached model lists, and recent selections.
class ProviderInstanceRepository {
  final Database _db;

  /// Uses a shared [AgentStateDatabase] connection (production path).
  ProviderInstanceRepository(AgentStateDatabase state) : _db = state.db;

  /// Opens an in-memory database for tests and ephemeral runtimes.
  @visibleForTesting
  ProviderInstanceRepository.inMemory()
    : _db = AgentStateDatabase.inMemory().db;

  /// Wraps an existing connection without taking ownership (used by tests that
  /// share one [AgentStateDatabase] across repositories).
  @visibleForTesting
  ProviderInstanceRepository.fromDatabase(this._db);

  // ── Instance CRUD ───────────────────────────────────────────────────────

  void createInstance(ProviderInstance instance) {
    final stmt = _db.prepare('''
      INSERT INTO provider_instances (
        id, template_id, display_name, display_name_lower, protocol,
        auth_method, base_url, default_model, status, is_default,
        config_revision, credential_revision, requests_per_minute,
        allow_auto_failover, created_at, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ''');
    try {
      stmt.execute([
        instance.id,
        instance.templateId,
        instance.displayName,
        instance.displayName.toLowerCase(),
        instance.protocol,
        instance.authMethod,
        instance.baseUrl,
        instance.defaultModel,
        instance.status,
        instance.isDefault ? 1 : 0,
        instance.configRevision,
        instance.credentialRevision,
        instance.requestsPerMinute,
        instance.allowAutoFailover ? 1 : 0,
        instance.createdAt.toIso8601String(),
        instance.updatedAt.toIso8601String(),
      ]);
    } finally {
      stmt.dispose();
    }
  }

  ProviderInstance? findById(String id) {
    final rows = _db.select('SELECT * FROM provider_instances WHERE id = ?', [
      id,
    ]);
    if (rows.isEmpty) return null;
    return _rowToInstance(rows.first);
  }

  List<ProviderInstance> findAll() {
    final rows = _db.select(
      'SELECT * FROM provider_instances ORDER BY created_at DESC',
    );
    return rows.map(_rowToInstance).toList(growable: false);
  }

  List<ProviderInstance> findByTemplate(String templateId) {
    final rows = _db.select(
      'SELECT * FROM provider_instances WHERE template_id = ? ORDER BY created_at DESC',
      [templateId],
    );
    return rows.map(_rowToInstance).toList(growable: false);
  }

  ProviderInstance? findDefault() {
    final rows = _db.select(
      'SELECT * FROM provider_instances WHERE is_default = 1 LIMIT 1',
    );
    if (rows.isEmpty) return null;
    return _rowToInstance(rows.first);
  }

  /// Whether [displayName] is taken (case-insensitive) by any instance other
  /// than [excludeId].
  bool isDisplayNameTaken(String displayName, {String? excludeId}) {
    final lower = displayName.toLowerCase();
    if (excludeId == null) {
      final rows = _db.select(
        'SELECT 1 FROM provider_instances WHERE display_name_lower = ? LIMIT 1',
        [lower],
      );
      return rows.isNotEmpty;
    }
    final rows = _db.select(
      'SELECT 1 FROM provider_instances WHERE display_name_lower = ? AND id != ? LIMIT 1',
      [lower, excludeId],
    );
    return rows.isNotEmpty;
  }

  /// Replaces all mutable metadata fields. Does not change the id, templateId,
  /// or created_at. Bumps `updated_at` to [now] (defaults to current time).
  void update(ProviderInstance instance, {DateTime? now}) {
    final ts = (now ?? DateTime.now()).toIso8601String();
    final stmt = _db.prepare('''
      UPDATE provider_instances SET
        display_name = ?,
        display_name_lower = ?,
        protocol = ?,
        auth_method = ?,
        base_url = ?,
        default_model = ?,
        status = ?,
        is_default = ?,
        config_revision = ?,
        credential_revision = ?,
        requests_per_minute = ?,
        allow_auto_failover = ?,
        updated_at = ?
      WHERE id = ?
    ''');
    try {
      stmt.execute([
        instance.displayName,
        instance.displayName.toLowerCase(),
        instance.protocol,
        instance.authMethod,
        instance.baseUrl,
        instance.defaultModel,
        instance.status,
        instance.isDefault ? 1 : 0,
        instance.configRevision,
        instance.credentialRevision,
        instance.requestsPerMinute,
        instance.allowAutoFailover ? 1 : 0,
        ts,
        instance.id,
      ]);
    } finally {
      stmt.dispose();
    }
  }

  /// Sets [id] as the single default instance. Clears any prior default inside
  /// the same transaction. The partial unique index
  /// `idx_provider_single_default` enforces the single-default invariant at the
  /// DB level even if a writer bypasses this method.
  /// Throws [StateError] if [id] does not exist.
  void setDefault(String id) {
    _db.execute('BEGIN TRANSACTION');
    try {
      final exists = _db.select(
        'SELECT 1 FROM provider_instances WHERE id = ? LIMIT 1',
        [id],
      ).isNotEmpty;
      if (!exists) {
        throw StateError('Provider instance not found: $id');
      }
      _db.execute('UPDATE provider_instances SET is_default = 0');
      _db.execute(
        'UPDATE provider_instances SET is_default = 1, updated_at = ? WHERE id = ?',
        [DateTime.now().toIso8601String(), id],
      );
      _db.execute('COMMIT');
    } catch (e) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Clears the default flag for every instance (used when the default is
  /// removed without a replacement).
  void clearDefault() {
    _db.execute(
      'UPDATE provider_instances SET is_default = 0, updated_at = ?',
      [DateTime.now().toIso8601String()],
    );
  }

  void delete(String id) {
    _db.execute('DELETE FROM provider_instances WHERE id = ?', [id]);
    // Cache + recent rows cascade via ON DELETE CASCADE.
  }

  // ── Model cache (written by ProviderModelCacheService, Stage E) ──────────

  /// Returns the cached model list row for an instance + cache key, or null.
  Map<String, dynamic>? readModelCache(String instanceId, String cacheKey) {
    final rows = _db.select(
      'SELECT * FROM provider_model_cache WHERE instance_id = ? AND cache_key = ?',
      [instanceId, cacheKey],
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    return {
      'instance_id': row['instance_id'],
      'cache_key': row['cache_key'],
      'models': jsonDecode(row['models_json'] as String),
      'fetched_at': row['fetched_at'],
      'source': row['source'],
      'endpoint_fingerprint': row['endpoint_fingerprint'],
      'config_revision': row['config_revision'],
      'credential_revision': row['credential_revision'],
      'last_error': row['last_error'],
    };
  }

  void upsertModelCache({
    required String instanceId,
    required String cacheKey,
    required List<dynamic> models,
    required DateTime fetchedAt,
    required String source,
    String? endpointFingerprint,
    required int configRevision,
    required int credentialRevision,
    String? lastError,
  }) {
    final stmt = _db.prepare('''
      INSERT INTO provider_model_cache (
        instance_id, cache_key, models_json, fetched_at, source,
        endpoint_fingerprint, config_revision, credential_revision, last_error
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(instance_id, cache_key) DO UPDATE SET
        models_json = excluded.models_json,
        fetched_at = excluded.fetched_at,
        source = excluded.source,
        endpoint_fingerprint = excluded.endpoint_fingerprint,
        config_revision = excluded.config_revision,
        credential_revision = excluded.credential_revision,
        last_error = excluded.last_error
    ''');
    try {
      stmt.execute([
        instanceId,
        cacheKey,
        jsonEncode(models),
        fetchedAt.toIso8601String(),
        source,
        endpointFingerprint,
        configRevision,
        credentialRevision,
        lastError,
      ]);
    } finally {
      stmt.dispose();
    }
  }

  void deleteModelCache(String instanceId) {
    _db.execute('DELETE FROM provider_model_cache WHERE instance_id = ?', [
      instanceId,
    ]);
  }

  // ── Recent model selections (written by Stage E service) ────────────────

  /// Records (or bumps) a selection. Upserts so re-selecting the same pair
  /// moves it to the top via [selectedAt].
  void recordRecentSelection({
    required String instanceId,
    required String modelId,
    DateTime? selectedAt,
  }) {
    final ts = (selectedAt ?? DateTime.now()).toIso8601String();
    final stmt = _db.prepare('''
      INSERT INTO recent_model_selections (instance_id, model_id, selected_at)
      VALUES (?, ?, ?)
      ON CONFLICT(instance_id, model_id) DO UPDATE SET
        selected_at = excluded.selected_at
    ''');
    try {
      stmt.execute([instanceId, modelId, ts]);
    } finally {
      stmt.dispose();
    }
  }

  /// Returns up to [limit] recent selections joined with the instance's
  /// current display name so renames are reflected immediately (Plan 29 §7.3).
  List<Map<String, dynamic>> recentSelections({int limit = 100}) {
    final rows = _db.select(
      '''
      SELECT r.instance_id, r.model_id, r.selected_at, i.display_name
      FROM recent_model_selections r
      INNER JOIN provider_instances i ON i.id = r.instance_id
      ORDER BY r.selected_at DESC
      LIMIT ?
    ''',
      [limit],
    );
    return rows
        .map(
          (row) => {
            'instance_id': row['instance_id'],
            'model_id': row['model_id'],
            'selected_at': row['selected_at'],
            'instance_display_name': row['display_name'],
          },
        )
        .toList(growable: false);
  }

  void deleteRecentSelections(String instanceId) {
    _db.execute('DELETE FROM recent_model_selections WHERE instance_id = ?', [
      instanceId,
    ]);
  }

  // ── Helpers ─────────────────────────────────────────────────────────────

  static ProviderInstance _rowToInstance(Map<String, dynamic> row) {
    return ProviderInstance(
      id: row['id'] as String,
      templateId: row['template_id'] as String,
      displayName: row['display_name'] as String,
      protocol: row['protocol'] as String,
      authMethod: row['auth_method'] as String,
      baseUrl: row['base_url'] as String?,
      defaultModel: row['default_model'] as String?,
      status: row['status'] as String,
      isDefault: (row['is_default'] as int) == 1,
      configRevision: row['config_revision'] as int,
      credentialRevision: row['credential_revision'] as int,
      requestsPerMinute: (row['requests_per_minute'] as int?) ?? 0,
      allowAutoFailover: ((row['allow_auto_failover'] as int?) ?? 1) == 1,
      createdAt: DateTime.parse(row['created_at'] as String),
      updatedAt: DateTime.parse(row['updated_at'] as String),
    );
  }
}
