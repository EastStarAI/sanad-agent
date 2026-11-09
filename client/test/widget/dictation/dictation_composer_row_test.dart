import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:sanad_client/core/presentation/bloc/locale/locale_cubit.dart'
    show kSupportedLocales;
import 'package:sanad_client/features/conversations/domain/models/device_workspace.dart';
import 'package:sanad_client/features/conversations/domain/models/message_delivery_intent.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/composer_slash_commands_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_messages_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_messages_state.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_state.dart';
import 'package:sanad_client/features/conversations/domain/models/session.dart';
import 'package:sanad_client/features/conversations/presentation/controllers/slash_command_text_controller.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/conversation_input_composer.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/conversation_input_slices.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/route_thinking_mode_selector.dart';
import 'package:sanad_client/features/devices/domain/models/capability.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/dictation/domain/dictation_audio_capture.dart';
import 'package:sanad_client/features/dictation/domain/dictation_transport.dart';
import 'package:sanad_client/features/dictation/domain/dictation_transport_resolver.dart';
import 'package:sanad_client/features/dictation/presentation/bloc/dictation_cubit.dart';
import 'package:sanad_client/features/dictation/presentation/bloc/dictation_state.dart';
import 'package:sanad_client/features/dictation/presentation/widgets/dictation_mic_button.dart';
import 'package:sanad_client/features/voice/presentation/bloc/voice_stream_cubit.dart';
import 'package:sanad_client/infrastructure/local_tools/workspace_policy.dart';
import 'package:sanad_client/l10n/app_localizations.dart';

import '../../helpers/pump_app.dart';

/// The composer row is the only place the dictation meter lives, and every
/// selector in that row yields to it while the user speaks. These tests pin the
/// swap in both directions, because the failure mode is silent: a control that
/// stays visible while the meter is drawn behind it, or a control that never
/// comes back after the session ends.
class _Transport implements DictationTransport {
  final StreamController<Map<String, dynamic>> eventsController =
      StreamController<Map<String, dynamic>>.broadcast();
  final List<String> commands = <String>[];

  @override
  Stream<Map<String, dynamic>> get events => eventsController.stream;

  @override
  bool get isOpen => true;

  @override
  void sendCommand(String event, [Map<String, dynamic> payload = const {}]) =>
      commands.add(event);

  @override
  void sendAudio(List<int> pcm16) {}

  @override
  Future<void> close() async {}
}

class _Capture implements DictationCapture {
  final StreamController<List<int>> controller =
      StreamController<List<int>>.broadcast();

  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<Stream<List<int>>> start() async => controller.stream;

  @override
  Future<void> stop() async {
    if (!controller.isClosed) await controller.close();
  }

  @override
  Future<void> dispose() async {
    if (!controller.isClosed) await controller.close();
  }
}

class _Resolver implements DictationResolver {
  _Resolver(this._transport);

  final _Transport _transport;

  @override
  Future<DictationTransport> resolve({
    required DeviceConfig device,
    required String sessionId,
  }) async => _transport;
}

