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
            label: 'stt.model_path',
            labelCode: 'path_override',
            installed: true,
          ),
        ],
      ),
    );

    final l10n = await pumpSheet(tester);

    expect(find.text(l10n.dictationPathOverrideModel), findsOneWidget);
    expect(find.text('stt.model_path'), findsNothing);
    expect(find.text('path_override'), findsNothing);
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
            label: 'Large',
            hosted: true,
            totalBytes: 812000000,
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

  testWidgets('a downloaded model offers use, not another download',
      (tester) async {
    cubit.show(
      const DictationModelStatus(
        isPlatformSupported: true,
        isReady: true,
        selectedModelId: 'small',
        models: [
          DictationModelOption(id: 'small', label: 'Small', installed: true),
          DictationModelOption(
            id: 'medium',
            label: 'Medium',
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
