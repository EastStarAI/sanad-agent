import 'package:sanad_agent/core/provider_runtime/provider_model_id.dart';

/// Wire projection of cached provider models onto the `model.snapshot_result`
/// contract.
///
/// The cache keeps each provider's raw `/models` record (`model_metadata`) for
/// Agent-side capability derivation; it is not part of the snapshot contract and
/// dominated the payload (about 1.2 MB of a 1.5 MB aggregator catalog), which
/// stalled every later reply on the relayed cloud path.
class ProviderModelProjection {
  const ProviderModelProjection._();

  /// Maps [cachedModels] onto the snapshot contract, normalizing each model id
  /// for [templateId] and [protocol] and dropping the internal metadata field.
  static List<dynamic> normalizeCachedModels(
    List<dynamic> cachedModels, {
    required String templateId,
    required String protocol,
  }) {
    return cachedModels
        .map((entry) {
          if (entry is! Map) {
            return entry;
          }
          final map = Map<String, dynamic>.from(entry);
          final rawValue = map['value']?.toString();
          if (rawValue == null || rawValue.isEmpty) {
            return normalizeModelEntry(map);
          }
          return normalizeModelEntry({
            ...map,
            'value': ProviderModelId.normalize(
              templateId: templateId,
              protocol: protocol,
              rawModelId: rawValue,
            ),
          });
        })
        .toList(growable: false);
  }

  /// Projects one cached model onto the `model.snapshot_result` contract.
  static Map<String, dynamic> normalizeModelEntry(Map<String, dynamic> map) {
    final normalized = Map<String, dynamic>.from(map)
      // The pre-policy provider window is internal evidence only; the snapshot
      // carries the single effective `context_window`.
      ..remove('context_window_raw')
      ..remove('model_metadata');
    final value = normalized['value']?.toString();
    if (value != null && value.isNotEmpty) {
      normalized['id'] ??= value;
    }
    final label = normalized['label']?.toString();
    if (label != null && label.isNotEmpty) {
      normalized['name'] ??= label;
    }
    if (normalized.containsKey('supports_reasoning')) {
      normalized['supports_reasoning_output'] ??=
          normalized['supports_reasoning'];
    }
    return normalized;
  }

  /// Normalizes one instance-local model id for [templateId] and [protocol].
  static String? normalizeModelId(
    String templateId,
    String protocol,
    String? rawModelId,
  ) {
    if (rawModelId == null || rawModelId.isEmpty) {
      return rawModelId;
    }
    return ProviderModelId.normalize(
      templateId: templateId,
      protocol: protocol,
      rawModelId: rawModelId,
    );
  }
}