class _StubSessionCubit extends Cubit<SessionState> implements SessionCubit {
  _StubSessionCubit(Session? session)
      : super(SessionState(selectedSession: session));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _StubSessionMessagesCubit extends Cubit<SessionMessagesState>
    implements SessionMessagesCubit {
  _StubSessionMessagesCubit() : super(const SessionMessagesState());

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late SlashCommandTextController chatController;
  late FocusNode focusNode;
  late ComposerSlashCommandsCubit slashCubit;
  late FakeVoiceStreamCubit voiceCubit;
  late _Transport transport;
  late _Capture capture;
  late DictationCubit cubit;
  late _StubSessionCubit sessionCubit;
  late _StubSessionMessagesCubit messagesCubit;

  final agent = DeviceConfig(id: 'agent-1', name: 'SanadAgent', isOnline: true);
  final agentSlice = ConversationInputAgentSlice(
    activeAgent: agent,
    agents: [agent],
  );

  setUp(() {
    chatController = SlashCommandTextController();
    focusNode = FocusNode();
    slashCubit = ComposerSlashCommandsCubit(searcher: ({query, workspaceId}) async => const []);
    voiceCubit = FakeVoiceStreamCubit();
    transport = _Transport();
    capture = _Capture();
    cubit = DictationCubit(
      resolver: _Resolver(transport),
      capture: capture,
      sessionIdFactory: () => 's1',
    );
    sessionCubit = _StubSessionCubit(
      Session(
        id: 'session-1',
        title: 'Session 1',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        modelProvider: 'provider-1',
        model: 'model-narrow',
      ),
    );
    messagesCubit = _StubSessionMessagesCubit();
  });

  tearDown(() async {
    chatController.dispose();
    focusNode.dispose();
    await slashCubit.close();
    await cubit.close().timeout(
      const Duration(seconds: 2),
      onTimeout: () {},
    );
    await sessionCubit.close();
    await messagesCubit.close();
    await transport.eventsController.close();
  });

  ConversationInputSlice idleSlice({DeviceWorkspace? selectedWorkspace}) =>
      ConversationInputSlice(
        isProcessing: false,
        nextMessageModel: null,
        nextMessageProviderId: null,
        nextMessageThinkingMode: null,
        availableWorkspaces:
            selectedWorkspace == null ? [] : [selectedWorkspace],
        selectedWorkspace: selectedWorkspace,
        isLoadingWorkspaces: false,
        requiresWorkspace: false,
        permissionMode: WorkspacePermissionMode.defaultMode,
        isLoadingPermissionMode: false,
        pendingSuspendedRequest: null,
        runtimeNotice: null,
        executionSnapshot: null,
        isAwaitingMessageAcceptance: false,
        queuedMessages: [],
      );

  Future<void> pumpComposer(
    WidgetTester tester, {
    required ConversationInputSlice inputSlice,
    Locale locale = const Locale('en'),
  }) async {
    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider<ComposerSlashCommandsCubit>.value(value: slashCubit),
          BlocProvider<VoiceStreamCubit>.value(value: voiceCubit),
          BlocProvider<DictationCubit>.value(value: cubit),
          BlocProvider<SessionCubit>.value(value: sessionCubit),
          BlocProvider<SessionMessagesCubit>.value(value: messagesCubit),
        ],
        child: MaterialApp(
          locale: locale,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: kSupportedLocales,
          home: Scaffold(
            body: ConversationInputComposer(
              chatController: chatController,
              chatFocusNode: focusNode,
              agentSlice: agentSlice,
              inputSlice: inputSlice,
              capabilities: const Capability(
                supportsDictation: true,
                supportsToolPermissions: true,
                supportsModelChange: true,
              ),
              inputBgColor: Colors.white,
              borderColor: Colors.grey,
              dimTextColor: Colors.black54,
              chipBgColor: Colors.grey,
              onSelectSlashSuggestion: (_) {},
              onSendAttempt: ({MessageDeliveryIntent intent = MessageDeliveryIntent.auto}) {},
              onStop: () {},
              sessionId: 'session-1',
              onConfirmFullAccess: () async => true,
              agentSelectorKey: GlobalKey<PopupMenuButtonState<String>>(),
              onPickAndCreateWorkspace: (_) async {},
              pickAttachmentFiles: () async => const [],
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

  /// Lets the cubit's real teardown (capture close, transport detach) finish.
  ///
  /// The composer row is driven by the real cubit, whose session futures need
  /// real event-loop turns, which only [WidgetTester.runAsync] supplies.
  Future<void> settleRow(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
  }

  /// Presses Stop in the real row, which also swaps the meter out.
  Future<void> stopSession(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('dictation_mic_btn')));
    await tester.pump();
    await settleRow(tester);
  }

  testWidgets('the idle row keeps every selector and draws no meter', (
    tester,
  ) async {
    await pumpComposer(
      tester,
      inputSlice: idleSlice(
        selectedWorkspace:
            const DeviceWorkspace(id: 'w1', name: 'Project', path: '/project'),
      ),
    );

    expect(find.byKey(const Key('model_selector_btn')), findsOneWidget);
    expect(find.byKey(const Key('permission_mode_selector_button')), findsOneWidget);
    expect(find.byType(RouteThinkingModeSelector), findsOneWidget);
    expect(find.byKey(const Key('dictation_row_meter')), findsNothing);
    expect(find.byKey(const Key('dictation_mic_btn')), findsOneWidget);
    expect(find.byIcon(Symbols.mic), findsOneWidget);
  });

  testWidgets('listening hides the row selectors and shows the meter', (
    tester,
  ) async {
    await pumpComposer(
      tester,
      inputSlice: idleSlice(
        selectedWorkspace:
            const DeviceWorkspace(id: 'w1', name: 'Project', path: '/project'),
      ),
    );
    await seedReadyModel(tester);
    await startSession(tester);
    expect(cubit.state.status, DictationStatus.listening);

    expect(find.byKey(const Key('dictation_row_meter')), findsOneWidget);
    expect(find.byKey(const Key('model_selector_btn')), findsNothing);
    expect(find.byKey(const Key('permission_mode_selector_button')), findsNothing);
    expect(find.byType(RouteThinkingModeSelector), findsNothing);
    // The controls that stay: the Stop button and the send button.
    expect(find.byKey(const Key('dictation_mic_btn')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('dictation_mic_btn')),
        matching: find.byIcon(Icons.stop_circle_outlined),
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('send_message_btn')), findsOneWidget);
    // The visualization is no longer painted behind the composer text.
    expect(find.byKey(const Key('dictation_composer_meter')), findsNothing);
  });

  testWidgets('ending the session restores the row exactly as it was', (
    tester,
  ) async {
    await pumpComposer(
      tester,
      inputSlice: idleSlice(
        selectedWorkspace:
            const DeviceWorkspace(id: 'w1', name: 'Project', path: '/project'),
      ),
    );
    await seedReadyModel(tester);
    await startSession(tester);
    expect(find.byKey(const Key('dictation_row_meter')), findsOneWidget);

    // Cancel is the local end of the session: a real stop waits for the
    // daemon's final event, which a fake transport never sends. The future is
    // not awaited inside the fake-async zone — closing the capture needs real
    // event-loop turns, which the runAsync loop below supplies.
    unawaited(cubit.cancel());
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }

    expect(find.byKey(const Key('dictation_row_meter')), findsNothing);
    expect(find.byKey(const Key('model_selector_btn')), findsOneWidget);
    expect(find.byKey(const Key('permission_mode_selector_button')), findsOneWidget);
    expect(find.byType(RouteThinkingModeSelector), findsOneWidget);
    expect(find.byIcon(Symbols.mic), findsOneWidget);
  });

