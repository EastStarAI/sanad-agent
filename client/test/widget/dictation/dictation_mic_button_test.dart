import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/presentation/controllers/slash_command_text_controller.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/dictation/domain/dictation_audio_capture.dart';
import 'package:sanad_client/features/dictation/domain/dictation_transport.dart';
import 'package:sanad_client/features/dictation/domain/dictation_transport_resolver.dart';
import 'package:sanad_client/features/dictation/presentation/bloc/dictation_cubit.dart';
import 'package:sanad_client/features/dictation/presentation/bloc/dictation_state.dart';
import 'package:sanad_client/features/dictation/presentation/widgets/dictation_mic_button.dart';
import 'package:sanad_client/l10n/app_localizations.dart';

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
  Future<void> close() async {
    // The fake resolver hands the same transport to every session, so the event
    // stream stays open across sessions like a fresh daemon connection would.
  }
}

class _Capture implements DictationCapture {
  final StreamController<List<int>> controller =
      StreamController<List<int>>.broadcast();
  bool started = false;

  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<Stream<List<int>>> start() async {
    started = true;
    return controller.stream;
  }

  @override
  Future<void> stop() async {
    started = false;
    // The real recorder closes its stream on stop, which is how the cubit knows
    // the last frames were handed over before it tells the daemon to decode.
    if (!controller.isClosed) await controller.close();
  }

  @override
  Future<void> dispose() async {
    if (!controller.isClosed) await controller.close();
  }
}

