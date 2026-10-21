import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/core/di/injection.dart';
import 'package:sanad_client/features/conversations/data/repositories/conversation_cache_repository.dart';
import 'package:sanad_client/features/conversations/domain/models/session.dart';
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

/// Proves that opening or hydrating a conversation never writes thinking
/// preferences (live acceptance 106b r2 G2), while the thinking control still
/// shows the conversation's persisted selection or, when it has none, the
/// route's native default.
///
/// The control runs over the real `ConversationInputCubit` and
/// `SessionMessagesCubit`, so the displayed/next-send value is asserted where
/// the next send reads it (`nextMessageThinkingMode`), the device preference in
/// `IDevicePreferencesRepository`, and every `update_session_preferences` in the
/// fake repository. Only an explicit menu choice may write.
const mediumDefaultDescriptor = ThinkingControlDescriptorDto(
  status: ThinkingCapabilityStatus.supported,
  kind: ThinkingControlKind.effort,
  defaultOptionId: 'medium',
  options: [
    ThinkingControlOptionDto(id: 'off', label: 'Off', isOff: true),
    ThinkingControlOptionDto(id: 'low', label: 'Low'),
    ThinkingControlOptionDto(id: 'medium', label: 'Medium'),
    ThinkingControlOptionDto(id: 'high', label: 'High'),
  ],
);

