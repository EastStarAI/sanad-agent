import 'dart:io';

import 'package:logging/logging.dart';
import 'package:sanad_agent/capabilities/permissions/child_process_security_contract.dart';

/// Central policy engine for child process environment variables.
///
/// Under Plan 83 (Task 83e), this service enforces secret isolation and developer parity:
/// 1. Strips Sanad control-plane credentials and session secrets from child processes.
/// 2. Strips ambient provider API keys unless explicitly granted by the owner.
/// 3. Preserves developer tools, SDK roots, PATH, compiler settings, and package caches.
/// 4. Rejects request-scoped overrides that attempt to replace protected operator variables
///    (e.g. PATH, HOME) or inject dynamic loader/hook vectors (e.g. LD_PRELOAD).
/// 5. Diagnostics log only rejected key names and reasons, never credential values.
class ProcessEnvironmentPolicy {
  const ProcessEnvironmentPolicy({Logger? logger}) : _logger = logger;

  final Logger? _logger;

  static final _defaultLogger = Logger('ProcessEnvironmentPolicy');
  Logger get logger => _logger ?? _defaultLogger;

  /// Builds a sanitized child environment for the specified [purpose].
  Map<String, String> buildChildEnvironment({
    required ChildProcessPurpose purpose,
    Map<String, String>? inheritedEnvironment,
    Map<String, String>? requestOverrides,
    Set<String>? explicitGrants,
    void Function(String rejectedKey, String reason)? onRejectedOverride,
  }) {
    final base = inheritedEnvironment ?? Platform.environment;
    final childEnv = <String, String>{};

    final upperGrants = explicitGrants?.map((k) => k.toUpperCase()).toSet() ??
        const <String>{};

    // 1. Ingest inherited environment, filtering out secrets & daemon markers
    for (final entry in base.entries) {
      final key = entry.key;
      final upperKey = key.toUpperCase();

      // Control-plane secrets are strictly never forwarded
      if (ChildProcessSecurityContract.isSanadControlPlaneSecret(upperKey)) {
        continue;
      }

      // Provider secrets stripped unless explicitly granted by the owner
      if (ChildProcessSecurityContract.isProviderSecret(upperKey)) {
        if (!upperGrants.contains(upperKey)) {
          continue;
        }
      }

      // Daemon-internal virtualenv marker stripped to avoid corrupting user project venvs
      if (upperKey == 'VIRTUAL_ENV') {
        continue;
      }

      // Strip ambient dev launcher & runtime nonce markers
      if (upperKey == 'SANAD_DEV_LAUNCHER_ID' ||
          upperKey == 'SANAD_DEV_RUNTIME_NONCE' ||
          upperKey == 'SANAD_DEV_WORKSPACE_HASH') {
        continue;
      }

      childEnv[key] = entry.value;
    }

    // 2. Apply request overrides safely
    if (requestOverrides != null && requestOverrides.isNotEmpty) {
      for (final entry in requestOverrides.entries) {
        final key = entry.key;
        final upperKey = key.toUpperCase();

        if (ChildProcessSecurityContract.isDangerousRequestOverride(upperKey) ||
            ChildProcessSecurityContract.isProtectedOperatorKey(upperKey)) {
          const reason =
              'Protected operator or control-plane variable cannot be overridden by request.';
          logger.warning(
            'Rejected request environment override: key=$key, reason=$reason',
          );
          onRejectedOverride?.call(key, reason);
          continue;
        }

        // On Windows or case-insensitive platforms, remove existing variant if any
        if (Platform.isWindows) {
          childEnv.removeWhere(
            (k, _) => k.toUpperCase() == upperKey,
          );
        }

        childEnv[key] = entry.value;
      }
    }

    return childEnv;
  }
}
