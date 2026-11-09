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

  /// The owner indexes. Their names are non-secret and identify the one item a
  /// refused read failed on, which is what makes a closed vault actionable
  /// without exposing a value.
  static const indexKeys = <String>{
    providerIndexKey,
    mcpIndexKey,
    customIndexKey,
  };

  /// The unprefixed entries the Agent's auth owner reads through the same
  /// store. They live here so one definition serves the readers, the aliases on
  /// `AuthManager` and `DeviceAuthorizationClient`, and the refusal diagnostic,
  /// which may name them because a key name is not a secret.
  static const deviceCredentialKey = 'device_credential';
  static const devicePrivateKeyKey = 'device_private_key';
  static const pendingDeviceCredentialKey = 'pending_device_credential';
  static const previousDeviceCredentialKey = 'pairing_previous_device_credential';
  static const pairingTokenKey = 'pairing_token';
  static const pendingAgentLogoutKey = 'agent_logout_pending';
  static const serverTimeOffsetKey = 'trusted_server_time_offset_seconds';

  /// Every unprefixed auth entry, including the pairing state the device
  /// authorization client owns.
  static const authEntryKeys = <String>{
    deviceCredentialKey,
    devicePrivateKeyKey,
    pendingDeviceCredentialKey,
    previousDeviceCredentialKey,
    pairingTokenKey,
    pendingAgentLogoutKey,
    serverTimeOffsetKey,
  };

  static String authKey(String key) => '$authPrefix$key';
  static String providerKey(String instanceId) => '$providerPrefix$instanceId';
  static String mcpKey(String reference) => '$mcpPrefix$reference';

  /// User secret named [name] (Plan 84); the name is its environment
  /// variable name.
  static String customKey(String name) => '$customPrefix$name';

  static bool isAuthKey(String key) => key.startsWith(authPrefix);
  static bool isProviderKey(String key) => key.startsWith(providerPrefix);
  static bool isMcpKey(String key) => key.startsWith(mcpPrefix);
  static bool isCustomKey(String key) => key.startsWith(customPrefix);
  static bool isIndexKey(String key) => indexKeys.contains(key);

  /// Whether a refusal diagnostic may name [key].
  ///
  /// Owner indexes and auth entries qualify: the name says which item needs an
  /// authorization decision, and it is not a value. A provider instance id, an
  /// MCP reference or a user-chosen secret name does not qualify, so the
  /// refusal never turns into a list of someone's credentials.
  static bool isShareableKeyLabel(String key) =>
      isIndexKey(key) || authEntryKeys.contains(key);
}
