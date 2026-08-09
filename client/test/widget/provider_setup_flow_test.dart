import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:sanad_client/core/di/injection.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/model_picker_dialog.dart';
import 'package:sanad_client/features/provider_setup/data/models/auth_session_dto.dart';
import 'package:sanad_client/features/provider_setup/data/models/model_options_dto.dart';
import 'package:sanad_client/features/provider_setup/data/models/provider_dto.dart';
import 'package:sanad_client/features/provider_setup/data/models/provider_readiness_dto.dart';
import 'package:sanad_client/features/provider_setup/data/models/provider_template_dto.dart';
import 'package:sanad_client/features/provider_setup/data/models/provider_usage_dto.dart';
import 'package:sanad_client/features/provider_setup/data/models/provider_instance_dto.dart';
import 'package:sanad_client/features/provider_setup/data/models/credential_summary_dto.dart';
import 'package:sanad_client/features/provider_setup/data/models/model_cache_snapshot_dto.dart';
import 'package:sanad_client/features/provider_setup/data/provider_setup_client.dart';
import 'package:sanad_client/features/provider_setup/presentation/bloc/provider_setup_cubit.dart';
import 'package:sanad_client/features/provider_setup/presentation/widgets/provider_instance_form_view.dart';
import 'package:sanad_client/features/provider_setup/presentation/widgets/provider_picker_view.dart';
import 'package:sanad_client/features/provider_setup/presentation/widgets/provider_setup_flow.dart';
import 'package:toastification/toastification.dart';

class _FakeClient extends ProviderSetupClient {
  _FakeClient({
    this.providers = const [],
    this.instances = const [],
    this.runtimeReady = false,
    this.modelOptionsResult,
    this.modelRefreshError,
  });

  final List<ProviderDto> providers;
  final List<ProviderInstanceDto> instances;
  bool runtimeReady;
  final ModelOptionsDto? modelOptionsResult;
  final Object? modelRefreshError;
  Completer<void>? usageSupportGate;
  final List<String> usageGetCalls = [];
  final List<String?> usageDeviceCalls = [];

  @override
  Future<ProviderReadinessDto> setupStatus({DeviceConfig? agent}) async => ProviderReadinessDto(
    hasProvider: runtimeReady,
    runtimeReady: runtimeReady,
    activeProvider: runtimeReady ? 'inst-1' : null,
    activeModel: runtimeReady ? modelOptionsResult?.selectedModel : null,
  );

  @override
  Future<ProviderReadinessDto> runtimeCheck({DeviceConfig? agent}) async => ProviderReadinessDto(
    hasProvider: runtimeReady,
    runtimeReady: runtimeReady,
    activeProvider: runtimeReady ? 'inst-1' : null,
    activeModel: runtimeReady ? modelOptionsResult?.selectedModel : null,
  );

  @override
  Future<AuthSessionDto> authStart({
    required String providerId,
    String? providerInstanceId,
    String? templateId,
    String? authMethod,
    DeviceConfig? agent,
  }) async => const AuthSessionDto(
    sessionId: 's1',
    flow: 'deviceCode',
    userCode: 'ABCD-1234',
    verificationUri: 'https://example.com/device',
  );

  @override
  Future<AuthPollDto> authPoll({
    required String sessionId,
    DeviceConfig? agent,
  }) async => const AuthPollDto(status: AuthPollStatus.pending);

  @override
  Future<AuthPollDto> authSubmit({
    required String sessionId,
    required String code,
    DeviceConfig? agent,
  }) async => const AuthPollDto(status: AuthPollStatus.pending);

  @override
  Future<void> authCancel({
    required String sessionId,
    DeviceConfig? agent,
  }) async {}

  @override
  Future<String> authStatus({
    required String providerId,
    String? providerInstanceId,
    DeviceConfig? agent,
  }) async => 'missing';

  @override
  Future<List<ModelOptionsDto>> modelOptions({
    String? providerId,
    bool fetchLive = false,
    DeviceConfig? agent,
  }) async => [if (modelOptionsResult != null) modelOptionsResult!];