void main() {
  final device = DeviceConfig(id: 'dev-1', name: 'Device', isOnline: true);

  late _Transport transport;
  late _Capture capture;
  late DictationCubit cubit;
  late SlashCommandTextController chatController;

  setUp(() {
    transport = _Transport();
    capture = _Capture();
    cubit = DictationCubit(
      resolver: _Resolver(transport),
      capture: capture,
      sessionIdFactory: () => 's1',
    );
    chatController = SlashCommandTextController();
  });

  tearDown(() async {
    chatController.dispose();
    await cubit.close();
    await transport.eventsController.close();
  });

  /// Seeds the daemon state a real session would have: one installed model.
  Future<void> seedReadyModel(WidgetTester tester) async {
    // The status round-trip resolves only once the reply is pumped through, so
    // the request is started here and awaited after the event lands.
    final pending = cubit.refreshStatus(device);
    await tester.pump();
    transport.eventsController.add({
      'event': 'stt_status',
      'supported': true,
      'selected': 'whisper-base-int8',
      'models': [
        {
          'id': 'whisper-base-int8',
          'label': 'Whisper base',
          'hosted': true,
          'installed': true,
        },
      ],
    });
    await tester.pump();
    await pending;
    await tester.pump();
  }

  /// Completes the daemon handshake that unlocks capture: the session is
  /// "listening" only once the recognizer reports it is loaded.
  Future<void> emitReady(WidgetTester tester) async {
    transport.eventsController.add({
      'event': 'dictation_ready',
      'model_id': 'whisper-base-int8',
      'load_ms': 12,
    });
    await tester.pump();
    await tester.pump();
  }

  /// Gives the session teardown real event-loop turns: cancelling stream
  /// subscriptions cannot complete on the fake clock alone.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
  }

  /// Starts a session through the button and waits for the ready handshake.
  Future<void> startSession(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('dictation_mic_btn')));
    await tester.pump();
    await emitReady(tester);
  }

  Widget build({Object? scopeKey}) {    return MaterialApp(
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      supportedLocales: const [Locale('en'), Locale('ar')],
      home: Scaffold(
        body: BlocProvider.value(
          value: cubit,
          child: DictationMicButton(
            chatController: chatController,
            device: device,
            scopeKey: scopeKey,
          ),
        ),
      ),
    );
  }

  testWidgets('renders the composer mic button', (tester) async {
    await tester.pumpWidget(build());
    expect(find.byKey(const Key('dictation_mic_btn')), findsOneWidget);
  });

  testWidgets('pressing the mic starts a dictation session', (tester) async {
    await tester.pumpWidget(build());
    await seedReadyModel(tester);

    await startSession(tester);

    expect(transport.commands, contains('start'));
    expect(capture.started, isTrue);
    expect(cubit.state.status, DictationStatus.listening);
  });

  testWidgets('a disabled device still shows the button as inert', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        supportedLocales: const [Locale('en'), Locale('ar')],
        home: Scaffold(
          body: BlocProvider.value(
            value: cubit,
            child: DictationMicButton(
              chatController: chatController,
              device: null,
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('dictation_mic_btn')));
    await tester.pump();

    expect(transport.commands, isEmpty);
    expect(capture.started, isFalse);
  });

  testWidgets('finalized text lands in the composer at the caret', (tester) async {
    chatController.text = 'قبل ';
    chatController.selection = const TextSelection.collapsed(offset: 4);

    await tester.pumpWidget(build());
    await seedReadyModel(tester);
    await startSession(tester);

    transport.eventsController
        .add({'event': 'dictation_final', 'seq': 1, 'text': 'السلام عليكم'});
    await tester.pump();
    await tester.pump();

    expect(chatController.text, 'قبل السلام عليكم');
  });

  testWidgets('cancel returns the composer to its pre-session text', (tester) async {
    chatController.text = 'draft: ';
    chatController.selection = const TextSelection.collapsed(offset: 7);

    await tester.pumpWidget(build());
    await seedReadyModel(tester);
    await startSession(tester);

    transport.eventsController
        .add({'event': 'dictation_final', 'seq': 1, 'text': 'dictated'});
    await tester.pump();
    await tester.pump();
    expect(chatController.text, 'draft: dictated');

    await tester.runAsync(() => cubit.cancel());
    await tester.pump();
    await tester.pump();

    expect(chatController.text, 'draft: ');
    expect(chatController.selection.baseOffset, lessThanOrEqualTo(7));
  });

  testWidgets('a voice meter replaces the elapsed timer while listening', (
    tester,
  ) async {
    await tester.pumpWidget(build());
    await seedReadyModel(tester);

    // Before the daemon reports the model ready, the mic only shows loading.
    await tester.tap(find.byKey(const Key('dictation_mic_btn')));
    await tester.pump();
    expect(find.byKey(const Key('dictation_level')), findsNothing);
    expect(find.byKey(const Key('dictation_elapsed')), findsNothing);

    await emitReady(tester);
    // The meter lives inside the button itself, replacing the stop icon.
    expect(
      find.descendant(
        of: find.byKey(const Key('dictation_mic_btn')),
        matching: find.byKey(const Key('dictation_level')),
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('dictation_elapsed')), findsNothing);
  });

  testWidgets('a press starts recording when a model is ready', (tester) async {
    await tester.pumpWidget(build());
    await seedReadyModel(tester);
    expect(cubit.state.model.isReady, isTrue);

    await startSession(tester);

    expect(transport.commands, contains('start'));
    expect(cubit.state.status, DictationStatus.listening);
  });

  testWidgets('a press without a ready model does not start recording', (tester) async {
    await tester.pumpWidget(build());

    await tester.tap(find.byKey(const Key('dictation_mic_btn')));
    await tester.pump();
    // The first press asks the daemon for its status and waits for the reply
    // (or its 4s fallback) before deciding it cannot record.
    await tester.pump(const Duration(seconds: 10));
    await tester.pump(const Duration(seconds: 10));

    expect(transport.commands, isNot(contains('start')));
    expect(find.byKey(const Key('dictation_model_sheet')), findsOneWidget);
  });

  testWidgets('changing the composer scope cancels the live session', (tester) async {
    await tester.pumpWidget(build());
    await seedReadyModel(tester);
    await startSession(tester);
    expect(cubit.state.status, DictationStatus.listening);

    await tester.pumpWidget(build(scopeKey: 'other-conversation'));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pump();

    expect(transport.commands, contains('cancel'));
    expect(chatController.text, isEmpty);
  });

  testWidgets('a second session appends without repeating the first', (
    tester,
  ) async {
    await tester.pumpWidget(build());
    await seedReadyModel(tester);

    Future<void> dictate(String text) async {
      await startSession(tester);
      transport.eventsController
          .add({'event': 'dictation_final', 'seq': 1, 'text': text});
      await tester.pump();
      await tester.pump();
      // A second press stops the session, and the daemon's drain closes it.
      await tester.tap(find.byKey(const Key('dictation_mic_btn')));
      await settle(tester);
      transport.eventsController.add({'event': 'dictation_done', 'segments': 1});
      await settle(tester);
      expect(cubit.state.status, DictationStatus.idle);
    }

    await dictate('First');
    await dictate('Second');

    final text = chatController.text;
    expect(text, contains('First'));
    expect(text, contains('Second'));
    // The finished session hands its text to the composer; the next one must
    // not rewrite it as part of its own range.
    expect(RegExp('First').allMatches(text), hasLength(1));
    expect(RegExp('Second').allMatches(text), hasLength(1));
  });
}

class _Resolver implements DictationResolver {
  _Resolver(this.transport);

  final DictationTransport transport;

  @override
  Future<DictationTransport> resolve({
    required DeviceConfig device,
    required String sessionId,
  }) async =>
      transport;
}
