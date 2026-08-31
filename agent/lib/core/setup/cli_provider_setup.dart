// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'dart:io';

import 'package:sanad_agent/core/agent_runtime_service.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/core/provider_runtime/env_file_service.dart';
import 'package:sanad_agent/core/provider_runtime/model_options_service.dart';
import 'package:sanad_agent/core/provider_runtime/model_selection_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_auth_session_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_catalog_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_config_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_credential_store.dart';
import 'package:sanad_agent/core/provider_runtime/provider_credential_resolver.dart';
import 'package:sanad_agent/core/provider_runtime/provider_readiness_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_state_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_credential_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_model_cache_service.dart';
import 'package:sanad_agent/core/provider_runtime/secret_store.dart';
import 'package:sanad_agent/core/provider_runtime/secure_file_secret_store.dart';
import 'package:sanad_agent/core/provider_runtime/provider_protocol_constants.dart';
import 'package:sanad_agent/core/provider_runtime/recent_model_selection_service.dart';
import 'package:sanad_agent/core/provider_thinking/provider_thinking_di.dart';
import 'package:sanad_agent/engine/adapters/provider_registry.dart';
import 'package:sanad_agent/core/setup/setup_helpers.dart';
import 'package:sanad_agent/core/utils/terminal_prompts.dart';

/// Bundle of provider runtime services shared by the CLI wizard and
/// subcommands. Both the CLI and the Flutter onboarding consume the same
/// service classes, so they always see the same providers, state, and
/// storage (Plan 19 D3, Plan 29).
class CliProviderServices {
  final EnvFileService env;
  final ProviderCredentialStore credStore;
  final ProviderCatalogService catalog;
  final ProviderStateService state;
  final ProviderCredentialResolver resolver;
  final ProviderAuthSessionService auth;
  final ProviderConfigService config;
  final ProviderReadinessService readiness;
  final ModelOptionsService modelOptions;
  final ModelSelectionService modelSelection;
  final ProviderInstanceRepository instanceRepo;
  final ProviderInstanceService instanceService;
  final ProviderCredentialService credentialService;
  final ProviderModelCacheService modelCache;
  final RecentModelSelectionService recentSelection;
  final SecretStore secretStore;

  /// Builds the bundle sharing a single `EnvFileService` and
  /// `ProviderCredentialStore` across all derived services.
  factory CliProviderServices() {
    if (!getIt.isRegistered<AgentStateDatabase>()) {
      setupDI();
    }
    return CliProviderServices.from(
      env: getIt<EnvFileService>(),
      credStore: getIt<ProviderCredentialStore>(),
      catalog: getIt<ProviderCatalogService>(),
      state: getIt<ProviderStateService>(),
      resolver: getIt<ProviderCredentialResolver>(),
      auth: getIt<ProviderAuthSessionService>(),
      config: getIt<ProviderConfigService>(),
      readiness: getIt<ProviderReadinessService>(),
      modelOptions: getIt<ModelOptionsService>(),
      modelSelection: getIt<ModelSelectionService>(),
      instanceRepo: getIt<ProviderInstanceRepository>(),
      instanceService: getIt<ProviderInstanceService>(),
      credentialService: getIt<ProviderCredentialService>(),
      modelCache: getIt<ProviderModelCacheService>(),
      recentSelection: getIt<RecentModelSelectionService>(),
      secretStore: getIt<SecretStore>(),
    );
  }

