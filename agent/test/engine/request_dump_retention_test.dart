import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:sanad_agent/core/config/request_dump_retention_policy.dart';
import 'package:sanad_agent/engine/llm_request_dumper.dart';
import 'package:sanad_agent/engine/request_dump_retention.dart';
import 'package:test/test.dart';

import '../support/isolated_sanad_test_home.dart';

/// Retention is the only deleter of diagnostic dumps: it must remove expired
/// dump files, leave everything it does not own, never follow a link, and never
/// touch a dump an in-flight request still owns.
void main() {
  useIsolatedSanadStateRoot();

  final now = DateTime.utc(2026, 11, 5, 12);
  late Directory root;
  late String dumpsPath;

  setUp(() {
    root = Directory.systemTemp.createTempSync('sanad_dump_retention_');
    dumpsPath = p.join(root.path, 'request_dumps');
    Directory(dumpsPath).createSync();
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  File dumpFile(String name, {required Duration age, int bytes = 16}) {
    final file = File(p.join(dumpsPath, name));
    file.writeAsBytesSync(List<int>.filled(bytes, 1));
    file.setLastModifiedSync(now.subtract(age));
    return file;
  }

  RequestDumpRetentionService service({
    RequestDumpRetentionPolicy policy = const RequestDumpRetentionPolicy(),
    Set<String> inFlight = const {},
  }) {
    return RequestDumpRetentionService(
      policy: policy,
      dumpsDirectoryPath: () => dumpsPath,
      inFlightPaths: () => inFlight,
      clock: () => now,
    );
  }

  test('deletes expired dumps and keeps the retention window', () {
    final expired = dumpFile(
      'request_dump_session_20261101_101010_000_000.json',
      age: const Duration(days: 4),
      bytes: 100,
    );
    final expiredCompaction = dumpFile(
      'compaction_dump_key_20261101_101010_000_000.json',
      age: const Duration(days: 4),
      bytes: 50,
    );
    final fresh = dumpFile(
      'request_dump_session_20261104_101010_000_000.json',
      age: const Duration(days: 1),
    );
    final collisionSuffixed = dumpFile(
      'request_dump_session_20261101_101010_000_000_1730000000000.json',
      age: const Duration(days: 4),
    );

    final result = service().sweep();

    expect(result.deletedFiles, equals(3));
    expect(result.deletedBytes, equals(100 + 50 + 16));
    expect(expired.existsSync(), isFalse);
    expect(expiredCompaction.existsSync(), isFalse);
    expect(collisionSuffixed.existsSync(), isFalse);
    expect(fresh.existsSync(), isTrue);
  });

  test('leaves every name it does not own', () {
    final otherFile = File(p.join(dumpsPath, 'notes.txt'))
      ..writeAsStringSync('keep me');
    otherFile.setLastModifiedSync(now.subtract(const Duration(days: 30)));
    final unprefixed = File(p.join(dumpsPath, 'dump_session_20260101.json'))
      ..writeAsStringSync('{}');
    unprefixed.setLastModifiedSync(now.subtract(const Duration(days: 30)));
    final nestedDirectory = Directory(p.join(dumpsPath, 'archive'))
      ..createSync();

    final result = service().sweep();

    expect(result.deletedFiles, isZero);
    expect(otherFile.existsSync(), isTrue);
    expect(unprefixed.existsSync(), isTrue);
    expect(nestedDirectory.existsSync(), isTrue);
  });

  test('never follows or deletes a symbolic link', () {
    final target = File(p.join(root.path, 'outside.json'))
      ..writeAsStringSync('{}');
    target.setLastModifiedSync(now.subtract(const Duration(days: 30)));
    final linkPath = p.join(
      dumpsPath,
      'request_dump_linked_20260101_101010_000_000.json',
    );
    Link(linkPath).createSync(target.path);

    final result = service().sweep();

    expect(result.deletedFiles, isZero);
    expect(
      Link(linkPath).existsSync(),
      isTrue,
      reason: 'a link is not a dump file this owner created',
    );
    expect(target.existsSync(), isTrue);
  });

  test('does nothing when request_dumps is a symbolic link', () {
    final outside = Directory(p.join(root.path, 'outside_dumps'))..createSync();
    final stale = File(
      p.join(outside.path, 'request_dump_x_20260101_101010_000_000.json'),
    )..writeAsStringSync('{}');
    stale.setLastModifiedSync(now.subtract(const Duration(days: 30)));
    Directory(dumpsPath).deleteSync();
    Link(dumpsPath).createSync(outside.path);

    final result = service().sweep();

    expect(result.deletedFiles, isZero);
    expect(stale.existsSync(), isTrue);
  });

  test('keeps an expired dump an in-flight request still owns', () {
    final inFlightFile = dumpFile(
      'request_dump_live_20261101_101010_000_000.json',
      age: const Duration(days: 4),
    );

    final result = service(inFlight: {inFlightFile.path}).sweep();

    expect(result.deletedFiles, isZero);
    expect(result.skippedInUseFiles, equals(1));
    expect(inFlightFile.existsSync(), isTrue);
  });

  test('an owner-configured window replaces the default', () {
    final fourDaysOld = dumpFile(
      'request_dump_session_20261101_101010_000_000.json',
      age: const Duration(days: 4),
    );

    final kept = service(
      policy: const RequestDumpRetentionPolicy(retention: Duration(days: 5)),
    ).sweep();
    expect(kept.deletedFiles, isZero);
    expect(fourDaysOld.existsSync(), isTrue);

    final removed = service().sweep();
    expect(removed.deletedFiles, equals(1));
    expect(fourDaysOld.existsSync(), isFalse);
  });

  test('a missing dump directory is a no-op', () {
    Directory(dumpsPath).deleteSync();

    final result = service().sweep();

    expect(result.deletedFiles, isZero);
    expect(result.deletedBytes, isZero);
    expect(Directory(dumpsPath).existsSync(), isFalse);
  });

  test('logs one lifecycle line with the removed count and bytes', () {
    dumpFile(
      'request_dump_a_20261101_101010_000_000.json',
      age: const Duration(days: 4),
      bytes: 32,
    );
    dumpFile(
      'request_dump_b_20261101_101010_000_000.json',
      age: const Duration(days: 4),
      bytes: 8,
    );
    final records = <LogRecord>[];
    final subscription = Logger(
      'RequestDumpRetention',
    ).onRecord.listen(records.add);
    addTearDown(subscription.cancel);

    service().sweep();

    expect(records, hasLength(1));
    expect(
      records.single.message,
      'Request dump retention: removed 2 dump(s), 40 bytes older than '
      '3 days.',
    );
  });

  group('LLMRequestDumper.isDumpFileName', () {
    test('accepts both dump families', () {
      expect(
        LLMRequestDumper.isDumpFileName(
          'request_dump_session_20261105_101010_000_000.json',
        ),
        isTrue,
      );
      expect(
        LLMRequestDumper.isDumpFileName(
          'compaction_dump_key_20261105_101010_000_000.json',
        ),
        isTrue,
      );
    });

    test('rejects anything else in the directory', () {
      expect(LLMRequestDumper.isDumpFileName('notes.json'), isFalse);
      expect(LLMRequestDumper.isDumpFileName('request_dump_.json'), isFalse);
      expect(
        LLMRequestDumper.isDumpFileName('request_dump_x_20260101.json.bak'),
        isFalse,
      );
    });
  });
}
