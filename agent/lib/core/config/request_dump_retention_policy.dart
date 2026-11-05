/// Owner of the diagnostic request-dump retention policy.
///
/// Request dumps are mutable diagnostic state, not user data: the daemon keeps
/// a bounded recent window instead of growing one directory forever. The
/// window is an owner-tunable policy in the central `config.yaml`
/// (`diagnostics.requestDumpRetentionDays`), never a hard-coded constant.
class RequestDumpRetentionPolicy {
  /// Retention used when the owner configures nothing.
  static const Duration defaultRetention = Duration(days: 3);

  /// How often the daemon sweeps expired dumps while it stays running.
  static const Duration defaultSweepInterval = Duration(days: 1);

  /// Dumps older than this window are deleted.
  final Duration retention;

  const RequestDumpRetentionPolicy({this.retention = defaultRetention});

  /// Instant before which a dump is expired at [now].
  DateTime cutoff(DateTime now) => now.toUtc().subtract(retention);

  /// Whether a dump modified at [modifiedAt] is expired at [now].
  bool isExpired(DateTime modifiedAt, DateTime now) =>
      modifiedAt.toUtc().isBefore(cutoff(now));
}
