import 'package:sanad_agent/core/provider_runtime/secret_record.dart';
import 'package:sanad_agent/core/provider_runtime/secret_store.dart';

/// [SecretStore] that keeps records in memory and masks summaries through the
/// real `SecretSummary.fromRecord` projection.
///
/// Shared by every provider-runtime suite so no test reaches the OS credential
/// vault or a real Home.
class MemoryProviderSecretStore implements SecretStore {
  final Map<String, SecretRecord> _records = {};

  @override
  SecretRecord? read(String instanceId) => _records[instanceId];

  @override
  Future<void> write(String instanceId, SecretRecord record) async {
    _records[instanceId] = record;
  }

  @override
  SecretSummary summary(String instanceId) =>
      SecretSummary.fromRecord(_records[instanceId], instanceId);

  @override
  Future<void> remove(String instanceId) async {
    _records.remove(instanceId);
  }

  @override
  List<String> listIds() => _records.keys.toList(growable: false);

  @override
  Future<void> pruneOrphans(Set<String> validInstanceIds) async {
    _records.removeWhere((id, _) => !validInstanceIds.contains(id));
  }
}
