import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/dictation/domain/dictation_audio_capture.dart';
import 'package:sanad_client/features/dictation/domain/dictation_transport.dart';
import 'package:sanad_client/features/dictation/domain/dictation_transport_resolver.dart';
import 'package:sanad_client/features/dictation/presentation/bloc/dictation_cubit.dart';
import 'package:sanad_client/features/dictation/presentation/bloc/dictation_state.dart';
import 'package:sanad_client/features/dictation/presentation/widgets/dictation_model_sheet.dart';
import 'package:sanad_client/l10n/app_localizations.dart';

import '../helpers/dictation_fakes.dart';
import '../helpers/pump_app.dart';

/// The sheet renders daemon-owned codes, never daemon sentences, and never sends
/// a command itself. These tests pin the two user-visible decisions: which
/// repair action a blocked state offers, and that every code is localized while
/// an unknown code still stays visible instead of being swallowed.
class _RecordingCubit extends DictationCubit {
  _RecordingCubit()
      : super(resolver: _UnusedResolver(), capture: _UnusedCapture());

  final preparedFor = <String>[];
  final installedModels = <String>[];
  final selectedModels = <String>[];
  int refreshes = 0;

  void show(DictationModelStatus model) => emit(DictationState(model: model));

  @override
  Future<void> refreshStatus(
    DeviceConfig device, {
    Duration timeout = const Duration(seconds: 4),
  }) async {
    refreshes++;
  }

  @override
  Future<void> prepareRuntime(DeviceConfig device) async {
    preparedFor.add(device.id);
  }

  @override
  Future<void> installModel(String modelId, {required DeviceConfig device}) async {
    installedModels.add(modelId);
  }

  final cancelledDownloads = <String>[];

  @override
  Future<void> cancelInstallModel({required DeviceConfig device}) async {
    cancelledDownloads.add(device.id);
  }

  @override
  Future<void> selectModel(String modelId, {required DeviceConfig device}) async {
    selectedModels.add(modelId);
  }
}

class _UnusedResolver implements DictationResolver {
  @override
  Future<DictationTransport> resolve({
    required DeviceConfig device,
    required String sessionId,
  }) =>
      throw UnimplementedError('the sheet never resolves a transport');
}

class _UnusedCapture implements DictationCapture {
  @override
  Future<bool> hasPermission() async => false;

  @override
  Future<Stream<List<int>>> start() => throw UnimplementedError();

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}

