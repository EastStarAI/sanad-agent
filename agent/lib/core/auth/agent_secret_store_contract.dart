abstract interface class AgentSecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class AgentSecretStoreUnavailable implements Exception {
  const AgentSecretStoreUnavailable(this.message);

  final String message;

  @override
  String toString() => 'AgentSecretStoreUnavailable: $message';
}
