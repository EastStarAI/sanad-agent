import 'package:sanad_client/features/provider_setup/data/models/provider_discovery_error_dto.dart';

/// Parsed `provider.instance.test_result` payload.
///
/// Success means the daemon proved the credential twice: a verified live model
/// list **and** one minimal generation request answered (issue 339).
class ProviderInstanceTestResultDto {
  final bool success;
  final int modelsCount;

  /// Model the generation probe used.
  final String? model;

  /// Round-trip time of the probe, in milliseconds.
  final int? latencyMs;

  /// Sanitized cause when [success] is false.
  final ProviderDiscoveryErrorDto? failure;

  const ProviderInstanceTestResultDto({
    required this.success,
    required this.modelsCount,
    this.model,
    this.latencyMs,
    this.failure,
  });

  factory ProviderInstanceTestResultDto.fromJson(Map<String, dynamic> json) {
    return ProviderInstanceTestResultDto(
      success: json['success'] == true,
      modelsCount: (json['models_count'] as num?)?.toInt() ?? 0,
      model: json['model']?.toString(),
      latencyMs: (json['latency_ms'] as num?)?.toInt(),
      failure: ProviderDiscoveryErrorDto.fromJson(json['failure']),
    );
  }

  /// Probe round-trip seconds for display, when measured.
  String? get latencySeconds {
    final ms = latencyMs;
    if (ms == null) return null;
    return (ms / 1000).toStringAsFixed(1);
  }

  @override
  bool operator ==(Object other) =>
      other is ProviderInstanceTestResultDto &&
      other.success == success &&
      other.modelsCount == modelsCount &&
      other.model == model &&
      other.latencyMs == latencyMs &&
      other.failure == failure;

  @override
  int get hashCode =>
      Object.hash(success, modelsCount, model, latencyMs, failure);
}
