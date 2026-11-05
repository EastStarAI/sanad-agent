import 'dart:io';

import 'package:sanad_agent/core/provider_runtime/runtime_failure_reason.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_notice.dart';
import 'package:sanad_agent/core/storage/storage_full_failure.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

/// A full disk is a local storage failure, never a provider error.
void main() {
  group('StorageFullFailure.from', () {
    test('recognizes SQLITE_FULL', () {
      final failure = StorageFullFailure.from(
        SqliteException(13, 'database or disk is full'),
      );
      expect(failure, isNotNull);
      expect(failure!.code, equals('sqlite_full'));
    });

    test('recognizes an extended SQLITE_FULL result code', () {
      final failure = StorageFullFailure.from(
        SqliteException(13 | (2 << 8), 'database or disk is full'),
      );
      expect(failure?.code, equals('sqlite_full'));
    });

    test('recognizes SQLITE_IOERR only when it reports a full disk', () {
      expect(
        StorageFullFailure.from(
          SqliteException(10, 'disk I/O error: no space left on device'),
        )?.code,
        equals('sqlite_io_error_enospc'),
      );
      expect(
        StorageFullFailure.from(SqliteException(10, 'disk I/O error')),
        isNull,
        reason: 'an I/O error is not a full disk unless it says so',
      );
    });

    test('recognizes an ENOSPC filesystem failure', () {
      final error = FileSystemException(
        'Failed to write request dump',
        '/tmp/dump.json',
        const OSError('No space left on device', 28),
      );
      final failure = StorageFullFailure.from(error);
      expect(failure?.code, equals('os_disk_full'));
    });

    test('recognizes the Windows disk-full OS error code', () {
      final error = FileSystemException(
        'Failed to write request dump',
        r'C:\dumps\dump.json',
        const OSError('The disk is full.', 112),
      );
      expect(StorageFullFailure.from(error)?.code, equals('os_disk_full'));
    });

    test('does not treat another filesystem failure as a full disk', () {
      final error = FileSystemException(
        'Permission denied',
        '/tmp/dump.json',
        const OSError('Permission denied', 13),
      );
      expect(StorageFullFailure.from(error), isNull);
    });

    test('does not treat an unrelated error as a full disk', () {
      expect(StorageFullFailure.from(StateError('boom')), isNull);
      expect(
        StorageFullFailure.from(SqliteException(5, 'database is locked')),
        isNull,
      );
    });
  });

  group('RuntimeFailureReason storage classification', () {
    test('classifies the full-disk message as storageFull', () {
      expect(
        RuntimeFailureReason.classify(
          body: 'SqliteException(13): database or disk is full',
        ),
        equals(RuntimeFailureReason.storageFull),
      );
      expect(
        RuntimeFailureReason.classify(body: 'No space left on device'),
        equals(RuntimeFailureReason.storageFull),
      );
    });

    test('storageFull never retries automatically or fails over', () {
      final decision = RuntimeFailureReason.storageFull.decision();
      expect(decision.noticeStatus, equals(RuntimeNoticeStatus.blocked));
      expect(decision.severity, equals(RuntimeNoticeSeverity.error));
      expect(decision.retryable, isFalse);
      expect(decision.allowAutoFailover, isFalse);
      expect(
        decision.uiActions,
        equals([RuntimeNoticeAction.retry]),
        reason: 'the operator frees space, then retries the turn',
      );
    });
  });
}
