import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/core/di/injection.dart';
import 'package:sanad_client/features/conversations/data/repositories/conversation_cache_repository.dart';
import 'package:sanad_client/features/conversations/domain/models/thinking_control.dart';
import 'package:sanad_client/features/conversations/domain/stores/conversation_cache_store.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/conversation_input_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/conversation_input_state.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_messages_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/conversation_input_slices.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/route_thinking_mode_selector.dart';
import 'package:sanad_client/features/devices/domain/models/capability.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/devices/domain/stores/device_capabilities_store.dart';
import 'package:sanad_client/features/devices/presentation/bloc/device_state.dart';
import 'package:sanad_client/features/provider_setup/data/models/model_cache_snapshot_dto.dart';
import 'package:sanad_client/features/provider_setup/data/provider_setup_client.dart';
import 'package:sanad_client/l10n/app_localizations.dart';

import '../helpers/fake_conversation_repository.dart';
import '../helpers/fake_device_preferences_repository.dart';
import '../helpers/fake_device_repository.dart';
import '../helpers/fake_socket.dart';

/// Live acceptance L2 (Task 115): a hidden, carried-over thinking selection.
///
/// The user picks `high` on a supported route, then starts a New Conversation on
/// a route whose control renders "Not reported" (unknown) or "No control"
/// (unsupported) and sends immediately. The real composer stack must send no
/// `thinking_mode` with `create_session` or the turn, write none onto the new
/// session, and keep the device's `high` for the supported route.
const supportedDescriptor = ThinkingControlDescriptorDto(
  status: ThinkingCapabilityStatus.supported,
  kind: ThinkingControlKind.effort,
  options: [
    ThinkingControlOptionDto(id: 'low', label: 'Low'),
    ThinkingControlOptionDto(id: 'high', label: 'High'),
  ],
);
const unknownDescriptor = ThinkingControlDescriptorDto(
  status: ThinkingCapabilityStatus.unknown,
);
const unsupportedDescriptor = ThinkingControlDescriptorDto(
  status: ThinkingCapabilityStatus.unsupported,
);

class _StubProviderSetupClient extends Fake implements ProviderSetupClient {
  ModelCacheSnapshotDto snapshotResult = const ModelCacheSnapshotDto(
    instances: [],
    recent: [],
  );

  @override
  Stream<ModelCacheUpdateEvent> get modelUpdates => const Stream.empty();

  @override
  Future<ModelCacheSnapshotDto> modelSnapshot({DeviceConfig? agent}) async => snapshotResult;
}

