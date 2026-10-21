import 'package:sanad_agent/engine/adapters/provider_registry.dart';

/// Why a child process is spawned. Each purpose owns its environment rule.
enum ChildProcessPurpose {
  /// Model-requested command on the host (Direct Developer execution).
  directDeveloper('direct_developer'),

  /// Model-requested command inside an isolated backend.
  protectedExecution('protected_execution');

  const ChildProcessPurpose(this.value);
  final String value;
}

/// Ownership classification of child-process environment variables.
///
/// Ownership comes from the registry that reads a value, not from a name
/// suffix: a project's own `*_TOKEN` stays available to the developer, while a
/// credential Sanad reads for itself never reaches a general child.
abstract final class ChildProcessSecurityContract {
  /// Credentials Sanad itself reads from its process environment outside the
  /// provider registry (`Config`).
  static const configCredentialNames = {'LLM_API_KEY', 'SERPER_API_KEY'};

  /// Variables a request or model override may never set. They select the
  /// executable search path, identity, Sanad state, dynamic loader hooks,
  /// interpreter start-up hooks, Git transport hooks, or trust roots.
  static const protectedOverrideKeys = {
    'PATH',
    'PATHEXT',
    'COMSPEC',
    'HOME',
    'USER',
    'USERNAME',
    'USERPROFILE',
    'SHELL',
    'TMPDIR',
    'TEMP',
    'TMP',
    'NODE_OPTIONS',
    'PYTHONSTARTUP',
    'PYTHONPATH',
    'PERL5OPT',
    'RUBYOPT',
    'BASH_ENV',
    'ENV',
    'GIT_SSH',
    'GIT_SSH_COMMAND',
    'GIT_ASKPASS',
    'GIT_EXEC_PATH',
    'GIT_CONFIG_GLOBAL',
    'GIT_CONFIG_SYSTEM',
    'GIT_CONFIG_COUNT',
    'GIT_CONFIG_PARAMETERS',
    'GIT_PROXY_COMMAND',
    'JAVA_TOOL_OPTIONS',
    'PYTHONHOME',
    'NODE_PATH',
    'ZDOTDIR',
    'SSH_ASKPASS',
    'SSL_CERT_FILE',
    'SSL_CERT_DIR',
    'NODE_EXTRA_CA_CERTS',
    'REQUESTS_CA_BUNDLE',
    'CURL_CA_BUNDLE',
    'HTTP_PROXY',
    'HTTPS_PROXY',
    'ALL_PROXY',
    'NO_PROXY',
  };

  /// Prefixes a request or model override may never set.
  static const protectedOverridePrefixes = [
    'LD_',
    'DYLD_',
    'SANAD_',
    // `GIT_CONFIG_KEY_<n>`/`GIT_CONFIG_VALUE_<n>` inject arbitrary Git config.
    'GIT_CONFIG_KEY_',
    'GIT_CONFIG_VALUE_',
  ];

  static Set<String>? _credentialNames;

  /// Every credential name Sanad reads from its own environment, derived from
  /// the provider registry plus [configCredentialNames].
  static Set<String> get sanadCredentialNames => _credentialNames ??= {
    ...configCredentialNames,
    for (final profile in ProviderRegistry.profiles)
      if (profile.envApiKeyName != null) profile.envApiKeyName!.toUpperCase(),
  };

  /// Whether [key] is a credential owned by Sanad (case-insensitive, as on
  /// Windows).
  static bool isSanadCredential(String key) =>
      sanadCredentialNames.contains(key.toUpperCase());

  /// Whether [key] is an operator variable a request may never replace.
  static bool isProtectedOperatorKey(String key) {
    final upper = key.toUpperCase();
    return protectedOverrideKeys.contains(upper) ||
        protectedOverridePrefixes.any(upper.startsWith);
  }

  /// Whether a request override of [key] must be rejected.
  static bool isDangerousRequestOverride(String key) =>
      isProtectedOperatorKey(key) || isSanadCredential(key);
}