void main() {
  final device = DeviceConfig(
    id: 'agent-1',
    name: 'Studio Mac',
    hardwareId: 'studio-mac',
  );

  const hostedRow = <String, dynamic>{
    'id': 'large',
    'name': 'Whisper Large v3 Turbo',
    'size_bytes': 812000000,
    'hosted': true,
    'installed': false,
  };

  late _RecordingCubit cubit;

  setUp(() => cubit = _RecordingCubit());

  tearDown(() async => cubit.close());

  Future<AppLocalizations> pumpSheet(WidgetTester tester) async {
    await pumpTestApp(
      tester,
      child: BlocProvider<DictationCubit>.value(
        value: cubit,
        child: DictationModelSheet(device: device),
      ),
    );
    await tester.pump();
    return AppLocalizations.of(
      tester.element(find.byKey(const Key('dictation_model_sheet'))),
    )!;
  }

  testWidgets('a supported device missing its runtime offers the repair',
      (tester) async {
    cubit.show(
      const DictationModelStatus(
        readinessReason: 'native_runtime_missing',
        isPlatformSupported: true,
      ),
    );

    await pumpSheet(tester);

    expect(find.byKey(const Key('dictation_model_sheet')), findsOneWidget);
    expect(find.byKey(const Key('dictation_prepare_runtime')), findsOneWidget);
    expect(cubit.refreshes, 1, reason: 'opening the sheet asks for the catalog');

    await tester.tap(find.byKey(const Key('dictation_prepare_runtime')));
    await tester.pump();

    expect(cubit.preparedFor, ['agent-1']);
  });

  testWidgets('a preparing runtime shows a spinner instead of a button',
      (tester) async {
    cubit.show(
      const DictationModelStatus(
        readinessReason: 'native_runtime_preparing',
        isPlatformSupported: true,
      ),
    );

    await pumpSheet(tester);

    expect(find.byKey(const Key('dictation_prepare_runtime')), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsWidgets);
  });

  testWidgets('an unsupported platform shows a localized reason, no repair',
      (tester) async {
    cubit.show(
      const DictationModelStatus(
        readinessReason: 'unsupported_platform',
        isPlatformSupported: false,
      ),
    );

    final l10n = await pumpSheet(tester);

    expect(find.byKey(const Key('dictation_blocked_reason')), findsOneWidget);
    expect(
      find.textContaining(l10n.dictationUnsupportedPlatform),
      findsOneWidget,
    );
    expect(find.byKey(const Key('dictation_prepare_runtime')), findsNothing);
  });

  testWidgets('the daemon override row is localized through its label code',
      (tester) async {
    cubit.show(
      const DictationModelStatus(
        isPlatformSupported: true,
        isReady: true,
        selectedModelId: 'override',
        models: [
          DictationModelOption(
            id: 'override',
            labelCode: 'path_override',
            badge: 'custom',
            installed: true,
          ),
        ],
      ),
    );

    final l10n = await pumpSheet(tester);

    expect(find.text(l10n.dictationPathOverrideModel), findsOneWidget);
    expect(find.text('path_override'), findsNothing);
    expect(find.byKey(const Key('dictation_badge_override')), findsOneWidget);
  });

  testWidgets('an unknown daemon code is localized, never rendered raw',
      (tester) async {
    cubit.show(
      const DictationModelStatus(
        readinessReason: 'some_future_code',
        isPlatformSupported: false,
      ),
    );

    final l10n = await pumpSheet(tester);

    expect(find.textContaining('some_future_code'), findsNothing);
    expect(find.textContaining(l10n.dictationUnavailable), findsOneWidget);
  });

  testWidgets('an installing hosted model shows the owned progress bar',
      (tester) async {
    cubit.show(
      const DictationModelStatus(
        isPlatformSupported: true,
        isReady: true,
        installingModelId: 'large',
        downloadProgress: 0.4,
        models: [
          DictationModelOption(
            id: 'large',
            name: 'Whisper Large v3 Turbo',
            hosted: true,
            sizeBytes: 812000000,
          ),
        ],
      ),
    );

    await pumpSheet(tester);

    expect(find.byKey(const Key('dictation_download_progress')), findsOneWidget);
    expect(find.byKey(const Key('dictation_download_percent')), findsOneWidget);
    expect(find.text('40%'), findsOneWidget);
    expect(find.byKey(const Key('dictation_download_large')), findsNothing);
  });

  testWidgets('a running install shows size, percentage, remaining time, cancel',
      (tester) async {
    cubit.show(
      const DictationModelStatus(
        isPlatformSupported: true,
        isReady: false,
        installingModelId: 'large',
        downloadProgress: 0.25,
        installReceivedBytes: 250,
        installTotalBytes: 1000,
        installBytesPerSecond: 125,
        installPhase: 'downloading',
        models: [
          DictationModelOption(
            id: 'large',
            name: 'Whisper Large v3 Turbo',
            hosted: true,
            sizeBytes: 812000000,
          ),
        ],
      ),
    );

    final l10n = await pumpSheet(tester);

    // Real progress, not an indeterminate line.
    final bar = tester.widget<LinearProgressIndicator>(
      find.byKey(const Key('dictation_download_progress')),
    );
    expect(bar.value, closeTo(0.25, 1e-9));
    expect(find.text('25%'), findsOneWidget);
    // Size and the estimate are what make a multi-minute wait legible.
    final caption = tester
        .widget<Text>(find.byKey(const Key('dictation_download_eta_large')))
        .data;
    expect(caption, contains(l10n.dictationModelSizeMb('774')));
    expect(caption, contains(l10n.dictationDownloadEtaSeconds('6')));
    // The only action is an explicit cancel; a second writer is impossible.
    expect(find.byKey(const Key('dictation_download_large')), findsNothing);
    await tester.tap(find.byKey(const Key('dictation_cancel_download_large')));
    await tester.pump();
    expect(cubit.cancelledDownloads, ['agent-1']);
  });

  testWidgets('the rename phase replaces the estimate', (tester) async {
    cubit.show(
      const DictationModelStatus(
        isPlatformSupported: true,
        installingModelId: 'large',
        downloadProgress: 1,
        installReceivedBytes: 1000,
        installTotalBytes: 1000,
        installPhase: 'activating',
        models: [
          DictationModelOption(
            id: 'large',
            name: 'Whisper Large v3 Turbo',
            hosted: true,
            sizeBytes: 812000000,
          ),
        ],
      ),
    );

    final l10n = await pumpSheet(tester);

    expect(
      tester
          .widget<Text>(find.byKey(const Key('dictation_download_eta_large')))
          .data,
      contains(l10n.dictationDownloadFinishing),
    );
    expect(find.text('100%'), findsOneWidget);
  });

  testWidgets('another row cannot start a second install', (tester) async {
    cubit.show(
      const DictationModelStatus(
        isPlatformSupported: true,
        installingModelId: 'large',
        downloadProgress: 0.5,
        installTotalBytes: 1000,
        installReceivedBytes: 500,
        models: [
          DictationModelOption(
            id: 'large',
            name: 'Whisper Large v3 Turbo',
            hosted: true,
            sizeBytes: 812000000,
          ),
          DictationModelOption(
            id: 'kroko',
            name: 'Zipformer EN Kroko',
            hosted: true,
            sizeBytes: 70092599,
          ),
        ],
      ),
    );

    await pumpSheet(tester);

    final other = tester.widget<FilledButton>(
      find.byKey(const Key('dictation_download_kroko')),
    );
    expect(
      other.onPressed,
      isNull,
      reason: 'the daemon installs one model at a time',
    );
    expect(find.byKey(const Key('dictation_process_loading')), findsNothing);
  });

  testWidgets('a finished install clears the row without closing the sheet',
      (tester) async {
    // D1, end to end from the widget's side: the sheet is mounted the whole
    // time, and the daemon's terminal status — one without `install` — has to
    // turn the downloading row back into Use.
    final resolver = FakeDictationResolver();
    final liveCubit = DictationCubit(
      resolver: resolver,
      capture: SilentDictationCapture(),
    );
    addTearDown(liveCubit.close);

    await pumpTestApp(
      tester,
      child: BlocProvider<DictationCubit>.value(
        value: liveCubit,
        child: DictationModelSheet(device: device),
      ),
    );
    await tester.pump();

    final transport = resolver.latest('agent-1');
    transport.emit(
      dictationStatusEvent(
        selected: null,
        ready: false,
        models: [hostedRow],
        install: {
          'model_id': 'large',
          'received_bytes': 800,
          'total_bytes': 1000,
          'phase': 'downloading',
          'bytes_per_second': 125,
        },
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(liveCubit.state.model.installingModelId, 'large');
    expect(
      find.byKey(const Key('dictation_cancel_download_large')),
      findsOneWidget,
    );

    transport.emit(
      dictationStatusEvent(
        selected: null,
        ready: false,
        models: [
          {...hostedRow, 'installed': true},
        ],
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(
      find.byKey(const Key('dictation_cancel_download_large')),
      findsNothing,
      reason: 'the sheet never had to be reopened',
    );
    expect(find.byKey(const Key('dictation_download_progress')), findsNothing);
    expect(find.byKey(const Key('dictation_use_large')), findsOneWidget);
  });

  testWidgets('a cancelled install returns the row to Download', (tester) async {
    final resolver = FakeDictationResolver();
    final liveCubit = DictationCubit(
      resolver: resolver,
      capture: SilentDictationCapture(),
    );
    addTearDown(liveCubit.close);

    await pumpTestApp(
      tester,
      child: BlocProvider<DictationCubit>.value(
        value: liveCubit,
        child: DictationModelSheet(device: device),
      ),
    );
    await tester.pump();

    final transport = resolver.latest('agent-1');
    transport.emit(
      dictationStatusEvent(
        selected: null,
        ready: false,
        models: [hostedRow],
        install: {
          'model_id': 'large',
          'received_bytes': 150,
          'total_bytes': 1000,
          'phase': 'downloading',
          'bytes_per_second': 50,
        },
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(const Key('dictation_cancel_download_large')));
    await tester.pump();
    expect(transport.commandNames, contains('cancelInstall'));

    // The daemon's answer to the cancel: nothing is in flight any more.
    transport.emit(
      dictationStatusEvent(selected: null, ready: false, models: [hostedRow]),
    );
    await tester.pump();
    await tester.pump();

    expect(
      find.byKey(const Key('dictation_download_large')),
      findsOneWidget,
      reason: 'a cancelled download is offered again, in place',
    );
    expect(find.byKey(const Key('dictation_cancel_download_large')), findsNothing);
  });

  testWidgets('a row renders its name, badge, description and speed', (
    tester,
  ) async {
    cubit.show(
      const DictationModelStatus(
        isPlatformSupported: true,
        isReady: true,
        selectedModelId: 'egy-whisper-turbo-ggml-q8',
        models: [
          DictationModelOption(
            id: 'egy-whisper-turbo-ggml-q8',
            name: 'Egyptian Whisper Turbo Q8',
            description: {
              'en': 'Recommended for Arabic.',
              'ar': 'الموصى به للعربية.',
            },
            badge: 'recommended',
            speedTier: 3,
            sizeBytes: 874208239,
            installed: true,
          ),
          DictationModelOption(
            id: 'kroko',
            name: 'Zipformer EN Kroko',
            description: {'en': 'English streaming.', 'ar': 'بث إنجليزي.'},
            badge: 'faster',
            speedTier: 4,
            sizeBytes: 70092599,
            streaming: true,
          ),
        ],
      ),
    );

    final l10n = await pumpSheet(tester);

    // Names are proper nouns and never translated.
    expect(find.text('Egyptian Whisper Turbo Q8'), findsOneWidget);
    expect(find.text('Zipformer EN Kroko'), findsOneWidget);
    // The description comes from the model's own locale map, in this locale.
    expect(find.text('Recommended for Arabic.'), findsOneWidget);
    expect(find.text('الموصى به للعربية.'), findsNothing);
    // Badges are closed-set codes the Client localizes.
    expect(find.text(l10n.dictationBadgeRecommended), findsOneWidget);
    expect(find.text(l10n.dictationBadgeFaster), findsOneWidget);
    expect(find.text('recommended'), findsNothing);
    // Speed and streaming are drawn as bars and an icon, not as prose.
    expect(
      find.byKey(const Key('dictation_speed_egy-whisper-turbo-ggml-q8')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('dictation_mode_streaming_badge')), findsOneWidget);
    // The size is a row fact like the rest: keyed, so the driver projection can
    // prove it instead of relying on a screenshot.
    expect(
      find.byKey(const Key('dictation_model_size_egy-whisper-turbo-ggml-q8')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<Text>(
            find.byKey(
              const Key('dictation_model_size_egy-whisper-turbo-ggml-q8'),
            ),
          )
          .data,
      l10n.dictationModelSizeMb('834'),
    );
  });

  testWidgets('installed rows come first in the sheet', (tester) async {
    cubit.show(
      const DictationModelStatus(
        isPlatformSupported: true,
        isReady: true,
        models: [
          DictationModelOption(
            id: 'new',
            name: 'New Model',
            hosted: true,
          ),
          DictationModelOption(
            id: 'on-disk',
            name: 'Installed Model',
            installed: true,
          ),
        ],
      ),
    );

    await pumpSheet(tester);

    final installedY = tester
        .getTopLeft(find.byKey(const Key('dictation_model_name_on-disk')))
        .dy;
    final newY =
        tester.getTopLeft(find.byKey(const Key('dictation_model_name_new'))).dy;
    expect(installedY, lessThan(newY));
  });

  testWidgets('a downloaded model offers use, not another download',
      (tester) async {
    cubit.show(
      const DictationModelStatus(
        isPlatformSupported: true,
        isReady: true,
        selectedModelId: 'small',
        models: [
          DictationModelOption(
            id: 'small',
            name: 'Whisper Base Int8',
            installed: true,
          ),
          DictationModelOption(
            id: 'medium',
            name: 'Egyptian Whisper Turbo Q8',
            hosted: true,
            installed: true,
          ),
        ],
      ),
    );

    await pumpSheet(tester);

    await tester.tap(find.byKey(const Key('dictation_use_medium')));
    await tester.pump();

    expect(cubit.selectedModels, ['medium']);
    expect(find.byKey(const Key('dictation_use_small')), findsNothing);
  });
}