  /// Build the bundle from explicitly-provided instances (used by tests).
  CliProviderServices.from({
    required this.env,
    required this.credStore,
    required this.catalog,
    required this.state,
    required this.resolver,
    required this.auth,
    required this.config,
    required this.readiness,
    required this.modelOptions,
    required this.modelSelection,
    ProviderInstanceRepository? instanceRepo,
    ProviderInstanceService? instanceService,
    ProviderCredentialService? credentialService,
    ProviderModelCacheService? modelCache,
    RecentModelSelectionService? recentSelection,
    SecretStore? secretStore,
  }) : instanceRepo = instanceRepo ?? ProviderInstanceRepository.inMemory(),
       instanceService =
           instanceService ??
           ProviderInstanceService(
             instanceRepo ?? ProviderInstanceRepository.inMemory(),
           ),
       credentialService =
           credentialService ??
           ProviderCredentialService(
             instanceRepo ?? ProviderInstanceRepository.inMemory(),
             secretStore ?? SecureFileSecretStore(),
           ),
       modelCache =
           modelCache ??
           ProviderModelCacheService(
             instanceRepo ?? ProviderInstanceRepository.inMemory(),
             getIt<AgentRuntimeService>(),
             buildDefaultThinkingCapabilityAssembler(),
           ),
       recentSelection =
           recentSelection ??
           RecentModelSelectionService(
             instanceRepo ?? ProviderInstanceRepository.inMemory(),
           ),
       secretStore = secretStore ?? SecureFileSecretStore();
}

/// Interactive CLI wizard built on top of the Plan 19 provider runtime
/// services. Replaces the legacy raw `.env` mutation and inline device-code
/// flow so the CLI and Flutter onboarding share one contract.
class CliProviderSetup {
  CliProviderSetup(this._s);

  final CliProviderServices _s;

  Future<void> runWizard() async {
    while (true) {
      final instances = _s.instanceService.findAll();
      final defaultInst = _s.instanceService.findDefault();

      print('\n=== AI Provider Instances ===');
      if (instances.isEmpty) {
        print('No provider instances configured yet.');
      } else {
        for (var i = 0; i < instances.length; i++) {
          final inst = instances[i];
          final suffix = inst.id == defaultInst?.id ? ' [DEFAULT]' : '';
          print(
            '  ${i + 1}. ${inst.displayName} (${inst.templateId}) - ${inst.status.toUpperCase()}$suffix',
          );
        }
      }
      print('');

      final options = [
        'Add a new provider instance',
        if (instances.isNotEmpty) 'Manage an existing instance',
        'Show readiness status',
        'Exit setup',
      ];

      final choice = selectInteractive('Options:', options);
      if (choice == 0) {
        await _runAddWizard();
      } else if (instances.isNotEmpty && choice == 1) {
        await _runManageWizard(instances);
      } else if ((instances.isEmpty && choice == 1) ||
          (instances.isNotEmpty && choice == 2)) {
        _printReadiness();
      } else {
        break;
      }
    }
  }

