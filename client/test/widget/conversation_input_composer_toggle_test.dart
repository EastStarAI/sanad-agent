import 'package:sanad_client/features/conversations/domain/models/slash_command_entry.dart';
import 'package:sanad_client/features/conversations/domain/models/message_delivery_intent.dart';
import 'package:sanad_client/features/conversations/domain/models/runtime_notice.dart';
import 'package:sanad_client/features/conversations/domain/models/device_workspace.dart';
import 'package:sanad_client/features/conversations/domain/models/session_execution_snapshot.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/composer_slash_commands_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/controllers/slash_command_text_controller.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/conversation_input_composer.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/conversation_input_slices.dart';
import 'package:sanad_client/features/devices/domain/models/capability.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/voice/presentation/bloc/voice_stream_cubit.dart';
import 'package:sanad_client/infrastructure/local_tools/workspace_policy.dart';
import 'package:sanad_client/utils/app_platform.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/pump_app.dart';

void main() {
  late SlashCommandTextController chatController;
  late FocusNode focusNode;
  late ComposerSlashCommandsCubit slashCubit;
  late FakeVoiceStreamCubit voiceCubit;

  final agent = DeviceConfig(id: 'agent-1', name: 'SanadAgent', isOnline: true);
  final offlineAgent = DeviceConfig(id: 'agent-1', name: 'SanadAgent', isOnline: false);
  final onlineAgentSlice = ConversationInputAgentSlice(
    activeAgent: agent,
    agents: [agent],
  );
  final offlineAgentSlice = ConversationInputAgentSlice(
    activeAgent: offlineAgent,
    agents: [offlineAgent],
  );

  setUp(() {
    AppPlatform.overrideIsMobile = null;
    chatController = SlashCommandTextController();
    focusNode = FocusNode();
    slashCubit = ComposerSlashCommandsCubit(
      searcher: ({query, workspaceId}) async => const <SlashCommandEntry>[],
    );
    voiceCubit = FakeVoiceStreamCubit();
  });

  tearDown(() async {
    AppPlatform.overrideIsMobile = null;
    chatController.dispose();
    focusNode.dispose();
    await slashCubit.close();
  });

  ConversationInputSlice idleSlice({
    SessionExecutionSnapshot? executionSnapshot,
    bool isAwaitingMessageAcceptance = false,
  }) => ConversationInputSlice(
    isProcessing: false,
    nextMessageModel: null,
    nextMessageProviderId: null,
    nextMessageThinkingMode: null,
    availableWorkspaces: [],
    selectedWorkspace: null,
    isLoadingWorkspaces: false,
    requiresWorkspace: false,
    permissionMode: WorkspacePermissionMode.defaultMode,
    isLoadingPermissionMode: false,
    pendingSuspendedRequest: null,
    runtimeNotice: null,
    executionSnapshot: executionSnapshot,
    isAwaitingMessageAcceptance: isAwaitingMessageAcceptance,
    queuedMessages: [],
  );

  Future<void> pumpComposer(
    WidgetTester tester, {
    required Capability capabilities,
    required ConversationInputSlice inputSlice,
    required ConversationInputAgentSlice agentSlice,
    void Function({MessageDeliveryIntent intent})? onSendAttempt,
  }) {
    return tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider<ComposerSlashCommandsCubit>.value(value: slashCubit),
          BlocProvider<VoiceStreamCubit>.value(value: voiceCubit),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: ConversationInputComposer(
              chatController: chatController,
              chatFocusNode: focusNode,
              agentSlice: agentSlice,
              inputSlice: inputSlice,
              capabilities: capabilities,
              inputBgColor: Colors.white,
              borderColor: Colors.grey,
              dimTextColor: Colors.black54,
              chipBgColor: Colors.grey.shade200,
              onSelectSlashSuggestion: (_) {},
              onSendAttempt: onSendAttempt ?? ({intent = MessageDeliveryIntent.auto}) {},
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
  }

  testWidgets('shows voice button when input is empty and supportsVoiceCall is true', (tester) async {
    await pumpComposer(
      tester,
      capabilities: const Capability(supportsVoiceCall: true),
      inputSlice: idleSlice(),
      agentSlice: onlineAgentSlice,
    );
    await tester.pump();

    expect(find.byKey(const Key('voice_chat_btn')), findsOneWidget);
    expect(find.byKey(const Key('send_message_btn')), findsNothing);
  });

  testWidgets('hides voice button and shows send button when input has content', (tester) async {
    await pumpComposer(
      tester,
      capabilities: const Capability(supportsVoiceCall: true),
      inputSlice: idleSlice(),
      agentSlice: onlineAgentSlice,
    );
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'hello sanad');
    await tester.pump();

    expect(find.byKey(const Key('voice_chat_btn')), findsNothing);
    expect(find.byKey(const Key('send_message_btn')), findsOneWidget);
  });

  testWidgets('shows acceptance spinner and disables duplicate send while awaiting canonical acceptance', (
    tester,
  ) async {
    await pumpComposer(
      tester,
      capabilities: const Capability(supportsVoiceCall: true),
      inputSlice: idleSlice(isAwaitingMessageAcceptance: true),
      agentSlice: onlineAgentSlice,
    );
    await tester.enterText(find.byKey(const Key('chat_input')), 'hello sanad');
    await tester.pump();

    expect(find.byKey(const Key('send_message_acceptance_indicator')), findsOneWidget);
    expect(find.byKey(const Key('send_message_btn')), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(
      tester.widget<IconButton>(find.byKey(const Key('send_message_acceptance_indicator'))).onPressed,
      isNull,
    );
  });

  testWidgets('Enter sends auto while Ctrl and Command Enter request queue', (tester) async {
    final intents = <MessageDeliveryIntent>[];
    await pumpComposer(
      tester,
      capabilities: const Capability(),
      inputSlice: idleSlice(),
      agentSlice: onlineAgentSlice,
      onSendAttempt: ({intent = MessageDeliveryIntent.auto}) => intents.add(intent),
    );
    await tester.enterText(find.byKey(const Key('chat_input')), 'follow up');
    await tester.tap(find.byKey(const Key('chat_input')));

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);

    expect(intents, [MessageDeliveryIntent.auto, MessageDeliveryIntent.queue, MessageDeliveryIntent.queue]);
  });

  testWidgets('Shift+Enter inserts a composer line break without sending', (tester) async {
    final intents = <MessageDeliveryIntent>[];
    await pumpComposer(
      tester,
      capabilities: const Capability(),
      inputSlice: idleSlice(),
      agentSlice: onlineAgentSlice,
      onSendAttempt: ({intent = MessageDeliveryIntent.auto}) => intents.add(intent),
    );
    final inputFinder = find.byKey(const Key('chat_input'));
    await tester.enterText(inputFinder, 'first line');
    await tester.tap(inputFinder);
    chatController.selection = TextSelection.collapsed(offset: chatController.text.length);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();

    expect(chatController.exportPlainText(), 'first line\n');
    expect(intents, isEmpty);
  });

  testWidgets('mobile Enter remains a multiline action and does not send', (tester) async {
    AppPlatform.overrideIsMobile = true;
    final intents = <MessageDeliveryIntent>[];
    await pumpComposer(
      tester,
      capabilities: const Capability(),
      inputSlice: idleSlice(),
      agentSlice: onlineAgentSlice,
      onSendAttempt: ({intent = MessageDeliveryIntent.auto}) => intents.add(intent),
    );

    final inputFinder = find.byKey(const Key('chat_input'));
    await tester.enterText(inputFinder, 'first line');
    await tester.tap(inputFinder);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.enterText(inputFinder, 'first line\nsecond line');
    await tester.pump();

    final input = tester.widget<TextField>(inputFinder);
    expect(input.keyboardType, TextInputType.multiline);
    expect(input.textInputAction, TextInputAction.newline);
    expect(chatController.exportPlainText(), 'first line\nsecond line');
    expect(intents, isEmpty);
  });

  testWidgets('running send button explains steer and explicit queue shortcuts', (tester) async {
    await pumpComposer(
      tester,
      capabilities: const Capability(),
      inputSlice: idleSlice(
        executionSnapshot: SessionExecutionSnapshot(
          sessionId: 'session-1',
          state: SessionExecutionState.running,
          workItemId: 'work-1',
          requestId: 'request-1',
          revision: 1,
          updatedAt: DateTime.utc(2026, 7, 15),
        ),
      ),
      agentSlice: onlineAgentSlice,
    );
    await tester.enterText(find.byKey(const Key('chat_input')), 'follow up');
    await tester.pump();

    expect(find.byTooltip('Press Enter to steer • Ctrl/Cmd+Enter to queue'), findsOneWidget);
  });

  testWidgets('hides voice button when supportsVoiceCall is false', (
    tester,
  ) async {
    await pumpComposer(
      tester,
      capabilities: const Capability(supportsVoiceCall: false),
      inputSlice: idleSlice(),
      agentSlice: onlineAgentSlice,
    );
    await tester.pump();

    expect(find.byKey(const Key('voice_chat_btn')), findsNothing);
    expect(find.byKey(const Key('send_message_btn')), findsOneWidget);
  });

  testWidgets('hides voice button when agent is offline even with empty input', (tester) async {
    await pumpComposer(
      tester,
      capabilities: const Capability(supportsVoiceCall: true),
      inputSlice: idleSlice(),
      agentSlice: offlineAgentSlice,
    );
    await tester.pump();

    expect(find.byKey(const Key('voice_chat_btn')), findsNothing);
    // Send button is still shown as an affordance for offline agents.
    expect(find.byKey(const Key('send_message_btn')), findsOneWidget);
  });

  testWidgets('hides voice button and shows stop button when agent is processing', (tester) async {
    const processingSlice = ConversationInputSlice(
      isProcessing: true,
      nextMessageModel: null,
      nextMessageProviderId: null,
      nextMessageThinkingMode: null,
      availableWorkspaces: [],
      selectedWorkspace: null,
      isLoadingWorkspaces: false,
      requiresWorkspace: false,
      permissionMode: WorkspacePermissionMode.defaultMode,
      isLoadingPermissionMode: false,
      pendingSuspendedRequest: null,
      runtimeNotice: null,
      executionSnapshot: SessionExecutionSnapshot(
        sessionId: 'session-1',
        state: SessionExecutionState.running,
        workItemId: 'work-1',
        requestId: 'request-1',
        revision: 1,
        updatedAt: null,
      ),
      queuedMessages: [],
    );
    await pumpComposer(
      tester,
      capabilities: const Capability(supportsVoiceCall: true, supportsStop: true),
      inputSlice: processingSlice,
      agentSlice: onlineAgentSlice,
    );
    await tester.pump();

    expect(find.byKey(const Key('voice_chat_btn')), findsNothing);
    expect(find.byKey(const Key('send_message_btn')), findsNothing);
    // Stop button should be visible instead
    expect(find.byIcon(Icons.stop_circle_outlined), findsOneWidget);
  });

  testWidgets('renders runtime notice banner actions above the composer', (tester) async {
    const waitingSlice = ConversationInputSlice(
      isProcessing: false,
      nextMessageModel: null,
      nextMessageProviderId: 'provider-2',
      nextMessageThinkingMode: null,
      availableWorkspaces: [],
      selectedWorkspace: null,
      isLoadingWorkspaces: false,
      requiresWorkspace: false,
      permissionMode: WorkspacePermissionMode.defaultMode,
      isLoadingPermissionMode: false,
      pendingSuspendedRequest: null,
      runtimeNotice: RuntimeNotice(
        sessionId: 'session-1',
        requestId: 'req-1',
        status: 'waiting',
        reason: 'provider_rate_limit',
        title: 'NVIDIA NIM rate limit reached',
        retryAfterMs: 24000,
        requestsPerMinuteLimit: 38,
        actions: ['stop', 'continue_with_provider'],
      ),
      executionSnapshot: SessionExecutionSnapshot(
        sessionId: 'session-1',
        state: SessionExecutionState.waiting,
        workItemId: 'work-1',
        requestId: 'req-stop-visible',
        revision: 2,
        updatedAt: null,
      ),
      queuedMessages: [],
    );

    await pumpComposer(
      tester,
      capabilities: const Capability(supportsVoiceCall: true, supportsStop: true),
      inputSlice: waitingSlice,
      agentSlice: onlineAgentSlice,
    );
    await tester.pump();

    expect(find.text('NVIDIA NIM rate limit reached'), findsOneWidget);
    expect(find.textContaining('Continuing automatically in'), findsOneWidget);
    expect(find.text('Stop'), findsOneWidget);
    expect(find.text('Change Provider'), findsOneWidget);
  });

  testWidgets('formats long runtime recovery countdowns with days and hours', (tester) async {
    final longWaitSlice = ConversationInputSlice(
      isProcessing: false,
      nextMessageModel: null,
      nextMessageProviderId: 'provider-2',
      nextMessageThinkingMode: null,
      availableWorkspaces: const [],
      selectedWorkspace: null,
      isLoadingWorkspaces: false,
      requiresWorkspace: false,
      permissionMode: WorkspacePermissionMode.defaultMode,
      isLoadingPermissionMode: false,
      pendingSuspendedRequest: null,
      runtimeNotice: RuntimeNotice(
        sessionId: 'session-1',
        requestId: 'req-long-wait',
        status: 'waiting',
        reason: 'usage_limit',
        title: 'Usage limit reached',
        retryAfterMs: const Duration(days: 1, hours: 5, minutes: 10).inMilliseconds,
        actions: const ['stop'],
      ),
      queuedMessages: const [],
    );

    await pumpComposer(
      tester,
      capabilities: const Capability(supportsVoiceCall: true, supportsStop: true),
      inputSlice: longWaitSlice,
      agentSlice: onlineAgentSlice,
    );
    await tester.pump();

    expect(find.textContaining('Continuing automatically in 1d 5h.'), findsOneWidget);
  });

  testWidgets('shows the stop affordance while a runtime notice is waiting even when processing is false', (
    tester,
  ) async {
    const waitingSlice = ConversationInputSlice(
      isProcessing: false,
      nextMessageModel: null,
      nextMessageProviderId: 'provider-2',
      nextMessageThinkingMode: null,
      availableWorkspaces: [],
      selectedWorkspace: null,
      isLoadingWorkspaces: false,
      requiresWorkspace: false,
      permissionMode: WorkspacePermissionMode.defaultMode,
      isLoadingPermissionMode: false,
      pendingSuspendedRequest: null,
      runtimeNotice: RuntimeNotice(
        sessionId: 'session-1',
        requestId: 'req-stop-visible',
        status: 'waiting',
        reason: 'provider_rate_limit',
        title: 'Waiting for NVIDIA NIM',
        retryAfterMs: 24000,
        actions: ['stop'],
      ),
      executionSnapshot: SessionExecutionSnapshot(
        sessionId: 'session-1',
        state: SessionExecutionState.waiting,
        workItemId: 'work-1',
        requestId: 'req-stop-visible',
        revision: 2,
        updatedAt: null,
      ),
      queuedMessages: [],
    );

    await pumpComposer(
      tester,
      capabilities: const Capability(supportsVoiceCall: true, supportsStop: true),
      inputSlice: waitingSlice,
      agentSlice: onlineAgentSlice,
    );
    await tester.pump();

    expect(find.text('Stop'), findsOneWidget);
    expect(find.byIcon(Icons.stop_circle_outlined), findsOneWidget);
  });

  testWidgets('derives Stop visibility and enabled state from all seven authoritative states', (
    tester,
  ) async {
    for (final executionState in SessionExecutionState.values) {
      await pumpComposer(
        tester,
        capabilities: const Capability(supportsStop: true),
        inputSlice: ConversationInputSlice(
          isProcessing: false,
          nextMessageModel: null,
          nextMessageProviderId: null,
          nextMessageThinkingMode: null,
          availableWorkspaces: const [],
          selectedWorkspace: null,
          isLoadingWorkspaces: false,
          requiresWorkspace: false,
          permissionMode: WorkspacePermissionMode.defaultMode,
          isLoadingPermissionMode: false,
          pendingSuspendedRequest: null,
          runtimeNotice: null,
          executionSnapshot: SessionExecutionSnapshot(
            sessionId: 'session-1',
            state: executionState,
            workItemId: executionState == SessionExecutionState.idle ? null : 'work-1',
            requestId: executionState == SessionExecutionState.idle ? null : 'request-1',
            revision: 3,
            updatedAt: null,
          ),
          queuedMessages: const [],
        ),
        agentSlice: onlineAgentSlice,
      );
      await tester.pump();

      final stopButton = find.byKey(const Key('stop_message_btn'));
      if (executionState == SessionExecutionState.idle) {
        expect(stopButton, findsNothing, reason: executionState.name);
      } else {
        expect(stopButton, findsOneWidget, reason: executionState.name);
        final button = tester.widget<IconButton>(stopButton);
        expect(
          button.onPressed != null,
          executionState != SessionExecutionState.stopping,
          reason: executionState.name,
        );
      }
    }
  });

  testWidgets('stopping replaces the Stop icon with a disabled red progress indicator', (
    tester,
  ) async {
    const stoppingSlice = ConversationInputSlice(
      isProcessing: false,
      nextMessageModel: null,
      nextMessageProviderId: null,
      nextMessageThinkingMode: null,
      availableWorkspaces: [],
      selectedWorkspace: null,
      isLoadingWorkspaces: false,
      requiresWorkspace: false,
      permissionMode: WorkspacePermissionMode.defaultMode,
      isLoadingPermissionMode: false,
      pendingSuspendedRequest: null,
      runtimeNotice: null,
      executionSnapshot: SessionExecutionSnapshot(
        sessionId: 'session-1',
        state: SessionExecutionState.stopping,
        workItemId: 'work-1',
        requestId: 'request-1',
        revision: 4,
        updatedAt: null,
      ),
      queuedMessages: [],
    );

    await pumpComposer(
      tester,
      capabilities: const Capability(supportsStop: true),
      inputSlice: stoppingSlice,
      agentSlice: onlineAgentSlice,
    );
    await tester.pump();

    final stopButton = find.byKey(const Key('stop_message_btn'));
    final progress = find.byKey(
      const Key('stop_message_progress_indicator'),
    );
    expect(stopButton, findsOneWidget);
    expect(tester.widget<IconButton>(stopButton).onPressed, isNull);
    expect(find.byIcon(Icons.stop_circle_outlined), findsNothing);
    expect(progress, findsOneWidget);
    expect(
      tester
          .widget<CircularProgressIndicator>(
            find.descendant(
              of: progress,
              matching: find.byType(CircularProgressIndicator),
            ),
          )
          .color,
      Theme.of(tester.element(stopButton)).colorScheme.error,
    );
    expect(find.byTooltip('Stopping response'), findsOneWidget);
  });

  testWidgets('voice and send buttons expose 32x32 targets', (tester) async {
    // Voice button: empty input, agent online
    await pumpComposer(
      tester,
      capabilities: const Capability(supportsVoiceCall: true),
      inputSlice: idleSlice(),
      agentSlice: onlineAgentSlice,
    );
    await tester.pump();
    final voiceSize = tester.getSize(
      find
          .ancestor(
            of: find.byKey(const Key('voice_chat_btn')),
            matching: find.byType(SizedBox),
          )
          .first,
    );
    expect(voiceSize.width, 32);
    expect(voiceSize.height, 32);
    expect(find.byTooltip('Start voice session'), findsOneWidget);

    // Send button: input has content
    await tester.enterText(find.byType(TextField), 'some text');
    await tester.pump();
    final sendSize = tester.getSize(
      find
          .ancestor(
            of: find.byKey(const Key('send_message_btn')),
            matching: find.byType(SizedBox),
          )
          .first,
    );
    expect(sendSize.width, 32);
    expect(sendSize.height, 32);
    expect(find.byTooltip('Send message'), findsOneWidget);
  });

  testWidgets('send button keeps its 32x32 target when stop is supported', (tester) async {
    // Send button: input has content
    await pumpComposer(
      tester,
      capabilities: const Capability(supportsVoiceCall: true, supportsStop: true),
      inputSlice: idleSlice(),
      agentSlice: onlineAgentSlice,
    );
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'some text');
    await tester.pump();
    final sendSize = tester.getSize(
      find
          .ancestor(
            of: find.byKey(const Key('send_message_btn')),
            matching: find.byType(SizedBox),
          )
          .first,
    );
    expect(sendSize.width, 32);
    expect(sendSize.height, 32);
  });

  testWidgets('bottom controls do not overflow on a narrow mobile width', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(280, 500));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await pumpComposer(
      tester,
      capabilities: const Capability(
        supportsToolPermissions: true,
      ),
      inputSlice: const ConversationInputSlice(
        isProcessing: false,
        nextMessageModel: null,
        nextMessageProviderId: null,
        nextMessageThinkingMode: null,
        availableWorkspaces: [
          DeviceWorkspace(id: 'workspace-1', name: 'Project', path: '/project'),
        ],
        selectedWorkspace: DeviceWorkspace(
          id: 'workspace-1',
          name: 'Project',
          path: '/project',
        ),
        isLoadingWorkspaces: false,
        requiresWorkspace: false,
        permissionMode: WorkspacePermissionMode.defaultMode,
        isLoadingPermissionMode: false,
        pendingSuspendedRequest: null,
        runtimeNotice: null,
        queuedMessages: [],
      ),
      agentSlice: onlineAgentSlice,
    );
    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('send_message_btn')), findsOneWidget);
  });
}
