// The composer's chips are reusable, state-agnostic widgets extracted from the
// composer. This suite pins the surface they contribute: every string key,
// every `Semantics` label/flag, every tooltip, and every visible string. The
// extraction is only a move when these lists stay identical (113b C5).

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/core/presentation/bloc/locale/locale_cubit.dart' show kSupportedLocales;
import 'package:sanad_client/features/conversations/domain/models/device_workspace.dart';
import 'package:sanad_client/features/conversations/domain/models/message_delivery_intent.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/composer_slash_commands_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_messages_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_messages_state.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_state.dart';
import 'package:sanad_client/features/conversations/presentation/controllers/slash_command_text_controller.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/conversation_context_chips.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/conversation_input_composer.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/conversation_input_slices.dart';
import 'package:sanad_client/features/devices/domain/models/capability.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/voice/presentation/bloc/voice_stream_cubit.dart';
import 'package:sanad_client/infrastructure/local_tools/workspace_policy.dart';
import 'package:sanad_client/l10n/app_localizations.dart';

import '../helpers/pump_app.dart';

/// The composer surface, captured before the chips became reusable widgets.
const _composerSurface = <String>[
  'key: chat_input',
  'key: composer_add_attachment',
  'key: composer_focus_surface',
  'key: model_selector_btn',
  'key: route_thinking_mode_unavailable',
  'key: send_message_btn',
  'semantics-button: Add attachments',
  'semantics-tooltip: Add attachments',
  'semantics-tooltip: Send message',
  'semantics-tooltip: Thinking mode selection is not available for this device.',
  'semantics: Add attachments',
  'text: Ask Sanad anything',
  'text: Provider 1 | gpt-4o',
  'text: Unavailable',
  'tooltip: Add attachments',
  'tooltip: Send message',
  'tooltip: Thinking mode selection is not available for this device.',
];

/// The new-conversation context chips with a bound session workspace.
const _contextChipsSurface = <String>[
  'key: workspace_selector_btn',
  'semantics-tooltip: Select Device',
  'semantics-tooltip: Workspace is locked for this session',
  'text: Project',
  'text: SanadAgent',
  'tooltip: Select Device',
  'tooltip: Workspace is locked for this session',
];

/// The workspace menu on the new-conversation surface, where it is enabled.
const _workspaceMenuSurface = <String>[
  'key: workspace_item_workspace-1',
  'key: workspace_selector_btn',
  'semantics-tooltip: Select Device',
  'semantics-tooltip: Select Workspace',
  'semantics: Dismiss menu',
  'semantics: Popup menu',
  'text: /project',
  'text: Add New Workspace',
  'text: No workspace',
  'text: Project',
  'text: SanadAgent',
  'tooltip: Select Device',
  'tooltip: Select Workspace',
];

