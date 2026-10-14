/// The operational purpose of a child process spawn.
enum ChildProcessPurpose {
  directDeveloper('direct_developer'),
  protectedExecution('protected_execution'),
  mcpServer('mcp_server'),
  helper('helper'),
  update('update');

  const ChildProcessPurpose(this.value);
  final String value;
}

/// The origin or category of an environment variable source.
enum EnvironmentSource {
  inheritedOperator('inherited_operator'),
  requestOverride('request_override'),
  systemDefault('system_default'),
  mcpConfig('mcp_config');

  const EnvironmentSource(this.value);
  final String value;
}

/// The owner of a secret or sensitive credential.
enum SecretOwner {
  sanadControlPlane('sanad_control_plane'),
  providerCredential('provider_credential'),
  mcpServer('mcp_server'),
  operatorEnvironment('operator_environment'),
  projectWorkspace('project_workspace');

  const SecretOwner(this.value);
  final String value;
}

/// Classification and policy rules for child process environment variables.
class ChildProcessSecurityContract {
  const ChildProcessSecurityContract._();

  /// Environment variable keys that untrusted requests or models MUST NEVER override.
  static const Set<String> protectedOperatorKeys = {
    'PATH',
    'HOME',
    'USER',
    'USERNAME',
    'USERPROFILE',
    'SHELL',
    'COMSPEC',
    'PATHEXT',
    'TMPDIR',
    'TEMP',
    'TMP',
    'LD_PRELOAD',
    'LD_LIBRARY_PATH',
    'DYLD_INSERT_LIBRARIES',
    'DYLD_LIBRARY_PATH',
    'DYLD_FRAMEWORK_PATH',
    'SANAD_HOME',
    'SANAD_STATE_HOME',
    'SANAD_AUTH_TOKEN',
    'SANAD_AGENT_KEY',
    'SANAD_SECRET_KEY',
    'SANAD_LOCAL_GATEWAY_TOKEN',
    'SANAD_DEVICE_CREDENTIAL',
    'SANAD_GATEWAY_URL',
    'SANAD_LOCAL_GATEWAY_URL',
    // Injection and hook vectors
    'NODE_OPTIONS',
    'PYTHONSTARTUP',
    'PERL5OPT',
    'RUBYOPT',
    'BASH_ENV',
    'ENV',
    'GIT_SSH',
    'GIT_SSH_COMMAND',
    'GIT_ASKPASS',
    'SSH_ASKPASS',
    'SSL_CERT_FILE',
    'SSL_CERT_DIR',
  };

  /// Common patterns or prefixes of control-plane and provider secrets
  /// that must be stripped from generic child processes.
  static const List<String> sanadSecretPrefixes = [
    'SANAD_AUTH_',
    'SANAD_AGENT_',
    'SANAD_DEVICE_',
    'SANAD_TOKEN_',
    'SANAD_LOCAL_GATEWAY_',
    'SANAD_DEV_',
  ];

  static const Set<String> commonProviderSecretKeys = {
    'OPENAI_API_KEY',
    'ANTHROPIC_API_KEY',
    'GEMINI_API_KEY',
    'GROQ_API_KEY',
    'MISTRAL_API_KEY',
    'DEEPSEEK_API_KEY',
    'COHERE_API_KEY',
    'FIREWORKS_API_KEY',
    'TOGETHER_API_KEY',
    'PERPLEXITY_API_KEY',
    'OPENROUTER_API_KEY',
    'AI21_API_KEY',
    'VOYAGE_API_KEY',
  };

  /// Checks if an environment variable key is a protected operator variable
  /// that cannot be overwritten by request overrides.
  static bool isProtectedOperatorKey(String key) {
    return protectedOperatorKeys.contains(key.toUpperCase());
  }

  /// Checks if an environment variable key is a dangerous request override.
  static bool isDangerousRequestOverride(String key) {
    final upper = key.toUpperCase();
    if (protectedOperatorKeys.contains(upper)) return true;
    if (isSanadControlPlaneSecret(upper)) return true;
    return false;
  }

  /// Checks if an environment variable key represents a Sanad control-plane secret.
  static bool isSanadControlPlaneSecret(String key) {
    final upper = key.toUpperCase();
    if (upper == 'SANAD_AUTH_TOKEN' ||
        upper == 'SANAD_AGENT_KEY' ||
        upper == 'SANAD_SECRET_KEY' ||
        upper == 'SANAD_LOCAL_GATEWAY_TOKEN' ||
        upper == 'SANAD_DEVICE_CREDENTIAL' ||
        upper == 'SANAD_PAIRING_TOKEN') {
      return true;
    }
    for (final prefix in sanadSecretPrefixes) {
      if (upper.startsWith(prefix)) return true;
    }
    return false;
  }

  /// Checks if an environment variable key represents a known ambient provider secret.
  static bool isProviderSecret(String key) {
    return commonProviderSecretKeys.contains(key.toUpperCase());
  }
}
