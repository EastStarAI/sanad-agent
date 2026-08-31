import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/provider_setup/data/models/auth_session_dto.dart';
import 'package:sanad_client/features/provider_setup/data/models/model_options_dto.dart';
import 'package:sanad_client/features/provider_setup/data/models/provider_dto.dart';
import 'package:sanad_client/features/provider_setup/data/models/provider_readiness_dto.dart';
import 'package:sanad_client/features/provider_setup/data/models/provider_template_dto.dart';
import 'package:sanad_client/features/provider_setup/data/models/provider_instance_dto.dart';
import 'package:sanad_client/features/provider_setup/data/provider_setup_client.dart';
import 'package:sanad_client/features/provider_setup/presentation/bloc/provider_setup_state.dart';

/// Controls the provider setup flow for multi-instance support and cache management.
class ProviderSetupCubit extends Cubit<ProviderSetupState> {
  static const _unverifiedApiKeyMessage =
      'The API key was saved, but its connection could not be verified. Check the key and try again.';

  ProviderSetupCubit({
    required ProviderSetupClient client,
    this.agent,
    this.showReadyState = true,
  }) : _client = client,
       super(const ProviderSetupState());

  final ProviderSetupClient _client;
  final DeviceConfig? agent;
  final bool showReadyState;
  Timer? _pollTimer;
  int _pollGeneration = 0;
  int? _activePollGeneration;
  int? _pollIntervalSeconds;
  int _modelDiscoveryGeneration = 0;
  String? _draftDisplayName;
  String? _draftBaseUrl;
  String? _draftApiKey;
  String? _draftProtocol;
  bool? _draftAllowAutoFailover;

  String? get draftDisplayName => _draftDisplayName;
  String? get draftBaseUrl => _draftBaseUrl;
  String? get draftApiKey => _draftApiKey;
  String? get draftProtocol => _draftProtocol;
  bool? get draftAllowAutoFailover => _draftAllowAutoFailover;

  void rememberDraft({
    required String displayName,
    required String protocol,
    required bool allowAutoFailover,
    String? baseUrl,
    String? apiKey,
  }) {
    _draftDisplayName = displayName;
    _draftBaseUrl = baseUrl;
    _draftApiKey = apiKey;
    _draftProtocol = protocol;
    _draftAllowAutoFailover = allowAutoFailover;
  }

  void _clearDraft() {
    _draftDisplayName = null;
    _draftBaseUrl = null;
    _draftApiKey = null;
    _draftProtocol = null;
    _draftAllowAutoFailover = null;
  }

  void clearError() {
    if (state.error != null) {
      emit(state.copyWith(error: null));
    }
  }

  /// Loads provider templates, instances, and current readiness.
  Future<void> load({bool forcePicker = false}) async {
    emit(
      state.copyWith(
        status: ProviderSetupStatus.loading,
        error: null,
        loadingMessage: 'Loading providers...',
      ),
    );
    try {
      final templates = await _client.listTemplates(agent: agent);
      final instances = await _client.listInstances(agent: agent);
      final readiness = await _client.runtimeCheck(agent: agent);
      final targetStatus = _targetStatusFor(
        instances: instances,
        readiness: readiness,
        forcePicker: forcePicker,
      );
      _emitSnapshot(
        templates: templates,
        instances: instances,
        readiness: readiness,
        status: targetStatus,
      );
    } catch (error) {
      emit(
        state.copyWith(
          status: ProviderSetupStatus.error,
          error: _friendlyError(error, 'Could not load providers.'),
        ),
      );
    }
  }

  Future<bool> checkReadiness() async {
    try {
      final readiness = await _client.runtimeCheck(agent: agent);
      emit(state.copyWith(readiness: readiness));
      return readiness.runtimeReady;
    } catch (_) {
      return false;
    }
  }

  void backToInstances() {
    _stopPolling();
    _modelDiscoveryGeneration++;
    emit(
      state.copyWith(
        status: ProviderSetupStatus.instancesList,
        selectedTemplate: null,
        selectedInstance: null,
        modelOptions: null,
        selectedModel: null,
        authSession: null,
        authPollStatus: null,
        testResult: null,
        error: null,
      ),
    );
  }

