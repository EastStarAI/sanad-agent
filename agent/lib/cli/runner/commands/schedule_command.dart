import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/scheduled_task_repository.dart';
import 'package:sanad_agent/evolution/scheduling/schedule_model.dart';

import '../sanad_command.dart';

/// Command to inspect background schedules of the selected Home.
///
/// Inspection only: schedule changes stay owned by the daemon's
/// `CronScheduler` (single writer), so no mutation subcommand exists here.
class ScheduleCommand extends SanadCommand {
  ScheduleCommand({super.customAction}) {
    addSubcommand(
      ScheduleListCommand(
        customAction: customAction != null ? (cmd) => customAction!(cmd) : null,
      ),
    );
  }

  @override
  String get name => 'schedule';

  @override
  String get description => 'Inspect background scheduled tasks';

  @override
  String get invocation => 'sanad schedule <subcommand> [options]';

  @override
  Future<int> execute() async {
    printUsage();
    return 0;
  }
}

/// `sanad schedule list`: reads `scheduled_tasks` of the selected Home through
/// a strictly read-only SQLite connection (no migration, no write), so it is
/// safe while the daemon owns the Home.
class ScheduleListCommand extends SanadCommand {
  ScheduleListCommand({super.customAction}) {
    addCommonOptions(argParser);
  }

  @override
  String get name => 'list';

  @override
  String get description =>
      'List scheduled tasks of the selected Home (read-only)';

  @override
  String get invocation => 'sanad schedule list [--json] [--home <path>]';

  @override
  Future<int> execute() async {
    final ScheduleListing listing;
    try {
      listing = readScheduleListing(_stateHome());
    } catch (e) {
      stderrSink.writeln('Failed to read scheduled tasks: $e');
      return 1;
    }
    if (getFlag('json')) {
      stdoutSink.writeln(jsonEncode(listing.toJson()));
    } else {
      stdoutSink.write(listing.renderText());
    }
    return 0;
  }

  /// `--home` selects the Home whose root holds `state.db`; otherwise the
  /// process state root (`SANAD_STATE_HOME`, then `SANAD_HOME`, then default).
  String _stateHome() {
    return normalizeSanadHomeOption(getOption('home')) ?? getSanadStateHome();
  }
}

/// Where a listing came from; serialized as the stable JSON `source` value.
enum ScheduleListingSource {
  current('current'),
  legacy('legacy'),
  missingTable('missing_table'),
  missingDatabase('missing_database');

  final String wireName;
  const ScheduleListingSource(this.wireName);
}

/// Reads the schedules under [stateHome] read-only. Never creates the
/// database, its directory, or any schema.
ScheduleListing readScheduleListing(String stateHome) {
  final dbFile = File(
    p.join(stateHome, AgentStateDatabase.stateDatabaseFileName),
  );
  if (!dbFile.existsSync()) {
    return const ScheduleListing(ScheduleListingSource.missingDatabase, []);
  }
  final db = AgentStateDatabase.readOnlyAtPath(stateHome);
  try {
    final result = ScheduledTaskRepository(db).inspectScheduledTasks();
    final source = switch (result.shape) {
      ScheduledTaskTableShape.missing => ScheduleListingSource.missingTable,
      ScheduledTaskTableShape.legacy => ScheduleListingSource.legacy,
      ScheduledTaskTableShape.current => ScheduleListingSource.current,
    };
    return ScheduleListing(source, [
      for (final row in result.rows) ScheduleListEntry.fromRow(row),
    ]);
  } finally {
    db.dispose();
  }
}

/// One listed schedule, projected from the shared [ScheduledTaskRecord] model.
class ScheduleListEntry {
  final ScheduledTaskRecord record;

  /// Effective next run, or null when the row carries none.
  final DateTime? nextRunAt;

  ScheduleListEntry._(this.record, this.nextRunAt);

  factory ScheduleListEntry.fromRow(Map<String, dynamic> row) {
    final rawNext = row['next_run_at']?.toString();
    return ScheduleListEntry._(
      ScheduledTaskRecord.fromRow(row),
      rawNext == null ? null : DateTime.tryParse(rawNext)?.toUtc(),
    );
  }

  /// Human recurrence summary from the schedule model (Decision D9); falls
  /// back to the kind name when a stored definition is incomplete.
  String get summary {
    try {
      final definition = record.toDefinition();
      return nextRunAt == null && record.kind == ScheduleKind.once
          ? 'once'
          : definition.humanRecurrenceSummary;
    } catch (_) {
      return record.kind.name;
    }
  }

  String? _inZone(DateTime? instant) {
    if (instant == null) return null;
    try {
      return ScheduleZone.parse(record.zone).formatInstant(instant);
    } catch (_) {
      return instant.toUtc().toIso8601String();
    }
  }

  String? get nextRunInZone => _inZone(nextRunAt);
  String? get lastRunInZone => _inZone(record.lastRunAt);

  Map<String, Object?> toJson() => {
    'id': record.id,
    'task': record.task,
    'kind': record.kind.name,
    'summary': summary,
    'zone': record.zone,
    'next_run_at': nextRunInZone,
    'next_run_at_utc': nextRunAt?.toIso8601String(),
    'session_id': record.sessionId,
    'enabled': record.enabled,
    'last_status': record.lastStatus,
    'last_run_at': lastRunInZone,
    'last_run_at_utc': record.lastRunAt?.toIso8601String(),
  };
}

/// Result of `sanad schedule list`, in text and stable JSON forms.
class ScheduleListing {
  static const int shortSessionIdLength = 8;
  static const String emptyMessage = 'No scheduled tasks';

  final ScheduleListingSource source;
  final List<ScheduleListEntry> entries;

  const ScheduleListing(this.source, this.entries);

  /// Stable shape: `{source, count, tasks: [...]}`.
  Map<String, Object?> toJson() => {
    'source': source.wireName,
    'count': entries.length,
    'tasks': [for (final entry in entries) entry.toJson()],
  };

  String renderText() {
    if (entries.isEmpty) return '$emptyMessage\n';
    const header = [
      'ID',
      'SCHEDULE',
      'NEXT RUN',
      'ZONE',
      'SESSION',
      'ENABLED',
      'LAST',
    ];
    final rows = [
      for (final entry in entries)
        [
          entry.record.id,
          entry.summary,
          entry.nextRunInZone ?? '-',
          entry.record.zone,
          _shortId(entry.record.sessionId),
          entry.record.enabled ? 'yes' : 'no',
          _lastColumn(entry),
        ],
    ];
    final widths = [
      for (var i = 0; i < header.length; i++)
        [
          header[i],
          for (final row in rows) row[i],
        ].map((cell) => cell.length).reduce((a, b) => a > b ? a : b),
    ];
    String line(List<String> cells) => [
      for (var i = 0; i < cells.length; i++)
        i == cells.length - 1 ? cells[i] : cells[i].padRight(widths[i]),
    ].join('  ');
    final buffer = StringBuffer()..writeln(line(header));
    for (final row in rows) {
      buffer.writeln(line(row));
    }
    if (source == ScheduleListingSource.legacy) {
      buffer.writeln(
        '(legacy schedule table: recurrence details appear after the daemon '
        'migrates this Home)',
      );
    }
    return buffer.toString();
  }

  static String _shortId(String id) => id.length > shortSessionIdLength
      ? id.substring(0, shortSessionIdLength)
      : id;

  static String _lastColumn(ScheduleListEntry entry) {
    final status = entry.record.lastStatus;
    final at = entry.lastRunInZone;
    if (status == null && at == null) return '-';
    return [?status, ?at].join(' ');
  }
}