  @override
  Future<List<ProviderTemplateDto>> listTemplates({DeviceConfig? agent}) async {
    return providers
        .map(
          (p) => ProviderTemplateDto(
            name: p.id,
            displayName: p.displayName,
            description: p.description,
            defaultBaseUrl: p.defaultBaseUrl,
            keyEnv: p.keyEnv,
            envModelName: p.envModelName,
            envBaseUrlName: p.envBaseUrlName,
            authType: p.authType,
            authFlow: p.authFlow,
            apiMode: p.apiMode,
            docsUrl: p.docsUrl,
            supportsModelFetch: p.supportsModelFetch,
            disconnectable: p.disconnectable,
            fallbackModels: p.fallbackModels,
            aliases: p.aliases,
            authMethods: _authMethodsForFlow(p.authFlow),
          ),
        )
        .toList();
  }

  @override
  Future<List<ProviderInstanceDto>> listInstances({
    DeviceConfig? agent,
  }) async => instances;

  @override
  Future<ProviderInstanceDto> createInstance({
    required String templateId,
    required String displayName,
    required String authMethod,
    String? protocol,
    String? baseUrl,
    String? defaultModel,
    int? requestsPerMinute,
    bool? allowAutoFailover,
    bool isDefault = false,
    DeviceConfig? agent,
  }) async {
    return ProviderInstanceDto(
      id: 'inst-1',
      templateId: templateId,
      displayName: displayName,
      protocol: protocol ?? 'openai',
      authMethod: authMethod,
      baseUrl: baseUrl,
      defaultModel: defaultModel,
      status: 'ready',
      isDefault: isDefault,
      configRevision: 1,
      credentialRevision: 1,
      requestsPerMinute: requestsPerMinute ?? 0,
      allowAutoFailover: allowAutoFailover ?? true,
    );
  }

  @override
  Future<ProviderInstanceDto> updateInstance({
    required String providerInstanceId,
    String? displayName,
    String? defaultModel,
    String? baseUrl,
    String? protocol,
    int? requestsPerMinute,
    bool? allowAutoFailover,
    DeviceConfig? agent,
  }) async {
    return ProviderInstanceDto(
      id: providerInstanceId,
      templateId: 'openai',
      displayName: displayName ?? 'OpenAI',
      protocol: protocol ?? 'openai',
      authMethod: 'api_key',
      baseUrl: baseUrl,
      defaultModel: defaultModel,
      status: 'ready',
      isDefault: true,
      configRevision: 2,
      credentialRevision: 1,
      requestsPerMinute: requestsPerMinute ?? 0,
      allowAutoFailover: allowAutoFailover ?? true,
    );
  }

  @override
  Future<ProviderInstanceDto> renameInstance({
    required String providerInstanceId,
    required String displayName,
    DeviceConfig? agent,
  }) async {
    return ProviderInstanceDto(
      id: providerInstanceId,
      templateId: 'openai',
      displayName: displayName,
      protocol: 'openai',
      authMethod: 'api_key',
      status: 'ready',
      isDefault: true,
      configRevision: 2,
      credentialRevision: 1,
    );
  }

  @override
  Future<void> removeInstance({
    required String providerInstanceId,
    DeviceConfig? agent,
  }) async {}

  @override
  Future<void> setInstanceDefault({
    required String providerInstanceId,
    DeviceConfig? agent,
  }) async {}

  @override
  Future<Map<String, dynamic>> testInstanceConnection({
    required String providerInstanceId,
    DeviceConfig? agent,
  }) async => const {};

  @override
  Future<CredentialSummaryDto> updateCredential({
    required String providerInstanceId,
    required String action,
    String? apiKey,
    DeviceConfig? agent,
  }) async {
    return const CredentialSummaryDto(
      authMethod: 'api_key',
      hasSecret: true,
      status: 'ready',
    );
  }