  void backToPicker() {
    _stopPolling();
    _modelDiscoveryGeneration++;
    _clearDraft();
    emit(
      state.copyWith(
        status: ProviderSetupStatus.picker,
        selectedTemplate: null,
        selectedInstance: null,
        provisionalInstanceId: null,
        modelOptions: null,
        selectedModel: null,
        authSession: null,
        authPollStatus: null,
        testResult: null,
        error: null,
      ),
    );
  }

  Future<void> backToProviderDetails() async {
    _stopPolling();
    _modelDiscoveryGeneration++;
    final sessionId = state.authSession?.sessionId;
    if (sessionId != null) {
      try {
        await _client.authCancel(sessionId: sessionId, agent: agent);
      } catch (_) {}
    }
    emit(
      state.copyWith(
        status: ProviderSetupStatus.instanceForm,
        modelOptions: null,
        selectedModel: null,
        authSession: null,
        authPollStatus: null,
        error: null,
      ),
    );
  }

  Future<void> discardProvisionalSetup() async {
    _stopPolling();
    _modelDiscoveryGeneration++;
    final sessionId = state.authSession?.sessionId;
    if (sessionId != null) {
      try {
        await _client.authCancel(sessionId: sessionId, agent: agent);
      } catch (_) {}
    }
    final provisionalId = state.provisionalInstanceId;
    if (provisionalId == null) {
      if (state.instances.isEmpty) {
        backToPicker();
      } else {
        backToInstances();
      }
      return;
    }
    try {
      await _client.removeInstance(
        providerInstanceId: provisionalId,
        agent: agent,
      );
      _clearDraft();
      await load();
    } catch (_) {
      _clearDraft();
      await load();
      emit(
        state.copyWith(
          status: ProviderSetupStatus.instancesList,
          error: 'Could not discard provider setup. Delete the incomplete provider and try again.',
        ),
      );
    }
  }

  void selectTemplate(ProviderTemplateDto template) {
    _clearDraft();
    emit(
      state.copyWith(
        status: ProviderSetupStatus.instanceForm,
        selectedTemplate: template,
        selectedInstance: null,
        provisionalInstanceId: null,
        error: null,
      ),
    );
  }

  void selectInstanceForEdit(ProviderInstanceDto instance) {
    _clearDraft();
    final template = state.templates.where((t) => t.name == instance.templateId).firstOrNull;
    emit(
      state.copyWith(
        status: ProviderSetupStatus.instanceForm,
        selectedTemplate: template,
        selectedInstance: instance,
        provisionalInstanceId: null,
        error: null,
      ),
    );
  }

  void resumeDraft(ProviderInstanceDto instance) {
    _clearDraft();
    final template = state.templates.where((candidate) => candidate.name == instance.templateId).firstOrNull;
    emit(
      state.copyWith(
        status: ProviderSetupStatus.instanceForm,
        selectedTemplate: template,
        selectedInstance: instance,
        provisionalInstanceId: instance.id,
        error: null,
      ),
    );
  }

  Future<void> saveApiKey({
    required String apiKey,
    String? baseUrl,
    String? model,
  }) async {
    final template = state.selectedTemplate;
    final instance = state.selectedInstance;
    emit(
      state.copyWith(
        status: ProviderSetupStatus.saving,
        error: null,
        loadingMessage: 'Saving API key...',
      ),
    );
    try {
      ProviderInstanceDto inst;
      if (instance != null) {
        inst = instance;
        if (baseUrl != null || model != null) {
          inst = await _client.updateInstance(
            providerInstanceId: inst.id,
            baseUrl: baseUrl,
            defaultModel: model,
            agent: agent,
          );
        }
      } else if (template != null) {
        inst = await _client.createInstance(
          templateId: template.name,
          displayName: template.displayName,
          authMethod: 'api_key',
          baseUrl: baseUrl,
          defaultModel: model,
          isDefault: true,
          agent: agent,
        );
      } else {
        throw StateError('No instance or template selected.');
      }

      // Only persist a non-empty key via replace. For optional templates the
      // user may proceed with an empty key — 'No API key' is a valid state
      // (Plan 29 §6.1, criterion 32). An empty replace is never sent.
      if (apiKey.trim().isNotEmpty) {
        await _client.updateCredential(
          providerInstanceId: inst.id,
          action: 'replace',
          apiKey: apiKey,
          agent: agent,
        );
      }
      emit(state.copyWith(selectedInstance: inst));
      await _enterModelSelection(inst);
    } catch (error) {
      emit(
        state.copyWith(
          status: ProviderSetupStatus.apiKey,
          error: _friendlyError(error, 'Could not save the API key.'),
        ),
      );
    }
  }

