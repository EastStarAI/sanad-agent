import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/core/provider_runtime/provider_model_id.dart';

/// Manages the persistence of recently selected models per provider instance,
/// keeping a bounded history of up to 100 items (Plan 29 §10.4).
class RecentModelSelectionService {
  final ProviderInstanceRepository _repo;

  RecentModelSelectionService(this._repo);

  /// Records (or bumps) a model selection.
  void selectModel({
    required String instanceId,
    required String modelId,
    DateTime? selectedAt,
  }) {
    if (instanceId.trim().isEmpty || modelId.trim().isEmpty) return;
    final instance = _repo.findById(instanceId);
    final normalizedModelId = instance == null
        ? modelId
        : ProviderModelId.normalize(
            templateId: instance.templateId,
            protocol: instance.protocol,
            rawModelId: modelId,
          );
    _repo.recordRecentSelection(
      instanceId: instanceId,
      modelId: normalizedModelId,
      selectedAt: selectedAt ?? DateTime.now(),
    );
  }

  /// Returns up to 100 recently selected models.
  List<Map<String, dynamic>> getRecentSelections() {
    return _repo.recentSelections(limit: 100);
  }
}
