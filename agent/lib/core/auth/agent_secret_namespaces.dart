/// Key layout of Agent-owned secrets inside [AgentSecretStore].
///
/// Each owner has its own prefix so one owner can never list or resolve
/// another's entries. `<prefix>index` holds the JSON list of ids an owner has
/// committed; entries are `<prefix><id>`.
abstract final class AgentSecretNamespaces {
  static const authPrefix = 'agent:auth:';
  static const providerPrefix = 'providers:';
  static const mcpPrefix = 'mcp:';
  static const customPrefix = 'custom:';

  static const providerIndexKey = '${providerPrefix}index';
  static const mcpIndexKey = '${mcpPrefix}index';
  static const customIndexKey = '${customPrefix}index';

  static String authKey(String key) => '$authPrefix$key';
  static String providerKey(String instanceId) => '$providerPrefix$instanceId';
  static String mcpKey(String reference) => '$mcpPrefix$reference';
  static String customKey(String key) =>
      key.startsWith(customPrefix) ? key : '$customPrefix$key';

  static bool isAuthKey(String key) => key.startsWith(authPrefix);
  static bool isProviderKey(String key) => key.startsWith(providerPrefix);
  static bool isMcpKey(String key) => key.startsWith(mcpPrefix);
  static bool isCustomKey(String key) => key.startsWith(customPrefix);
}