  testWidgets('the RTL row mirrors the meter and keeps the Stop control', (
    tester,
  ) async {
    await pumpComposer(
      tester,
      inputSlice: idleSlice(),
      locale: const Locale('ar'),
    );
    await seedReadyModel(tester);
    await startSession(tester);

    final meter = find.byKey(const Key('dictation_row_meter'));
    expect(meter, findsOneWidget);
    final flip = tester.widget<Transform>(
      find.ancestor(of: meter, matching: find.byType(Transform)).first,
    );
    // The newest sample enters on the leading edge: the right edge in RTL.
    expect(flip.transform.storage[0], -1);
    expect(find.byIcon(Icons.stop_circle_outlined), findsOneWidget);
  });

  // A streaming session keeps a partial in the composer until its segment is
  // finalized. The row itself is what made the final land twice: entering and
  // leaving the listening layout moves the mic button between two branches, so
  // the button that wrote the partial is not the button that receives the
  // final. The composer range therefore has to belong to the composer, not to
  // the widget that drew it — every ordering below is a live one (runs A–D of
  // the Test Home 3 leg), and each must end with the final text exactly once.
  const partial = 'The quick brown fox';
  const finalText = 'The quick brown fox jumps over the lazy do';

  testWidgets('a final that lands after Stop replaces the partial', (
    tester,
  ) async {
    await pumpComposer(tester, inputSlice: idleSlice());
    await seedReadyModel(tester);
    await startSession(tester);

    await emit(tester, {
      'event': 'dictation_partial',
      'seq': 0,
      'text': partial,
    });
    expect(chatController.text, partial);
    final wrotePartial = tester.element(find.byType(DictationMicButton));

    // Run A: the audio ended before the owner pressed Stop, so the daemon
    // delivers the final after the row already gave the meter back.
    await stopSession(tester);
    expect(find.byKey(const Key('dictation_row_meter')), findsNothing);
    // The row moves the button between two branches, so Stop really does
    // replace the widget that wrote the partial — the composer, not that
    // widget's State, has to remember the range.
    expect(
      tester.element(find.byType(DictationMicButton)),
      isNot(same(wrotePartial)),
    );

    await emit(tester, {
      'event': 'dictation_final',
      'seq': 0,
      'text': finalText,
    });

    expect(chatController.text, finalText);

    await emit(tester, {'event': 'dictation_done', 'segments': 1});
    await settleRow(tester);
    expect(cubit.state.status, DictationStatus.idle);
    expect(chatController.text, finalText);
  });