  Future<void> saveCustomEndpoint({
    required String protocol,
    required String baseUrl,
    required String model,
    String? apiKey,
  }) async {
    final template = state.selectedTemplate;
    emit(
      state.copyWith(
        status: ProviderSetupStatus.saving,
        error: null,
        loadingMessage: 'Saving custom endpoint...',
      ),
    );
    try {
      final inst = await _client.createInstance(
        templateId: template?.name ?? 'custom',
        displayName: template?.displayName ?? 'Custom Endpoint',
        authMethod: 'api_key',
        protocol: protocol,
        baseUrl: baseUrl,
        defaultModel: model,
        isDefault: true,
        agent: agent,
      );
      if (apiKey != null) {
        await _client.updateCredential(
          providerInstanceId: inst.id,
          action: 'replace',
          apiKey: apiKey,
          agent: agent,
        );
      }
      emit(state.copyWith(selectedInstance: inst));
      await _finishSetup();
    } catch (error) {
      emit(
        state.copyWith(
          status: ProviderSetupStatus.customEndpoint,
          error: _friendlyError(error, 'Could not save the custom endpoint.'),
        ),
      );
    }
  }

  // ── Instance CRUD Actions ──────────────────────────────────────────────

  Future<void> createOrUpdateInstance({
    required String displayName,
    required String authMethod,
    String? protocol,
    String? baseUrl,
    String? defaultModel,
    bool? allowAutoFailover,
    bool isDefault = false,
    String? credentialAction,
    String? newApiKey,
  }) async {
    final selected = state.selectedInstance;
    final wasEditingExisting = selected != null && state.provisionalInstanceId != selected.id;
    final isResumingProvisional = selected != null && state.provisionalInstanceId == selected.id;
    emit(
      state.copyWith(
        operation: ProviderSetupOperation.savingDetails,
        error: null,
        loadingMessage: 'Saving provider details...',
      ),
    );

    try {
      // The first instance created during onboarding must become the default
      // automatically; otherwise readiness fails with "no default provider
      // instance is set" and the user is stuck on the providers page
      // (Plan 29 §7.2 / criterion 25). Subsequent instances are not default.
      final shouldMakeDefault = !wasEditingExisting && !isResumingProvisional && state.instances.isEmpty;
      final createdNew = selected == null;
      ProviderInstanceDto instance;
      if (selected != null) {
        instance = await _client.updateInstance(
          providerInstanceId: selected.id,
          displayName: displayName,
          baseUrl: wasEditingExisting ? null : baseUrl,
          protocol: wasEditingExisting ? null : protocol,
          defaultModel: wasEditingExisting ? null : defaultModel,
          allowAutoFailover: allowAutoFailover,
          agent: agent,
        );
      } else {
        final template = state.selectedTemplate;
        if (template == null) {
          throw StateError('No template selected for instance creation.');
        }
        instance = await _client.createInstance(
          templateId: template.name,
          displayName: displayName,
          authMethod: authMethod,
          protocol: protocol,
          baseUrl: baseUrl,
          defaultModel: defaultModel,
          allowAutoFailover: allowAutoFailover,
          isDefault: isDefault || shouldMakeDefault,
          agent: agent,
        );
      }

      emit(
        state.copyWith(
          selectedInstance: instance,
          provisionalInstanceId: createdNew ? instance.id : state.provisionalInstanceId,
        ),
      );

      if (!wasEditingExisting && authMethod == 'api_key' && newApiKey?.trim().isNotEmpty == true) {
        await _client.updateCredential(
          providerInstanceId: instance.id,
          action: 'replace',
          apiKey: newApiKey!.trim(),
          agent: agent,
        );
      }

      // Existing credentials change only after an explicit edit action.
      if (wasEditingExisting && credentialAction != null && credentialAction != 'keep') {
        await _client.updateCredential(
          providerInstanceId: instance.id,
          action: credentialAction,
          apiKey: credentialAction == 'replace' ? newApiKey : null,
          agent: agent,
        );
        // Replacing a credential invalidates the model verification associated
        // with the previous credential revision. Complete the canonical
        // connection test before reporting a successful edit so a valid new
        // key does not leave the provider stranded in draft.
        if (credentialAction == 'replace') {
          emit(state.copyWith(loadingMessage: 'Verifying API key...'));
          final result = await _client.testInstanceConnection(
            providerInstanceId: instance.id,
            agent: agent,
          );
          if (result['success'] != true) {
            throw ArgumentError(_unverifiedApiKeyMessage);
          }
        }

        // Reload the authoritative lifecycle after the credential mutation and
        // its optional verification. A transport-level successful test is not
        // enough if the daemon still reports an incomplete revision.
        instance = await _client.updateInstance(
          providerInstanceId: instance.id,
          agent: agent,
        );
        emit(state.copyWith(selectedInstance: instance));
        if (credentialAction == 'replace' && instance.status != 'ready') {
          throw ArgumentError(_unverifiedApiKeyMessage);
        }
      }

      if (authMethod == 'api_key') {
        if (wasEditingExisting) {
          _clearDraft();
          await _refreshInstances(
            feedback: {instance.id: 'Changes saved.'},
          );
        } else {
          await _enterModelSelection(instance);
        }
      } else if (authMethod == 'external' || authMethod == 'device_code' || authMethod == 'loopback') {
        if (wasEditingExisting) {
          _clearDraft();
          await _refreshInstances(
            feedback: {instance.id: 'Changes saved.'},
          );
        } else {
          await startOAuthAuth(
            providerInstanceId: instance.id,
            templateId: instance.templateId,
            authMethod: authMethod,
          );
        }
      } else {
        await _enterModelSelection(instance);
      }
    } catch (e) {
      emit(
        state.copyWith(
          status: ProviderSetupStatus.instanceForm,
          operation: null,
          loadingMessage: null,
          error: _friendlyError(e, 'Could not save provider details.'),
        ),
      );
    }
  }

