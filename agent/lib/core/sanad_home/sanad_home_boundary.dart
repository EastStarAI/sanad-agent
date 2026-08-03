/// Typed errors raised by the Sanad Home boundary helpers (SEC-02 / INV-6).
///
/// These errors are the single failure surface used by every writer that
/// flows through [SanadHomeBootstrap]. Callers must convert them to their
/// transport-level responses without logging the path or the secret bytes.
library;

class SanadHomeBoundaryViolation implements Exception {
  final String code;
  final String reason;
  final String? path;

  const SanadHomeBoundaryViolation(this.code, this.reason, {this.path});

  @override
  String toString() => 'SanadHomeBoundaryViolation($code): $reason';
}

class SanadHomeWriteFailure implements Exception {
  final String code;
  final String reason;
  final String? path;

  const SanadHomeWriteFailure(this.code, this.reason, {this.path});

  @override
  String toString() => 'SanadHomeWriteFailure($code): $reason';
}
