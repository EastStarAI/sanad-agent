import 'dart:convert';

import '../auth/secret_vault.dart';
import 'secret_record.dart';
import 'secret_store.dart';

/// Provider credentials stored in the Agent vault (Plan 83, Task 83c).
///
/// Records are keyed by provider instance UUID inside the `providers:`
/// namespace. Raw records stay inside the daemon; callers that render cards
/// use [summary].
class VaultSecretStore implements SecretStore {
  VaultSecretStore(this._vaults);

  final SecretVaults _vaults;

  SecretVaultNamespace get _namespace => _vaults.providers;

  @override
  SecretRecord? read(String instanceId) {
    final raw = _namespace.read(instanceId);
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic>
          ? SecretRecord.fromJson(decoded)
          : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(String instanceId, SecretRecord record) =>
      _vaults.put(_namespace, {instanceId: jsonEncode(record.toJson())});

  @override
  SecretSummary summary(String instanceId) =>
      SecretSummary.fromRecord(read(instanceId), instanceId);

  @override
  Future<void> remove(String instanceId) =>
      _vaults.remove(_namespace, [instanceId]);

  @override
  List<String> listIds() => _namespace.ids;

  @override
  Future<void> pruneOrphans(Set<String> validInstanceIds) => _vaults.remove(
    _namespace,
    _namespace.ids.where((id) => !validInstanceIds.contains(id)),
  );
}
