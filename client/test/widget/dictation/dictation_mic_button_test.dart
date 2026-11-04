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
    if (!eventsController.isClosed) await eventsController.close();
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
  Future<void> stop() async {}

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
  });

  Widget build({Object? scopeKey}) {
    return MaterialApp(
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

    await tester.tap(find.byKey(const Key('dictation_mic_btn')));
    await tester.pump();

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

  testWidgets('finalized text lands in the composer', (tester) async {
    await tester.pumpWidget(build());
    await tester.tap(find.byKey(const Key('dictation_mic_btn')));
    await tester.pump();

    transport.eventsController
        .add({'event': 'dictation_final', 'seq': 1, 'text': 'السلام عليكم'});
    await tester.pump();
    await tester.pump();

    expect(chatController.text, 'السلام عليكم');
  });

  testWidgets('cancel returns the composer to its pre-session text', (tester) async {
    chatController.text = 'draft: ';
    chatController.selection = const TextSelection.collapsed(offset: 7);

    await tester.pumpWidget(build());
    await tester.tap(find.byKey(const Key('dictation_mic_btn')));
    await tester.pump();

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

  testWidgets('the elapsed counter appears while listening', (tester) async {
    await tester.pumpWidget(build());
    await tester.tap(find.byKey(const Key('dictation_mic_btn')));
    await tester.pump();

    expect(find.byKey(const Key('dictation_elapsed')), findsNothing);

    await tester.pump(const Duration(seconds: 2));
    await tester.pump();

    expect(find.byKey(const Key('dictation_elapsed')), findsOneWidget);
    expect(find.text('0:02'), findsOneWidget);
  });

  testWidgets('changing the composer scope cancels the live session', (tester) async {
    await tester.pumpWidget(build());
    await tester.tap(find.byKey(const Key('dictation_mic_btn')));
    await tester.pump();
    expect(cubit.state.status, DictationStatus.listening);

    await tester.pumpWidget(build(scopeKey: 'other-conversation'));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pump();

    expect(transport.commands, contains('cancel'));
    expect(chatController.text, isEmpty);
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
