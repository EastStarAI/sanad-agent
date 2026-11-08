import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/settings/data/device_settings_client.dart';
import 'package:sanad_client/features/settings/presentation/widgets/dictation_settings_card.dart';
import 'package:sanad_client/l10n/app_localizations.dart';

import '../../helpers/pump_app.dart';

/// The settings card is a projection of the daemon snapshot: it owns no runtime
/// state, it never renders a daemon code or path, and the toggle is the only
/// action it performs.
void main() {
  Future<AppLocalizations> pumpCard(
    WidgetTester tester, {
    required DictationSettingsSetting dictation,
    bool enabled = true,
    ValueChanged<bool>? onToggle,
  }) async {
    await pumpTestApp(
      tester,
      child: DictationSettingsCard(
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
            label: 'Whisper Turbo',
            totalBytes: 812000000,
            installed: true,
          ),
        ],
      ),
    );

    expect(find.text(l10n.deviceSettingsDictationTitle), findsOneWidget);
    expect(find.text('Whisper Turbo'), findsOneWidget);
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
            label: 'stt.model_path',
            labelCode: 'path_override',
            installed: true,
          ),
        ],
      ),
    );

    expect(find.text(l10n.dictationPathOverrideModel), findsOneWidget);
    expect(find.text('stt.model_path'), findsNothing);
  });
}
