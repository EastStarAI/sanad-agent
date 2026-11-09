import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/presentation/controllers/slash_command_text_controller.dart';
import 'package:sanad_client/driver/dictation_driver_extensions.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/dictation/domain/dictation_audio_capture.dart';
import 'package:sanad_client/features/dictation/domain/dictation_transport.dart';
import 'package:sanad_client/features/dictation/domain/dictation_transport_resolver.dart';
import 'package:sanad_client/features/dictation/presentation/bloc/dictation_cubit.dart';
import 'package:sanad_client/features/dictation/presentation/bloc/dictation_state.dart';
import 'package:sanad_client/features/dictation/presentation/widgets/dictation_mic_button.dart';
import 'package:sanad_client/l10n/app_localizations.dart';

/// The daemon's `seq` is the replacement key of a transcript segment: a partial
/// and its final carry the same value, so the composer must **replace** that
/// segment instead of appending the final after the partial it already shows.
/// These legs run the real button, insertion helper, and cubit, and read the
/// composer the user actually sees.
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
  _Resolver(this.transport);

  final DictationTransport transport;

  @override
  Future<DictationTransport> resolve({
    required DeviceConfig device,
    required String sessionId,
  }) async => transport;
}

void main() {
  final device = DeviceConfig(id: 'dev-1', name: 'Device', isOnline: true);

  late _Transport transport;
  late DictationCubit cubit;
  late SlashCommandTextController chatController;

  const partial = 'The lazy dog. the quick brown fox jump';
  const finalText = 'The lazy dog. the quick brown fox jumps over the lazy dog';

  setUp(() {
    transport = _Transport();
    cubit = DictationCubit(
      resolver: _Resolver(transport),
      capture: _Capture(),
      sessionIdFactory: () => 's1',
    );
    chatController = SlashCommandTextController();
  });

  tearDown(() async {
    chatController.dispose();
    await cubit.close();
    await transport.eventsController.close();
  });

  Future<void> seedReadyModel(WidgetTester tester) async {
    final pending = cubit.refreshStatus(device);
    await tester.pump();
    transport.eventsController.add({
      'event': 'stt_status',
      'supported': true,
      'selected': 'en-streaming',
      'models': [
        {
          'id': 'en-streaming',
          'name': 'Zipformer EN',
          'streaming': true,
          'installed': true,
        },
      ],
    });
    await tester.pump();
    await pending;
    await tester.pump();
  }

  Future<void> emit(WidgetTester tester, Map<String, dynamic> event) async {
    transport.eventsController.add(event);
    await tester.pump();
    await tester.pump();
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
  }

  Future<void> startSession(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('dictation_mic_btn')));
    await tester.pump();
    await emit(tester, {
      'event': 'dictation_ready',
      'model_id': 'en-streaming',
      'load_ms': 5,
    });
    expect(cubit.state.status, DictationStatus.listening);
  }

  Widget build() => MaterialApp(
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
        ),
      ),
    ),
  );

  testWidgets('a partial and its final share one seq, so the final replaces it', (
    tester,
  ) async {
    await tester.pumpWidget(build());
    await seedReadyModel(tester);
    await startSession(tester);

    await emit(tester, {
      'event': 'dictation_partial',
      'seq': 0,
      'text': partial,
    });
    expect(chatController.text, partial);

    await emit(tester, {
      'event': 'dictation_final',
      'seq': 0,
      'text': finalText,
    });

    // The final is the whole segment, so it lands once — never after the
    // partial it replaces.
    expect(chatController.text, finalText);
  });

  testWidgets('each closed segment is committed exactly once', (tester) async {
    await tester.pumpWidget(build());
    await seedReadyModel(tester);
    await startSession(tester);

    await emit(tester, {
      'event': 'dictation_partial',
      'seq': 0,
      'text': 'First segment',
    });
    await emit(tester, {
      'event': 'dictation_final',
      'seq': 0,
      'text': 'First segment.',
    });
    await emit(tester, {
      'event': 'dictation_partial',
      'seq': 1,
      'text': 'Second',
    });
    expect(chatController.text, 'First segment. Second');

    await emit(tester, {
      'event': 'dictation_final',
      'seq': 1,
      'text': 'Second segment.',
    });

    expect(chatController.text, 'First segment. Second segment.');
  });

  testWidgets('a stop mid-utterance keeps the final once', (tester) async {
    await tester.pumpWidget(build());
    await seedReadyModel(tester);
    await startSession(tester);

    await emit(tester, {
      'event': 'dictation_partial',
      'seq': 0,
      'text': partial,
    });

    await tester.tap(find.byKey(const Key('dictation_mic_btn')));
    await tester.pump();
    expect(cubit.state.status, DictationStatus.finalizing);

    await emit(tester, {
      'event': 'dictation_final',
      'seq': 0,
      'text': finalText,
    });
    expect(chatController.text, finalText);

    await settle(tester);
    await emit(tester, {'event': 'dictation_done', 'segments': 1});
    await settle(tester);
    expect(cubit.state.status, DictationStatus.idle);
    // Ending the session hands the text to the composer as ordinary user text.
    expect(chatController.text, finalText);
  });

  testWidgets('an empty partial between writes does not duplicate the segment', (
    tester,
  ) async {
    await tester.pumpWidget(build());
    await seedReadyModel(tester);
    await startSession(tester);

    await emit(tester, {
      'event': 'dictation_partial',
      'seq': 0,
      'text': partial,
    });
    // A recognizer that revises its tail down to nothing must not make the next
    // write look like a new utterance: the composer replaces, never appends.
    await emit(tester, {'event': 'dictation_partial', 'seq': 0, 'text': ''});
    await emit(tester, {
      'event': 'dictation_partial',
      'seq': 0,
      'text': finalText,
    });

    expect(chatController.text, finalText);
  });

  testWidgets('a repeated final for one seq does not append again', (
    tester,
  ) async {
    await tester.pumpWidget(build());
    await seedReadyModel(tester);
    await startSession(tester);

    await emit(tester, {
      'event': 'dictation_final',
      'seq': 0,
      'text': finalText,
    });
    await emit(tester, {
      'event': 'dictation_final',
      'seq': 0,
      'text': finalText,
    });

    expect(chatController.text, finalText);
  });

  // D7: the seam's documented compose check answered `present: false, chars: 0`
  // for a session that had just produced a transcript, because it read the
  // session state after the cubit reset it. The composer controller is the
  // truthful source, and it is what the user sends.
  testWidgets('the seam reports the composer after the session settles', (
    tester,
  ) async {
    await tester.pumpWidget(build());
    await seedReadyModel(tester);
    await startSession(tester);

    await emit(tester, {
      'event': 'dictation_final',
      'seq': 0,
      'text': finalText,
    });
    await settle(tester);
    await emit(tester, {'event': 'dictation_done', 'segments': 1});
    await settle(tester);
    expect(cubit.state.status, DictationStatus.idle);

    // The session state is empty again; the composer is not.
    expect(cubit.state.visibleText, isEmpty);
    expect(driverComposerText(WidgetsBinding.instance.rootElement), finalText);
    expect(
      composerFacts(
        text: driverComposerText(WidgetsBinding.instance.rootElement)!,
      ),
      {'status': 'ok', 'present': true, 'chars': finalText.length, 'matches_expected': false},
    );
  });
}
