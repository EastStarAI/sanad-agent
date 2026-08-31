import 'agent_state_database.dart';

/// Sole SQL owner of `agent_maintenance_state`.
///
/// Stores success timestamps only. A missing, malformed, or future value is
/// treated as due so a bad stamp cannot block maintenance indefinitely.
class AgentMaintenanceStateRepository {
  static const lastTerminalPruneSucceededAtKey =
      'last_terminal_prune_succeeded_at';
  static const lastVacuumSucceededAtKey = 'last_vacuum_succeeded_at';

  static const Set<String> knownKeys = {
    lastTerminalPruneSucceededAtKey,
    lastVacuumSucceededAtKey,
  };

  final AgentStateDatabase _state;

  AgentMaintenanceStateRepository(this._state);

  MaintenanceTimestamp readTerminalPruneSucceededAt(DateTime nowUtc) {
    return readSucceededAt(lastTerminalPruneSucceededAtKey, nowUtc);
  }

  MaintenanceTimestamp readVacuumSucceededAt(DateTime nowUtc) {
    return readSucceededAt(lastVacuumSucceededAtKey, nowUtc);
  }

  MaintenanceTimestamp readSucceededAt(String key, DateTime nowUtc) {
    _assertKnownKey(key);
    final rows = _state.db.select(
      'SELECT value FROM agent_maintenance_state WHERE key = ?',
      [key],
    );
    final raw = rows.isEmpty ? null : rows.first['value'] as String?;
    return parseSuccessTimestamp(raw, nowUtc);
  }

  void writeTerminalPruneSucceededAt(
    DateTime succeededAt, {
    AgentStateTransaction? transaction,
  }) {
    writeSucceededAt(
      lastTerminalPruneSucceededAtKey,
      succeededAt,
      transaction: transaction,
    );
  }

  void writeVacuumSucceededAt(
    DateTime succeededAt, {
    AgentStateTransaction? transaction,
  }) {
    writeSucceededAt(
      lastVacuumSucceededAtKey,
      succeededAt,
      transaction: transaction,
    );
  }

  void writeSucceededAt(
    String key,
    DateTime succeededAt, {
    AgentStateTransaction? transaction,
  }) {
    _assertKnownKey(key);
    final value = succeededAt.toUtc().toIso8601String();
    void write(AgentStateTransaction tx) {
      tx.db.execute(
        '''
        INSERT INTO agent_maintenance_state (key, value)
        VALUES (?, ?)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value
        ''',
        [key, value],
      );
    }

    if (transaction != null) {
      write(transaction);
      return;
    }
    _state.transaction(write);
  }

  /// Parses a stored success timestamp against [nowUtc].
  ///
  /// Missing, unparseable, and future values are due immediately.
  static MaintenanceTimestamp parseSuccessTimestamp(
    String? raw,
    DateTime nowUtc,
  ) {
    if (raw == null) {
      return const MaintenanceTimestamp.missing();
    }
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return const MaintenanceTimestamp.malformed();
    }
    final parsed = DateTime.tryParse(trimmed);
    if (parsed == null) {
      return const MaintenanceTimestamp.malformed();
    }
    final utc = parsed.toUtc();
    final now = nowUtc.toUtc();
    if (utc.isAfter(now)) {
      return MaintenanceTimestamp.future(utc);
    }
    return MaintenanceTimestamp.valid(utc);
  }

  void _assertKnownKey(String key) {
    if (!knownKeys.contains(key)) {
      throw ArgumentError.value(
        key,
        'key',
        'Unknown agent_maintenance_state key.',
      );
    }
  }
}

enum MaintenanceTimestampStatus { missing, valid, malformed, future }

class MaintenanceTimestamp {
  final MaintenanceTimestampStatus status;
  final DateTime? value;

  const MaintenanceTimestamp._(this.status, this.value);

  const MaintenanceTimestamp.missing()
    : this._(MaintenanceTimestampStatus.missing, null);

  const MaintenanceTimestamp.malformed()
    : this._(MaintenanceTimestampStatus.malformed, null);

  const MaintenanceTimestamp.valid(DateTime value)
    : this._(MaintenanceTimestampStatus.valid, value);

  const MaintenanceTimestamp.future(DateTime value)
    : this._(MaintenanceTimestampStatus.future, value);

  bool get isDueImmediately => status != MaintenanceTimestampStatus.valid;

  /// Returns true when maintenance should run: missing/malformed/future
  /// stamps, or a valid success that is at least [interval] old.
  bool isDue(DateTime nowUtc, Duration interval) {
    if (isDueImmediately) return true;
    return !nowUtc.toUtc().isBefore(value!.add(interval));
  }
}
