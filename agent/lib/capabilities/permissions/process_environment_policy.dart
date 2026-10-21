import 'dart:io';

import 'package:logging/logging.dart';

import 'child_process_security_contract.dart';

export 'child_process_security_contract.dart';

/// A request override that the policy refused. Carries the key and the
/// reason only; the value is never retained.
class RejectedEnvironmentOverride {
  const RejectedEnvironmentOverride(this.key, this.reason);

  final String key;
  final String reason;
}

/// Single owner of the environment handed to model-requested child processes.
///
/// Direct Developer starts from the inherited operator environment so SDKs,
/// caches, helpers, proxies and `PATH` keep working, then removes credentials
/// Sanad reads for itself. Request overrides are applied after that and can
/// never replace a protected operator variable or reintroduce a Sanad
/// credential. Diagnostics name the key and reason, never the value.
class ProcessEnvironmentPolicy {
  const ProcessEnvironmentPolicy({Logger? logger}) : _logger = logger;

  final Logger? _logger;

  static final _defaultLogger = Logger('ProcessEnvironmentPolicy');

  Logger get _log => _logger ?? _defaultLogger;

  static const _overrideRejectedReason =
      'protected operator variable or Sanad credential';

  /// Builds the child environment for [purpose].
  ///
  /// [inheritedEnvironment] defaults to the daemon's own environment.
  /// [requestOverrides] are typed per-request values (never a raw dump).
  /// [secretEnvironment] holds the user secrets explicitly requested for this
  /// call (Plan 84); it follows the same protected-key rule as overrides and
  /// is empty unless a caller names a secret.
  Map<String, String> buildChildEnvironment({
    required ChildProcessPurpose purpose,
    Map<String, String>? inheritedEnvironment,
    Map<String, String>? requestOverrides,
    Map<String, String> secretEnvironment = const {},
    void Function(RejectedEnvironmentOverride rejected)? onRejectedOverride,
  }) {
    final child = <String, String>{};
    if (purpose == ChildProcessPurpose.directDeveloper) {
      final inherited = inheritedEnvironment ?? Platform.environment;
      for (final entry in inherited.entries) {
        if (ChildProcessSecurityContract.isSanadCredential(entry.key)) continue;
        child[entry.key] = entry.value;
      }
    }

    void apply(String key, String value) {
      if (ChildProcessSecurityContract.isDangerousRequestOverride(key)) {
        final rejected = RejectedEnvironmentOverride(
          key,
          _overrideRejectedReason,
        );
        _log.warning(
          'Rejected child environment override: key=$key, '
          'reason=${rejected.reason}',
        );
        onRejectedOverride?.call(rejected);
        return;
      }
      // Environment names are case-insensitive on Windows: replace any
      // inherited spelling instead of creating a second entry.
      if (Platform.isWindows) {
        final upper = key.toUpperCase();
        child.removeWhere((existing, _) => existing.toUpperCase() == upper);
      }
      child[key] = value;
    }

    secretEnvironment.forEach(apply);
    requestOverrides?.forEach(apply);

    return child;
  }
}
