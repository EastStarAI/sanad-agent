import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:sanad_agent/capabilities/permissions/child_process_security_contract.dart';
import 'package:sanad_agent/core/auth/agent_secret_namespaces.dart';
import 'package:sanad_agent/core/auth/agent_secret_store_contract.dart';

/// Central policy engine for child process environment variables.
///
/// Under Plan 83 (Task 83e) and Plan 84 (Gate G3), this service enforces secret isolation,
/// developer parity, and safe vault injection:
/// 1. Strips Sanad control-plane credentials and session secrets from child processes.
/// 2. Strips ambient provider API keys unless explicitly granted by the owner.
/// 3. Injects custom vault secrets safely into child processes without logging or terminal exposure.
/// 4. Preserves developer tools, SDK roots, PATH, compiler settings, and package caches.
/// 5. Rejects request-scoped overrides that attempt to replace protected operator variables
///    (e.g. PATH, HOME) or inject dynamic loader/hook vectors (e.g. LD_PRELOAD).
/// 6. Diagnostics log only rejected key names and reasons, never credential values.
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
    Map<String, String>? customSecrets,
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

    // 2. Apply custom vault secrets safely
    if (customSecrets != null && customSecrets.isNotEmpty) {
      for (final entry in customSecrets.entries) {
        final key = entry.key;
        final upperKey = key.toUpperCase();

        if (ChildProcessSecurityContract.isDangerousRequestOverride(upperKey) ||
            ChildProcessSecurityContract.isProtectedOperatorKey(upperKey)) {
          logger.warning(
            'Rejected custom secret injection for protected key: $key',
          );
          continue;
        }

        if (Platform.isWindows) {
          childEnv.removeWhere(
            (k, _) => k.toUpperCase() == upperKey,
          );
        }

        childEnv[key] = entry.value;
      }
    }

    // 3. Apply request overrides safely
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

  /// Resolves secrets stored under [targetVault] (or all active `custom:*` keys)
  /// from [store] and returns a key-value map suitable for child process injection.
  Future<Map<String, String>> resolveVaultSecrets({
    required AgentSecretStore store,
    String? targetVault,
    Set<String>? requestedKeys,
  }) async {
    final secrets = <String, String>{};
    try {
      final rawIndex = await store.read(AgentSecretNamespaces.customIndexKey);
      if (rawIndex == null || rawIndex.isEmpty) {
        return secrets;
      }
      final decoded = jsonDecode(rawIndex);
      if (decoded is! List) {
        return secrets;
      }
      final prefix = targetVault != null && targetVault.isNotEmpty
          ? AgentSecretNamespaces.customKey(targetVault)
          : AgentSecretNamespaces.customPrefix;

      for (final rawKey in decoded) {
        final keyStr = rawKey.toString();
        if (keyStr.startsWith(prefix)) {
          final parts = keyStr.split(':');
          final varName = parts.last;
          if (requestedKeys != null && !requestedKeys.contains(varName)) {
            continue;
          }
          final val = await store.read(keyStr);
          if (val != null) {
            secrets[varName] = val;
          }
        }
      }
    } catch (e) {
      logger.warning('Failed to resolve custom vault secrets: $e');
    }
    return secrets;
  }
}