  testWidgets('a final that lands while the meter is still up replaces the partial', (
    tester,
  ) async {
    await pumpComposer(tester, inputSlice: idleSlice());
    await seedReadyModel(tester);
    await startSession(tester);

    await emit(tester, {
      'event': 'dictation_partial',
      'seq': 0,
      'text': 'G. the quick',
    });

    // Run B: the daemon closes the segment while the user is still speaking.
    await emit(tester, {
      'event': 'dictation_final',
      'seq': 0,
      'text': 'G. the quick brown fox jumps over',
    });
    expect(chatController.text, 'G. the quick brown fox jumps over');

    await stopSession(tester);
    await emit(tester, {'event': 'dictation_done', 'segments': 1});
    await settleRow(tester);
    expect(chatController.text, 'G. the quick brown fox jumps over');
  });

  testWidgets('a longer final never appends itself to the partial it revises', (
    tester,
  ) async {
    await pumpComposer(tester, inputSlice: idleSlice());
    await seedReadyModel(tester);
    await startSession(tester);

    const runC = 'The lazy dog. the quick brown fox';
    const runCFinal = 'The lazy dog. the quick brown fox jumps over the lazy dog';
    await emit(tester, {'event': 'dictation_partial', 'seq': 0, 'text': runC});
    await stopSession(tester);
    await emit(tester, {
      'event': 'dictation_final',
      'seq': 0,
      'text': runCFinal,
    });

    // Run C: 30-char partial + a 57-char final is one paragraph, not two.
    expect(chatController.text, runCFinal);
    expect(chatController.text.length, runCFinal.length);

    await emit(tester, {'event': 'dictation_done', 'segments': 1});
    await settleRow(tester);
    expect(chatController.text, runCFinal);
  });

  testWidgets('a final equal to the partial still lands once', (tester) async {
    await pumpComposer(tester, inputSlice: idleSlice());
    await seedReadyModel(tester);
    await startSession(tester);

    const runD = 'The quick brown fox jumps over the';
    await emit(tester, {'event': 'dictation_partial', 'seq': 0, 'text': runD});
    await stopSession(tester);
    // Run D: identical text, the masking case that used to hide the defect.
    await emit(tester, {'event': 'dictation_final', 'seq': 0, 'text': runD});
    await emit(tester, {'event': 'dictation_done', 'segments': 1});
    await settleRow(tester);

    expect(chatController.text, runD);
  });

  testWidgets('the next session never rewrites the text it found', (tester) async {
    await pumpComposer(tester, inputSlice: idleSlice());
    await seedReadyModel(tester);
    await startSession(tester);

    await emit(tester, {'event': 'dictation_partial', 'seq': 0, 'text': partial});
    await stopSession(tester);
    await emit(tester, {
      'event': 'dictation_final',
      'seq': 0,
      'text': finalText,
    });
    await emit(tester, {'event': 'dictation_done', 'segments': 1});
    await settleRow(tester);
    expect(chatController.text, finalText);

    // The finished transcript is ordinary user text now: a second session
    // appends its own span and leaves the first one exactly as it was.
    await startSession(tester);
    await emit(tester, {
      'event': 'dictation_partial',
      'seq': 0,
      'text': 'Second run',
    });
    await emit(tester, {
      'event': 'dictation_final',
      'seq': 0,
      'text': 'Second run.',
    });
    await stopSession(tester);
    await emit(tester, {'event': 'dictation_done', 'segments': 1});
    await settleRow(tester);

    expect(chatController.text, '$finalText Second run.');
  });
}
