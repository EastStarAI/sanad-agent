import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:test/test.dart';

/// Opens an isolated on-disk `AgentStateDatabase` inside a worker isolate and
/// runs [count] transactions before signalling completion through [sendPort].
void _writerMain(List<Object> args) {
  final sendPort = args[0] as SendPort;
  final dirPath = args[1] as String;
  final writerIndex = args[2] as int;
  final count = args[3] as int;
  final ready = args[4] as SendPort;
  AgentStateDatabase? db;
  var announcedReady = false;
  try {
    db = AgentStateDatabase.atPath(dirPath);
    ready.send(const ['ready']);
    announcedReady = true;
    for (var i = 0; i < count; i++) {
      db.transaction((tx) {
        tx.db.execute(
          'INSERT INTO sessions '
          '(session_id, model, created_at, updated_at) '
          'VALUES (?, ?, ?, ?)',
          [
            'iso-$writerIndex-$i',
            'model',
            '2026-01-01T00:00:00Z',
            '2026-01-01T00:00:00Z',
          ],
        );
      });
    }
    final observed =
        db.db.select('SELECT COUNT(*) FROM sessions').first.values.first as int;
    sendPort.send(['success', observed]);
  } catch (error, stackTrace) {
    final failure = ['error', '$error', '$stackTrace'];
    if (!announcedReady) ready.send(failure);
    sendPort.send(failure);
  } finally {
    db?.dispose();
  }
}

void main() {
  test(
    'concurrent writers on separate handles commit without lock failures',
    () async {
      final dir = Directory.systemTemp.createTempSync('sanad_conc_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final dirPath = dir.path;

      const writers = 4;
      const writesPerWriter = 25;

      // First handle creates schema so worker isolates only write.
      final bootstrap = AgentStateDatabase.atPath(dirPath);
      bootstrap.dispose();

      final results = await Future.wait(
        List.generate(writers, (w) async {
          final ready = ReceivePort();
          final done = ReceivePort();
          final isolate = await Isolate.spawn(_writerMain, [
            done.sendPort,
            dirPath,
            w,
            writesPerWriter,
            ready.sendPort,
          ]);
          try {
            final readyMessage = await ready.first as List<Object?>;
            if (readyMessage.first != 'ready') {
              fail(
                'writer $w failed to initialize: ${readyMessage.skip(1).join('\n')}',
              );
            }
            final result = await done.first as List<Object?>;
            if (result.first != 'success') {
              fail('writer $w failed: ${result.skip(1).join('\n')}');
            }
            return result[1]! as int;
          } finally {
            isolate.kill();
            ready.close();
            done.close();
          }
        }),
      );

      final verify = AgentStateDatabase.atPath(dirPath);
      addTearDown(verify.dispose);
      final total =
          verify.db.select('SELECT COUNT(*) FROM sessions').first.values.first
              as int;

      expect(total, writers * writesPerWriter);
      // Each writer observes at least its own writes; WAL readers may see a
      // snapshot taken before cross-writer commits landed. Assert per-writer
      // minimums and the authoritative total instead.
      for (var w = 0; w < writers; w++) {
        expect(
          results[w],
          greaterThanOrEqualTo(writesPerWriter),
          reason: 'writer $w observed ${results[w]} rows',
        );
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