/// A glm-5.2-like route on OpenCode Go: High/Max only, default Max, no Medium.
const maxDefaultDescriptor = ThinkingControlDescriptorDto(
  status: ThinkingCapabilityStatus.supported,
  kind: ThinkingControlKind.effort,
  defaultOptionId: 'max',
  options: [
    ThinkingControlOptionDto(id: 'high', label: 'High'),
    ThinkingControlOptionDto(id: 'max', label: 'Max', isProviderDefault: true),
  ],
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

  /// Two unset conversations plus one that already carries an explicit Off, all
  /// on the same provider/model route.
  List<Session> seededSessions() {
    Session build(String id, {String? thinkingMode, String model = 'model-a'}) {
      return Session(
        id: id,
        title: id,
        deviceId: agent.id,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        modelProvider: 'provider-1',
        model: model,
        thinkingMode: thinkingMode,
      );
    }

    return [
      build('unset-a'),
      build('unset-b'),
      build('off-a', thinkingMode: 'off'),
      build('off-b'),
      build('low-a', thinkingMode: 'low'),
      build('glm-medium', thinkingMode: 'medium', model: 'model-glm'),
    ];
  }

  Session sessionById(String id) => seededSessions().firstWhere((s) => s.id == id);

  ModelCacheSnapshotDto snapshotFor(Map<String, ThinkingControlDescriptorDto> descriptors) {
    return ModelCacheSnapshotDto(
      instances: [
        ModelCacheInstanceDto(
          id: 'provider-1',
          displayName: 'Provider 1',
          status: 'ready',
          isDefault: true,
          cacheStatus: 'fetched',
          models: [
            for (final entry in descriptors.entries)
              ModelCacheModelDto(id: entry.key, thinkingControl: entry.value),
          ],
        ),
      ],
      recent: const [],
    );
  }

  /// Every thinking write sent through the real `updateSessionPreferences`.
  List<Map<String, String?>> thinkingWrites() => conversationRepository.updatedSessionPreferences
      .where((entry) => entry.containsKey('thinking_mode') && entry['thinking_mode'] != null)
      .toList();

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
    conversationRepository.seedSessions(agent, seededSessions());
    capabilitiesStore = DeviceCapabilitiesStore(
      createTestResolver(cloudSocket: socket, localSocket: socket),
    );
    // Readiness is resolved here, outside the widget test fake-async zone, so
    // the composer sees a route that declares model thinking controls.
    await capabilitiesStore.ensureFreshForAgent(agent, force: true);
    getIt.registerSingleton<ProviderSetupClient>(
      _StubProviderSetupClient()
        ..snapshotResult = snapshotFor({
          'model-a': mediumDefaultDescriptor,
          'model-glm': maxDefaultDescriptor,
        }),
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

  testWidgets(
    'G2: opening an unset conversation shows the route default without writing it',
    (tester) async {
      buildStack();
      await sessionCubit.selectSession(sessionById('unset-a'));
      await pumpControl(tester);

      expect(inputCubit.state.activeSessionId, 'unset-a');
      expect(find.byKey(const Key('chip_Medium')), findsOneWidget);
      expect(
        inputCubit.state.nextMessageThinkingMode,
        'medium',
        reason: 'the shown default is the value the next send carries',
      );
      expect(thinkingWrites(), isEmpty, reason: 'opening never writes preferences');
      expect(sessionCubit.state.selectedSession?.thinkingMode, isNull);
      expect(
        preferencesRepository.getLastThinkingMode(agent.id),
        isNull,
        reason: 'hydration is not a user choice for the device either',
      );

      // Another unset conversation on the same route: still no write.
      await sessionCubit.selectSession(sessionById('unset-b'));
      await settle(tester);
      expect(inputCubit.state.activeSessionId, 'unset-b');
      expect(inputCubit.state.nextMessageThinkingMode, 'medium');
      expect(thinkingWrites(), isEmpty);

      await sessionCubit.selectSession(sessionById('unset-a'));
      await settle(tester);
      expect(sessionCubit.state.selectedSession?.thinkingMode, isNull);
      expect(thinkingWrites(), isEmpty);
    },
  );

  testWidgets(
    'G2: opening a conversation with a persisted explicit Low keeps it and writes nothing',
    (tester) async {
      buildStack();
      await sessionCubit.selectSession(sessionById('low-a'));
      await pumpControl(tester);

      expect(find.byKey(const Key('chip_Low')), findsOneWidget);
      expect(inputCubit.state.nextMessageThinkingMode, 'low');
      expect(sessionCubit.state.selectedSession?.thinkingMode, 'low');
      expect(thinkingWrites(), isEmpty);
    },
  );

  testWidgets(
    'G2: a persisted value the route does not offer is shown as the route '
    'default and is not rewritten on open',
    (tester) async {
      buildStack();
      await sessionCubit.selectSession(sessionById('glm-medium'));
      await pumpControl(tester);

      expect(find.byKey(const Key('chip_Max')), findsOneWidget);
      expect(inputCubit.state.nextMessageThinkingMode, 'max');
      expect(
        thinkingWrites(),
        isEmpty,
        reason: 'the agent revalidates the stored value at turn admission',
      );
      expect(sessionCubit.state.selectedSession?.thinkingMode, 'medium');
    },
  );

  testWidgets(
    'an explicit Off survives a switch, and an explicit menu choice is the only write',
    (tester) async {
      buildStack();
      await sessionCubit.selectSession(sessionById('off-a'));
      await pumpControl(tester);

      expect(inputCubit.state.activeSessionId, 'off-a');
      expect(inputCubit.state.nextMessageThinkingMode, 'off');
      expect(find.byKey(const Key('chip_Off')), findsOneWidget);

      await sessionCubit.selectSession(sessionById('off-b'));
      await settle(tester);
      expect(inputCubit.state.activeSessionId, 'off-b');
      expect(inputCubit.state.nextMessageThinkingMode, 'medium');

      await sessionCubit.selectSession(sessionById('off-a'));
      await settle(tester);
      expect(inputCubit.state.nextMessageThinkingMode, 'off');
      expect(sessionCubit.state.selectedSession?.thinkingMode, 'off');
      expect(thinkingWrites(), isEmpty);

      // The user explicitly picks High: exactly that one write happens.
      await inputCubit.selectThinkingMode(
        scope: CapabilityValueScope.session,
        thinkingMode: 'high',
      );
      await settle(tester);
      expect(thinkingWrites(), hasLength(1));
      expect(thinkingWrites().single['session_id'], 'off-a');
      expect(thinkingWrites().single['thinking_mode'], 'high');
    },
  );
}