  Future<void> testInstance(String instanceId) async {
    if (state.instanceOperations.containsKey(instanceId)) return;
    _setInstanceOperation(instanceId, 'Testing...');
    try {
      final result = await _client.testInstanceConnection(
        providerInstanceId: instanceId,
        agent: agent,
      );
      final success = result['success'] == true;
      _finishInstanceOperation(
        instanceId,
        success ? 'Connection test passed.' : (result['message']?.toString() ?? 'Connection test failed.'),
      );
    } catch (error) {
      _finishInstanceOperation(
        instanceId,
        _friendlyError(error, 'Connection test failed.'),
      );
    }
  }

  Future<void> removeInstance(String instanceId) async {
    if (state.instanceOperations.containsKey(instanceId)) return;
    _setInstanceOperation(instanceId, 'Deleting...');
    try {
      await _client.removeInstance(
        providerInstanceId: instanceId,
        agent: agent,
      );
      await _refreshInstances(feedback: const {});
    } catch (error) {
      _finishInstanceOperation(
        instanceId,
        _friendlyError(error, 'Could not delete this provider.'),
      );
    }
  }

  Future<void> setInstanceDefault(String instanceId) async {
    if (state.instanceOperations.containsKey(instanceId)) return;
    _setInstanceOperation(instanceId, 'Setting default...');
    try {
      await _client.setInstanceDefault(
        providerInstanceId: instanceId,
        agent: agent,
      );
      await _refreshInstances(
        feedback: {instanceId: 'Default provider updated.'},
      );
    } catch (error) {
      _finishInstanceOperation(
        instanceId,
        _friendlyError(error, 'Could not change the default provider.'),
      );
    }
  }

