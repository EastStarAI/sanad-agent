import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';

import '../schema/schema_migration_support.dart';

/// Legacy workspace identity: replaces path-valued workspace references with
/// immutable UUIDs and keeps every session/runtime reference consistent.
///
/// `AgentStateDatabase` calls [apply] at the pinned migration position this
/// owner occupied before the SRP 138-11 split. The migration is additive and
/// idempotent: a database that already stores `workspaces.id` only gains rows
/// for orphaned absolute-path references.
class WorkspaceIdentityMigration {
  const WorkspaceIdentityMigration._();

  /// Migrates legacy path workspaces in one transaction, or repairs orphaned
  /// absolute-path references when the UUID schema is already present.
  static void apply(Database db) {
    final columns = db.select('PRAGMA table_info(workspaces)');
    final columnNames = columns.map((row) => row['name']?.toString()).toSet();
    if (columnNames.contains('id')) {
      _migrateOrphanedPathWorkspaceReferences(db);
      return;
    }

    final paths = <String>{};
    final legacyRows = db.select(
      'SELECT path, source, updated_at FROM workspaces',
    );
    for (final row in legacyRows) {
      final path = row['path']?.toString().trim();
      if (path != null && path.isNotEmpty) paths.add(path);
    }

    const referenceTables = [
      'sessions',
      'session_suspended_runs',
      'session_pending_runs',
      'session_work_items',
    ];
    for (final table in referenceTables) {
      if (!columnExists(db, table, 'workspace_id')) continue;
      for (final row in db.select(
        'SELECT DISTINCT workspace_id FROM $table '
        'WHERE workspace_id IS NOT NULL AND TRIM(workspace_id) != \'\'',
      )) {
        final path = row['workspace_id']?.toString().trim();
        if (path != null && path.isNotEmpty) paths.add(path);
      }
    }

    final now = DateTime.now().toUtc().toIso8601String();
    final idsByPath = <String, String>{
      for (final path in paths) path: const Uuid().v4(),
    };

    db.execute('BEGIN IMMEDIATE');
    try {
      db.execute('ALTER TABLE workspaces RENAME TO workspaces_legacy');
      db.execute('''
        CREATE TABLE workspaces (
          id TEXT PRIMARY KEY,
          display_name TEXT NOT NULL,
          path TEXT NOT NULL UNIQUE,
          source TEXT NOT NULL,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        );
      ''');

      final insert = db.prepare('''
        INSERT INTO workspaces (
          id, display_name, path, source, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?)
      ''');
      for (final entry in idsByPath.entries) {
        final legacy = legacyRows.where(
          (row) => row['path']?.toString().trim() == entry.key,
        );
        final legacyRow = legacy.isEmpty ? null : legacy.first;
        final updatedAt = legacyRow?['updated_at']?.toString() ?? now;
        insert.execute([
          entry.value,
          _workspaceDisplayName(entry.key),
          entry.key,
          legacyRow?['source']?.toString() ?? 'migrated_session',
          updatedAt,
          updatedAt,
        ]);
      }
      insert.dispose();

      for (final table in referenceTables) {
        if (!columnExists(db, table, 'workspace_id')) continue;
        final update = db.prepare(
          'UPDATE $table SET workspace_id = ? WHERE workspace_id = ?',
        );
        for (final entry in idsByPath.entries) {
          update.execute([entry.value, entry.key]);
        }
        update.dispose();
      }

      _migrateWorkspaceIdsInJsonColumn(
        db,
        table: 'session_suspended_runs',
        idColumn: 'session_id',
        jsonColumn: 'event_metadata',
        idsByPath: idsByPath,
      );
      _migrateWorkspaceIdsInJsonColumn(
        db,
        table: 'session_pending_runs',
        idColumn: 'id',
        jsonColumn: 'event_metadata',
        idsByPath: idsByPath,
      );
      _migrateWorkspaceIdsInJsonColumn(
        db,
        table: 'session_work_items',
        idColumn: 'work_item_id',
        jsonColumn: 'payload_json',
        idsByPath: idsByPath,
      );

      db.execute('DROP TABLE workspaces_legacy');
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  static void _migrateOrphanedPathWorkspaceReferences(Database db) {
    final knownIds = db
        .select('SELECT id FROM workspaces')
        .map((row) => row['id']?.toString())
        .whereType<String>()
        .toSet();
    const referenceTables = [
      'sessions',
      'session_suspended_runs',
      'session_pending_runs',
      'session_work_items',
    ];
    final paths = <String>{};
    for (final table in referenceTables) {
      if (!columnExists(db, table, 'workspace_id')) continue;
      for (final row in db.select(
        'SELECT DISTINCT workspace_id FROM $table '
        'WHERE workspace_id IS NOT NULL AND TRIM(workspace_id) != \'\'',
      )) {
        final value = row['workspace_id']?.toString().trim();
        if (value != null &&
            value.isNotEmpty &&
            !knownIds.contains(value) &&
            p.isAbsolute(value)) {
          paths.add(value);
        }
      }
    }
    if (paths.isEmpty) return;

    final now = DateTime.now().toUtc().toIso8601String();
    final idsByPath = <String, String>{
      for (final path in paths) path: const Uuid().v4(),
    };
    db.execute('BEGIN IMMEDIATE');
    try {
      final insert = db.prepare('''
        INSERT INTO workspaces (
          id, display_name, path, source, created_at, updated_at
        ) VALUES (?, ?, ?, 'migrated_session', ?, ?)
        ON CONFLICT(path) DO NOTHING
      ''');
      try {
        for (final path in idsByPath.keys.toList(growable: false)) {
          insert.execute([
            idsByPath[path],
            _workspaceDisplayName(path),
            path,
            now,
            now,
          ]);
          final stored = db.select(
            'SELECT id FROM workspaces WHERE path = ? LIMIT 1',
            [path],
          );
          if (stored.isNotEmpty) {
            idsByPath[path] = stored.first['id'] as String;
          }
        }
      } finally {
        insert.dispose();
      }

      for (final table in referenceTables) {
        if (!columnExists(db, table, 'workspace_id')) continue;
        final update = db.prepare(
          'UPDATE $table SET workspace_id = ? WHERE workspace_id = ?',
        );
        try {
          for (final entry in idsByPath.entries) {
            update.execute([entry.value, entry.key]);
          }
        } finally {
          update.dispose();
        }
      }
      _migrateWorkspaceIdsInJsonColumn(
        db,
        table: 'session_suspended_runs',
        idColumn: 'session_id',
        jsonColumn: 'event_metadata',
        idsByPath: idsByPath,
      );
      _migrateWorkspaceIdsInJsonColumn(
        db,
        table: 'session_pending_runs',
        idColumn: 'id',
        jsonColumn: 'event_metadata',
        idsByPath: idsByPath,
      );
      _migrateWorkspaceIdsInJsonColumn(
        db,
        table: 'session_work_items',
        idColumn: 'work_item_id',
        jsonColumn: 'payload_json',
        idsByPath: idsByPath,
      );
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  static void _migrateWorkspaceIdsInJsonColumn(
    Database db, {
    required String table,
    required String idColumn,
    required String jsonColumn,
    required Map<String, String> idsByPath,
  }) {
    if (!columnExists(db, table, idColumn) ||
        !columnExists(db, table, jsonColumn)) {
      return;
    }
    final rows = db.select('SELECT $idColumn, $jsonColumn FROM $table');
    final update = db.prepare(
      'UPDATE $table SET $jsonColumn = ? WHERE $idColumn = ?',
    );
    try {
      for (final row in rows) {
        final raw = row[jsonColumn]?.toString();
        if (raw == null || raw.isEmpty) continue;
        try {
          final decoded = jsonDecode(raw);
          final migrated = _replaceWorkspaceIds(decoded, idsByPath);
          final encoded = jsonEncode(migrated);
          if (encoded != raw) update.execute([encoded, row[idColumn]]);
        } on SqliteException catch (error) {
          if (isBusyOrLocked(error)) rethrow;
        } catch (_) {
          // Preserve malformed legacy payloads; top-level workspace columns are
          // still migrated and remain authoritative for recovery.
        }
      }
    } finally {
      update.dispose();
    }
  }

  static dynamic _replaceWorkspaceIds(
    dynamic value,
    Map<String, String> idsByPath, {
    String? key,
  }) {
    if (value is Map) {
      final migrated = value.map(
        (entryKey, entryValue) => MapEntry(
          entryKey,
          _replaceWorkspaceIds(entryValue, idsByPath, key: entryKey.toString()),
        ),
      );
      if (key == 'workspace' && migrated['id'] is String) {
        final legacyId = migrated['id'] as String;
        migrated['id'] = idsByPath[legacyId] ?? legacyId;
      }
      return migrated;
    }
    if (value is List) {
      return value
          .map((item) => _replaceWorkspaceIds(item, idsByPath))
          .toList();
    }
    if (key == 'workspace_id' && value is String) {
      return idsByPath[value] ?? value;
    }
    return value;
  }

  static String _workspaceDisplayName(String path) {
    final normalized = path.replaceAll(RegExp(r'[\\/]+$'), '');
    final name = p.basename(normalized).trim();
    return name.isEmpty ? path : name;
  }
}
