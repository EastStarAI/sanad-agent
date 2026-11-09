import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/core/presentation/bloc/locale/locale_cubit.dart' show kSupportedLocales;
import 'package:sanad_client/features/conversations/domain/models/device_workspace.dart';
import 'package:sanad_client/features/conversations/domain/models/message_delivery_intent.dart';
import 'package:sanad_client/features/conversations/domain/models/session_execution_snapshot.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/composer_slash_commands_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_messages_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/controllers/slash_command_text_controller.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/conversation_input_composer.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/conversation_input_slices.dart';
import 'package:sanad_client/features/devices/domain/models/capability.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/dictation/domain/dictation_audio_capture.dart';
import 'package:sanad_client/features/dictation/domain/dictation_transport.dart';
import 'package:sanad_client/features/dictation/domain/dictation_transport_resolver.dart';
import 'package:sanad_client/features/dictation/presentation/bloc/dictation_cubit.dart';
import 'package:sanad_client/features/dictation/presentation/bloc/dictation_state.dart';
import 'package:sanad_client/features/voice/presentation/bloc/voice_stream_cubit.dart';
import 'package:sanad_client/infrastructure/local_tools/workspace_policy.dart';
import 'package:sanad_client/l10n/app_localizations.dart';

import '../../helpers/composer_conversation_scope.dart';
import '../../helpers/pump_app.dart';

/// The composer's trailing control while a dictation session owns the row.
///
/// Two live defects live here, and both are silent:
///
/// * pressing Send while speaking never dispatched the transcript, because the
///   row moved Send between branches and the send continuation resumed on an
///   unmounted element (v1.0.22, PR337);
/// * during an active turn the row rendered the turn's Stop *and* the mic's own
///   Stop, so one gesture had two controls.
///
/// These tests drive the real `ConversationInputComposer`, the real
/// `DictationCubit`, and the daemon's own drain order (`stop` first, then
/// `dictation_final`, then `dictation_done`).
class _Transport implements DictationTransport {
  final StreamController<Map<String, dynamic>> eventsController = StreamController<Map<String, dynamic>>.broadcast();
  final List<String> commands = <String>[];

  @override
  Stream<Map<String, dynamic>> get events => eventsController.stream;

  @override
  bool get isOpen => true;

  @override
  void sendCommand(String event, [Map<String, dynamic> payload = const {}]) => commands.add(event);

  @override
  void sendAudio(List<int> pcm16) {}

  @override
  Future<void> close() async {}
}

class _Resolver implements DictationTransportResolver {
  _Resolver(this.transport);

  final _Transport transport;

  @override
  Future<DictationTransport> resolve({
    required DeviceConfig device,
    required String sessionId,
  }) async => transport;
}

class _Capture implements DictationCapture {
  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<Stream<List<int>>> start() async => const Stream<List<int>>.empty();

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}

