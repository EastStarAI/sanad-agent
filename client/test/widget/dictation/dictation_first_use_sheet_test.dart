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
import 'package:sanad_client/features/dictation/presentation/widgets/dictation_mic_button.dart';
import 'package:sanad_client/l10n/app_localizations.dart';

/// The first-use route, end to end on the Client side.
///
/// A device with no installed model must not start a session: one press opens
/// the model sheet. The daemon now says so itself (`ready: false` with
/// `reason: model_not_installed`), and the same sheet is offered when a session
/// is refused late — the one consumer of the cubit's first-use flag.
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

class _Resolver implements DictationTransportResolver {
  _Resolver(this.transport);
  final _Transport transport;

  @override
  Future<DictationTransport> resolve({
    required DeviceConfig device,
    required String sessionId,
  }) async => transport;
}

/// What the resolver throws when the transport boundary refuses the channel.
///
/// A hosted device without the relay, an outdated Gateway, or a frame it read
/// as malformed is refused *before* a single command leaves the Client, so no
/// `stt_status` can ever arrive and the catalog stays unknown — not empty
/// because the device has no model.
class _RefusingResolver implements DictationTransportResolver {
  _RefusingResolver(this.reason);
  final String reason;

  @override
  Future<DictationTransport> resolve({
    required DeviceConfig device,
    required String sessionId,
  }) async => throw DictationTransportUnavailable(reason);
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

  /// The daemon's own answer for a Home with a catalog but nothing installed.
  Future<void> seedNoInstalledModel(WidgetTester tester) async {
    final pending = cubit.refreshStatus(device);
    await tester.pump();
    transport.eventsController.add({
      'event': 'stt_status',
      'supported': true,
      'ready': false,
      'reason': 'model_not_installed',
      'selected': 'egy-whisper-turbo-ggml-q8',
      'models': [
        {
          'id': 'egy-whisper-turbo-ggml-q8',
          'name': 'Egyptian Whisper Turbo Q8',
          'description': {'en': 'Recommended for Arabic.', 'ar': 'الموصى به.'},
          'badge': 'recommended',
          'speed_tier': 3,
          'size_bytes': 874208239,
          'streaming': false,
          'location': 'local',
          'hosted': true,
          'installed': false,
        },
      ],
    });
    await tester.pump();
    await pending;
    await tester.pump();
  }

  /// The daemon's own answer for a Home whose catalog is genuinely empty: it
  /// answered, listed nothing, and named the readiness reason.
  Future<void> seedEmptyCatalog(WidgetTester tester) async {
    final pending = cubit.refreshStatus(device);
    await tester.pump();
    transport.eventsController.add({
      'event': 'stt_status',
      'supported': true,
      'ready': false,
      'reason': 'model_not_installed',
      'models': const [],
    });
    await tester.pump();
    await pending;
    await tester.pump();
  }

  Widget build({DictationCubit? withCubit}) {
    return MaterialApp(
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      supportedLocales: const [Locale('en'), Locale('ar')],
      home: Scaffold(
        body: BlocProvider.value(
          value: withCubit ?? cubit,
          child: DictationMicButton(
            chatController: chatController,
            device: device,
          ),
        ),
      ),
    );
  }

  testWidgets('one press on a model-less device opens the model sheet', (
    tester,
  ) async {
    await tester.pumpWidget(build());
    await seedNoInstalledModel(tester);

    await tester.tap(find.byKey(const Key('dictation_mic_btn')));
    await tester.pump();
    // The press re-reads the catalog first and waits for the reply (or its 4 s
    // fallback) before deciding it cannot record.
    await tester.pump(const Duration(seconds: 10));
    await tester.pump(const Duration(seconds: 10));

    expect(transport.commands, isNot(contains('start')));
    expect(capture.started, isFalse);
    expect(find.byKey(const Key('dictation_model_sheet')), findsOneWidget);
    // The sheet explains itself in the user's language instead of the generic
    // "dictation could not start" notice.
    expect(
      find.textContaining('No dictation model is installed yet'),
      findsWidgets,
    );

    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('a late model_not_installed refusal ends in the sheet', (
    tester,
  ) async {
    await tester.pumpWidget(build());
    await seedNoInstalledModel(tester);
    await tester.pump();

    // A session the Client thought it could start: the daemon refuses it, which
    // is the state the cubit's first-use flag exists for.
    unawaited(cubit.start(device));
    await tester.pump();
    transport.eventsController.add({
      'event': 'dictation_error',
      'code': 'model_not_installed',
      'message': 'install a dictation model first',
    });
    // The teardown path awaits real futures (transport close, capture stop), so
    // the fake clock alone cannot finish it.
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }

    expect(cubit.state.sessionNeedsFirstUseSheet, isTrue);
    expect(find.byKey(const Key('dictation_model_sheet')), findsOneWidget);

    // Drain the notice and status timers so the test ends with no pending work.
    await tester.pump(const Duration(seconds: 6));
  });

  // The sheet's empty state has two causes, and telling them apart is the whole
  // point: a channel refusal never reached the daemon, so the catalog is
  // unknown and the reason is the only honest sentence. "Install a model"
  // belongs to a catalog that answered and listed nothing.
  testWidgets('a channel refusal names its reason, never the install sentence', (
    tester,
  ) async {
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    final refusing = DictationCubit(
      resolver: _RefusingResolver('dictation_unavailable'),
      capture: _Capture(),
      sessionIdFactory: () => 's-refused',
    );
    addTearDown(refusing.close);

    await tester.pumpWidget(build(withCubit: refusing));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('dictation_mic_btn')));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));

    expect(find.byKey(const Key('dictation_model_sheet')), findsOneWidget);
    final reason = find.byKey(const Key('dictation_sheet_channel_reason'));
    expect(reason, findsOneWidget);
    expect(tester.widget<Text>(reason).data, l10n.dictationUnavailable);
    expect(find.text(l10n.dictationModelRequired), findsNothing);
    expect(find.byKey(const Key('dictation_sheet_model_required')), findsNothing);
    // Nothing was ever sent: the refusal happens at the transport boundary.
    expect(refusing.state.errorCode, 'dictation_unavailable');

    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('an answered catalog with no rows keeps the install sentence', (
    tester,
  ) async {
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    await tester.pumpWidget(build());
    await seedEmptyCatalog(tester);

    await tester.tap(find.byKey(const Key('dictation_mic_btn')));
    await tester.pump();
    // The press re-reads the catalog and waits for the reply or its fallback.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('dictation_model_sheet')), findsOneWidget);
    expect(find.byKey(const Key('dictation_sheet_model_required')), findsOneWidget);
    expect(find.text(l10n.dictationModelRequired), findsOneWidget);
    expect(find.byKey(const Key('dictation_sheet_channel_reason')), findsNothing);

    await tester.pump(const Duration(seconds: 10));
  });
}
