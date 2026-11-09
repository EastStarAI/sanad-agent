import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/dictation/domain/dictation_audio_capture.dart';
import 'package:sanad_client/features/dictation/domain/dictation_transport.dart';
import 'package:sanad_client/features/dictation/domain/dictation_transport_resolver.dart';
import 'package:sanad_client/features/dictation/presentation/bloc/dictation_cubit.dart';
import 'package:sanad_client/features/settings/data/device_settings_client.dart';
import 'package:sanad_client/features/settings/presentation/widgets/dictation_settings_card.dart';
import 'package:sanad_client/l10n/app_localizations.dart';

import '../../helpers/pump_app.dart';

/// The settings card is a projection of the daemon snapshot: it owns no runtime
/// state, it never renders a daemon code or path, and the toggle plus the install
/// route are the only actions it performs.
///
/// The install route is the same model sheet the composer mic opens, so a Home
/// with no model can be fixed from Settings without a second install surface.

class _Transport implements DictationTransport {
  final StreamController<Map<String, dynamic>> controller =
      StreamController<Map<String, dynamic>>.broadcast();

  @override
  Stream<Map<String, dynamic>> get events => controller.stream;

  @override
  bool get isOpen => true;

  @override
  void sendCommand(String event, [Map<String, dynamic> payload = const {}]) {}

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
  Future<Stream<List<int>>> start() async => const Stream.empty();

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}

void main() {
  final device = DeviceConfig(id: 'dev-1', name: 'Device', isOnline: true);

  late _Transport transport;
  late DictationCubit dictationCubit;

  setUp(() {
    transport = _Transport();
    dictationCubit = DictationCubit(
      resolver: _Resolver(transport),
      capture: _Capture(),
      sessionIdFactory: () => 's1',
    );
  });

  tearDown(() async {
    await dictationCubit.close();
    await transport.controller.close();
  });

  Future<AppLocalizations> pumpCard(
    WidgetTester tester, {
    required DictationSettingsSetting dictation,
    bool enabled = true,
    ValueChanged<bool>? onToggle,
  }) async {
    await pumpTestApp(
      tester,
      dictationCubit: dictationCubit,
      child: DictationSettingsCard(
        device: device,
        dictation: dictation,
        enabled: enabled,
        onToggle: onToggle ?? (_) {},
      ),
    );
    return AppLocalizations.of(
      tester.element(find.byKey(const Key('device_settings_dictation_enabled'))),
    )!;
  }

  testWidgets('a ready projection shows the selected model and ready chip',
      (tester) async {
    final l10n = await pumpCard(
      tester,
      dictation: const DictationSettingsSetting(
        enabled: true,
        managedExternally: false,
        supported: true,
        ready: true,
        busy: false,
        selectedModelId: 'whisper',
        models: [
          DictationModelSizeSetting(
            id: 'whisper',
            name: 'Whisper Large v3 Turbo',
            sizeBytes: 812000000,
            installed: true,
          ),
        ],
      ),
    );

    expect(find.text(l10n.deviceSettingsDictationTitle), findsOneWidget);
    expect(find.text('Whisper Large v3 Turbo'), findsOneWidget);
    expect(find.text(l10n.deviceSettingsDictationReady), findsOneWidget);
    expect(find.byKey(const Key('device_settings_dictation_reason')), findsNothing);
  });

  testWidgets('the toggle is the only action and reports its value',
      (tester) async {
    final values = <bool>[];
    await pumpCard(
      tester,
      dictation: const DictationSettingsSetting(
        enabled: true,
        managedExternally: false,
        supported: true,
        ready: true,
        busy: false,
      ),
      onToggle: values.add,
    );

    await tester.tap(find.byKey(const Key('device_settings_dictation_enabled')));
    await tester.pump();

    expect(values, [false]);
  });

  testWidgets('an owner-managed toggle is disabled and explains why',
      (tester) async {
    final l10n = await pumpCard(
      tester,
      dictation: const DictationSettingsSetting(
        enabled: true,
        managedExternally: true,
        supported: true,
        ready: true,
        busy: true,
      ),
      enabled: false,
    );

    expect(
      find.text(l10n.deviceSettingsDictationManagedExternally),
      findsOneWidget,
    );
    expect(find.text(l10n.deviceSettingsDictationBusy), findsOneWidget);
    final toggle = tester.widget<SwitchListTile>(
      find.byKey(const Key('device_settings_dictation_enabled')),
    );
    expect(toggle.onChanged, isNull);
  });

  testWidgets('a config failure is localized, never rendered as a code',
      (tester) async {
    final l10n = await pumpCard(
      tester,
      dictation: const DictationSettingsSetting(
        enabled: true,
        managedExternally: false,
        supported: false,
        ready: false,
        busy: false,
        reason: 'config_invalid',
      ),
    );

    expect(find.byKey(const Key('device_settings_dictation_reason')), findsOneWidget);
    expect(find.text('config_invalid'), findsNothing);
    expect(find.text(l10n.dictationUnavailable), findsOneWidget);
    expect(find.text(l10n.deviceSettingsDictationNotReady), findsOneWidget);
  });

  testWidgets('a daemon override row is shown through its label code',
      (tester) async {
    final l10n = await pumpCard(
      tester,
      dictation: const DictationSettingsSetting(
        enabled: true,
        managedExternally: false,
        supported: true,
        ready: true,
        busy: false,
        selectedModelId: 'override',
        hasModelPath: true,
        models: [
          DictationModelSizeSetting(
            id: 'override',
            labelCode: 'path_override',
            installed: true,
          ),
        ],
      ),
    );

    expect(find.text(l10n.dictationPathOverrideModel), findsOneWidget);
  });

  testWidgets('a model-less device is never Ready and explains the reason',
      (tester) async {
    final l10n = await pumpCard(
      tester,
      dictation: const DictationSettingsSetting(
        enabled: true,
        managedExternally: false,
        supported: true,
        ready: false,
        busy: false,
        reason: 'model_not_installed',
        selectedModelId: 'egy-whisper-turbo-ggml-q8',
        models: [
          DictationModelSizeSetting(
            id: 'egy-whisper-turbo-ggml-q8',
            name: 'Egyptian Whisper Turbo Q8',
            sizeBytes: 874208239,
          ),
        ],
      ),
    );

    expect(find.text(l10n.deviceSettingsDictationNotReady), findsOneWidget);
    expect(find.text(l10n.deviceSettingsDictationReady), findsNothing);
    expect(
      find.text(l10n.dictationModelNotInstalled),
      findsOneWidget,
      reason: 'the reason is a sentence, never the daemon code',
    );
    expect(find.text('model_not_installed'), findsNothing);
  });

  testWidgets('the install route opens the same model sheet as the mic',
      (tester) async {
    await pumpCard(
      tester,
      dictation: const DictationSettingsSetting(
        enabled: true,
        managedExternally: false,
        supported: true,
        ready: false,
        busy: false,
        reason: 'model_not_installed',
      ),
    );

    await tester.tap(
      find.byKey(const Key('device_settings_dictation_manage')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byKey(const Key('dictation_model_sheet')), findsOneWidget);

    // The sheet asks the daemon for its catalog on open; drain that timer so
    // the test ends without pending work.
    await tester.pump(const Duration(seconds: 6));
  });
}