  void _setInstanceOperation(String instanceId, String label) {
    emit(
      state.copyWith(
        instanceOperations: {...state.instanceOperations, instanceId: label},
        instanceFeedback: {...state.instanceFeedback}..remove(instanceId),
        error: null,
      ),
    );
  }

  void _finishInstanceOperation(String instanceId, String feedback) {
    final operations = {...state.instanceOperations}..remove(instanceId);
    emit(
      state.copyWith(
        instanceOperations: operations,
        instanceFeedback: {...state.instanceFeedback, instanceId: feedback},
      ),
    );
  }

  Future<void> _refreshInstances({
    required Map<String, String> feedback,
  }) async {
    final templates = await _client.listTemplates(agent: agent);
    final instances = await _client.listInstances(agent: agent);
    final readiness = await _client.runtimeCheck(agent: agent);
    final mappedProviders = _mapProviders(templates, instances);
    emit(
      state.copyWith(
        status: ProviderSetupStatus.instancesList,
        templates: templates,
        instances: instances,
        providers: mappedProviders,
        activeProvider: readiness.activeProvider,
        activeModel: readiness.activeModel,
        readiness: readiness,
        selectedTemplate: null,
        selectedInstance: null,
        provisionalInstanceId: null,
        operation: null,
        loadingMessage: null,
        instanceOperations: const {},
        instanceFeedback: feedback,
        error: null,
      ),
    );
  }

  // ── OAuth Login Actions ────────────────────────────────────────────────

  Future<void> reconnectInstance(ProviderInstanceDto instance) async {
    emit(
      state.copyWith(
        status: instance.authMethod == 'loopback' ? ProviderSetupStatus.loopback : ProviderSetupStatus.deviceCode,
        selectedInstance: instance,
        provisionalInstanceId: null,
        authSession: null,
        authPollStatus: null,
        error: null,
        verificationLaunchAttempted: false,
        verificationPageOpened: false,
        verificationLaunchError: null,
      ),
    );
    try {
      final session = await _client.authReconnect(
        providerInstanceId: instance.id,
        agent: agent,
      );
      emit(state.copyWith(authSession: session));
      if (!session.hasError) {
        _startPolling(session.interval ?? 5);
      }
    } catch (error) {
      emit(
        state.copyWith(
          error: _friendlyError(error, 'Could not start account sign-in.'),
        ),
      );
    }
  }

  Future<void> startOAuthAuth({
    required String templateId,
    required String authMethod,
    String? providerInstanceId,
  }) async {
    emit(
      state.copyWith(
        status: authMethod == 'loopback' ? ProviderSetupStatus.loopback : ProviderSetupStatus.deviceCode,
        error: null,
        loadingMessage: 'Starting sign-in...',
        verificationLaunchAttempted: false,
        verificationPageOpened: false,
        verificationLaunchError: null,
      ),
    );
    try {
      final session = await _client.authStart(
        providerId: templateId,
        providerInstanceId: providerInstanceId,
        templateId: templateId,
        authMethod: authMethod,
        agent: agent,
      );
      if (session.hasError) {
        emit(
          state.copyWith(
            error: 'Could not start account sign-in.',
            authSession: session,
            loadingMessage: null,
          ),
        );
        return;
      }
      emit(state.copyWith(authSession: session, loadingMessage: null));
      _startPolling(session.interval ?? 5);
    } catch (error) {
      emit(
        state.copyWith(
          error: _friendlyError(error, 'Could not start account sign-in.'),
          loadingMessage: null,
        ),
      );
    }
  }