  Future<void> _runAddWizard() async {
    print('\n--- Add New Provider Instance ---');
    final profiles = _s.catalog.visibleProfiles;
    final options = [
      ...profiles.map((p) => p.displayName),
      'Custom API Endpoint',
    ];

    final selectedIdx = selectInteractive('Choose a template:', options);
    final isCustom = selectedIdx >= profiles.length;
    final templateId = isCustom ? 'custom' : profiles[selectedIdx].name;
    final profile = isCustom ? null : profiles[selectedIdx];

    final defaultName = profile != null
        ? _s.instanceService.suggestName(profile)
        : 'Custom Provider';
    stdout.write('Enter display name (default: $defaultName): ');
    final nameInput = stdin.readLineSync()?.trim();
    final displayName = (nameInput != null && nameInput.isNotEmpty)
        ? nameInput
        : defaultName;

    // Choose Auth method — only API Key and OAuth (device_code/loopback/external)
    final List<String> authMethods = profile == null
        ? const ['api_key']
        : ProviderAuthMethod.accountMethods.contains(profile.effectiveAuthFlow)
        ? [profile.effectiveAuthFlow, 'api_key']
        : const ['api_key'];

    final authChoice = selectInteractive(
      'Choose authentication method:',
      authMethods
          .map((m) => m == 'api_key' ? 'API Key' : 'OAuth Account')
          .toList(),
    );
    final String authMethod = authMethods[authChoice];

    String? protocol;
    if (isCustom) {
      final protoChoice = selectInteractive('Choose protocol:', [
        'OpenAI API Compatible',
        'Anthropic API Compatible',
      ]);
      protocol = protoChoice == 0
          ? ProviderProtocol.openaiCompatible
          : ProviderProtocol.anthropicCompatible;
    }

    final defaultUrl = profile?.defaultBaseUrl ?? '';
    String? baseUrl;
    if (isCustom || defaultUrl.isNotEmpty) {
      stdout.write('Enter base URL (default: $defaultUrl): ');
      final urlInput = stdin.readLineSync()?.trim();
      baseUrl = (urlInput != null && urlInput.isNotEmpty)
          ? urlInput
          : (defaultUrl.isNotEmpty ? defaultUrl : null);
    }

    // Create the draft instance!
    final inst = _s.instanceService.create(
      templateId: templateId,
      displayName: displayName,
      authMethod: authMethod,
      protocol: protocol,
      baseUrl: baseUrl,
      makeDefault: _s.instanceService
          .findAll()
          .isEmpty, // Make default if it's the first one
    );

    print('\n✓ Created draft instance "${inst.displayName}".');

    // Auth credential
    if (authMethod == 'api_key') {
      // For optional templates an empty key is valid (Plan 29 §7.1).
      final isOptional =
          profile?.apiKeyRequirement == ApiKeyRequirement.optional || isCustom;
      stdout.write(
        isOptional
            ? 'Enter API Key (optional, press Enter to skip): '
            : 'Enter API Key: ',
      );
      final keyInput = stdin.readLineSync()?.trim() ?? '';
      if (keyInput.isNotEmpty) {
        final apiKey = checkNonAsciiCredential('API_KEY', keyInput);
        await _s.credentialService.applyApiKeyEdit(
          inst.id,
          action: 'replace',
          newApiKey: apiKey,
        );
      } else if (!isOptional) {
        print('\n❌ API key is required for this provider.');
        return;
      } else {
        print('  (Proceeding without an API key — optional template.)');
      }
    } else if (ProviderAuthMethod.accountMethods.contains(authMethod)) {
      print('\nOAuth flow needed. Starting device authentication...');
      final oauthOk = await _runOAuthFlowForInstance(inst);
      if (!oauthOk) {
        print(
          '\n⚠ OAuth was not completed. Instance "${inst.displayName}" remains as draft.',
        );
        print('  You can reconnect later via the manage wizard.');
        return;
      }
    }

    // Prompt for default model
    final resolvedInst = _s.instanceService.findById(inst.id)!;
    final model = await _promptModelForInstance(resolvedInst);
    _s.instanceService.updateMetadata(inst.id, defaultModel: model);
    final configured = _s.credentialService.summary(inst.id).configured;
    _s.instanceService.markReadyIfComplete(
      inst.id,
      credentialConfigured: configured,
    );

    print('\n✓ Setup complete for "${inst.displayName}".');
  }

