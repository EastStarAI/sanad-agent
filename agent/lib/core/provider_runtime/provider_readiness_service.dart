import 'package:sanad_agent/core/provider_runtime/provider_discovery_error.dart';
import 'package:sanad_agent/core/provider_runtime/provider_discovery_projection.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance.dart';
import 'package:sanad_agent/core/provider_runtime/secret_store.dart';
import 'package:sanad_agent/core/provider_runtime/provider_protocol_constants.dart';

/// Lightweight readiness result returned by `setup_status` / `runtime_check`.
class ProviderReadiness {
  /// Whether any provider is configured at all.
  final bool hasProvider;

  /// Whether the runtime can resolve a usable credential + model right now.
  final bool runtimeReady;

  /// Active provider instance id (UUID).
  final String? activeProvider;

  /// Active model name, if any.
  final String? activeModel;

  /// Why the runtime is not ready, when [runtimeReady] is false.
  final String? reason;

  /// Sanitized cause of the last failed model discovery for the instance this
  /// readiness verdict is about, when it is the reason the instance is not
  /// ready (issue 339).
  final ProviderDiscoveryError? discoveryError;

  ProviderReadiness({
    required this.hasProvider,
    required this.runtimeReady,
    this.activeProvider,
    this.activeModel,
    this.reason,
    this.discoveryError,
  });

  Map<String, dynamic> toMap() => {
    'has_provider': hasProvider,
    'runtime_ready': runtimeReady,
    if (activeProvider != null) 'active_provider': activeProvider,
    if (activeModel != null) 'active_model': activeModel,
    if (reason != null) 'reason': reason,
    if (discoveryError != null) 'discovery_error': discoveryError!.toMap(),
  };
}

/// Implements the readiness gate using the Plan 29 provider instance model.
///
/// `setupStatus` checks metadata and model via [ProviderInstanceRepository].
/// `runtimeCheck` additionally resolves credentials through [SecretStore] to
/// catch expired OAuth tokens and missing API keys.
class ProviderReadinessService {
  final ProviderInstanceRepository _repo;
  final SecretStore _secretStore;

  ProviderReadinessService(this._repo, this._secretStore);

  /// The default instance only. Never silently selects the first row when no
  /// default is set — fail-closed so readiness surfaces the missing default
  /// explicitly (Plan 29 §3.10, criterion 24/25).
  ProviderInstance? _resolveInstance() {
    return _repo.findDefault();
  }

  /// Storage-only readiness: checks for a default or any instance with
  /// a resolved model and basic credential check.
  ProviderReadiness setupStatus() {
    final defaultInst = _resolveInstance();
    if (defaultInst == null) {
      return ProviderReadiness(
        hasProvider: false,
        runtimeReady: false,
        reason: 'No provider instance is configured.',
      );
    }
    final model = defaultInst.defaultModel;
    if (model == null || model.trim().isEmpty) {
      return ProviderReadiness(
        hasProvider: true,
        runtimeReady: false,
        activeProvider: defaultInst.id,
        reason: 'No model is selected for the active provider.',
      );
    }
    final summary = _secretStore.summary(defaultInst.id);
    if (defaultInst.status == InstanceStatus.needsAuth ||
        summary.status == 'relogin_required') {
      return ProviderReadiness(
        hasProvider: true,
        runtimeReady: false,
        activeProvider: defaultInst.id,
        activeModel: model,
        reason: summary.accountLabel != null
            ? 'Sign in required for ${summary.accountLabel}.'
            : 'Credential missing or expired.',
      );
    }
    return ProviderReadiness(
      hasProvider: true,
      runtimeReady: defaultInst.status == InstanceStatus.ready,
      activeProvider: defaultInst.id,
      activeModel: model,
      reason: defaultInst.status != InstanceStatus.ready
          ? _incompleteReason(defaultInst)
          : null,
      discoveryError: defaultInst.status != InstanceStatus.ready
          ? _discoveryErrorOf(defaultInst)
          : null,
    );
  }

  /// Why a stored-but-not-ready instance is not ready. A failed model discovery
  /// names its own sanitized cause instead of exposing the bare status name
  /// (issue 339), so a rejected credential is distinguishable from an instance
  /// that was never configured.
  String _incompleteReason(ProviderInstance instance) =>
      _discoveryErrorOf(instance)?.summary ??
      'Instance status: ${instance.status}';

  ProviderDiscoveryError? _discoveryErrorOf(ProviderInstance instance) =>
      ProviderDiscoveryProjection.of(_repo, instance).error;

  /// Deeper runtime check that resolves credentials via SecretStore.
  ProviderReadiness runtimeCheck() {
    final setup = setupStatus();
    if (!setup.hasProvider || !setup.runtimeReady) return setup;

    final inst = _repo.findById(setup.activeProvider ?? '');
    if (inst == null) {
      return ProviderReadiness(
        hasProvider: false,
        runtimeReady: false,
        reason: 'Provider instance not found.',
      );
    }

    final summary = _secretStore.summary(inst.id);
    final apiKeyRequired = _isApiKeyRequired(inst);
    if (apiKeyRequired && !summary.configured) {
      return ProviderReadiness(
        hasProvider: true,
        runtimeReady: false,
        activeProvider: inst.id,
        activeModel: setup.activeModel,
        reason: 'API key is required but not configured.',
      );
    }
    if (summary.reloginRequired) {
      return ProviderReadiness(
        hasProvider: true,
        runtimeReady: false,
        activeProvider: inst.id,
        activeModel: setup.activeModel,
        reason: 'Sign in required for the active provider.',
      );
    }
    if (inst.status != InstanceStatus.ready) {
      return ProviderReadiness(
        hasProvider: true,
        runtimeReady: false,
        activeProvider: inst.id,
        activeModel: setup.activeModel,
        reason: _incompleteReason(inst),
        discoveryError: _discoveryErrorOf(inst),
      );
    }
    return ProviderReadiness(
      hasProvider: true,
      runtimeReady: true,
      activeProvider: inst.id,
      activeModel: setup.activeModel,
    );
  }

  bool _isApiKeyRequired(ProviderInstance inst) {
    final template = inst.template;
    if (template == null) return inst.authMethod == ProviderAuthMethod.apiKey;
    return template.apiKeyRequirement == ApiKeyRequirement.required;
  }
}
