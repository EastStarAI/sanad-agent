import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

/// Typed recognition of a local storage-full failure.
///
/// A full disk is not a provider problem, so it must never be presented as one.
/// Two shapes reach the runtime:
///
/// * `SqliteException` with `SQLITE_FULL` (result code 13), which SQLite may
///   also report through `SQLITE_IOERR` (10) when the write fails with
///   `ENOSPC`; SQLite has already rolled the transaction back when this
///   surfaces.
/// * `FileSystemException` whose OS error is `ENOSPC` (28 on POSIX, 112 on
///   Windows).
///
/// The owning runtime maps a recognized failure to
/// `RuntimeFailureReason.storageFull` so the notice names the real cause.
class StorageFullFailure {
  const StorageFullFailure._(this.code, this.detail);

  /// SQLite result code `SQLITE_FULL`.
  static const int sqliteFull = 13;

  /// SQLite result code `SQLITE_IOERR`.
  static const int sqliteIoError = 10;

  /// POSIX and Windows "no space left on device" OS error codes.
  static const Set<int> diskFullOsErrorCodes = {28, 112};

  /// Stable machine code for the recognized cause.
  final String code;

  /// Bounded human-readable detail taken from the original error.
  final String detail;

  /// Recognizes [error] as a storage-full failure, or returns null.
  static StorageFullFailure? from(Object error) {
    if (error is SqliteException) {
      final primary = error.resultCode & 0xff;
      if (primary == sqliteFull) {
        return StorageFullFailure._('sqlite_full', error.message);
      }
      if (primary == sqliteIoError && _isDiskFullText(error.message)) {
        return StorageFullFailure._('sqlite_io_error_enospc', error.message);
      }
    }
    if (error is FileSystemException) {
      final osCode = error.osError?.errorCode;
      if (osCode != null && diskFullOsErrorCodes.contains(osCode)) {
        return StorageFullFailure._('os_disk_full', error.message);
      }
      if (_isDiskFullText(error.message) ||
          _isDiskFullText(error.osError?.message ?? '')) {
        return StorageFullFailure._('os_disk_full', error.message);
      }
    }
    // Other owners wrap the cause in a message instead of a typed field.
    final text = error.toString();
    if (_isDiskFullText(text)) {
      return StorageFullFailure._('disk_full', text);
    }
    return null;
  }

  /// Whether [error] reports a full local disk.
  static bool matches(Object error) => from(error) != null;

  /// Whether free-form failure text reports a full local disk.
  static bool matchesText(String text) => _isDiskFullText(text);

  static bool _isDiskFullText(String text) {
    final lower = text.toLowerCase();
    return lower.contains('database or disk is full') ||
        lower.contains('disk is full') ||
        lower.contains('disk full') ||
        lower.contains('no space left on device') ||
        lower.contains('enospc') ||
        lower.contains('sqlite_full');
  }
}