  Future<void> _runManageWizard(List<ProviderInstance> instances) async {
    final idx = selectInteractive(
      'Select instance to manage:',
      instances.map((i) => i.displayName).toList(),
    );
    final inst = instances[idx];

    while (true) {
      final fresh = _s.instanceService.findById(inst.id);
      if (fresh == null) break;

      final isDefault = fresh.isDefault;
      final summary = _s.credentialService.summary(fresh.id);

      print('\n--- Manage Instance: ${fresh.displayName} ---');
      print('  ID:          ${fresh.id}');
      print('  Template:    ${fresh.templateId}');
      print('  Protocol:    ${fresh.protocol}');
      print('  Auth Method: ${fresh.authMethod}');
      print('  Base URL:    ${fresh.baseUrl ?? "(default)"}');
      print('  Model:       ${fresh.defaultModel ?? "(none)"}');
      print('  Status:      ${fresh.status.toUpperCase()}');
      print('  Default:     ${isDefault ? "Yes" : "No"}');
      if (summary.configured) {
        print('  Secret:      ${summary.maskedKeyHint ?? "[Configured]"}');
      } else {
        print('  Secret:      [Not Configured]');
      }
      print('');

      final options = [
        if (!isDefault) 'Make Default',
        'Test Connection',
        'Rename Display Name',
        'Edit Base URL & Default Model',
        if (fresh.authMethod == 'api_key') 'Replace API Key',
        if (fresh.authMethod == 'api_key' && summary.configured)
          'Remove API Key',
        if (ProviderAuthMethod.accountMethods.contains(fresh.authMethod))
          'Reconnect (OAuth Sign-in)',
        if (ProviderAuthMethod.accountMethods.contains(fresh.authMethod))
          'Disconnect OAuth',
        'Show Cached Models',
        'Remove / Delete',
        'Back to main menu',
      ];

      final choice = selectInteractive('Choose action:', options);

      // Determine what was clicked
      final action = options[choice];
      if (action == 'Make Default') {
        _s.instanceService.setDefault(fresh.id);
        print('\n✓ "${fresh.displayName}" is now the default provider.');
      } else if (action == 'Test Connection') {
        try {
          final models = await _s.modelCache.refresh(fresh.id, manual: true);
          final configured = _s.credentialService.summary(fresh.id).configured;
          _s.instanceService.markReadyIfComplete(
            fresh.id,
            credentialConfigured: configured,
          );
          print(
            '\n✓ Connection test succeeded (${models.length} models found).',
          );
        } catch (e) {
          _s.instanceService.markError(fresh.id);
          print('\n❌ Connection test failed: $e');
        }
      } else if (action == 'Rename Display Name') {
        stdout.write('Enter new display name: ');
        final newName = stdin.readLineSync()?.trim() ?? '';
        if (newName.isNotEmpty) {
          try {
            _s.instanceService.rename(fresh.id, newName);
            print('\n✓ Renamed successfully.');
          } catch (e) {
            print('\n❌ Error: $e');
          }
        }
      } else if (action == 'Edit Base URL & Default Model') {
        stdout.write(
          'Enter new base URL (leave empty to keep current [${fresh.baseUrl}]): ',
        );
        final urlInput = stdin.readLineSync()?.trim();
        final baseUrl = (urlInput != null && urlInput.isNotEmpty)
            ? urlInput
            : fresh.baseUrl;

        stdout.write(
          'Enter default model (leave empty to keep current [${fresh.defaultModel}]): ',
        );
        final modelInput = stdin.readLineSync()?.trim();
        final defaultModel = (modelInput != null && modelInput.isNotEmpty)
            ? modelInput
            : fresh.defaultModel;

        _s.instanceService.updateMetadata(
          fresh.id,
          baseUrl: baseUrl,
          defaultModel: defaultModel,
        );
        final cred = _s.credentialService.summary(fresh.id);
        _s.instanceService.reconcileStatus(
          fresh.id,
          credentialConfigured: cred.configured,
        );
        print('\n✓ Metadata updated.');
      } else if (action == 'Replace API Key') {
        stdout.write('Enter new API Key (press Enter to keep current): ');
        final keyInput = stdin.readLineSync()?.trim() ?? '';
        if (keyInput.isNotEmpty) {
          final apiKey = checkNonAsciiCredential('API_KEY', keyInput);
          await _s.credentialService.applyApiKeyEdit(
            fresh.id,
            action: 'replace',
            newApiKey: apiKey,
          );
          _s.instanceService.reconcileStatus(
            fresh.id,
            credentialConfigured: true,
          );
          print('\n✓ API key updated.');
        } else {
          print('\nAPI key kept.');
        }
      } else if (action == 'Reconnect (OAuth Sign-in)') {
        await _runOAuthFlowForInstance(fresh);
      } else if (action == 'Disconnect OAuth') {
        final confirm = selectInteractive(
          'Disconnect OAuth for "${fresh.displayName}"?',
          ['No', 'Yes (Disconnect)'],
        );
        if (confirm == 1) {
          await _s.credentialService.disconnect(fresh.id);
          _s.instanceService.markNeedsAuth(fresh.id);
          print('\n✓ OAuth disconnected. You can reconnect later.');
        }
      } else if (action == 'Remove API Key') {
        final confirm = selectInteractive(
          'Remove the stored API key for "${fresh.displayName}"?',
          ['No', 'Yes (Remove)'],
        );
        if (confirm == 1) {
          await _s.credentialService.applyApiKeyEdit(
            fresh.id,
            action: 'remove',
          );
          final cred = _s.credentialService.summary(fresh.id);
          _s.instanceService.reconcileStatus(
            fresh.id,
            credentialConfigured: cred.configured,
          );
          print('\n✓ API key removed.');
        }
      } else if (action == 'Show Cached Models') {
        final cachedModels = _s.modelCache.snapshot(fresh.id);
        final cache = _s.instanceRepo.readModelCache(fresh.id, 'models');
        if (cache != null && cachedModels != null && cachedModels.isNotEmpty) {
          print(
            '\nCached models for "${fresh.displayName}" '
            '(fetched: ${cache['fetched_at'] ?? "unknown"}):',
          );
          for (final m in cachedModels) {
            print('  - ${m.value}');
          }
        } else {
          print(
            '\nNo cached models. Run "Test Connection" or refresh to fetch.',
          );
        }
      } else if (action == 'Remove / Delete') {
        final confirm = selectInteractive(
          'Are you sure you want to delete this instance?',
          ['No', 'Yes (Delete)'],
        );
        if (confirm == 1) {
          await _s.credentialService.applyApiKeyEdit(
            fresh.id,
            action: 'remove',
          );
          _s.instanceService.delete(fresh.id);
          print('\n✓ Instance "${fresh.displayName}" deleted.');
          break;
        }
      } else {
        break;
      }
    }
  }

