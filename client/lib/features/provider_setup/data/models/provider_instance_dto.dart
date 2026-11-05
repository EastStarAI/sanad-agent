import 'credential_summary_dto.dart';
import 'provider_discovery_error_dto.dart';

class ProviderInstanceDto {
  final String id;
  final String templateId;
  final String displayName;
  final String protocol;
  final String authMethod;
  final String? baseUrl;
  final String? defaultModel;
  final String status;
  final bool isDefault;
  final int configRevision;
  final int credentialRevision;

  /// Plan 30: max requests per minute for this instance. 0 = unlimited.
  final int requestsPerMinute;

  /// Plan 30: whether this instance may be used automatically during failover.
  final bool allowAutoFailover;
  final CredentialSummaryDto? credential;

  /// Sanitized cause of the last failed model discovery (issue 339).
  final ProviderDiscoveryErrorDto? discoveryError;

  /// Where this instance's cached model list came from.
  final ProviderModelCacheDto? modelCache;

  const ProviderInstanceDto({
    required this.id,
    required this.templateId,
    required this.displayName,
    required this.protocol,
    required this.authMethod,
    this.baseUrl,
    this.defaultModel,
    required this.status,
    required this.isDefault,
    required this.configRevision,
    required this.credentialRevision,
    this.requestsPerMinute = 0,
    this.allowAutoFailover = true,
    this.credential,
    this.discoveryError,
    this.modelCache,
  });

  factory ProviderInstanceDto.fromJson(Map<String, dynamic> json) {
    return ProviderInstanceDto(
      id: (json['id'] ?? '').toString(),
      templateId: (json['template_id'] ?? '').toString(),
      displayName: (json['display_name'] ?? '').toString(),
      protocol: (json['protocol'] ?? '').toString(),
      authMethod: (json['auth_method'] ?? '').toString(),
      baseUrl: json['base_url']?.toString(),
      defaultModel: json['default_model']?.toString(),
      status: (json['status'] ?? '').toString(),
      isDefault: (json['is_default'] as bool?) ?? false,
      configRevision: (json['config_revision'] as int?) ?? 1,
      credentialRevision: (json['credential_revision'] as int?) ?? 1,
      requestsPerMinute: (json['requests_per_minute'] as num?)?.toInt() ?? 0,
      allowAutoFailover: (json['allow_auto_failover'] as bool?) ?? true,
      credential: json['credential'] != null
          ? CredentialSummaryDto.fromJson(json['credential'] as Map<String, dynamic>)
          : null,
      discoveryError: ProviderDiscoveryErrorDto.fromJson(json['discovery_error']),
      modelCache: ProviderModelCacheDto.fromJson(json['model_cache']),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'template_id': templateId,
    'display_name': displayName,
    'protocol': protocol,
    'auth_method': authMethod,
    if (baseUrl != null) 'base_url': baseUrl,
    if (defaultModel != null) 'default_model': defaultModel,
    'status': status,
    'is_default': isDefault,
    'config_revision': configRevision,
    'credential_revision': credentialRevision,
    'requests_per_minute': requestsPerMinute,
    'allow_auto_failover': allowAutoFailover,
    if (credential != null) 'credential': credential!.toJson(),
    if (discoveryError != null) 'discovery_error': discoveryError!.toJson(),
    if (modelCache != null) 'model_cache': modelCache!.toJson(),
  };
}
