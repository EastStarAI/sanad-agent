import 'package:sqlite3/sqlite3.dart';

/// `agent_maintenance_state` success timestamps and the pending-vacuum marker.
///
/// `AgentStateDatabase` calls [apply] at the pinned schema position this
/// module occupied before the SRP 138-11 split. Reads and writes belong to
/// `AgentMaintenanceStateRepository`, never to this module.
class MaintenanceSchema {
  const MaintenanceSchema._();

  /// Creates the `agent_maintenance_state` key/value table.
  static void apply(Database db) {
    // ── Task 65: agent_maintenance_state ────────────────────────────────
    db.execute('''
      CREATE TABLE IF NOT EXISTS agent_maintenance_state (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      );
    ''');
  }
}
