import 'service_models.dart';

/// A service definition staged for activation, together with the exact reversal
/// that restores whatever the Home and the init manager held before it.
///
/// Staging, activation, health, and rollback each succeed or fail independently,
/// so the manager keeps them in one value instead of tracking loose closures.
class ServiceConfigTransaction {
  ServiceConfigTransaction({
    required Future<void> Function() commit,
    required Future<void> Function() rollback,
  }) : _commit = commit,
       _rollback = rollback,
       error = null;

  ServiceConfigTransaction.failed(this.error)
    : _commit = _noop,
      _rollback = _noop;

  final String? error;
  final Future<void> Function() _commit;
  final Future<void> Function() _rollback;
  bool get ready => error == null;
  Future<void> commit() => _commit();
  Future<void> rollback() => _rollback();
  static Future<void> _noop() async {}
}

/// A legacy user-scoped definition preserved until its system-scope replacement
/// is proven healthy.
class LegacyUserMigration {
  LegacyUserMigration({
    required Future<ServiceProcessResult> Function() commit,
    required Future<void> Function() restore,
  }) : _commit = commit,
       _restore = restore,
       error = null;

  LegacyUserMigration.failed(this.error)
    : _commit = _failedCommit,
      _restore = _noop;

  final String? error;
  final Future<ServiceProcessResult> Function() _commit;
  final Future<void> Function() _restore;
  bool get ready => error == null;
  Future<ServiceProcessResult> commit() => _commit();
  Future<void> restore() => _restore();

  static Future<ServiceProcessResult> _failedCommit() async =>
      const ServiceProcessResult(exitCode: 1);
  static Future<void> _noop() async {}
}