  Future<void> pollOnce() async {
    final session = state.authSession;
    final sessionId = session?.sessionId;
    if (sessionId == null) return;
    final generation = _pollGeneration;
    if (_activePollGeneration == generation) return;
    _activePollGeneration = generation;
    try {
      final poll = await _client.authPoll(
        sessionId: sessionId,
        agent: agent,
      );
      if (!_isCurrentAuthFlow(generation, sessionId)) return;
      emit(state.copyWith(authPollStatus: poll.status));
      if (poll.status == AuthPollStatus.pending && poll.interval != null) {
        _retunePolling(poll.interval!);
      }
      if (poll.status == AuthPollStatus.approved && poll.authenticated) {
        _stopPolling();
        final instance = state.selectedInstance;
        if (instance != null) {
          final refreshed = await _client.updateInstance(
            providerInstanceId: instance.id,
            agent: agent,
          );
          if (isClosed || state.authSession?.sessionId != sessionId) return;
          emit(state.copyWith(selectedInstance: refreshed));
          await _enterModelSelection(refreshed);
        } else {
          await load();
        }
      } else if (poll.status == AuthPollStatus.expired ||
          poll.status == AuthPollStatus.error ||
          poll.status == AuthPollStatus.cancelled) {
        _stopPolling();
        if (poll.error != null) {
          emit(state.copyWith(error: _friendlyError(poll.error!, 'Authentication failed.')));
        }
      }
    } catch (error) {
      if (_isCurrentAuthFlow(generation, sessionId)) {
        emit(state.copyWith(error: _friendlyError(error, 'Could not check authentication status.')));
      }
    } finally {
      if (_activePollGeneration == generation) {
        _activePollGeneration = null;
      }
    }
  }

  bool _isCurrentAuthFlow(int generation, String sessionId) {
    return !isClosed && _pollGeneration == generation && state.authSession?.sessionId == sessionId;
  }

  void recordVerificationLaunch({
    required String? sessionId,
    required bool opened,
    String? error,
  }) {
    if (isClosed || state.authSession?.sessionId != sessionId) return;
    emit(
      state.copyWith(
        verificationLaunchAttempted: true,
        verificationPageOpened: opened,
        verificationLaunchError: opened ? null : (error ?? 'Could not open the verification page.'),
      ),
    );
  }

  Future<void> cancelAuth() async {
    _stopPolling();
    final session = state.authSession;
    if (session != null && session.sessionId != null) {
      try {
        await _client.authCancel(sessionId: session.sessionId!, agent: agent);
      } catch (_) {}
    }
    if (state.provisionalInstanceId != null) {
      await discardProvisionalSetup();
      return;
    }
    emit(
      state.copyWith(
        status: state.instances.isEmpty ? ProviderSetupStatus.picker : ProviderSetupStatus.instancesList,
        authSession: null,
        authPollStatus: null,
        error: null,
      ),
    );
  }

  void _startPolling(int intervalSeconds) {
    _stopPolling();
    final clamped = intervalSeconds.clamp(1, 30);
    _pollIntervalSeconds = clamped;
    _pollTimer = Timer.periodic(Duration(seconds: clamped), (_) => pollOnce());
  }

  /// Applies RFC 8628 `slow_down` without cancelling the current auth generation.
  void _retunePolling(int intervalSeconds) {
    final clamped = intervalSeconds.clamp(1, 30);
    if (_pollTimer == null || _pollIntervalSeconds == clamped) return;
    _pollTimer?.cancel();
    _pollTimer = null;
    _pollIntervalSeconds = clamped;
    _pollTimer = Timer.periodic(Duration(seconds: clamped), (_) => pollOnce());
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _pollIntervalSeconds = null;
    _pollGeneration++;
    _activePollGeneration = null;
  }

  // ── Model Selection & Caching ──────────────────────────────────────────

