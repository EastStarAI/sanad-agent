import 'package:sqlite3/sqlite3.dart';

/// Lineage columns for materialized conversation forks.
///
/// Existing sessions backfill as independent roots: `lineage_id = session_id`
/// and `fork_sequence = 0`. Parent deletion never cascades to children.
class SessionLineage {
  static void backfill(Database db) {
    db.execute('''
      UPDATE sessions
      SET lineage_id = session_id
      WHERE lineage_id IS NULL OR TRIM(lineage_id) = '';
    ''');
    db.execute('''
      UPDATE sessions
      SET last_user_message_at = created_at
      WHERE fork_sequence > 0
        AND (
          last_user_message_at IS NULL OR
          last_user_message_at < created_at
        );
    ''');
  }
}
