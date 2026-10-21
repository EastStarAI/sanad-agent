import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sanad_agent/cli/runner/sanad_command_runner.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/scheduled_task_repository.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import '../support/isolated_sanad_test_home.dart';

/// `scheduled_tasks` as shipped before Task 112.
const _legacyCreateTable = '''
  CREATE TABLE scheduled_tasks (
    id TEXT PRIMARY KEY,
    task TEXT NOT NULL,
    run_at TEXT NOT NULL,
    session_id TEXT NOT NULL,
    created_at TEXT NOT NULL
  );
''';

void main() {
  useIsolatedSanadTestHome();

  late Directory home;
  late StringBuffer out;
  late StringBuffer err;

  String dbPath() =>
      p.join(home.path, AgentStateDatabase.stateDatabaseFileName);

  Future<int> run(List<String> args) => SanadCommandRunner(
    stdoutSink: out,
    stderrSink: err,
  ).run(['schedule', 'list', '--home', home.path, ...args]);

  /// Seeds one row of every kind through the production repository, then
  /// closes the writer cleanly (no WAL/SHM sidecars remain).
  void seedAllKinds() {
    final db = AgentStateDatabase.atPath(home.path);
    final repo = ScheduledTaskRepository(db);
    repo.saveScheduledTask(
      'sched-daily',
      'Daily report',
      DateTime.utc(2026, 10, 22, 11, 52),
      'session-daily-0123456789',
      kind: 'daily',
      atTime: '14:52',
      zone: '+03:00',
      lastRunAt: DateTime.utc(2026, 10, 21, 11, 52),
      lastStatus: 'ok',
    );
    repo.saveScheduledTask(
      'sched-interval',
      'Poll inbox',
      DateTime.utc(2026, 10, 21, 12, 10),
      'session-interval-0123',
      kind: 'interval',
      intervalMinutes: 10,
      zone: 'Z',
    );
    repo.saveScheduledTask(
      'sched-weekly',
      'Weekly backup',
      DateTime.utc(2026, 10, 23, 4, 45),
      'session-weekly-0123',
      kind: 'weekly',
      weekdays: 'mon,wed',
      atTime: '23:45',
      zone: '-05:00',
      enabled: false,
    );
    repo.saveScheduledTask(
      'sched-monthly',
      'Pay invoices',
      DateTime.utc(2026, 11, 15, 9),
      'session-monthly-0123',
      kind: 'monthly',
      monthDay: 15,
      atTime: '09:00',
      zone: 'Z',
    );
    repo.saveScheduledTask(
      'sched-once',
      'One-off reminder',
      DateTime.utc(2026, 10, 21, 18),
      'session-once-0123',
      zone: 'Z',
    );
    db.dispose();
  }

  /// Hashes the database content files. `-shm` is excluded on purpose: it is
  /// SQLite's WAL shared-memory index, where every WAL reader (read-only ones
  /// included) records read marks; it holds no database content.
  String fingerprint() {
    final parts = <String>[];
    for (final suffix in ['', '-wal']) {
      final file = File('${dbPath()}$suffix');
      parts.add(
        file.existsSync()
            ? '$suffix:${sha256.convert(file.readAsBytesSync())}'
            : '$suffix:absent',
      );
    }
    return parts.join('|');
  }

  setUp(() {
    home = Directory.systemTemp.createTempSync('sanad_schedule_list_');
    out = StringBuffer();
    err = StringBuffer();
  });

  tearDown(() {
    if (home.existsSync()) home.deleteSync(recursive: true);
  });

  test('a Home without a database prints the empty message and creates '
      'nothing', () async {
    expect(await run([]), 0);
    expect(out.toString(), 'No scheduled tasks\n');
    expect(home.listSync(), isEmpty);
  });

  test('an initialized Home with no rows is empty in text and JSON', () async {
    AgentStateDatabase.atPath(home.path).dispose();
    expect(await run([]), 0);
    expect(out.toString(), 'No scheduled tasks\n');

    out.clear();
    expect(await run(['--json']), 0);
    expect(jsonDecode(out.toString()), {
      'source': 'current',
      'count': 0,
      'tasks': <Object>[],
    });
  });

  test('a database without the scheduled_tasks table is empty', () async {
    sqlite3.open(dbPath())
      ..execute('CREATE TABLE unrelated (id INTEGER)')
      ..dispose();
    expect(await run(['--json']), 0);
    expect(jsonDecode(out.toString()), {
      'source': 'missing_table',
      'count': 0,
      'tasks': <Object>[],
    });
  });

  test('lists one row of each kind with summary, zoned next run, short '
      'session, enabled and last run', () async {
    seedAllKinds();
    expect(await run([]), 0, reason: err.toString());
    final lines = out.toString().trimRight().split('\n');
    expect(lines.first, startsWith('ID'));
    expect(lines, hasLength(6));
    // Ordered by next run.
    expect(lines[1], startsWith('sched-interval'));
    expect(lines[1], contains('every 10 minutes'));
    expect(lines[1], contains('2026-10-21T12:10:00Z'));
    expect(lines[2], startsWith('sched-once'));
    expect(lines[2], contains('once at 2026-10-21T18:00:00Z'));
    expect(lines[3], startsWith('sched-daily'));
    expect(lines[3], contains('daily at 14:52'));
    expect(lines[3], contains('2026-10-22T14:52:00+03:00'));
    expect(lines[3], contains('session-'));
    expect(lines[3], isNot(contains('session-daily-0123456789')));
    expect(lines[3], contains('ok 2026-10-21T14:52:00+03:00'));
    expect(lines[4], startsWith('sched-weekly'));
    expect(lines[4], contains('weekly on mon, wed at 23:45'));
    expect(lines[4], contains('2026-10-22T23:45:00-05:00'));
    expect(lines[4], contains(' no '));
    expect(lines[5], startsWith('sched-monthly'));
    expect(lines[5], contains('monthly on day 15 at 09:00'));
  });

  test('JSON output has the stable shape', () async {
    seedAllKinds();
    expect(await run(['--json']), 0, reason: err.toString());
    final decoded = jsonDecode(out.toString()) as Map<String, dynamic>;
    expect(decoded.keys, ['source', 'count', 'tasks']);
    expect(decoded['source'], 'current');
    expect(decoded['count'], 5);
    final tasks = (decoded['tasks'] as List).cast<Map<String, dynamic>>();
    expect(tasks.map((t) => t['id']), [
      'sched-interval',
      'sched-once',
      'sched-daily',
      'sched-weekly',
      'sched-monthly',
    ]);
    for (final task in tasks) {
      expect(task.keys, [
        'id',
        'task',
        'kind',
        'summary',
        'zone',
        'next_run_at',
        'next_run_at_utc',
        'session_id',
        'enabled',
        'last_status',
        'last_run_at',
        'last_run_at_utc',
      ]);
    }
    expect(tasks[2], {
      'id': 'sched-daily',
      'task': 'Daily report',
      'kind': 'daily',
      'summary': 'daily at 14:52',
      'zone': '+03:00',
      'next_run_at': '2026-10-22T14:52:00+03:00',
      'next_run_at_utc': '2026-10-22T11:52:00.000Z',
      'session_id': 'session-daily-0123456789',
      'enabled': true,
      'last_status': 'ok',
      'last_run_at': '2026-10-21T14:52:00+03:00',
      'last_run_at_utc': '2026-10-21T11:52:00.000Z',
    });
    expect(tasks[3]['enabled'], isFalse);
    expect(tasks[3]['last_status'], isNull);
  });

  test('a legacy pre-112 table is listed from run_at without migrating '
      'it', () async {
    sqlite3.open(dbPath())
      ..execute(_legacyCreateTable)
      ..execute(
        'INSERT INTO scheduled_tasks (id, task, run_at, session_id, '
        'created_at) VALUES (?, ?, ?, ?, ?)',
        [
          'legacy-1',
          'Old reminder',
          '2026-12-01T08:00:00.000Z',
          'session-legacy-0123',
          '2026-11-01T08:00:00.000Z',
        ],
      )
      ..dispose();
    final before = fingerprint();

    expect(await run([]), 0, reason: err.toString());
    expect(out.toString(), contains('legacy-1'));
    expect(out.toString(), contains('once at 2026-12-01T'));
    expect(out.toString(), contains('legacy schedule table'));

    out.clear();
    expect(await run(['--json']), 0);
    final decoded = jsonDecode(out.toString()) as Map<String, dynamic>;
    expect(decoded['source'], 'legacy');
    final task = (decoded['tasks'] as List).single as Map<String, dynamic>;
    expect(task['kind'], 'once');
    expect(task['zone'], 'local');
    expect(task['next_run_at_utc'], '2026-12-01T08:00:00.000Z');
    expect(task['enabled'], isTrue);

    expect(fingerprint(), before);
    final check = sqlite3.open(dbPath());
    try {
      final columns = check
          .select('PRAGMA table_info(scheduled_tasks)')
          .map((row) => row['name'])
          .toList();
      expect(columns, ['id', 'task', 'run_at', 'session_id', 'created_at']);
    } finally {
      check.dispose();
    }
  });

  test('listing never modifies the database, even while a writer holds '
      'it open', () async {
    seedAllKinds();
    final cleanBefore = fingerprint();
    expect(await run([]), 0);
    expect(await run(['--json']), 0);
    expect(fingerprint(), cleanBefore);

    // A daemon-like writer keeps its WAL connection open. SQLite increments
    // the writer's `data_version` whenever another connection commits.
    final writer = AgentStateDatabase.atPath(home.path);
    try {
      int dataVersion() =>
          writer.db.select('PRAGMA data_version').first.values.first as int;
      final versionBefore = dataVersion();
      final mainBefore = sha256.convert(File(dbPath()).readAsBytesSync());
      out.clear();
      expect(await run(['--json']), 0, reason: err.toString());
      expect((jsonDecode(out.toString()) as Map<String, dynamic>)['count'], 5);
      expect(dataVersion(), versionBefore);
      expect(sha256.convert(File(dbPath()).readAsBytesSync()), mainBefore);
    } finally {
      writer.dispose();
    }
  });

  test('the read-only connection rejects writes', () {
    seedAllKinds();
    final db = AgentStateDatabase.readOnlyAtPath(home.path);
    try {
      expect(
        () => db.db.execute("DELETE FROM scheduled_tasks"),
        throwsA(isA<SqliteException>()),
      );
    } finally {
      db.dispose();
    }
  });
}
