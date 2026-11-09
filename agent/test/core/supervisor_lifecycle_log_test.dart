import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sanad_agent/core/supervisor_lifecycle_log.dart';
import 'package:test/test.dart';

void main() {
  late Directory home;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('sanad-supervisor-log-');
  });

  tearDown(() async {
    if (await home.exists()) {
      await home.delete(recursive: true);
    }
  });

  File logFile() => File(p.join(home.path, 'logs', 'agent-supervisor.log'));

  test('records one line per transition with bounded detail', () async {
    final log = SupervisorLifecycleLog(
      home: home.path,
      clock: () => DateTime.utc(2026, 11, 9, 17, 30, 5),
    );

    log.record(SupervisorLifecycleEvent.start, pid: 2288, detail: 'managed');
    log.record(
      SupervisorLifecycleEvent.respawn,
      pid: 2288,
      attempt: 3,
      detail: 'child exit code 1',
    );
    log.record(
      SupervisorLifecycleEvent.breakerExit,
      pid: 2288,
      attempt: 5,
      detail: 'child exited with code 1 and failed 5 times in a row.',
    );
    log.record(SupervisorLifecycleEvent.shutdown, pid: 2288, detail: 'sigterm');

    final lines = logFile()
        .readAsLinesSync()
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
    expect(lines, hasLength(4));
    expect(lines[0], contains('2026-11-09T17:30:05.000Z'));
    expect(lines[0], contains('event=start'));
    expect(lines[0], contains('pid=2288'));
    expect(lines[1], contains('event=respawn'));
    expect(lines[1], contains('attempt=3'));
    expect(lines[2], contains('event=breakerExit'));
    expect(lines[3], contains('event=shutdown'));
  });

  test('rotation keeps at most the configured number of segments', () async {
    // A tight restart loop must not fill the disk: the cap is per segment and
    // the retained count is fixed.
    final log = SupervisorLifecycleLog(
      home: home.path,
      maxBytes: 200,
      segmentCount: 2,
    );

    for (var index = 0; index < 40; index++) {
      expect(
        log.record(
          SupervisorLifecycleEvent.respawn,
          pid: 2288,
          attempt: index,
          detail: 'a bounded reason for respawn $index',
        ),
        isNotNull,
      );
    }

    final active = logFile();
    final rotated = File('${active.path}.1');
    expect(active.existsSync(), isTrue);
    expect(rotated.existsSync(), isTrue);
    expect(File('${active.path}.2').existsSync(), isFalse);
    final total = active.lengthSync() + rotated.lengthSync();
    expect(total, lessThanOrEqualTo(200 * 2 + 200));
    // Every retained line is a complete record, never a truncated one.
    for (final line in [
      ...active.readAsLinesSync(),
      ...rotated.readAsLinesSync(),
    ].where((line) => line.isNotEmpty)) {
      expect(line, contains('event=respawn'));
    }
  });

  test('a Home that does not exist yet is never created', () async {
    final missing = Directory(p.join(home.path, 'absent'));
    final log = SupervisorLifecycleLog(home: missing.path);

    expect(log.record(SupervisorLifecycleEvent.start, pid: 1), isNull);
    expect(missing.existsSync(), isFalse);
  });
}