void main() {
  late SlashCommandTextController chatController;
  late FocusNode focusNode;
  late ComposerSlashCommandsCubit slashCubit;
  late _Transport transport;
  late DictationCubit cubit;
  late StubSessionCubit sessionCubit;
  late StubSessionMessagesCubit messagesCubit;
  late List<MessageDeliveryIntent> attempts;

  final agent = DeviceConfig(id: 'agent-1', name: 'SanadAgent', isOnline: true);
  final agentSlice = ConversationInputAgentSlice(
    activeAgent: agent,
    agents: [agent],
  );

  setUp(() {
    chatController = SlashCommandTextController();
    focusNode = FocusNode();
    slashCubit = ComposerSlashCommandsCubit(
      searcher: ({query, workspaceId}) async => const [],
    );
    transport = _Transport();
    cubit = DictationCubit(
      resolver: _Resolver(transport),
      capture: _Capture(),
      sessionIdFactory: () => 's1',
    );
    sessionCubit = StubSessionCubit();
    messagesCubit = StubSessionMessagesCubit();
    attempts = <MessageDeliveryIntent>[];
  });

  tearDown(() async {
    chatController.dispose();
    focusNode.dispose();
    await slashCubit.close();
    await cubit.close().timeout(const Duration(seconds: 2), onTimeout: () {});
    await sessionCubit.close();
    await messagesCubit.close();
    await transport.eventsController.close();
  });

  ConversationInputSlice slice({SessionExecutionSnapshot? executionSnapshot}) => ConversationInputSlice(
    isProcessing: false,
    nextMessageModel: null,
    nextMessageProviderId: null,
    nextMessageThinkingMode: null,
    availableWorkspaces: const [],
    selectedWorkspace: const DeviceWorkspace(
      id: 'w1',
      name: 'Project',
      path: '/project',
    ),
    isLoadingWorkspaces: false,
    requiresWorkspace: false,
    permissionMode: WorkspacePermissionMode.defaultMode,
    isLoadingPermissionMode: false,
    pendingSuspendedRequest: null,
    runtimeNotice: null,
    executionSnapshot: executionSnapshot,
    queuedMessages: const [],
  );

  /// An active turn: the snapshot the daemon publishes while it is running.
  SessionExecutionSnapshot runningTurn() => SessionExecutionSnapshot(
    sessionId: 'session-1',
    state: SessionExecutionState.running,
    workItemId: 'work-1',
    requestId: 'request-1',
    revision: 3,
    updatedAt: null,
  );

  Future<void> pumpComposer(
    WidgetTester tester, {
    required ConversationInputSlice inputSlice,
    Capability capabilities = const Capability(),
  }) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider<ComposerSlashCommandsCubit>.value(value: slashCubit),
          BlocProvider<VoiceStreamCubit>.value(value: FakeVoiceStreamCubit()),
          BlocProvider<SessionCubit>.value(value: sessionCubit),
          BlocProvider<SessionMessagesCubit>.value(value: messagesCubit),
          BlocProvider<DictationCubit>.value(value: cubit),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: kSupportedLocales,
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
              onSendAttempt: ({MessageDeliveryIntent intent = MessageDeliveryIntent.auto}) => attempts.add(intent),
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
  }

  /// Seeds the daemon state a real session would have: one installed model.
  Future<void> seedReadyModel(WidgetTester tester) async {
    final pending = cubit.refreshStatus(agent);
    await tester.pump();
    transport.eventsController.add({
      'event': 'stt_status',
      'supported': true,
      'ready': true,
      'selected': 'whisper-base-int8',
      'models': [
        {
          'id': 'whisper-base-int8',
          'name': 'Whisper Base Int8',
          'hosted': true,
          'installed': true,
        },
      ],
    });
    await tester.pump();
    await pending;
    await tester.pump();
  }

  Future<void> startSession(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('dictation_mic_btn')));
    await tester.pump();
    transport.eventsController.add({
      'event': 'dictation_ready',
      'model_id': 'whisper-base-int8',
      'load_ms': 12,
    });
    await tester.pump();
    await tester.pump();
  }

  Future<void> emit(WidgetTester tester, Map<String, dynamic> event) async {
    transport.eventsController.add(event);
    await tester.pump();
    await tester.pump();
  }

  /// Lets the cubit's real teardown and the send continuation finish.
  ///
  /// Both await real futures (capture stop, transport detach, `endOfFrame`),
  /// which only [WidgetTester.runAsync] supplies in a fake-async test.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
  }

  /// The daemon drains only after it has received the stop command, so every
  /// test sends the events in that order.
  Future<void> expectStopCommand(WidgetTester tester) async {
    await settle(tester);
    expect(transport.commands, contains('stop'));
  }

  testWidgets('Send pressed while listening dispatches the transcript once', (
    tester,
  ) async {
    await pumpComposer(tester, inputSlice: slice());
    await seedReadyModel(tester);
    await startSession(tester);
    expect(cubit.state.status, DictationStatus.listening);
    expect(attempts, isEmpty);

    await tester.tap(find.byKey(const Key('send_message_btn')));
    await tester.pump();
    await expectStopCommand(tester);
    // The daemon's own drain order: the final first, then done.
    await emit(tester, {'event': 'dictation_final', 'seq': 0, 'text': 'hello world'});
    await emit(tester, {'event': 'dictation_done', 'segments': 1});
    await settle(tester);

    expect(cubit.state.status, DictationStatus.idle);
    expect(chatController.exportPlainText(), 'hello world');
    expect(attempts, hasLength(1));
    expect(attempts.single, MessageDeliveryIntent.auto);
    // One dispatch, not one per rebuild of the row.
    await settle(tester);
    expect(attempts, hasLength(1));
  });

  testWidgets('Send pressed while listening dispatches once during an active turn', (
    tester,
  ) async {
    await pumpComposer(
      tester,
      inputSlice: slice(executionSnapshot: runningTurn()),
      capabilities: const Capability(supportsStop: true),
    );
    await seedReadyModel(tester);
    await startSession(tester);

    await tester.tap(find.byKey(const Key('send_message_btn')));
    await tester.pump();
    await expectStopCommand(tester);
    await emit(tester, {'event': 'dictation_final', 'seq': 0, 'text': 'steer this'});
    await emit(tester, {'event': 'dictation_done', 'segments': 1});
    await settle(tester);

    // The Client never decides steer vs queue: it dispatches `auto` and the
    // daemon classifies it, exactly as it does for typed text.
    expect(attempts, hasLength(1));
    expect(attempts.single, MessageDeliveryIntent.auto);
    expect(chatController.exportPlainText(), 'steer this');
  });

  testWidgets('while dictating during an active turn Send replaces the turn Stop', (
    tester,
  ) async {
    await pumpComposer(
      tester,
      inputSlice: slice(executionSnapshot: runningTurn()),
      capabilities: const Capability(supportsStop: true),
    );
    await seedReadyModel(tester);
    await startSession(tester);
    expect(cubit.state.status, DictationStatus.listening);

    final send = find.byKey(const Key('send_message_btn'));
    expect(send, findsOneWidget);
    expect(tester.widget<IconButton>(send).onPressed, isNotNull);
    // One stop control, and it is the dictation one.
    expect(find.byKey(const Key('stop_message_btn')), findsNothing);
    expect(find.byIcon(Icons.stop_circle_outlined), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('dictation_mic_btn')),
        matching: find.byIcon(Icons.stop_circle_outlined),
      ),
      findsOneWidget,
    );

    // The session still ends normally from the mic, and the turn Stop is back
    // once the composer is empty again.
    await tester.tap(find.byKey(const Key('dictation_mic_btn')));
    await tester.pump();
    await expectStopCommand(tester);
    await emit(tester, {'event': 'dictation_done', 'segments': 0});
    await settle(tester);
    expect(find.byKey(const Key('send_message_btn')), findsNothing);
    expect(find.byKey(const Key('stop_message_btn')), findsOneWidget);

    // The empty session announces "no speech detected"; drain that notice's own
    // timer so the test ends with no pending work.
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('the trailing Send control survives the session ending', (
    tester,
  ) async {
    await pumpComposer(tester, inputSlice: slice());
    await seedReadyModel(tester);
    await startSession(tester);

    final before = tester.element(find.byKey(const Key('send_message_btn')));

    // The owner stops with the mic, not with Send: the row still has to keep
    // the same Send element across the listening -> finalizing -> idle swap.
    await tester.tap(find.byKey(const Key('dictation_mic_btn')));
    await tester.pump();
    await expectStopCommand(tester);
    await emit(tester, {'event': 'dictation_final', 'seq': 0, 'text': 'kept'});
    await emit(tester, {'event': 'dictation_done', 'segments': 1});
    await settle(tester);

    expect(cubit.state.status, DictationStatus.idle);
    final after = find.byKey(const Key('send_message_btn'));
    expect(after, findsOneWidget);
    expect(identical(before, tester.element(after)), isTrue);
  });

  testWidgets('unsent dictation text keeps the turn Stop hidden until it leaves', (
    tester,
  ) async {
    await pumpComposer(
      tester,
      inputSlice: slice(executionSnapshot: runningTurn()),
      capabilities: const Capability(supportsStop: true),
    );
    await seedReadyModel(tester);
    await startSession(tester);

    // A streaming model finalizes a segment while the user is still speaking.
    await emit(tester, {'event': 'dictation_final', 'seq': 0, 'text': 'unsent words'});
    await tester.tap(find.byKey(const Key('dictation_mic_btn')));
    await tester.pump();
    await expectStopCommand(tester);
    await emit(tester, {'event': 'dictation_done', 'segments': 1});
    await settle(tester);
    expect(chatController.exportPlainText(), 'unsent words');

    // The turn is still running, but the composer holds text: Send owns the
    // slot, the same rule typed text already follows.
    expect(find.byKey(const Key('stop_message_btn')), findsNothing);
    expect(find.byKey(const Key('send_message_btn')), findsOneWidget);

    // Clearing the text hands the slot back to the turn Stop.
    await tester.enterText(find.byKey(const Key('chat_input')), '');
    await tester.pump();
    expect(find.byKey(const Key('send_message_btn')), findsNothing);
    expect(find.byKey(const Key('stop_message_btn')), findsOneWidget);

    // And typing again takes it back, in the other direction.
    await tester.enterText(find.byKey(const Key('chat_input')), 'typed');
    await tester.pump();
    expect(find.byKey(const Key('send_message_btn')), findsOneWidget);
    expect(find.byKey(const Key('stop_message_btn')), findsNothing);
  });
}