  @override
  Future<AuthSessionDto> authReconnect({
    required String providerInstanceId,
    DeviceConfig? agent,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<void> authDisconnect({
    required String providerInstanceId,
    DeviceConfig? agent,
  }) async {}

  @override
  Future<ModelCacheSnapshotDto> modelSnapshot({DeviceConfig? agent}) async {
    if (modelOptionsResult != null) {
      return ModelCacheSnapshotDto(
        instances: [
          ModelCacheInstanceDto(
            id: 'inst-1',
            displayName: 'OpenAI',
            defaultModel: modelOptionsResult!.selectedModel,
            status: runtimeReady ? 'ready' : 'draft',
            isDefault: true,
            cacheStatus: 'ready',
            models: modelOptionsResult!.models.map((m) => ModelCacheModelDto(id: m)).toList(),
          ),
        ],
        recent: const [],
      );
    }
    return const ModelCacheSnapshotDto(instances: [], recent: []);
  }

  @override
  Future<void> modelRefresh({
    required String providerInstanceId,
    bool manual = false,
    DeviceConfig? agent,
  }) async {
    if (modelRefreshError case final error?) throw error;
  }

  @override
  Future<List<RecentModelDto>> modelRecentList({DeviceConfig? agent}) async => const [];

  @override
  Future<void> modelRecentRecord({
    required String providerInstanceId,
    required String modelId,
    DeviceConfig? agent,
  }) async {}

  @override
  Future<ProviderUsageSupportDto> usageSupport({
    required List<String> providerInstanceIds,
    DeviceConfig? agent,
  }) async {
    await usageSupportGate?.future;
    return ProviderUsageSupportDto(
      support: {for (final id in providerInstanceIds) id: true},
    );
  }

  @override
  Future<ProviderUsageResultDto> usageGet({
    required String providerInstanceId,
    DeviceConfig? agent,
  }) async {
    usageGetCalls.add(providerInstanceId);
    usageDeviceCalls.add(agent?.id);
    return ProviderUsageResultDto(
      status: 'available',
      providerInstanceId: providerInstanceId,
      snapshot: ProviderUsageSnapshotDto(
        providerInstanceId: providerInstanceId,
        providerTemplateId: 'openai-codex',
        source: 'test',
        fetchedAt: DateTime.now().toUtc(),
        windows: const [
          ProviderUsageWindowDto(
            type: 'weekly',
            label: 'Weekly',
            usedPercent: 42,
          ),
        ],
      ),
    );
  }

  List<String> _authMethodsForFlow(String flow) {
    switch (flow) {
      case 'device_code':
      case 'external':
      case 'loopback':
        return [flow, 'api_key'];
      case 'custom_endpoint':
        return const ['api_key'];
      default:
        return const ['api_key'];
    }
  }
}

ProviderDto _provider({
  String id = 'openai',
  String displayName = 'OpenAI',
  String flow = 'api_key',
  List<String> models = const ['gpt-4o', 'gpt-4o-mini'],
  bool configured = false,
  bool authenticated = false,
}) {
  return ProviderDto(
    id: id,
    name: id,
    displayName: displayName,
    description: '$displayName provider',
    authType: 'api_key',
    authFlow: flow,
    apiMode: 'chat_completions',
    supportsModelFetch: false,
    disconnectable: true,
    fallbackModels: models,
    aliases: const [],
    configured: configured,
    authenticated: authenticated,
    isCurrent: false,
    models: models,
    authStatus: 'missing',
  );
}

Widget _wrap(Widget child) => ToastificationWrapper(
  child: MaterialApp(home: Scaffold(body: child)),
);

Widget _wrapInBoundedOverlay(Widget child) => MaterialApp(
  home: Scaffold(
    body: Center(
      child: SizedBox(
        width: 760,
        height: 420,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('Provider setup required'),
              const SizedBox(height: 20),
              Expanded(child: child),
            ],
          ),
        ),
      ),
    ),
  ),
);

Widget _wrapInSettingsScroll(Widget child) => MaterialApp(
  home: Scaffold(
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: child,
    ),
  ),
);

