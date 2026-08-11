import 'package:sanad_agent/core/auth/agent_secret_store.dart';

class MemoryAgentSecretStore implements AgentSecretStore {
  final Map<String, String> values = {};
  bool available = true;
  bool corruptWrites = false;

  void _requireAvailable() {
    if (!available) {
      throw const AgentSecretStoreUnavailable('Test vault unavailable.');
    }
  }

  @override
  Future<String?> read(String key) async {
    _requireAvailable();
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    _requireAvailable();
    values[key] = corruptWrites ? '$value-corrupted' : value;
  }

  @override
  Future<void> delete(String key) async {
    _requireAvailable();
    values.remove(key);
  }
}