  Future<String> _promptModelForInstance(ProviderInstance instance) async {
    final template = ProviderRegistry.findByNameOrAlias(instance.templateId);
    final fallbackModels = template?.fallbackModels ?? const <String>[];

    // Try live model discovery first (Plan 29 §13 / criterion 8). Uses the
    // instance's stored credential + base URL so the list reflects this
    // specific account. Falls back gracefully on failure.
    List<String> candidateModels = const [];
    try {
      final live = await _s.modelCache.refresh(instance.id, manual: true);
      candidateModels = live.map((m) => m.value).toList();
    } catch (_) {
      final cached = _s.modelCache.snapshot(instance.id);
      if (cached != null && cached.isNotEmpty) {
        candidateModels = cached.map((m) => m.value).toList();
      }
    }
    if (candidateModels.isEmpty) candidateModels = fallbackModels;

    final defaultModel =
        candidateModels.firstOrNull ??
        template?.fallbackModels.firstOrNull ??
        '';

    if (candidateModels.isEmpty) {
      stdout.write('Enter default model name: ');
      final input = stdin.readLineSync()?.trim() ?? '';
      return input.isNotEmpty ? input : 'gpt-4o';
    }

    final options = [
      ...candidateModels.map(
        (m) => '$m${m == defaultModel ? " (Recommended)" : ""}',
      ),
      'Custom model name (type manually)',
    ];
    final idx = selectInteractive('\nSelect default model:', options);
    if (idx < candidateModels.length) {
      final selected = candidateModels[idx];
      _s.recentSelection.selectModel(
        instanceId: instance.id,
        modelId: selected,
      );
      return selected;
    }
    stdout.write('Enter custom model name: ');
    final custom = stdin.readLineSync()?.trim();
    final selected = (custom != null && custom.isNotEmpty)
        ? custom
        : defaultModel;
    _s.recentSelection.selectModel(instanceId: instance.id, modelId: selected);
    return selected;
  }

  Future<bool> _runOAuthFlowForInstance(ProviderInstance instance) async {
    print('\nStarting OAuth Flow for "${instance.displayName}"...');
    try {
      final start = await _s.auth.startForInstance(
        instanceId: instance.id,
        templateId: instance.templateId,
        authMethod: instance.authMethod,
      );
      if (start.verificationUri != null) {
        print('\n  1. Open this URL in your browser:');
        print('     \x1B[94m${start.verificationUri}\x1B[0m');
      }
      if (start.userCode != null) {
        print('\n  2. Enter this code:');
        print('     \x1B[94m${start.userCode}\x1B[0m');
      }
      print('\nWaiting for authorization... (Ctrl+C to cancel)\n');

      final approved = await _pollAuth(start.sessionId, start.interval ?? 5);
      if (!approved) {
        print('\n❌ Authentication was not completed.');
        return false;
      }
      print('\n🔑 OAuth Sign-in successful!');
      return true;
    } catch (e) {
      print('\n❌ OAuth authentication failed: $e');
      return false;
    }
  }