  Future<void> _enterModelSelection(ProviderInstanceDto instance) async {
    final generation = ++_modelDiscoveryGeneration;
    emit(
      state.copyWith(
        status: ProviderSetupStatus.modelSelection,
        selectedInstance: instance,
        modelDiscoveryStatus: ModelDiscoveryStatus.loading,
        modelDiscoveryError: null,
        operation: null,
        loadingMessage: null,
        error: null,
      ),
    );
    try {
      await _client.modelRefresh(
        providerInstanceId: instance.id,
        manual: false,
        agent: agent,
      );
      if (!_isCurrentModelDiscovery(generation, instance.id)) return;
      final snapshot = await _client.modelSnapshot(agent: agent);
      if (!_isCurrentModelDiscovery(generation, instance.id)) return;
      final cachedInstance = snapshot.instances.where((candidate) => candidate.id == instance.id).firstOrNull;
      final modelIds = cachedInstance?.models.map((model) => model.id).toList() ?? const <String>[];
      if (cachedInstance == null || modelIds.isEmpty) {
        throw StateError('No models were returned by the provider.');
      }
      final recommended = cachedInstance.defaultModel ?? instance.defaultModel ?? modelIds.first;
      emit(
        state.copyWith(
          status: ProviderSetupStatus.modelSelection,
          modelOptions: ModelOptionsDto(
            providerId: instance.templateId,
            models: modelIds,
            selectedModel: recommended,
            authenticated: true,
            authType: instance.authMethod,
            keyEnv: null,
            source: 'live',
          ),
          selectedModel: recommended,
          modelDiscoveryStatus: ModelDiscoveryStatus.loaded,
          modelDiscoveryError: null,
        ),
      );
    } catch (error) {
      if (!_isCurrentModelDiscovery(generation, instance.id)) return;
      final suggestions = state.selectedTemplate?.fallbackModels ?? const <String>[];
      emit(
        state.copyWith(
          status: ProviderSetupStatus.modelSelection,
          modelOptions: ModelOptionsDto(
            providerId: instance.templateId,
            models: suggestions,
            selectedModel: null,
            authenticated: true,
            authType: instance.authMethod,
            keyEnv: null,
            source: 'cached_suggestions',
          ),
          selectedModel: null,
          modelDiscoveryStatus: ModelDiscoveryStatus.failed,
          modelDiscoveryError: _friendlyError(
            error,
            'Could not load models from this provider.',
          ),
          error: null,
        ),
      );
    }
  }

  bool _isCurrentModelDiscovery(int generation, String instanceId) {
    return !isClosed &&
        _modelDiscoveryGeneration == generation &&
        state.status == ProviderSetupStatus.modelSelection &&
        state.selectedInstance?.id == instanceId;
  }

  void selectModel(String model) {
    emit(state.copyWith(selectedModel: model, error: null));
  }

  void startManualModelEntry() {
    emit(
      state.copyWith(
        modelDiscoveryStatus: ModelDiscoveryStatus.manual,
        selectedModel: null,
        error: null,
      ),
    );
  }

  Future<void> refreshModels() async {
    final instance = state.selectedInstance;
    if (instance == null || state.modelDiscoveryStatus == ModelDiscoveryStatus.loading) {
      return;
    }
    await _enterModelSelection(instance);
  }

  Future<void> changeSelectedInstanceModel() async {
    final instance = state.selectedInstance;
    if (instance == null) return;
    await _enterModelSelection(instance);
  }

  Future<void> confirmModel() async {
    final instance = state.selectedInstance;
    final model = state.selectedModel?.trim();
    if (instance == null || model == null || model.isEmpty) {
      emit(state.copyWith(error: 'Enter or select a model first.'));
      return;
    }
    emit(
      state.copyWith(
        operation: ProviderSetupOperation.savingModel,
        error: null,
        loadingMessage: 'Saving default model...',
      ),
    );
    try {
      await _client.updateInstance(
        providerInstanceId: instance.id,
        defaultModel: model,
        agent: agent,
      );
      await _client.modelRecentRecord(
        providerInstanceId: instance.id,
        modelId: model,
        agent: agent,
      );
      emit(state.copyWith(operation: null, loadingMessage: null));
      await _finishSetup();
    } catch (error) {
      emit(
        state.copyWith(
          status: ProviderSetupStatus.modelSelection,
          operation: null,
          loadingMessage: null,
          selectedModel: model,
          error: _friendlyError(error, 'Could not save the default model.'),
        ),
      );
    }
  }