void main() {
  late FakeSanadSocketService socket;
  late FakeDeviceRepository agentRepository;
  late FakeDeviceClientRegistry agentClientRegistry;
  late TestDeviceCubit agentCubit;
  late FakeConversationRepository conversationRepository;
  late ConversationCacheRepository conversationCacheRepository;
  late FakeDevicePreferencesRepository preferencesRepository;
  late DeviceCapabilitiesStore capabilitiesStore;
  late SessionCubit sessionCubit;
  late SessionMessagesCubit messagesCubit;
  late ConversationInputCubit inputCubit;
  late DeviceConfig agent;

  bool stackOpen = false;


  ModelCacheSnapshotDto routesSnapshot() {
    return const ModelCacheSnapshotDto(
      instances: [
        ModelCacheInstanceDto(
          id: 'provider-1',
          displayName: 'Provider 1',
          status: 'ready',
          isDefault: true,
          cacheStatus: 'fetched',
          models: [
            ModelCacheModelDto(id: 'model-a', thinkingControl: supportedDescriptor),
            ModelCacheModelDto(id: 'kimi-for-coding', thinkingControl: unknownDescriptor),
            ModelCacheModelDto(id: 'gpt-6-luna', thinkingControl: unsupportedDescriptor),
          ],
        ),
      ],
      recent: [],
    );
  }

  /// Builds the real composer stack inside the running test, so its streams are
  /// delivered by the widget test's own asynchronous zone.
  void buildStack() {
    sessionCubit = SessionCubit(
      agentCubit: agentCubit,
      socketService: socket,
      conversationRepository: conversationRepository,
      conversationCacheRepository: conversationCacheRepository,
    );
    messagesCubit = SessionMessagesCubit(
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      conversationRepository: conversationRepository,
      conversationCacheRepository: conversationCacheRepository,
      preferencesRepository: preferencesRepository,
      capabilitiesStore: capabilitiesStore,
    );
    inputCubit = ConversationInputCubit(messagesCubit: messagesCubit);
    stackOpen = true;
  }

  /// Closes the stack inside the same zone that created it.
  Future<void> closeStack() async {
    if (!stackOpen) {
      return;
    }
    stackOpen = false;
    await inputCubit.close();
    await messagesCubit.close();
    await sessionCubit.close();
  }

  /// A bounded settle so a non-settling tree fails fast instead of hanging.
  Future<void> settle(WidgetTester tester) => tester.pumpAndSettle(
    const Duration(milliseconds: 100),
    EnginePhase.sendSemanticsUpdate,
    const Duration(seconds: 5),
  );

  setUp(() async {
    socket = FakeSanadSocketService();
    socket.setConnected(true);
    socket.autoCapabilitiesPayload = const {
      'supports_workspaces': true,
      'workspace_required': false,
      'supports_workspace_selection': true,
      'local_tool_runtime_scope': 'workspace',
      'tool_protocol_version': 'tools.v2',
      'thinking_mode_source': 'model',
      'thinking_mode_scope': 'session',
      'supports_thinking_mode_change': true,
    };
    agentRepository = FakeDeviceRepository();
    agentClientRegistry = FakeDeviceClientRegistry();
    agentCubit = TestDeviceCubit(
      socketService: socket,
      agentRepository: agentRepository,
      agentClientRegistry: agentClientRegistry,
    );
    conversationRepository = FakeConversationRepository();
    conversationCacheRepository = ConversationCacheRepository(
      cache: ConversationCacheStore(),
      transport: conversationRepository,
    );
    preferencesRepository = FakeDevicePreferencesRepository();
    agent = DeviceConfig(id: 'agent-1', name: 'Computer', isOnline: true);
    agentRepository.seedAgents([agent], activeAgentId: agent.id);
    agentCubit.emitState(DeviceActive(activeAgent: agent, agents: [agent]));
    capabilitiesStore = DeviceCapabilitiesStore(
      createTestResolver(cloudSocket: socket, localSocket: socket),
    );
    // Readiness is resolved here, outside the widget test fake-async zone, so
    // the composer sees a route that declares model thinking controls.
    await capabilitiesStore.ensureFreshForAgent(agent, force: true);
    getIt.registerSingleton<ProviderSetupClient>(
      _StubProviderSetupClient()..snapshotResult = routesSnapshot(),
    );
  });

  tearDown(() async {
    if (getIt.isRegistered<ProviderSetupClient>()) {
      await getIt.unregister<ProviderSetupClient>();
    }
    if (stackOpen) {
      // A failing body can leave the stack open; never block the runner on a
      // subscription created by the test's own zone.
      unawaited(closeStack());
    }
    await agentCubit.close();
    await conversationRepository.dispose();
  });

  /// Mounts the real control over the real composer cubit, rebuilding its input
  /// slice from composer state exactly like the production composer does.
  Future<void> pumpControl(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: MultiBlocProvider(
          providers: [
            BlocProvider<SessionCubit>.value(value: sessionCubit),
            BlocProvider<ConversationInputCubit>.value(value: inputCubit),
          ],
          child: Scaffold(
            body: BlocBuilder<ConversationInputCubit, ConversationInputState>(
              builder: (context, state) {
                return RouteThinkingModeSelector(
                  capabilities: const Capability(
                    supportsThinkingModeChange: true,
                    thinkingModeSource: ThinkingModeSource.model,
                    thinkingModeScope: CapabilityValueScope.session,
                  ),
                  inputSlice: ConversationInputSlice(
                    isProcessing: state.isProcessing,
                    nextMessageModel: state.nextMessageModel,
                    nextMessageProviderId: state.nextMessageProviderId,
                    nextMessageThinkingMode: state.nextMessageThinkingMode,
                    availableWorkspaces: state.availableWorkspaces,
                    selectedWorkspace: state.selectedWorkspace,
                    isLoadingWorkspaces: state.isLoadingWorkspaces,
                    requiresWorkspace: state.requiresWorkspace,
                    permissionMode: state.permissionMode,
                    isLoadingPermissionMode: state.isLoadingPermissionMode,
                    pendingSuspendedRequest: state.pendingSuspendedRequest,
                    runtimeNotice: state.runtimeNotice,
                    queuedMessages: state.queuedMessages,
                  ),
                  activeAgent: agent,
                  chipBuilder: (context, label, {required enabled}) {
                    return Text(label, key: Key('chip_$label'));
                  },
                );
              },
            ),
          ),
        ),
      ),
    );
    await settle(tester);
  }

  /// Drives a cubit call to completion under the widget test's fake clock:
  /// the future is pumped instead of awaited directly so its timers can fire.
  Future<void> drive(WidgetTester tester, Future<void> call) async {
    var done = false;
    unawaited(call.whenComplete(() => done = true));
    for (var i = 0; i < 50 && !done; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(done, isTrue, reason: 'composer call must complete');
    await settle(tester);
  }

  /// Picks `high` on the supported route, then moves the New Conversation
  /// composer to [model] and waits for its control to resolve.
  Future<void> carryHighTo(WidgetTester tester, String model) async {
    buildStack();
    await pumpControl(tester);
    await drive(tester, inputCubit.selectModel(
      // A New Conversation has no session yet, so the route is a next-message
      // preference exactly like the production composer stages it.
      scope: CapabilityValueScope.message,
      providerId: 'provider-1',
      model: 'model-a',
    ));
    await drive(tester, inputCubit.selectThinkingMode(
      scope: CapabilityValueScope.session,
      thinkingMode: 'high',
    ));
    expect(preferencesRepository.getLastThinkingMode(agent.id), 'high');

    await drive(tester, inputCubit.selectModel(
      // A New Conversation has no session yet, so the route is a next-message
      // preference exactly like the production composer stages it.
      scope: CapabilityValueScope.message,
      providerId: 'provider-1',
      model: model,
    ));
    expect(
      inputCubit.state.nextMessageThinkingMode,
      'high',
      reason: 'the hidden last-used value is still carried in composer state',
    );
  }

  for (final route in [
    (model: 'kimi-for-coding', chip: 'route_thinking_mode_unknown'),
    (model: 'gpt-6-luna', chip: 'route_thinking_mode_no_control'),
  ]) {
    testWidgets(
      'a carried-over high is not sent or persisted for a new conversation on ${route.model} (${route.chip})',
      (tester) async {
        await carryHighTo(tester, route.model);
        expect(find.byKey(Key(route.chip)), findsOneWidget);

        await drive(tester, inputCubit.sendMessage('hi'));

        final created = conversationRepository.createdSessionRequests.last;
        expect(created['model'], route.model);
        expect(created.containsKey('thinking_mode'), isFalse);
        final sent = conversationRepository.sentMessageRequests.last;
        expect(sent['model'], route.model);
        expect(sent['thinking_mode'], isNull);
        expect(
          sessionCubit.state.selectedSession?.thinkingMode,
          isNull,
          reason: 'no hidden value is written onto the new session',
        );
        expect(
          preferencesRepository.getLastThinkingMode(agent.id),
          'high',
          reason: 'the supported route keeps the user own choice',
        );
      },
    );
  }

  testWidgets('a supported route still sends the user explicit high', (tester) async {
    buildStack();
    await pumpControl(tester);
    await drive(tester, inputCubit.selectModel(
      // A New Conversation has no session yet, so the route is a next-message
      // preference exactly like the production composer stages it.
      scope: CapabilityValueScope.message,
      providerId: 'provider-1',
      model: 'model-a',
    ));
    await drive(tester, inputCubit.selectThinkingMode(
      scope: CapabilityValueScope.session,
      thinkingMode: 'high',
    ));

    await drive(tester, inputCubit.sendMessage('hi'));

    expect(conversationRepository.createdSessionRequests.last['thinking_mode'], 'high');
    expect(conversationRepository.sentMessageRequests.last['thinking_mode'], 'high');
  });
}
