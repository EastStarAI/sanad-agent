import 'package:sqlite3/sqlite3.dart';

/// `user_secret_metadata`: the non-secret metadata of a stored user secret
/// (Task 140 A1).
///
/// A user secret value lives only in the Agent vault's `custom:` namespace.
/// This table holds the three fields the Settings → Privacy & Security page
/// displays beside a name, and nothing about the value: no value, no hash of
/// one, and no prefix of one ever enters a column here. `name` is the vault
/// name and the only identity.
///
/// `AgentStateDatabase` calls [apply] from `_createSchemaAndMigrate` after
/// every pre-existing domain module, so an existing Home gains one empty
/// table on its next open and no existing table, row, or migration changes.
/// Reads and writes belong to `UserSecretMetadataRepository`; the catalog and
/// the acquisition path reach the table only through it.
class UserSecretsSchema {
  const UserSecretsSchema._();

  /// Creates `user_secret_metadata` when it is absent.
  ///
  /// Purely additive and idempotent: there is no earlier shape to migrate, so
  /// a second open re-runs this statement as a no-op and an older agent on the
  /// same Home keeps working because it never reads the table.
  static void apply(Database db) {
    // `name` is declared NOT NULL explicitly: SQLite allows a NULL in a
    // non-INTEGER primary key, and a row whose identity is NULL describes no
    // secret. `source` has no DB default, so every writer states how the
    // current value arrived (`agent_request` through the Task 84 card, `user`
    // through the Settings screen) and a row can never claim an unknown origin.
    db.execute('''
      CREATE TABLE IF NOT EXISTS user_secret_metadata (
        name TEXT PRIMARY KEY NOT NULL,
        description TEXT,
        source TEXT NOT NULL CHECK (source IN ('agent_request', 'user')),
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );
    ''');
  }
}