void main() {
  late SlashCommandTextController chatController;
  late FocusNode focusNode;
  late ComposerSlashCommandsCubit slashCubit;
  late FakeVoiceStreamCubit voiceCubit;

  final agent = DeviceConfig(id: 'agent-1', name: 'SanadAgent', isOnline: true);
  final agentSlice = ConversationInputAgentSlice(activeAgent: agent, agents: [agent]);
  const workspace = DeviceWorkspace(id: 'workspace-1', name: 'Project', path: '/project');

  const capabilities = Capability(
    supportsModelChange: true,
    supportsWorkspaces: true,
    supportsWorkspaceSelection: true,
  );

  final slice = ConversationInputSlice(
    isProcessing: false,
    nextMessageModel: 'gpt-4o',
    nextMessageProviderId: 'provider-1',
    nextMessageThinkingMode: null,
    availableWorkspaces: const [workspace],
    selectedWorkspace: workspace,
    isLoadingWorkspaces: false,
    requiresWorkspace: false,
    permissionMode: WorkspacePermissionMode.defaultMode,
    isLoadingPermissionMode: false,
    pendingSuspendedRequest: null,
    runtimeNotice: null,
    queuedMessages: const [],
  );

  setUp(() {
    chatController = SlashCommandTextController();
    focusNode = FocusNode();
    slashCubit = ComposerSlashCommandsCubit(
      searcher: ({query, workspaceId}) async => const [],
    );
    voiceCubit = FakeVoiceStreamCubit();
  });

  tearDown(() async {
    chatController.dispose();
    focusNode.dispose();
    await slashCubit.close();
    await voiceCubit.close();
  });

  Widget chipsApp({required String? sessionId}) {
    return MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: kSupportedLocales,
      home: Scaffold(
        body: ConversationContextChips(
          agentSelectorKey: GlobalKey<PopupMenuButtonState<String>>(),
          agentSlice: agentSlice,
          inputSlice: slice,
          capabilities: capabilities,
          sessionId: sessionId,
          inputBgColor: Colors.white,
          chipBgColor: Colors.grey.shade200,
          borderColor: Colors.grey,
          dimTextColor: Colors.black54,
          onPickAndCreateWorkspace: (_) async {},
        ),
      ),
    );
  }

  testWidgets('composer keeps every key, semantics node, and string', (tester) async {
    final sessionCubit = _StubSessionCubit();
    final messagesCubit = _StubSessionMessagesCubit();
    addTearDown(sessionCubit.close);
    addTearDown(messagesCubit.close);

    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider<ComposerSlashCommandsCubit>.value(value: slashCubit),
          BlocProvider<VoiceStreamCubit>.value(value: voiceCubit),
          BlocProvider<SessionCubit>.value(value: sessionCubit),
          BlocProvider<SessionMessagesCubit>.value(value: messagesCubit),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: kSupportedLocales,
          home: Scaffold(
            body: ConversationInputComposer(
              chatController: chatController,
              chatFocusNode: focusNode,
              agentSlice: agentSlice,
              inputSlice: slice,
              capabilities: capabilities,
              inputBgColor: Colors.white,
              borderColor: Colors.grey,
              dimTextColor: Colors.black54,
              chipBgColor: Colors.grey.shade200,
              onSelectSlashSuggestion: (_) {},
              onSendAttempt: ({MessageDeliveryIntent intent = MessageDeliveryIntent.auto}) {},
              onStop: () {},
              sessionId: 'session-1',
              onConfirmFullAccess: () async => true,
              agentSelectorKey: GlobalKey<PopupMenuButtonState<String>>(),
              onPickAndCreateWorkspace: (_) async {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(_surfaceSnapshot(tester), _composerSurface);
  });

  testWidgets('context chips keep every key, semantics node, and string', (tester) async {
    await tester.pumpWidget(
      chipsApp(
        sessionId: 'session-1',
      ),
    );
    await tester.pump();

    expect(_surfaceSnapshot(tester), _contextChipsSurface);
  });

  testWidgets('workspace menu keeps every key, semantics node, and string', (tester) async {
    // A bound session locks the chip, so the enabled menu is pinned on the new
    // conversation surface (no session id).
    await tester.pumpWidget(chipsApp(sessionId: null));
    await tester.pump();
    await tester.tap(find.byKey(const Key('workspace_selector_btn')));
    await tester.pumpAndSettle();

    expect(_surfaceSnapshot(tester), _workspaceMenuSurface);
  });

}

/// String keys, semantics labels, tooltips, and visible strings currently in
/// the tree, sorted so the listing is stable across rebuilds. Framework
/// `GlobalKey`s are ignored because their identities are per-run.
List<String> _surfaceSnapshot(WidgetTester tester) {
  final entries = <String>{};
  for (final element in tester.allElements) {
    final widget = element.widget;
    final key = widget.key;
    if (key is ValueKey<String>) entries.add('key: ${key.value}');
    if (widget is Semantics) {
      final label = widget.properties.label;
      if (label != null && label.isNotEmpty) {
        entries.add('semantics: $label');
        if (widget.properties.button == true) entries.add('semantics-button: $label');
      }
      final tooltip = widget.properties.tooltip;
      if (tooltip != null && tooltip.isNotEmpty) entries.add('semantics-tooltip: $tooltip');
    }
    if (widget is Tooltip) {
      final message = widget.message;
      if (message != null && message.isNotEmpty) entries.add('tooltip: $message');
    }
    if (widget is Text) {
      final data = widget.data;
      if (data != null && data.isNotEmpty) entries.add('text: $data');
    }
  }
  final sorted = entries.toList()..sort();
  return sorted;
}

class _StubSessionCubit extends Cubit<SessionState> implements SessionCubit {
  _StubSessionCubit() : super(const SessionState());

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _StubSessionMessagesCubit extends Cubit<SessionMessagesState> implements SessionMessagesCubit {
  _StubSessionMessagesCubit() : super(const SessionMessagesState());

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
