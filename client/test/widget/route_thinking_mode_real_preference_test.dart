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

/// Proves that the thinking control's auto-admitted native default reaches the
/// real composer preference path instead of a stub.
///
/// The control dispatches through the real `ConversationInputCubit
/// .selectThinkingMode`, which writes through the real `SessionMessagesCubit`,
/// so the admitted value is asserted where the next send actually reads it
/// (`nextMessageThinkingMode`), where it is persisted for the device
/// (`IDevicePreferencesRepository`), and which conversation received it
/// (`updateSessionPreferences`). A stub argument is never treated as an outgoing
/// request here; menu/route routing stays covered by
/// `route_thinking_mode_selector_test.dart`.
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
    Session build(String id, {String? thinkingMode}) {
      return Session(
        id: id,
        title: id,
        deviceId: agent.id,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        modelProvider: 'provider-1',
        model: 'model-a',
        thinkingMode: thinkingMode,
      );
    }

    return [
      build('unset-a'),
      build('unset-b'),
      build('off-a', thinkingMode: 'off'),
      build('off-b'),
    ];
  }

  Session sessionById(String id) => seededSessions().firstWhere((s) => s.id == id);

  ModelCacheSnapshotDto snapshotFor(String modelId, ThinkingControlDescriptorDto descriptor) {
    return ModelCacheSnapshotDto(
      instances: [
        ModelCacheInstanceDto(
          id: 'provider-1',
          displayName: 'Provider 1',
          status: 'ready',
          isDefault: true,
          cacheStatus: 'fetched',
          models: [ModelCacheModelDto(id: modelId, thinkingControl: descriptor)],
        ),
      ],
      recent: const [],
    );
  }

  /// Sessions written by the real `updateSessionPreferences`, filtered to one
  /// thinking value and the conversation that owned it.
  List<Map<String, Object?>> thinkingWritesFor(String sessionId, String thinkingMode) {
    return conversationRepository.updatedSessionPreferences
        .where((entry) => entry['session_id'] == sessionId && entry['thinking_mode'] == thinkingMode)
        .toList();
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
    conversationRepository.seedSessions(agent, seededSessions());
    capabilitiesStore = DeviceCapabilitiesStore(
      createTestResolver(cloudSocket: socket, localSocket: socket),
    );
    // Readiness is resolved here, outside the widget test fake-async zone, so
    // the composer sees a route that declares model thinking controls.
    await capabilitiesStore.ensureFreshForAgent(agent, force: true);
    getIt.registerSingleton<ProviderSetupClient>(
      _StubProviderSetupClient()..snapshotResult = snapshotFor('model-a', mediumDefaultDescriptor),
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
    'an unset same-route conversation admits its own default into real next-send and persisted state',
    (tester) async {
      buildStack();
      await sessionCubit.selectSession(sessionById('unset-a'));
      await pumpControl(tester);

      expect(inputCubit.state.activeSessionId, 'unset-a');
      expect(
        inputCubit.state.nextMessageThinkingMode,
        'medium',
        reason: 'the admitted default is the value the next send reads',
      );
      expect(preferencesRepository.getLastThinkingMode(agent.id), 'medium');
      expect(find.byKey(const Key('chip_Medium')), findsOneWidget);
      expect(thinkingWritesFor('unset-a', 'medium'), hasLength(1));

      // A fresh conversation on the same route stores no choice, so it must
      // admit the route native default on its own.
      await sessionCubit.selectSession(sessionById('unset-b'));
      await settle(tester);

      expect(inputCubit.state.activeSessionId, 'unset-b');
      expect(inputCubit.state.nextMessageThinkingMode, 'medium');
      expect(
        thinkingWritesFor('unset-b', 'medium'),
        hasLength(1),
        reason: 'the new conversation receives its own admitted default',
      );
      expect(
        thinkingWritesFor('unset-a', 'medium'),
        hasLength(1),
        reason: 'the earlier conversation is not written again by the switch',
      );

      // Switching back leaves the first conversation exactly as it was.
      await sessionCubit.selectSession(sessionById('unset-a'));
      await settle(tester);

      expect(inputCubit.state.activeSessionId, 'unset-a');
      expect(inputCubit.state.nextMessageThinkingMode, 'medium');
      expect(sessionCubit.state.selectedSession?.thinkingMode, 'medium');
      expect(thinkingWritesFor('unset-b', 'medium'), hasLength(1));
    },
  );

  testWidgets(
    'an explicit Off survives the real preference path while an unset conversation admits the default',
    (tester) async {
      buildStack();
      await sessionCubit.selectSession(sessionById('off-a'));
      await pumpControl(tester);

      expect(inputCubit.state.activeSessionId, 'off-a');
      expect(
        inputCubit.state.nextMessageThinkingMode,
        'off',
        reason: 'an explicit Off is the value the next send carries',
      );
      expect(
        preferencesRepository.getLastThinkingMode(agent.id),
        isNot('medium'),
        reason: 'an explicit Off is never replaced by the route default for the device',
      );
      expect(find.byKey(const Key('chip_Off')), findsOneWidget);
      expect(
        thinkingWritesFor('off-a', 'medium'),
        isEmpty,
        reason: 'a valid explicit Off is never rewritten, not even to the default',
      );

      await sessionCubit.selectSession(sessionById('off-b'));
      await settle(tester);

      expect(inputCubit.state.activeSessionId, 'off-b');
      expect(inputCubit.state.nextMessageThinkingMode, 'medium');
      expect(thinkingWritesFor('off-b', 'medium'), hasLength(1));
      expect(
        thinkingWritesFor('off-a', 'medium'),
        isEmpty,
        reason: 'the unset conversation never writes the default onto its sibling',
      );

      await sessionCubit.selectSession(sessionById('off-a'));
      await settle(tester);

      expect(
        inputCubit.state.nextMessageThinkingMode,
        'off',
        reason: 'the first conversation own explicit Off comes back with it',
      );
      expect(sessionCubit.state.selectedSession?.thinkingMode, 'off');
      expect(find.byKey(const Key('chip_Off')), findsOneWidget);
    },
  );
}
