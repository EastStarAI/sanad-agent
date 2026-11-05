import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import '../core/config/request_dump_retention_policy.dart';
import '../core/sanad_home/sanad_home_bootstrap.dart';
import 'llm_request_dumper.dart';

/// Outcome of one request-dump retention sweep.
class RequestDumpRetentionResult {
  /// Dump files deleted by this sweep.
  final int deletedFiles;

  /// Bytes reclaimed by this sweep.
  final int deletedBytes;

  /// Dump files kept because an in-flight request still owns them.
  final int skippedInUseFiles;

  const RequestDumpRetentionResult({
    required this.deletedFiles,
    required this.deletedBytes,
    this.skippedInUseFiles = 0,
  });

  static const empty = RequestDumpRetentionResult(
    deletedFiles: 0,
    deletedBytes: 0,
  );
}

/// Deletes expired diagnostic request dumps.
///
/// `LLMRequestDumper` writes sanitized payloads under the state Home's
/// `request_dumps` directory and never deletes them, so an unmanaged Home grows
/// without a ceiling (one owner Home held 25 900 dumps / 14 GB). This service
/// is the only deleter: it sweeps once at daemon start and then daily, using
/// the owner policy in `config.yaml` (`diagnostics.requestDumpRetentionDays`,
/// default 3 days).
///
/// One sweep is a single non-recursive directory listing plus one `stat` per
/// matching file. It deletes only names [LLMRequestDumper] produces, never
/// follows a symbolic link, and never touches a file an in-flight request still
/// owns. It logs one lifecycle line per sweep that actually reclaimed space.
class RequestDumpRetentionService {
  static final Logger _logger = Logger('RequestDumpRetention');

  /// Name of the dump directory inside the state Home.
  static const String directoryName = 'request_dumps';

  final RequestDumpRetentionPolicy _policy;
  final String Function() _dumpsDirectoryPath;
  final Set<String> Function() _inFlightPaths;
  final DateTime Function() _clock;
  final Duration _sweepInterval;

  Timer? _timer;

  RequestDumpRetentionService({
    required RequestDumpRetentionPolicy policy,
    @visibleForTesting String Function()? dumpsDirectoryPath,
    @visibleForTesting Set<String> Function()? inFlightPaths,
    @visibleForTesting DateTime Function()? clock,
    @visibleForTesting Duration? sweepInterval,
  }) : _policy = policy,
       _dumpsDirectoryPath =
           dumpsDirectoryPath ??
           (() => SanadHomeBootstrap.state().child(directoryName)),
       _inFlightPaths = inFlightPaths ?? LLMRequestDumper.inFlightDumpPaths,
       _clock = clock ?? DateTime.now,
       _sweepInterval =
           sweepInterval ?? RequestDumpRetentionPolicy.defaultSweepInterval;

  /// Sweeps once now, then keeps sweeping at the configured interval.
  void start() {
    if (_timer != null) return;
    _sweepSafely();
    _timer = Timer.periodic(_sweepInterval, (_) => _sweepSafely());
  }

  /// Stops the periodic sweep. Any sweep in flight finishes on its own.
  void dispose() {
    _timer?.cancel();
    _timer = null;
  }

  /// One retention sweep. Failures are contained so diagnostics can never
  /// affect the runtime.
  RequestDumpRetentionResult sweep() {
    final directoryPath = _dumpsDirectoryPath();
    if (FileSystemEntity.typeSync(directoryPath, followLinks: false) !=
        FileSystemEntityType.directory) {
      // Absent (no dumps ever written) or a symbolic link: never follow it.
      return RequestDumpRetentionResult.empty;
    }
    final directory = Directory(directoryPath);
    final now = _clock();
    final inFlight = _inFlightPaths();
    var deletedFiles = 0;
    var deletedBytes = 0;
    var skippedInUse = 0;
    for (final entity in directory.listSync(followLinks: false)) {
      // A link is never a dump we own, and deleting through it is forbidden.
      if (entity is! File) continue;
      if (!LLMRequestDumper.isDumpFileName(p.basename(entity.path))) continue;
      if (inFlight.contains(entity.path)) {
        skippedInUse++;
        continue;
      }
      final FileStat stat;
      try {
        stat = entity.statSync();
      } on FileSystemException {
        // Another process already removed it.
        continue;
      }
      if (!_policy.isExpired(stat.modified, now)) continue;
      try {
        entity.deleteSync();
      } on FileSystemException {
        continue;
      }
      deletedFiles++;
      deletedBytes += stat.size;
    }
    final result = RequestDumpRetentionResult(
      deletedFiles: deletedFiles,
      deletedBytes: deletedBytes,
      skippedInUseFiles: skippedInUse,
    );
    if (deletedFiles > 0) {
      final days = _policy.retention.inDays;
      final window = days == 1 ? '1 day' : '$days days';
      _logger.info(
        'Request dump retention: removed $deletedFiles dump(s), '
        '$deletedBytes bytes older than $window.',
      );
    }
    return result;
  }

  void _sweepSafely() {
    try {
      sweep();
    } catch (error, stack) {
      _logger.warning('Request dump retention sweep failed.', error, stack);
    }
  }
}
