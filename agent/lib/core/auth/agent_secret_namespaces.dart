/// Defines standard namespace prefixes and key formatters for [AgentSecretStore].
///
/// Under Plan 83 (Task 83c), all daemon secrets are unified under [AgentSecretStore]
/// with dedicated namespace boundaries to prevent cross-component collision
/// or unauthorized resolution.
abstract final class AgentSecretNamespaces {
  /// Namespace prefix for Agent control-plane and device authentication.
  static const String authPrefix = 'agent:auth:';

  /// Namespace prefix for LLM Provider API keys and credentials.
  static const String providerPrefix = 'providers:';

  /// Namespace prefix for Model Context Protocol (MCP) server secrets.
  static const String mcpPrefix = 'mcp:';

  /// Namespace prefix for user-provided custom secrets and credentials (Plan 84).
  static const String customPrefix = 'custom:';

  /// Well-known index keys used to track active keys in each namespace.
  static const String providerIndexKey = 'providers:index';
  static const String mcpIndexKey = 'mcp:index';
  static const String customIndexKey = 'custom:index';

  /// Formats an auth key within the auth namespace.
  static String authKey(String key) => '$authPrefix$key';

  /// Formats a provider instance key within the provider namespace.
  static String providerKey(String instanceId) => '$providerPrefix$instanceId';

  /// Formats an MCP secret reference within the MCP namespace.
  static String mcpKey(String reference) => '$mcpPrefix$reference';

  /// Formats a custom secret key within the custom namespace.
  static String customKey(String key) =>
      key.startsWith(customPrefix) ? key : '$customPrefix$key';

  /// Returns true if [key] belongs to the auth namespace.
  static bool isAuthKey(String key) => key.startsWith(authPrefix);

  /// Returns true if [key] belongs to the provider namespace.
  static bool isProviderKey(String key) => key.startsWith(providerPrefix);

  /// Returns true if [key] belongs to the MCP namespace.
  static bool isMcpKey(String key) => key.startsWith(mcpPrefix);

  /// Returns true if [key] belongs to the custom namespace.
  static bool isCustomKey(String key) => key.startsWith(customPrefix);
}