void main() {
  setUp(() async {
    await getIt.reset();
  });

  tearDown(() async {
    await getIt.reset();
  });

  testWidgets(
    'onboarding gate: connected agent without ready provider shows provider picker',
    (tester) async {
      final fake = _FakeClient(
        providers: [
          _provider(),
          _provider(
            id: 'anthropic',
            displayName: 'Anthropic',
            models: const ['claude-3'],
          ),
        ],
        runtimeReady: false,
      );
      await tester.pumpWidget(_wrap(ProviderSetupFlow(client: fake)));
      await tester.pumpAndSettle();

      // The picker must be shown, not the chat/home screen.
      expect(find.byType(ProviderPickerView), findsOneWidget);
      expect(find.text('Choose your AI provider'), findsOneWidget);
      expect(find.text('OpenAI'), findsOneWidget);
      expect(find.text('Anthropic'), findsOneWidget);
    },
  );

  testWidgets(
    'selected device without configured providers shows the provider picker',
    (tester) async {
      final fake = _FakeClient(
        providers: [
          _provider(),
          _provider(
            id: 'anthropic',
            displayName: 'Anthropic',
            models: const ['claude-3'],
          ),
        ],
        runtimeReady: false,
      );
      final device = DeviceConfig(
        id: 'remote-1',
        name: 'Remote Mac',
        token: 'token',
      );

      await tester.pumpWidget(
        _wrap(ProviderSetupFlow(client: fake, device: device)),
      );
      await tester.pumpAndSettle();

      expect(find.byType(ProviderPickerView), findsOneWidget);
      expect(find.text('Choose your AI provider'), findsOneWidget);
      expect(find.text('Configured Providers'), findsNothing);
      expect(find.text('OpenAI'), findsOneWidget);
      expect(find.text('Anthropic'), findsOneWidget);
    },
  );

  testWidgets(
    'settings flow with configured providers opens the configured providers list first',
    (tester) async {
      final fake = _FakeClient(
        providers: [_provider(configured: true)],
        instances: [
          ProviderInstanceDto(
            id: 'inst-1',
            templateId: 'openai',
            displayName: 'OpenAI Work',
            protocol: 'openai_compatible',
            authMethod: 'api_key',
            status: 'draft',
            isDefault: true,
            configRevision: 1,
            credentialRevision: 1,
          ),
        ],
        runtimeReady: false,
      );

      await tester.pumpWidget(_wrap(ProviderSetupFlow(client: fake)));
      await tester.pumpAndSettle();

      expect(find.text('Configured Providers'), findsOneWidget);
      expect(find.text('Choose your AI provider'), findsNothing);
      expect(find.text('OpenAI Work'), findsOneWidget);
    },
  );

  testWidgets(
    'configured provider cards render before usage capability and snapshot finish',
    (tester) async {
      final supportGate = Completer<void>();
      final fake = _FakeClient(
        providers: [_provider(configured: true)],
        instances: const [
          ProviderInstanceDto(
            id: 'inst-usage',
            templateId: 'openai-codex',
            displayName: 'ChatGPT Work',
            protocol: 'openai_responses',
            authMethod: 'device_code',
            status: 'ready',
            isDefault: true,
            configRevision: 1,
            credentialRevision: 1,
          ),
        ],
        runtimeReady: true,
      )..usageSupportGate = supportGate;

      await tester.pumpWidget(
        _wrap(ProviderSetupFlow(client: fake, showReadyState: false)),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('Configured Providers'), findsOneWidget);
      expect(find.text('ChatGPT Work'), findsOneWidget);
      expect(find.text('Usage & limits'), findsNothing);
      expect(fake.usageGetCalls, isEmpty);

      supportGate.complete();
      await tester.pumpAndSettle();

      expect(find.text('Usage & limits'), findsOneWidget);
      expect(fake.usageGetCalls, ['inst-usage']);
    },
  );

  testWidgets(
    'switching the target device recreates usage ownership for the new device',
    (tester) async {
      final fake = _FakeClient(
        providers: [_provider(configured: true)],
        instances: const [
          ProviderInstanceDto(
            id: 'inst-shared-id',
            templateId: 'openai-codex',
            displayName: 'ChatGPT Work',
            protocol: 'openai_responses',
            authMethod: 'device_code',
            status: 'ready',
            isDefault: true,
            configRevision: 1,
            credentialRevision: 1,
          ),
        ],
        runtimeReady: true,
      );
      final first = DeviceConfig(id: 'device-a', name: 'A');
      final second = DeviceConfig(id: 'device-b', name: 'B');

      await tester.pumpWidget(
        _wrap(
          ProviderSetupFlow(client: fake, device: first, showReadyState: false),
        ),
      );
      await tester.pumpAndSettle();
      expect(fake.usageDeviceCalls, ['device-a']);

      await tester.pumpWidget(
        _wrap(
          ProviderSetupFlow(
            client: fake,
            device: second,
            showReadyState: false,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(fake.usageDeviceCalls, ['device-a', 'device-b']);
      expect(find.text('ChatGPT Work'), findsOneWidget);
    },
  );

  testWidgets(
    'management flow keeps configured providers visible even when runtime is already ready',
    (tester) async {
      final fake = _FakeClient(
        providers: [_provider(configured: true)],
        instances: [
          ProviderInstanceDto(
            id: 'inst-1',
            templateId: 'openai',
            displayName: 'OpenAI Work',
            protocol: 'openai_compatible',
            authMethod: 'api_key',
            status: 'ready',
            isDefault: true,
            configRevision: 1,
            credentialRevision: 1,
          ),
        ],
        runtimeReady: true,
      );

      await tester.pumpWidget(
        _wrap(ProviderSetupFlow(client: fake, showReadyState: false)),
      );
      await tester.pumpAndSettle();

      expect(find.text('Configured Providers'), findsOneWidget);
      expect(find.text('Provider is ready'), findsNothing);
      expect(find.text('OpenAI Work'), findsOneWidget);
    },
  );

  testWidgets(
    'ready callback fires when the terminal ready screen is disabled',
    (tester) async {
      final fake = _FakeClient(
        providers: [_provider(configured: true)],
        instances: const [
          ProviderInstanceDto(
            id: 'inst-1',
            templateId: 'openai',
            displayName: 'OpenAI Work',
            protocol: 'openai_compatible',
            authMethod: 'api_key',
            defaultModel: 'gpt-4o',
            status: 'ready',
            isDefault: true,
            configRevision: 1,
            credentialRevision: 1,
          ),
        ],
        runtimeReady: true,
        modelOptionsResult: const ModelOptionsDto(
          providerId: 'inst-1',
          models: ['gpt-4o'],
          selectedModel: 'gpt-4o',
          authenticated: true,
          authType: 'api_key',
          source: 'cache',
        ),
      );
      ProviderReadinessDto? ready;

      await tester.pumpWidget(
        _wrap(
          ProviderSetupFlow(
            client: fake,
            showReadyState: false,
            onReady: (value) => ready = value,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(ready?.activeProvider, 'inst-1');
      expect(ready?.activeModel, 'gpt-4o');
      expect(find.text('Provider is ready'), findsNothing);
    },
  );

  testWidgets('selecting a provider opens the instance form first', (
    tester,
  ) async {
    final fake = _FakeClient(providers: [_provider()], runtimeReady: false);
    await tester.pumpWidget(_wrap(ProviderSetupFlow(client: fake)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('OpenAI'));
    await tester.pumpAndSettle();

    expect(find.byType(ProviderInstanceFormView), findsOneWidget);
    expect(find.text('Display Name'), findsOneWidget);
    expect(find.text('Authentication Method'), findsNothing);
    expect(
      find.text('Rate Limit (Requests per minute, 0 for unlimited)'),
      findsNothing,
    );
  });

  testWidgets(
    'bounded provider setup overlay scrolls a long instance form without overflow',
    (tester) async {
      final fake = _FakeClient(providers: [_provider()], runtimeReady: false);

      await tester.pumpWidget(
        _wrapInBoundedOverlay(ProviderSetupFlow(client: fake)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('OpenAI'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(
        find.descendant(
          of: find.byType(ProviderSetupFlow),
          matching: find.byType(SingleChildScrollView),
        ),
        findsOneWidget,
      );

      await tester.ensureVisible(find.text('Continue'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Continue'), findsOneWidget);
      expect(tester.getBottomRight(find.text('Continue')).dy, lessThan(500));
    },
  );

  testWidgets(
    'settings outer scroll remains the scroll owner for provider setup',
    (tester) async {
      final fake = _FakeClient(providers: [_provider()], runtimeReady: false);

      await tester.pumpWidget(
        _wrapInSettingsScroll(ProviderSetupFlow(client: fake)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('OpenAI'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(
        find.descendant(
          of: find.byType(ProviderSetupFlow),
          matching: find.byType(SingleChildScrollView),
        ),
        findsNothing,
      );

      await tester.ensureVisible(find.text('Continue'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Continue'), findsOneWidget);
    },
  );

  testWidgets(
    'new provider instance form suggests a unique display name and blocks duplicates',
    (tester) async {
      final fake = _FakeClient(
        providers: [_provider()],
        instances: [
          ProviderInstanceDto(
            id: 'inst-existing',
            templateId: 'openai',
            displayName: 'OpenAI',
            protocol: 'openai_compatible',
            authMethod: 'api_key',
            status: 'ready',
            isDefault: true,
            configRevision: 1,
            credentialRevision: 1,
          ),
        ],
        runtimeReady: false,
      );
      await tester.pumpWidget(
        _wrap(ProviderSetupFlow(client: fake, autoLoad: false)),
      );
      await tester.pump();

      final cubit = tester.element(find.byType(AnimatedSwitcher)).read<ProviderSetupCubit>();
      await cubit.load(forcePicker: true);
      await tester.pumpAndSettle();

      await tester.tap(find.text('OpenAI'));
      await tester.pumpAndSettle();

      expect(find.byType(ProviderInstanceFormView), findsOneWidget);
      expect(find.widgetWithText(TextFormField, 'OpenAI 2'), findsOneWidget);

      await tester.enterText(find.byType(TextFormField).first, 'OpenAI');
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      expect(find.text('This display name is already in use'), findsOneWidget);
    },
  );

  testWidgets('after saving api key and confirming model, onReady is called', (
    tester,
  ) async {
    final fake = _FakeClient(
      providers: [_provider()],
      runtimeReady: true,
      modelOptionsResult: ModelOptionsDto(
        providerId: 'openai',
        models: const ['gpt-4o', 'gpt-4o-mini'],
        selectedModel: 'gpt-4o',
        authenticated: true,
        authType: 'api_key',
        source: 'fallback',
      ),
    );
    ProviderReadinessDto? ready;
    await tester.pumpWidget(
      _wrap(ProviderSetupFlow(client: fake, onReady: (value) => ready = value)),
    );
    await tester.pumpAndSettle();

    // Select provider
    await tester.tap(find.text('OpenAI'));
    await tester.pumpAndSettle();

    // Create the instance first
    await tester.enterText(find.byType(TextFormField).first, 'OpenAI Work');
    await tester.enterText(
      find.byKey(const Key('provider_api_key_field')),
      'sk-test-key',
    );
    await tester.ensureVisible(find.text('Continue'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    // The key was entered once in provider details; model selection follows
    // directly without a second credential form.
    expect(find.text('Save & continue'), findsNothing);

    // Model selection view should be shown
    expect(find.text('Choose a model'), findsOneWidget);
    expect(find.text('gpt-4o'), findsOneWidget);

    // Confirm the recommended model
    await tester.tap(find.text('Confirm Model'));
    await tester.pumpAndSettle();

    expect(ready?.activeProvider, 'inst-1');
    expect(ready?.activeModel, 'gpt-4o');
  });

  testWidgets(
    'model discovery failure offers retry, manual entry, and a fixed Back action',
    (tester) async {
      final fake = _FakeClient(
        providers: [
          _provider(models: const ['cached-model']),
        ],
        modelRefreshError: StateError('private transport failure'),
      );
      await tester.pumpWidget(
        _wrapInBoundedOverlay(ProviderSetupFlow(client: fake)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('OpenAI'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('provider_display_name_field')),
        'OpenAI Work',
      );
      await tester.ensureVisible(
        find.byKey(const Key('provider_api_key_field')),
      );
      await tester.enterText(
        find.byKey(const Key('provider_api_key_field')),
        'sk-test',
      );
      await tester.tap(find.byKey(const Key('provider_form_submit')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('model_discovery_failure')), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('Add Model'), findsOneWidget);
      expect(find.text('Back'), findsOneWidget);
      expect(
        find.ancestor(
          of: find.byKey(const Key('add_model_button')),
          matching: find.byType(OverflowBar),
        ),
        findsOneWidget,
      );
      expect(find.text('Cached suggestions'), findsOneWidget);
      expect(find.textContaining('private transport'), findsNothing);

      await tester.tap(find.text('Add Model'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('manual_model_field')),
        'manual-model',
      );
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('confirm_model_button')),
            )
            .onPressed,
        isNotNull,
      );
    },
  );

  testWidgets(
    'selecting a device_code provider starts auth and shows the user code',
    (tester) async {
      final fake = _FakeClient(
        providers: [
          _provider(
            id: 'openai-codex',
            displayName: 'Codex',
            flow: 'device_code',
          ),
        ],
        runtimeReady: false,
      );
      var launchCount = 0;
      String? copiedCode;
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copiedCode = (call.arguments as Map<Object?, Object?>)['text']?.toString();
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );

      await tester.pumpWidget(
        _wrap(
          ProviderSetupFlow(
            client: fake,
            verificationLauncher: (uri) async {
              launchCount++;
              expect(uri, Uri.parse('https://example.com/device'));
              return true;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Codex'));
      await tester.pumpAndSettle();

      final failoverSwitchFinder = find.byKey(
        const Key('provider_auto_failover_switch'),
      );
      expect(failoverSwitchFinder, findsOneWidget);
      final failoverWarningFinder = find.byKey(
        const Key('provider_auto_failover_warning'),
      );
      expect(failoverWarningFinder, findsOneWidget);
      expect(tester.widget<Padding>(failoverWarningFinder), isA<Padding>());
      final failoverWarningText = tester.widget<Text>(
        find.text(
          'When enabled, Sanad may automatically use this provider if another provider fails.',
        ),
      );
      expect(
        failoverWarningText.style?.color,
        Theme.of(tester.element(failoverWarningFinder)).colorScheme.error,
      );
      expect(find.text('Advanced'), findsNothing);
      expect(find.text('OpenAI API Compatible'), findsOneWidget);
      expect(find.text('openai_compatible'), findsNothing);
      final failoverSwitch = tester.widget<SwitchListTile>(failoverSwitchFinder);
      expect(failoverSwitch.value, isTrue);
      expect(
        failoverSwitch.activeThumbColor,
        Theme.of(tester.element(failoverSwitchFinder)).colorScheme.error,
      );

      await tester.enterText(find.byType(TextFormField).first, 'Codex Work');
      await tester.tap(find.text('Continue'));
      // Pump a few frames (without settle) so the async auth start resolves.
      // A settle would loop forever on the indeterminate progress indicator.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.textContaining('Sign in with'), findsOneWidget);
      expect(find.text('Your code'), findsOneWidget);
      expect(find.text('ABCD-1234'), findsOneWidget);
      expect(find.text('ABCD--1234'), findsNothing);
      expect(find.byKey(const Key('copy_device_user_code_button')), findsOneWidget);
      await tester.tap(find.byKey(const Key('copy_device_user_code_button')));
      await tester.idle();
      await tester.pump(const Duration(milliseconds: 350));
      expect(copiedCode, 'ABCD-1234');
      expect(find.byType(SnackBar), findsNothing);
      expect(launchCount, 1);
      expect(find.text('Re-open verification page'), findsOneWidget);
      expect(
        find.text('The verification page was opened in your browser.'),
        findsOneWidget,
      );
      expect(find.text('Cancel'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
    },
  );

  test(
    'model picker item count includes all groups plus every recent item',
    () {
      expect(
        modelPickerVisibleSectionCount(groupCount: 7, recentCount: 5),
        equals(13),
      );
      expect(
        modelPickerVisibleSectionCount(groupCount: 7, recentCount: 0),
        equals(7),
      );
    },
  );

  testWidgets(
    'editing a provider instance with a credential that has no secret does not crash',
    (tester) async {
      final fake = _FakeClient(
        providers: [_provider()],
        instances: [
          ProviderInstanceDto(
            id: 'inst-1',
            templateId: 'openai',
            displayName: 'OpenAI Work',
            protocol: 'openai',
            authMethod: 'api_key',
            status: 'ready',
            isDefault: true,
            configRevision: 1,
            credentialRevision: 1,
            credential: const CredentialSummaryDto(
              authMethod: 'api_key',
              hasSecret: false,
              status: 'missing',
            ),
          ),
        ],
        runtimeReady: false,
      );

      await tester.pumpWidget(
        _wrap(ProviderSetupFlow(client: fake, autoLoad: false)),
      );
      await tester.pump();

      // Retrieve the cubit from the provider context and load instances (forcePicker: false)
      final cubit = tester.element(find.byType(AnimatedSwitcher)).read<ProviderSetupCubit>();
      await cubit.load(forcePicker: false);
      await tester.pumpAndSettle();

      // We should be on the instances list view since instances is not empty
      expect(find.text('OpenAI Work'), findsOneWidget);

      // Tap on edit button/icon for the instance
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();

      // We should now be on the ProviderInstanceFormView with explicit model
      // management and a danger zone instead of a free-form model field.
      expect(find.byType(ProviderInstanceFormView), findsOneWidget);
      expect(find.text('Edit Provider Instance'), findsOneWidget);
      expect(find.byKey(const Key('change_provider_model_button')), findsOneWidget);
      expect(find.byKey(const Key('delete_provider_from_edit_button')), findsOneWidget);

      // Click "Add API Key" text button since there is no secret
      await tester.tap(find.text('Add API Key'));
      await tester.pumpAndSettle();

      // The credential action dropdown should be displayed and default to a
      // non-mutating choice even when no secret is stored yet.
      expect(find.text('Credential Action'), findsOneWidget);
      expect(find.text('Keep as-is (no key stored)'), findsOneWidget);
      expect(find.text('New API Key'), findsNothing);

      await tester.enterText(
        find.byKey(const Key('provider_display_name_field')),
        'Renamed Provider',
      );
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Discard changes?'), findsOneWidget);
      expect(find.text('Keep editing'), findsOneWidget);
    },
  );

  testWidgets(
    'editing an API-key provider renders the canonical stored credential summary',
    (tester) async {
      final fake = _FakeClient(
        providers: [_provider(configured: true)],
        instances: [
          ProviderInstanceDto.fromJson(const {
            'id': 'api-instance',
            'template_id': 'openai',
            'display_name': 'OpenAI Work',
            'protocol': 'openai_compatible',
            'auth_method': 'api_key',
            'status': 'ready',
            'is_default': true,
            'credential': {
              'configured': true,
              'auth_method': 'api_key',
              'status': 'authenticated',
              'masked_key_hint': 'sk-p••••9X2A',
              'relogin_required': false,
            },
          }),
        ],
      );

      await tester.pumpWidget(
        _wrap(ProviderSetupFlow(client: fake, autoLoad: false)),
      );
      await tester.pump();
      final cubit = tester.element(find.byType(AnimatedSwitcher)).read<ProviderSetupCubit>();
      await cubit.load(forcePicker: false);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();

      expect(find.text('sk-p••••9X2A'), findsOneWidget);
      expect(find.text('OpenAI API Compatible'), findsOneWidget);
      expect(find.text('openai_compatible'), findsNothing);
      expect(find.text('Replace or remove key'), findsOneWidget);
      expect(find.text('Not set'), findsNothing);
      expect(find.text('Add API Key'), findsNothing);
    },
  );

  testWidgets(
    'editing an OAuth provider renders a configured connected account',
    (tester) async {
      final fake = _FakeClient(
        providers: [
          _provider(
            id: 'openai-codex',
            displayName: 'Codex',
            flow: 'device_code',
            configured: true,
            authenticated: true,
          ),
        ],
        instances: [
          ProviderInstanceDto.fromJson(const {
            'id': 'oauth-instance',
            'template_id': 'openai-codex',
            'display_name': 'Codex Work',
            'protocol': 'openai_compatible',
            'auth_method': 'device_code',
            'status': 'ready',
            'is_default': true,
            'credential': {
              'configured': true,
              'auth_method': 'device_code',
              'status': 'authenticated',
              'account_label': 'user@example.com',
              'account_name': 'User Name',
              'relogin_required': false,
            },
          }),
        ],
      );

      await tester.pumpWidget(
        _wrap(ProviderSetupFlow(client: fake, autoLoad: false)),
      );
      await tester.pump();
      final cubit = tester.element(find.byType(AnimatedSwitcher)).read<ProviderSetupCubit>();
      await cubit.load(forcePicker: false);
      await tester.pumpAndSettle();

      expect(find.text('Account: user@example.com'), findsOneWidget);
      expect(find.text('Name: User Name'), findsOneWidget);

      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();

      expect(find.text('user@example.com'), findsOneWidget);
      expect(find.text('User Name'), findsOneWidget);
      expect(find.text('Disconnected'), findsNothing);
      expect(find.text('Reconnect account'), findsOneWidget);
    },
  );
}
