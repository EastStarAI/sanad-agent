/// The permission picker must never decide "nothing changed" from its own copy.
///
/// The Client's copy of a session's mode can be stale (a session event may
/// describe an older authority than the Agent enforces), so selecting a mode
/// always sends the command. The Agent applies it idempotently and answers with
/// the durable mode, which is what makes a stale "Full access" chip repairable
/// instead of a silent no-op.
library;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/core/di/injection.dart';
import 'package:sanad_client/core/presentation/bloc/locale/locale_cubit.dart' show kSupportedLocales;
import 'package:sanad_client/features/conversations/domain/models/session.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/conversation_input_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_messages_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_workspace_coordinator.dart' show WorkspacePolicyChangeFailure;
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/composer_permission_mode_chip.dart';
import 'package:sanad_client/features/devices/data/device_connection_coordinator.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/devices/domain/stores/device_capabilities_store.dart';
import 'package:sanad_client/features/devices/presentation/bloc/device_state.dart';
import 'package:sanad_client/infrastructure/local_tools/workspace_policy.dart';
import 'package:sanad_client/l10n/app_localizations.dart';

import '../helpers/fake_conversation_repository.dart';
import '../helpers/fake_device_preferences_repository.dart';
import '../helpers/fake_device_repository.dart';
import '../helpers/fake_socket.dart';

void main() {
  late FakeSanadSocketService socket;
  late FakeDeviceRepository agentRepository;
  late FakeDeviceClientRegistry agentClientRegistry;
  late TestDeviceCubit agentCubit;
  late DeviceConnectionCoordinator resolver;
  late DeviceCapabilitiesStore capabilities;
  late FakeConversationRepository conversationRepository;
  late SessionCubit sessionCubit;
  late SessionMessagesCubit messagesCubit;
  late _RecordingInputCubit inputCubit;
  late DeviceConfig agent;

  setUp(() async {
    await getIt.reset();
    socket = FakeSanadSocketService();
    agentRepository = FakeDeviceRepository();
    agentClientRegistry = FakeDeviceClientRegistry();
    agentCubit = TestDeviceCubit(
      socketService: socket,
      agentRepository: agentRepository,
      agentClientRegistry: agentClientRegistry,
    );
    resolver = createTestResolver(cloudSocket: socket, localSocket: socket);
    capabilities = DeviceCapabilitiesStore(resolver);
    conversationRepository = FakeConversationRepository();
    agent = DeviceConfig(id: 'agent-1', name: 'SanadAgent', isOnline: true);
    agentRepository.seedAgents([agent], activeAgentId: agent.id);
    agentCubit.emitState(DeviceActive(activeAgent: agent, agents: [agent]));
    sessionCubit = SessionCubit(
      agentCubit: agentCubit,
      socketService: socket,
      conversationRepository: conversationRepository,
    );
    messagesCubit = SessionMessagesCubit(
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      conversationRepository: conversationRepository,
      preferencesRepository: FakeDevicePreferencesRepository(),
    );
    inputCubit = _RecordingInputCubit(messagesCubit: messagesCubit);
    sessionCubit.markSessionSelectedSync(
      Session(
        id: 'run-session',
        title: 'Run session',
        deviceId: agent.id,
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
        workspaceId: 'exec_root:/work/root',
        workspacePath: '/work/root',
        workspaceName: 'root',
        metadata: const {
          'execution_root': '/work/root',
          'allow_all_tools': true,
          'permission_mode': 'full_access',
        },
      ),
    );
  });

  tearDown(() async {
    await inputCubit.close();
    await messagesCubit.close();
    await sessionCubit.close();
    await agentCubit.close();
    capabilities.dispose();
    resolver.dispose();
    await conversationRepository.dispose();
    socket.dispose();
  });

  Future<void> pumpChip(
    WidgetTester tester,
    WorkspacePermissionMode mode,
  ) async {
    await tester.pumpWidget(
      BlocProvider<ConversationInputCubit>.value(
        value: inputCubit,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: kSupportedLocales,
          home: Scaffold(
            body: ComposerPermissionModeChip(
              permissionMode: mode,
              isLoadingPermissionMode: false,
              dimTextColor: Colors.black54,
              chipBgColor: Colors.grey.shade200,
              borderColor: Colors.grey,
              workspacePath: '/work/root',
              onConfirmFullAccess: () async => true,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('selecting the mode the chip already shows still sends it', (
    tester,
  ) async {
    await pumpChip(tester, WorkspacePermissionMode.fullAccess);

    await tester.tap(find.byKey(const Key('permission_mode_selector_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('composer_permission_mode_full_access')));
    await tester.pumpAndSettle();

    expect(inputCubit.requestedModes, [WorkspacePermissionMode.fullAccess]);
    expect(conversationRepository.setPermissionModeRequests, hasLength(1));
    expect(
      conversationRepository.setPermissionModeRequests.single['mode'],
      WorkspacePermissionMode.fullAccess,
    );
  });

  testWidgets('a downgrade selection is sent as well', (tester) async {
    await pumpChip(tester, WorkspacePermissionMode.defaultMode);

    await tester.tap(find.byKey(const Key('permission_mode_selector_button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('composer_permission_mode_default')));
    await tester.pumpAndSettle();

    expect(inputCubit.requestedModes, [WorkspacePermissionMode.defaultMode]);
    expect(
      conversationRepository.setPermissionModeRequests.single['mode'],
      WorkspacePermissionMode.defaultMode,
    );
  });
}

class _RecordingInputCubit extends ConversationInputCubit {
  _RecordingInputCubit({required super.messagesCubit});

  final List<WorkspacePermissionMode> requestedModes = [];

  @override
  Future<WorkspacePolicyChangeFailure?> setWorkspacePermissionMode(
    WorkspacePermissionMode permissionMode,
  ) async {
    requestedModes.add(permissionMode);
    return super.setWorkspacePermissionMode(permissionMode);
  }
}
