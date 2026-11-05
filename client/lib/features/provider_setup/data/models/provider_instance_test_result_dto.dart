import 'package:sanad_client/features/provider_setup/data/models/provider_discovery_error_dto.dart';

/// Parsed `provider.instance.test_result` payload.
///
/// The credential is proven by a verified live model list. The optional
/// generation probe adds route-level proof for the selected model, and its
/// outcome is reported separately so a probe that does not prove the route never
/// reads as a rejected credential (issue 339 review).
class ProviderInstanceTestResultDto {
  final bool success;
  final int modelsCount;

  /// `passed`, `skipped`, `warning`, `failed`, or `not_run`.
  final String probeState;

  /// Model the generation probe used, when a model is selected.
  final String? model;

  /// Round-trip time of the probe, in milliseconds.
  final int? latencyMs;

  /// Definitive cause when [success] is false.
  final ProviderDiscoveryErrorDto? failure;

  /// Non-blocking probe warning when [probeState] is `warning`.
  final ProviderProbeWarningDto? warning;

  const ProviderInstanceTestResultDto({
    required this.success,
    required this.modelsCount,
    this.probeState = 'not_run',
    this.model,
    this.latencyMs,
    this.failure,
    this.warning,
  });

  factory ProviderInstanceTestResultDto.fromJson(Map<String, dynamic> json) {
    return ProviderInstanceTestResultDto(
      success: json['success'] == true,
      modelsCount: (json['models_count'] as num?)?.toInt() ?? 0,
      probeState: json['probe_state']?.toString() ?? 'not_run',
      model: json['model']?.toString(),
      latencyMs: (json['latency_ms'] as num?)?.toInt(),
      failure: ProviderDiscoveryErrorDto.fromJson(json['failure']),
      warning: ProviderProbeWarningDto.fromJson(json['warning']),
    );
  }

  bool get probePassed => probeState == 'passed';

  /// Key accepted and models listed, but no model is selected to probe.
  bool get probeSkipped => probeState == 'skipped';

  bool get probeWarned => probeState == 'warning';

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
      other.probeState == probeState &&
      other.model == model &&
      other.latencyMs == latencyMs &&
      other.failure == failure &&
      other.warning == warning;

  @override
  int get hashCode => Object.hash(
    success,
    modelsCount,
    probeState,
    model,
    latencyMs,
    failure,
    warning,
  );
}

/// Non-blocking generation-probe warning.
class ProviderProbeWarningDto {
  /// `model_rejected`, `timeout`, `network`, `rate_limited`, or `unknown`.
  final String kind;
  final String? model;

  /// Sanitized cause carried by the daemon projection.
  final ProviderDiscoveryErrorDto? cause;

  const ProviderProbeWarningDto({required this.kind, this.model, this.cause});

  /// The model or its request parameters were rejected by the endpoint.
  bool get isModelRejected => kind == 'model_rejected';

  static ProviderProbeWarningDto? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final json = Map<String, dynamic>.from(raw);
    final kind = json['kind']?.toString() ?? '';
    if (kind.isEmpty) return null;
    return ProviderProbeWarningDto(
      kind: kind,
      model: json['model']?.toString(),
      cause: ProviderDiscoveryErrorDto.fromJson(json['cause']),
    );
  }

  Map<String, dynamic> toJson() => {
    'kind': kind,
    if (model != null) 'model': model,
    if (cause != null) 'cause': cause!.toJson(),
  };

  @override
  bool operator ==(Object other) =>
      other is ProviderProbeWarningDto &&
      other.kind == kind &&
      other.model == model &&
      other.cause == cause;

  @override
  int get hashCode => Object.hash(kind, model, cause);
}
