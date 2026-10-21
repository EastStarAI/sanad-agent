import '../../engine/adapters/provider_profile.dart';
import '../../engine/adapters/provider_registry.dart';
import 'provider_protocol_constants.dart';

/// A user-created connection to a provider (Plan 29 §7.2).
///
/// Unlike the immutable [ProviderProfile] (template), a `ProviderInstance` is
/// dynamic: it has a stable [id] (UUID), a user-editable [displayName], an
/// independent credential and default model, and lifecycle revisions. Multiple
/// instances may share the same `templateId` (e.g. `OpenAI Work` and
/// `OpenAI Personal`). The UUID is the permanent routing identity and is never
/// derived from the display name, so renaming never breaks routing, cache, or
/// sessions.
///
/// Instances hold metadata and revisions only — never secrets. Secrets live in
/// the `SecretStore`, keyed by [id].
class ProviderInstance {
  /// Stable UUID identifying this connection permanently.
  final String id;

  /// Template this instance was created from (a [ProviderProfile.name] or
  /// [kCustomProviderTemplateId]).
  final String templateId;

  /// User-chosen, editable display name (e.g. `OpenAI Work`). Must be unique
  /// case-insensitively within the runtime.
  final String displayName;

  /// Effective wire protocol. For official templates this mirrors the
  /// template's protocol; for `custom` it is chosen at creation time.
  final String protocol;

  /// Auth method the user actually used for this instance (one of
  /// [ProviderAuthMethod]). Drives the `Account` vs `API Key` badge.
  final String authMethod;

  /// Effective base URL. For official templates defaults to the template's
  /// base URL; always explicit for `custom`.
  final String? baseUrl;

  /// Default model selected for this instance.
  final String? defaultModel;

  /// Lifecycle status (one of [InstanceStatus]).
  final String status;

  /// Whether this is the runtime default instance. At most one instance may be
  /// default at a time.
  final bool isDefault;

  /// Increments whenever config that affects the adapter/cache (protocol, base
  /// URL, auth method) changes. Stale cache entries are invalidated by
  /// comparing revisions (Plan 29 §3.15, §10.3).
  final int configRevision;

  /// Increments whenever the credential is replaced. Used to invalidate cached
  /// adapters and model lists bound to an old credential.
  final int credentialRevision;

  /// Max requests per minute allowed for this instance (Plan 30 §6.1).
  /// `0` means unlimited. Defaults to the template's
  /// `ProviderProfile.defaultRequestsPerMinute` at creation time.
  final int requestsPerMinute;

  /// Whether this instance may be selected automatically during auto failover
  /// when another instance fails (Plan 30 §4.4, §6.1). Defaults to `true`.
  final bool allowAutoFailover;

  final DateTime createdAt;
  final DateTime updatedAt;

  /// Transient per-model route view (Task 120): the template re-pointed at one
  /// model's catalog-declared wire. Never persisted; `null` for stored rows.
  final ProviderProfile? routeTemplate;

  const ProviderInstance({
    required this.id,
    required this.templateId,
    required this.displayName,
    required this.protocol,
    required this.authMethod,
    this.baseUrl,
    this.defaultModel,
    this.status = InstanceStatus.draft,
    this.isDefault = false,
    this.configRevision = 1,
    this.credentialRevision = 1,
    this.requestsPerMinute = 0,
    this.allowAutoFailover = true,
    required this.createdAt,
    required this.updatedAt,
    this.routeTemplate,
  });

  /// Whether local rate limiting is active for this instance
  /// (`requestsPerMinute > 0`). `0` means unlimited (Plan 30 §6.1).
  bool get isRateLimited => requestsPerMinute > 0;

  /// Resolves the backing template. Returns null for unknown template ids
  /// (callers must fail closed — Plan 29 §3.10).
  ProviderProfile? get template =>
      routeTemplate ?? ProviderRegistry.findByNameOrAlias(templateId);

  /// Whether this instance was created from the reserved Custom template.
  bool get isCustom => templateId == kCustomProviderTemplateId;

  /// Effective base URL, falling back to the template default.
  String? get effectiveBaseUrl => baseUrl ?? template?.defaultBaseUrl;

  /// Convenience: does this instance classify under the `Account` badge?
  bool get isAccountBadge => ProviderAuthMethod.isAccountMethod(authMethod);

  ProviderInstance copyWith({
    String? displayName,
    String? protocol,
    String? authMethod,
    String? baseUrl,
    String? defaultModel,
    String? status,
    bool? isDefault,
    int? configRevision,
    int? credentialRevision,
    int? requestsPerMinute,
    bool? allowAutoFailover,
    DateTime? updatedAt,
  }) {
    return ProviderInstance(
      id: id,
      templateId: templateId,
      displayName: displayName ?? this.displayName,
      protocol: protocol ?? this.protocol,
      authMethod: authMethod ?? this.authMethod,
      baseUrl: baseUrl ?? this.baseUrl,
      defaultModel: defaultModel ?? this.defaultModel,
      status: status ?? this.status,
      isDefault: isDefault ?? this.isDefault,
      configRevision: configRevision ?? this.configRevision,
      credentialRevision: credentialRevision ?? this.credentialRevision,
      requestsPerMinute: requestsPerMinute ?? this.requestsPerMinute,
      allowAutoFailover: allowAutoFailover ?? this.allowAutoFailover,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      routeTemplate: routeTemplate,
    );
  }

  /// This instance viewed through [wireTemplate] for one model's route: the
  /// protocol, base URL and template follow the catalog-declared wire while
  /// identity and revisions stay unchanged (Task 120).
  ProviderInstance withRouteTemplate(ProviderProfile wireTemplate) =>
      ProviderInstance(
        id: id,
        templateId: templateId,
        displayName: displayName,
        protocol: wireTemplate.effectiveProtocol,
        authMethod: authMethod,
        baseUrl: wireTemplate.defaultBaseUrl,
        defaultModel: defaultModel,
        status: status,
        isDefault: isDefault,
        configRevision: configRevision,
        credentialRevision: credentialRevision,
        requestsPerMinute: requestsPerMinute,
        allowAutoFailover: allowAutoFailover,
        createdAt: createdAt,
        updatedAt: updatedAt,
        routeTemplate: wireTemplate,
      );

  /// Transport-safe map. Never includes secrets.
  Map<String, dynamic> toMap() => {
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
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
  };

  factory ProviderInstance.fromMap(Map<String, dynamic> map) {
    return ProviderInstance(
      id: map['id'] as String,
      templateId: map['template_id'] as String,
      displayName: map['display_name'] as String,
      protocol: map['protocol'] as String,
      authMethod: map['auth_method'] as String,
      baseUrl: map['base_url'] as String?,
      defaultModel: map['default_model'] as String?,
      status: map['status'] as String? ?? InstanceStatus.draft,
      isDefault: (map['is_default'] as bool?) ?? false,
      configRevision: (map['config_revision'] as num?)?.toInt() ?? 1,
      credentialRevision: (map['credential_revision'] as num?)?.toInt() ?? 1,
      requestsPerMinute: (map['requests_per_minute'] as num?)?.toInt() ?? 0,
      allowAutoFailover: (map['allow_auto_failover'] as bool?) ?? true,
      createdAt: DateTime.parse(map['created_at'] as String),
      updatedAt: DateTime.parse(map['updated_at'] as String),
    );
  }

  @override
  String toString() =>
      'ProviderInstance($id, template=$templateId, name=$displayName, '
      'protocol=$protocol, status=$status, default=$isDefault, '
      'rpm=$requestsPerMinute, autoFailover=$allowAutoFailover)';
}
