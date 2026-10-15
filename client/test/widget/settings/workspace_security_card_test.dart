import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/core/di/injection.dart';
import 'package:sanad_client/features/conversations/domain/models/device_workspace.dart';
import 'package:sanad_client/features/conversations/domain/repositories/conversation_repository.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/settings/presentation/widgets/workspace_security_card.dart';
import 'package:sanad_client/infrastructure/local_tools/workspace_policy.dart';

import '../../helpers/fake_conversation_repository.dart';

void main() {
  late FakeConversationRepository fakeRepo;
  final device = DeviceConfig(id: 'agent-1', name: 'Test Agent', isOnline: true);
  final workspace = DeviceWorkspace(
    id: 'ws-1',
    name: 'Test Workspace',
    path: '/path/to/ws',
  );

  setUp(() async {
    fakeRepo = FakeConversationRepository();
    if (getIt.isRegistered<ConversationRepository>()) {
      await getIt.unregister<ConversationRepository>();
    }
    getIt.registerSingleton<ConversationRepository>(fakeRepo);
  });

  tearDown(() async {
    if (getIt.isRegistered<ConversationRepository>()) {
      await getIt.unregister<ConversationRepository>();
    }
  });

  testWidgets('renders loaded policy and all security controls', (tester) async {
    fakeRepo.seededWorkspacePolicies[workspace.path] = const WorkspacePolicy(
      permissionMode: WorkspacePermissionMode.defaultMode,
      executionMode: ExecutionMode.direct,
      hostDiscoveryPolicy: HostDiscoveryPolicy.ownerOnly,
      revision: 1,
      editableByOwner: true,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: WorkspaceSecurityCard(
              device: device,
              workspace: workspace,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Workspace Security & Execution'), findsOneWidget);
    expect(find.text('Execution Backend'), findsOneWidget);
    expect(find.text('Direct Developer'), findsOneWidget);
    expect(find.text('Protected'), findsOneWidget);
    expect(find.text('Host Capability Discovery'), findsOneWidget);
    expect(find.text('Owner Only'), findsOneWidget);
    expect(find.text('Disabled'), findsOneWidget);
    expect(find.text('Permission Mode'), findsOneWidget);
    expect(find.text('Default'), findsOneWidget);
    expect(find.text('Full Access'), findsOneWidget);
  });

  testWidgets('switching execution mode calls setWorkspaceSecurityPolicy', (tester) async {
    fakeRepo.seededWorkspacePolicies[workspace.path] = const WorkspacePolicy(
      permissionMode: WorkspacePermissionMode.defaultMode,
      executionMode: ExecutionMode.direct,
      hostDiscoveryPolicy: HostDiscoveryPolicy.ownerOnly,
      revision: 1,
      editableByOwner: true,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: WorkspaceSecurityCard(
              device: device,
              workspace: workspace,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Protected'));
    await tester.pumpAndSettle();

    expect(fakeRepo.setSecurityPolicyRequests.length, 1);
    expect(
      fakeRepo.setSecurityPolicyRequests.first['execution_mode'],
      ExecutionMode.protected,
    );
  });

  testWidgets('switching host discovery calls setWorkspaceSecurityPolicy', (tester) async {
    fakeRepo.seededWorkspacePolicies[workspace.path] = const WorkspacePolicy(
      permissionMode: WorkspacePermissionMode.defaultMode,
      executionMode: ExecutionMode.direct,
      hostDiscoveryPolicy: HostDiscoveryPolicy.ownerOnly,
      revision: 1,
      editableByOwner: true,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: WorkspaceSecurityCard(
              device: device,
              workspace: workspace,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Disabled'));
    await tester.pumpAndSettle();

    expect(fakeRepo.setSecurityPolicyRequests.length, 1);
    expect(
      fakeRepo.setSecurityPolicyRequests.first['host_discovery_policy'],
      HostDiscoveryPolicy.disabled,
    );
  });

  testWidgets('switching to Full Access triggers confirmation dialog and cancels on Cancel', (tester) async {
    fakeRepo.seededWorkspacePolicies[workspace.path] = const WorkspacePolicy(
      permissionMode: WorkspacePermissionMode.defaultMode,
      executionMode: ExecutionMode.direct,
      hostDiscoveryPolicy: HostDiscoveryPolicy.ownerOnly,
      revision: 1,
      editableByOwner: true,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: WorkspaceSecurityCard(
              device: device,
              workspace: workspace,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Full Access'));
    await tester.pumpAndSettle();

    // Dialog appears
    expect(find.text('Turn on Full Access?'), findsOneWidget);

    // Cancel dialog
    await tester.tap(find.byKey(const Key('cancel_full_access_button')));
    await tester.pumpAndSettle();

    expect(find.text('Turn on Full Access?'), findsNothing);
    expect(fakeRepo.setSecurityPolicyRequests.isEmpty, isTrue);
  });

  testWidgets('switching to Full Access sends mutation when confirmed', (tester) async {
    fakeRepo.seededWorkspacePolicies[workspace.path] = const WorkspacePolicy(
      permissionMode: WorkspacePermissionMode.defaultMode,
      executionMode: ExecutionMode.direct,
      hostDiscoveryPolicy: HostDiscoveryPolicy.ownerOnly,
      revision: 1,
      editableByOwner: true,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: WorkspaceSecurityCard(
              device: device,
              workspace: workspace,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Full Access'));
    await tester.pumpAndSettle();

    // Confirm dialog
    await tester.tap(find.byKey(const Key('confirm_turn_on_full_access')));
    await tester.pumpAndSettle();

    expect(fakeRepo.setSecurityPolicyRequests.length, 1);
    expect(
      fakeRepo.setSecurityPolicyRequests.first['permission_mode'],
      WorkspacePermissionMode.fullAccess,
    );
  });

  testWidgets('disables controls and displays lock notice when editableByOwner is false', (tester) async {
    fakeRepo.seededWorkspacePolicies[workspace.path] = const WorkspacePolicy(
      permissionMode: WorkspacePermissionMode.defaultMode,
      executionMode: ExecutionMode.direct,
      hostDiscoveryPolicy: HostDiscoveryPolicy.ownerOnly,
      revision: 1,
      editableByOwner: false,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: WorkspaceSecurityCard(
              device: device,
              workspace: workspace,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('Only the device owner can modify these security settings.'),
      findsOneWidget,
    );

    // Tapping should not trigger any mutation
    await tester.tap(find.text('Protected'));
    await tester.pumpAndSettle();

    expect(fakeRepo.setSecurityPolicyRequests.isEmpty, isTrue);
  });
}