  Future<void> _finishSetup() async {
    emit(
      state.copyWith(
        operation: ProviderSetupOperation.savingModel,
        loadingMessage: 'Verifying provider...',
      ),
    );
    try {
      final readiness = await _client.runtimeCheck(agent: agent);
      final templates = await _client.listTemplates(agent: agent);
      final instances = await _client.listInstances(agent: agent);
      _emitSnapshot(
        templates: templates,
        instances: instances,
        readiness: readiness,
        status: readiness.runtimeReady && showReadyState
            ? ProviderSetupStatus.ready
            : ProviderSetupStatus.instancesList,
        error: readiness.runtimeReady ? null : (readiness.reason ?? 'Default provider is not ready.'),
      );
    } catch (error) {
      emit(
        state.copyWith(
          status: ProviderSetupStatus.modelSelection,
          operation: null,
          loadingMessage: null,
          error: _friendlyError(error, 'Could not verify this provider.'),
        ),
      );
    }
  }

  @override
  Future<void> close() async {
    _stopPolling();
    return super.close();
  }

  ProviderSetupStatus _targetStatusFor({
    required List<ProviderInstanceDto> instances,
    required ProviderReadinessDto readiness,
    required bool forcePicker,
  }) {
    if (instances.isEmpty || forcePicker) {
      return ProviderSetupStatus.picker;
    }
    if (readiness.runtimeReady && showReadyState) {
      return ProviderSetupStatus.ready;
    }
    return ProviderSetupStatus.instancesList;
  }

  List<ProviderDto> _mapProviders(
    List<ProviderTemplateDto> templates,
    List<ProviderInstanceDto> instances,
  ) {
    return templates.map((template) {
      final configuredInstance = instances.where((instance) => instance.templateId == template.name).firstOrNull;
      return ProviderDto(
        id: template.name,
        name: template.name,
        displayName: template.displayName,
        description: template.description,
        defaultBaseUrl: template.defaultBaseUrl,
        keyEnv: template.keyEnv,
        envModelName: template.envModelName,
        envBaseUrlName: template.envBaseUrlName,
        authType: template.authType,
        authFlow: template.authFlow,
        apiMode: template.apiMode,
        docsUrl: template.docsUrl,
        supportsModelFetch: template.supportsModelFetch,
        disconnectable: template.disconnectable,
        fallbackModels: template.fallbackModels,
        aliases: template.aliases,
        configured: configuredInstance != null,
        authenticated: configuredInstance?.status == 'ready',
        isCurrent: configuredInstance?.isDefault ?? false,
        models: configuredInstance?.defaultModel != null ? [configuredInstance!.defaultModel!] : const [],
        selectedModel: configuredInstance?.defaultModel,
        authStatus: configuredInstance?.status ?? 'missing',
      );
    }).toList();
  }

  String _friendlyError(Object error, String fallback) {
    if (error is ArgumentError) {
      return error.message?.toString() ?? fallback;
    }
    return fallback;
  }

  void _emitSnapshot({
    required List<ProviderTemplateDto> templates,
    required List<ProviderInstanceDto> instances,
    required ProviderReadinessDto readiness,
    required ProviderSetupStatus status,
    String? error,
  }) {
    _clearDraft();
    final mappedProviders = _mapProviders(templates, instances);

    emit(
      state.copyWith(
        status: status,
        templates: templates,
        instances: instances,
        providers: mappedProviders,
        activeProvider: readiness.activeProvider,
        activeModel: readiness.activeModel,
        readiness: readiness,
        selectedTemplate: null,
        selectedInstance: null,
        provisionalInstanceId: null,
        authSession: null,
        authPollStatus: null,
        operation: null,
        loadingMessage: null,
        modelDiscoveryStatus: ModelDiscoveryStatus.idle,
        modelDiscoveryError: null,
        error: error,
      ),
    );
  }
}
