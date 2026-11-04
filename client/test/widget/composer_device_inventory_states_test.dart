// A successful sign-in must never render as "no devices".
//
// Live reproduction (iPhone, 1.0.20/21): authentication completed, the cloud
// gateway connected and dropped 70ms later, and the inventory surface showed an
// authoritative empty state for ~24s until a resume-triggered reconnect fetched
// the devices. The chip therefore distinguishes a pending inventory (loading)
// from an authoritative empty result, and the empty copy names devices, not
// agents.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/core/presentation/bloc/locale/locale_cubit.dart' show kSupportedLocales;
import 'package:sanad_client/features/conversations/domain/models/device_workspace.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/conversation_context_chips.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/conversation_input_slices.dart';
import 'package:sanad_client/features/devices/domain/models/capability.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/devices/presentation/bloc/device_state.dart'
    show DevicesPhase;
import 'package:sanad_client/infrastructure/local_tools/workspace_policy.dart';
import 'package:sanad_client/l10n/app_localizations.dart';

void main() {
  const workspace = DeviceWorkspace(id: 'workspace-1', name: 'Project', path: '/project');
  const capabilities = Capability(
    supportsModelChange: false,
    supportsWorkspaces: false,
    supportsWorkspaceSelection: false,
  );

  const inputSlice = ConversationInputSlice(
    isProcessing: false,
    nextMessageModel: 'gpt-4o',
    nextMessageProviderId: 'provider-1',
    nextMessageThinkingMode: null,
    availableWorkspaces: [workspace],
    selectedWorkspace: null,
    isLoadingWorkspaces: false,
    requiresWorkspace: false,
    permissionMode: WorkspacePermissionMode.defaultMode,
    isLoadingPermissionMode: false,
    pendingSuspendedRequest: null,
    runtimeNotice: null,
    queuedMessages: [],
  );

  Widget host(ConversationInputAgentSlice agentSlice) {
    return MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: kSupportedLocales,
      home: Scaffold(
        body: ConversationContextChips(
          agentSelectorKey: GlobalKey<PopupMenuButtonState<String>>(),
          agentSlice: agentSlice,
          inputSlice: inputSlice,
          capabilities: capabilities,
          sessionId: null,
          inputBgColor: Colors.white,
          chipBgColor: Colors.grey.shade200,
          borderColor: Colors.grey,
          dimTextColor: Colors.black54,
          onPickAndCreateWorkspace: (_) async {},
        ),
      ),
    );
  }

  testWidgets('a pending inventory shows a loading chip, never an empty claim', (tester) async {
    await tester.pumpWidget(
      host(const ConversationInputAgentSlice(activeAgent: null, agents: [], phase: DevicesPhase.loading)),
    );

    expect(find.text('Loading devices…'), findsOneWidget);
    expect(find.text('No devices'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('only an authoritative empty result claims there are no devices', (tester) async {
    await tester.pumpWidget(
      host(const ConversationInputAgentSlice(activeAgent: null, agents: [], phase: DevicesPhase.readyEmpty)),
    );

    expect(find.text('No devices'), findsOneWidget);
    expect(find.text('Loading devices…'), findsNothing);
  });

  testWidgets('a retained cache during refresh keeps the loading phase', (tester) async {
    final cached = [DeviceConfig(id: 'cloud-device', name: 'Cloud Machine', isOnline: true)];
    await tester.pumpWidget(
      host(
        ConversationInputAgentSlice(
          activeAgent: null,
          agents: cached,
          phase: DevicesPhase.stale,
        ),
      ),
    );

    // Cached devices are selectable, so no loading claim replaces the selector.
    expect(find.text('Loading devices…'), findsNothing);
    expect(find.text('No devices'), findsNothing);
  });
}