  Future<bool> _pollAuth(String sessionId, int intervalSeconds) async {
    final interval = Duration(seconds: intervalSeconds.clamp(2, 30));
    while (true) {
      await Future.delayed(interval);
      stdout.write('.');
      final poll = await _s.auth.poll(sessionId);
      switch (poll.status) {
        case AuthSessionStatus.approved:
          print('');
          return true;
        case AuthSessionStatus.expired:
          print('\n❌ The code expired.');
          return false;
        case AuthSessionStatus.error:
          print('\n❌ ${poll.errorMessage ?? 'Authentication error.'}');
          return false;
        case AuthSessionStatus.cancelled:
          return false;
        case AuthSessionStatus.pending:
          continue;
      }
    }
  }

  void _printReadiness() {
    final defaultInst = _s.instanceService.findDefault();
    print('');
    if (defaultInst != null && defaultInst.status == InstanceStatus.ready) {
      print('┌─────────────────────────────────────────────────────────┐');
      print('│  ✓ Default Provider is ready. You can start chatting.   │');
      print('└─────────────────────────────────────────────────────────┘');
      print('  Active provider: ${defaultInst.displayName}');
      print('  Active model:     ${defaultInst.defaultModel ?? "(none)"}');
    } else {
      print('⚠️ No default provider instance is ready yet.');
    }
    print('\nDatabase: state.db');
    print('Secrets:  provider_secrets.json');
  }

  // ── Subcommands ────────────────────────────────────────────────────────

  /// `sanad setup list` — shows every supported provider and its state.
  void listProviders() {
    final instances = _s.instanceService.findAll();
    final defaultInst = _s.instanceService.findDefault();
    if (instances.isEmpty) {
      print('\nNo provider instances configured yet.');
      return;
    }

    print(
      '\nConfigured provider instances (default: ${defaultInst?.displayName ?? "(none)"}):\n',
    );
    for (final inst in instances) {
      final marker = inst.isDefault ? ' *' : '  ';
      print(
        '$marker${inst.displayName.padRight(20)} ${inst.templateId.padRight(16)} ${inst.status.toUpperCase()}',
      );
    }
    print('\n  * = default instance');

    final recent = _s.recentSelection.getRecentSelections();
    if (recent.isNotEmpty) {
      print('\nRecently selected models:');
      for (final r in recent) {
        final name = r['instance_display_name'] ?? r['instance_id'];
        print('  $name / ${r['model_id']}');
      }
    }
  }

  /// `sanad setup status` — shows readiness and current provider/model.
  void status() {
    final defaultInst = _s.instanceService.findDefault();
    final runtime = _s.readiness.runtimeCheck();
    print('\nProvider Setup Status:');
    print('  has_provider:    ${runtime.hasProvider}');
    print(
      '  active_provider: ${defaultInst?.displayName ?? runtime.activeProvider ?? "(none)"}',
    );
    print(
      '  active_model:    ${defaultInst?.defaultModel ?? runtime.activeModel ?? "(none)"}',
    );
    print('\nRuntime Check:');
    print('  runtime_ready:   ${runtime.runtimeReady}');
    if (runtime.reason != null) print('  reason:          ${runtime.reason}');
    print('');
  }

  /// `sanad setup remove <provider>` — removes a single provider's settings.
  Future<void> removeProvider(String providerId) async {
    final instances = _s.instanceService.findByTemplate(providerId);
    if (instances.isNotEmpty) {
      for (final inst in instances) {
        await _s.credentialService.applyApiKeyEdit(inst.id, action: 'remove');
        _s.instanceService.delete(inst.id);
      }
    }
    print('✓ Removed provider "$providerId" and its credentials.');
  }
}
