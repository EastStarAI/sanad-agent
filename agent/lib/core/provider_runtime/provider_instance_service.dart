import 'package:uuid/uuid.dart';

import '../../engine/adapters/provider_profile.dart';
import '../../engine/adapters/provider_registry.dart';
import 'provider_endpoint_resolver.dart';
import 'provider_instance.dart';
import 'provider_model_id.dart';
import 'provider_instance_repository.dart';
import 'provider_protocol_constants.dart';

/// Creates, validates, renames, and deletes [`ProviderInstance`]
/// connections and drives draft/ready/default lifecycle (Plan 29 §8.1).
///
/// This is the single entry point for instance CRUD. It enforces:
/// - Stable UUID identity (`Uuid().v4()`), never derived from `displayName`.
/// - Case-insensitive display-name uniqueness within the runtime.
/// - Template existence (or the reserved `custom` id).
/// - `custom` instances require an explicit protocol + base URL at creation.
/// - `api_key_requirement=required` templates cannot reach `ready` without a
///   stored credential; `optional` templates may reach `ready` with only an
///   endpoint + model (Plan 29 §3.8, §8.1).
/// - At most one default instance (DB-level partial index + transactional set).
///
/// Secrets are never written or read here — credential handling lives in
/// `ProviderCredentialService` / `ProviderAuthSessionService`.
class ProviderInstanceService {
  final ProviderInstanceRepository _repo;
  final Uuid _uuid;

  ProviderInstanceService(this._repo, {Uuid? uuid})
    : _uuid = uuid ?? const Uuid();

  // ── Name suggestion ───────────────────────────────────────────────────

  /// Suggests a unique display name for a new instance of [template]. Returns
  /// `template.displayName` if free, otherwise `OpenAI 2`, `OpenAI 3`, …
  String suggestName(ProviderProfile template) {
    final base = template.displayName.isEmpty
        ? template.name
        : template.displayName;
    if (!_repo.isDisplayNameTaken(base)) return base;
    var n = 2;
    while (_repo.isDisplayNameTaken('$base $n')) {
      n++;
    }
    return '$base $n';
  }

  // ── Create ────────────────────────────────────────────────────────────

