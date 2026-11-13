/// Client DTOs for provider account usage limits (Task 55).
library;

class ProviderUsageWindowDto {
  final String type;
  final String label;
  final double? usedPercent;
  final double? remainingPercent;
  final DateTime? resetAt;
  final String? detail;

  const ProviderUsageWindowDto({
    required this.type,
    required this.label,
    this.usedPercent,
    this.remainingPercent,
    this.resetAt,
    this.detail,
  });

  /// Whether at least one percentage is available.
  bool get hasPercent => usedPercent != null || remainingPercent != null;

  /// Whether this window is fully exhausted.
  bool get isExhausted =>
      (usedPercent != null && usedPercent! >= 100.0) || (remainingPercent != null && remainingPercent! <= 0.0);

  factory ProviderUsageWindowDto.fromJson(Map<String, dynamic> json) {
    return ProviderUsageWindowDto(
      type: json['type'] as String,
      label: (json['label'] as String?) ?? json['type'] as String,
      usedPercent: (json['used_percent'] as num?)?.toDouble(),
      remainingPercent: (json['remaining_percent'] as num?)?.toDouble(),
      resetAt: json['reset_at'] is String ? DateTime.tryParse(json['reset_at'] as String) : null,
      detail: json['detail'] as String?,
    );
  }
}

/// One display-safe banked reset credit (Task 174).
class ProviderUsageResetCreditDto {
  final DateTime? expiresAt;
  final DateTime? grantedAt;

  const ProviderUsageResetCreditDto({this.expiresAt, this.grantedAt});

  factory ProviderUsageResetCreditDto.fromJson(Map<String, dynamic> json) {
    return ProviderUsageResetCreditDto(
      expiresAt: json['expires_at'] is String ? DateTime.tryParse(json['expires_at'] as String) : null,
      grantedAt: json['granted_at'] is String ? DateTime.tryParse(json['granted_at'] as String) : null,
    );
  }
}

/// A unified usage snapshot for a single provider instance (Task 55 §3.2).
class ProviderUsageSnapshotDto {
  final String providerInstanceId;
  final String providerTemplateId;
  final String source;
  final DateTime fetchedAt;
  final String? planName;
  final List<ProviderUsageWindowDto> windows;
  final int availableResets;
  final List<ProviderUsageResetCreditDto> resetCredits;
  final List<String> extraDetails;
  final String? unavailableReason;

  const ProviderUsageSnapshotDto({
    required this.providerInstanceId,
    required this.providerTemplateId,
    required this.source,
    required this.fetchedAt,
    this.planName,
    this.windows = const [],
    this.availableResets = 0,
    this.resetCredits = const [],
    this.extraDetails = const [],
    this.unavailableReason,
  });

  factory ProviderUsageSnapshotDto.fromJson(Map<String, dynamic> json) {
    return ProviderUsageSnapshotDto(
      providerInstanceId: json['provider_instance_id'] as String,
      providerTemplateId: json['provider_template_id'] as String,
      source: json['source'] as String,
      fetchedAt: DateTime.tryParse(json['fetched_at'] as String? ?? '') ?? DateTime.now(),
      planName: json['plan_name'] as String?,
      windows: (json['windows'] as List? ?? [])
          .map((w) => ProviderUsageWindowDto.fromJson(w as Map<String, dynamic>))
          .toList(),
      availableResets: (json['available_resets'] as num?)?.toInt() ?? 0,
      resetCredits: (json['reset_credits'] as List? ?? [])
          .whereType<Map<String, dynamic>>()
          .map(ProviderUsageResetCreditDto.fromJson)
          .toList(),
      extraDetails: (json['extra_details'] as List? ?? []).map((d) => d.toString()).toList(),
      unavailableReason: json['unavailable_reason'] as String?,
    );
  }
}

/// Typed result of a `provider.usage.get` command (Task 55 §3.4).
class ProviderUsageResultDto {
  /// One of: available | unsupported | unavailable | auth_required | failed.
  final String status;

  final ProviderUsageSnapshotDto? snapshot;
  final String? message;
  final String? requestId;
  final String? providerInstanceId;

  const ProviderUsageResultDto({
    required this.status,
    this.snapshot,
    this.message,
    this.requestId,
    this.providerInstanceId,
  });

  bool get isAvailable => status == 'available';
  bool get isUnsupported => status == 'unsupported';

  factory ProviderUsageResultDto.fromJson(Map<String, dynamic> json) {
    return ProviderUsageResultDto(
      status: json['status'] as String,
      message: json['message'] as String?,
      requestId: json['request_id'] as String?,
      providerInstanceId: json['provider_instance_id'] as String?,
      snapshot: json['snapshot'] is Map<String, dynamic>
          ? ProviderUsageSnapshotDto.fromJson(
              json['snapshot'] as Map<String, dynamic>,
            )
          : null,
    );
  }
}

/// Response for `provider.usage.support` (Task 55 §3.5).
class ProviderUsageSupportDto {
  final Map<String, bool> support;
  final String? requestId;

  const ProviderUsageSupportDto({
    required this.support,
    this.requestId,
  });

  /// Whether [instanceId] has a usage adapter registered on the daemon.
  bool supports(String instanceId) => support[instanceId] ?? false;

  factory ProviderUsageSupportDto.fromJson(Map<String, dynamic> json) {
    final raw = json['support'] as Map<String, dynamic>? ?? {};
    return ProviderUsageSupportDto(
      support: raw.map((k, v) => MapEntry(k, v == true)),
      requestId: json['request_id'] as String?,
    );
  }
}

class ProviderUsageResetResultDto {
  final String status;
  final String providerInstanceId;
  final String message;
  final int? availableResets;
  final ProviderUsageSnapshotDto? snapshot;
  final String? confirmationToken;
  final bool refreshFailed;

  const ProviderUsageResetResultDto({
    required this.status,
    required this.providerInstanceId,
    required this.message,
    this.availableResets,
    this.snapshot,
    this.confirmationToken,
    this.refreshFailed = false,
  });

  factory ProviderUsageResetResultDto.fromJson(Map<String, dynamic> json) => ProviderUsageResetResultDto(
    status: json['status']?.toString() ?? 'failed',
    providerInstanceId: json['provider_instance_id']?.toString() ?? '',
    message: json['message']?.toString() ?? 'Reset could not be completed.',
    availableResets: (json['available_resets'] as num?)?.toInt(),
    snapshot: json['snapshot'] is Map<String, dynamic>
        ? ProviderUsageSnapshotDto.fromJson(json['snapshot'] as Map<String, dynamic>)
        : null,
    confirmationToken: json['confirmation_token'] as String?,
    refreshFailed: json['refresh_failed'] == true,
  );
}