  /// Creates a draft instance. [authMethod] must be advertised by the selected
  /// template. The optional [baseUrl] override is stored here, while secrets
  /// are written separately through `ProviderCredentialService`. For `custom`,
  /// [protocol] and a non-empty [baseUrl] are required; for official
  /// templates [protocol] defaults to the template's protocol.
  ///
  /// [requestsPerMinute] remains accepted for protocol compatibility but is
  /// dormant: all new instances are stored as unlimited (`0`).
  ///
  /// Returns the created draft instance. Pass `makeDefault: true` to also mark
  /// it default (it becomes ready lazily after credential + model are set).
  ProviderInstance create({
    required String templateId,
    required String displayName,
    required String authMethod,
    String? protocol,
    String? baseUrl,
    String? defaultModel,
    int? requestsPerMinute,
    bool allowAutoFailover = true,
    bool makeDefault = false,
    DateTime? now,
  }) {
    final trimmed = displayName.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('Display name is required.');
    }
    if (!_isTemplateKnown(templateId)) {
      throw ArgumentError('Unknown provider template: $templateId');
    }
    if (_repo.isDisplayNameTaken(trimmed)) {
      throw ArgumentError('Display name "$trimmed" is already in use.');
    }
    final template = ProviderRegistry.findByNameOrAlias(templateId);
    final isCustom = templateId == kCustomProviderTemplateId;
    if (isCustom && (protocol == null || !ProviderProtocol.isValid(protocol))) {
      throw ArgumentError('Custom provider requires an explicit protocol.');
    }
    final effProtocol =
        protocol ??
        template?.effectiveProtocol ??
        ProviderProtocol.openaiCompatible;
    final allowedAuthMethods =
        template?.effectiveAuthMethods ?? const <String>[];
    if (!allowedAuthMethods.contains(authMethod)) {
      throw ArgumentError(
        'Auth method $authMethod is not supported by template $templateId.',
      );
    }
    if (isCustom && (baseUrl == null || baseUrl.trim().isEmpty)) {
      throw ArgumentError('Custom provider requires a base URL.');
    }
    final ts = now ?? DateTime.now();
    final normalizedDefaultModel = defaultModel == null || defaultModel.isEmpty
        ? defaultModel
        : ProviderModelId.normalize(
            templateId: templateId,
            protocol: effProtocol,
            rawModelId: defaultModel,
          );
    // Rate-limit storage remains protocol-compatible but is dormant. Existing
    // non-zero values are normalized by the database migration.
    const effRpm = 0;
    final instance = ProviderInstance(
      id: _uuid.v4(),
      templateId: templateId,
      displayName: trimmed,
      protocol: effProtocol,
      authMethod: authMethod,
      baseUrl: _normalizeBaseUrl(baseUrl) ?? template?.defaultBaseUrl,
      defaultModel: normalizedDefaultModel,
      status: InstanceStatus.draft,
      isDefault: false,
      configRevision: 1,
      credentialRevision: 1,
      requestsPerMinute: effRpm,
      allowAutoFailover: allowAutoFailover,
      createdAt: ts,
      updatedAt: ts,
    );
    _repo.createInstance(instance);
    if (makeDefault) {
      _repo.setDefault(instance.id);
    }
    return _repo.findById(instance.id)!;
  }

  // ── Rename ────────────────────────────────────────────────────────────

  /// Renames an instance. The UUID, credential, cache, sessions, and revisions
  /// are untouched (Plan 29 §3.7, §9.3 — rename never breaks routing).
  ProviderInstance rename(String id, String newName, {DateTime? now}) {
    final trimmed = newName.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('Display name is required.');
    }
    final existing = _repo.findById(id);
    if (existing == null) {
      throw StateError('Provider instance not found: $id');
    }
    if (_repo.isDisplayNameTaken(trimmed, excludeId: id)) {
      throw ArgumentError('Display name "$trimmed" is already in use.');
    }
    final renamed = existing.copyWith(
      displayName: trimmed,
      updatedAt: now ?? DateTime.now(),
    );
    _repo.update(renamed);
    return _repo.findById(id)!;
  }

  // ── Edit metadata (no credential) ────────────────────────────────────

  /// Updates non-credential fields: base URL, default model, protocol, and
  /// auto-failover flag. The legacy [requestsPerMinute] input remains accepted
  /// but is normalized to unlimited (`0`). Changing base URL or protocol bumps
  /// `configRevision` so the adapter cache and model cache are invalidated
  /// downstream (Plan 29 §3.15). Auto-failover edits do not bump revisions.
  /// Callers wanting to change the credential use `ProviderCredentialService`.
  ProviderInstance updateMetadata(
    String id, {
    String? baseUrl,
    String? defaultModel,
    String? protocol,
    int? requestsPerMinute,
    bool? allowAutoFailover,
    DateTime? now,
  }) {
    final existing = _repo.findById(id);
    if (existing == null) {
      throw StateError('Provider instance not found: $id');
    }
    final normalizedBaseUrl = baseUrl == null
        ? null
        : _normalizeBaseUrl(baseUrl);
    final changedConfig =
        (normalizedBaseUrl != null && normalizedBaseUrl != existing.baseUrl) ||
        (protocol != null && protocol != existing.protocol);
    final next = existing.copyWith(
      baseUrl: normalizedBaseUrl ?? existing.baseUrl,
      defaultModel: defaultModel == null
          ? existing.defaultModel
          : ProviderModelId.normalize(
              templateId: existing.templateId,
              protocol: protocol ?? existing.protocol,
              rawModelId: defaultModel,
            ),
      protocol: protocol ?? existing.protocol,
      status: changedConfig ? InstanceStatus.draft : existing.status,
      configRevision: changedConfig
          ? existing.configRevision + 1
          : existing.configRevision,
      requestsPerMinute: 0,
      allowAutoFailover: allowAutoFailover ?? existing.allowAutoFailover,
      updatedAt: now ?? DateTime.now(),
    );
    _repo.update(next);
    return _repo.findById(id)!;
  }

  // ── Status lifecycle ──────────────────────────────────────────────────

  /// Marks the instance ready (credential + endpoint + model resolved).
  void markReady(String id, {DateTime? now}) =>
      _setStatus(id, InstanceStatus.ready, now: now);

  /// Promotes the instance to `ready` ONLY when both the credential and the
  /// default model are resolved **and** a successful model-discovery snapshot
  /// exists for the current config/credential revisions. Otherwise it leaves
  /// the status unchanged (stays `draft` / `needs_auth`). Use this instead of
  /// [markReady] after a credential-only or model-only change so instances
  /// don't become `ready` before the endpoint is actually verified (Plan 29
  /// §7.2, criterion 25 / problem 7).
  void markReadyIfComplete(String id, {bool credentialConfigured = true}) {
    final existing = _repo.findById(id);
    if (existing == null) return;
    // A model must be selected before the instance can be usable.
    final hasModel =
        existing.defaultModel != null && existing.defaultModel!.isNotEmpty;
    final cache = _repo.readModelCache(id, 'models');
    final endpointVerified =
        cache != null &&
        cache['config_revision'] == existing.configRevision &&
        cache['credential_revision'] == existing.credentialRevision &&
        cache['last_error'] == null &&
        cache['models'] is List &&
        (cache['models'] as List).isNotEmpty;
    // Optional templates may proceed without a credential.
    final needsCred = requiresCredential(existing);
    final credOk = !needsCred || credentialConfigured;
    if (hasModel &&
        endpointVerified &&
        credOk &&
        existing.status != InstanceStatus.ready) {
      _setStatus(id, InstanceStatus.ready);
    }
  }

  /// Recomputes the visible lifecycle status after a metadata/credential edit
  /// invalidates or restores the current verification state. Required-key
  /// instances without a credential fall back to `needs_auth`; all other
  /// incomplete states fall back to `draft` until the current revisions are
  /// tested successfully again.
  void reconcileStatus(String id, {bool credentialConfigured = true}) {
    final existing = _repo.findById(id);
    if (existing == null) return;

    final needsCred = requiresCredential(existing);
    if (needsCred && !credentialConfigured) {
      if (existing.status != InstanceStatus.needsAuth) {
        _setStatus(id, InstanceStatus.needsAuth);
      }
      return;
    }

    final hasModel =
        existing.defaultModel != null && existing.defaultModel!.isNotEmpty;
    final cache = _repo.readModelCache(id, 'models');
    final endpointVerified =
        cache != null &&
        cache['config_revision'] == existing.configRevision &&
        cache['credential_revision'] == existing.credentialRevision &&
        cache['last_error'] == null &&
        cache['models'] is List &&
        (cache['models'] as List).isNotEmpty;

    if (hasModel && endpointVerified) {
      if (existing.status != InstanceStatus.ready) {
        _setStatus(id, InstanceStatus.ready);
      }
      return;
    }

    if (existing.status != InstanceStatus.draft) {
      _setStatus(id, InstanceStatus.draft);
    }
  }

  void markNeedsAuth(String id, {DateTime? now}) =>
      _setStatus(id, InstanceStatus.needsAuth, now: now);

  void markError(String id, {DateTime? now}) =>
      _setStatus(id, InstanceStatus.error, now: now);

  void _setStatus(String id, String status, {DateTime? now}) {
    final existing = _repo.findById(id);
    if (existing == null) {
      throw StateError('Provider instance not found: $id');
    }
    _repo.update(
      existing.copyWith(status: status, updatedAt: now ?? DateTime.now()),
    );
  }

  // ── Default ──────────────────────────────────────────────────────────

  void setDefault(String id) {
    final existing = _repo.findById(id);
    if (existing == null) {
      throw StateError('Provider instance not found: $id');
    }
    if (existing.status != InstanceStatus.ready) {
      throw StateError('Only ready provider instances can become default.');
    }
    _repo.setDefault(id);
  }

  void clearDefault() => _repo.clearDefault();

  ProviderInstance? findDefault() => _repo.findDefault();

  // ── Read helpers ──────────────────────────────────────────────────────

  ProviderInstance? findById(String id) => _repo.findById(id);
  List<ProviderInstance> findAll() => _repo.findAll();
  List<ProviderInstance> findByTemplate(String templateId) =>
      _repo.findByTemplate(templateId);

  // ── Delete ────────────────────────────────────────────────────────────

  /// Deletes an instance. The caller is expected to clear its secret via
  /// `ProviderCredentialService` first; the DB cascades cache + recent rows.
  /// If the deleted instance was the default, the default flag is cleared
  /// (callers may promote another instance or leave none).
  void delete(String id) {
    final wasDefault = _repo.findById(id)?.isDefault ?? false;
    _repo.delete(id);
    if (wasDefault) {
      _repo.clearDefault();
    }
  }

  /// Whether a credential is required for [instance] to be considered ready
  /// (mirrors `apiKeyRequirement` of its template). For `optional` templates
  /// without a stored key, readiness depends only on endpoint + model.
  bool requiresCredential(ProviderInstance instance) {
    final template = instance.template;
    return template != null && template.requiresApiKey;
  }

  /// Whether [templateId] is a registered template or the reserved `custom` id.
  static bool _isTemplateKnown(String templateId) {
    return templateId == kCustomProviderTemplateId ||
        ProviderRegistry.findByNameOrAlias(templateId) != null;
  }

  static String? _normalizeBaseUrl(String? baseUrl) {
    if (baseUrl == null) return null;
    final trimmed = baseUrl.trim();
    if (trimmed.isEmpty) return null;
    return ProviderEndpointResolver.parseHttpBaseUrl(trimmed).toString();
  }
}
