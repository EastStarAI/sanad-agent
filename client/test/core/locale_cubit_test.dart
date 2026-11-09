import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sanad_client/core/presentation/bloc/locale/locale_cubit.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('locale', () {
    test('an explicit choice wins over the system language', () {
      expect(
        LocaleCubit.resolveInitial(
          systemLocale: const Locale('en'),
          savedCode: 'ar',
        ).languageCode,
        'ar',
      );
    });

    test('with no saved choice the system language is used', () {
      expect(
        LocaleCubit.resolveInitial(
          systemLocale: const Locale('ar', 'EG'),
          savedCode: null,
        ).languageCode,
        'ar',
      );
    });

    test('an unsupported system language falls back to en', () {
      expect(
        LocaleCubit.resolveInitial(
          systemLocale: const Locale('de'),
          savedCode: null,
        ).languageCode,
        'en',
      );
    });

    test('an unknown saved value defers to the system language', () {
      expect(
        LocaleCubit.resolveInitial(
          systemLocale: const Locale('ar'),
          savedCode: 'fr',
        ).languageCode,
        'ar',
      );
    });

    test('the stored-path resolver returns a supported locale', () async {
      final locale = await LocaleCubit.getSavedLocale();
      expect(kSupportedLocales, contains(locale));
    });

    test('supported locales contain en and ar', () {
      expect(
        kSupportedLocales.map((l) => l.languageCode),
        containsAll(['en', 'ar']),
      );
    });
  });

  group('arb parity', () {
    test('ar has exactly the same translation keys as en', () {
      final en = _keys('lib/l10n/app_en.arb');
      final ar = _keys('lib/l10n/app_ar.arb');
      expect(ar, en);
    });
  });

  group('schedules screen strings', () {
    // Task 139 C5: every key the task names is authored in both locales.
    const required = <String>{
      'schedules',
      'newSchedule',
      'scheduleName',
      'scheduleNameOptional',
      'scheduleTask',
      'scheduleTaskHint',
      'scheduleRecurrence',
      'scheduleRecurrenceOnce',
      'scheduleRecurrenceInterval',
      'scheduleRecurrenceDaily',
      'scheduleRecurrenceWeekly',
      'scheduleRecurrenceMonthly',
      'scheduleTime',
      'scheduleWeekdays',
      'scheduleDayOfMonth',
      'scheduleInterval',
      'scheduleZone',
      'scheduleWorkspace',
      'scheduleModel',
      'scheduleConversationMode',
      'scheduleModeContinuous',
      'scheduleModeNewEachRun',
      'scheduleNextRunPreview',
      'schedulePaused',
      'pauseSchedule',
      'resumeSchedule',
      'runNow',
      'deleteSchedule',
      'deleteScheduleConfirm',
      'scheduleDetails',
      'scheduleRunHistory',
      'scheduleRunStatusRunning',
      'scheduleRunStatusSucceeded',
      'scheduleRunStatusFailed',
      'scheduleRunStatusSkipped',
      'scheduleRunTriggerManual',
      'scheduleDuration',
      'scheduleOpenConversation',
      'scheduleEmpty',
      'scheduleUnavailable',
      'scheduleLoadFailed',
      'scheduleSaveFailed',
      'scheduleExpired',
      'scheduleFailureSuggestion',
      'scheduleOwnedByConversation',
      'scheduleOwnedByDevice',
      'scheduleHasSchedules',
      'scheduleConversationDeleteWarning',
      'scheduleFailureNotice',
      'scheduleInvalidZone',
      'schedulePreviewInvalid',
      'scheduleNoRuns',
      'scheduleLoadRunsFailed',
      'scheduleErrorInvalidRequest',
      'scheduleErrorInvalidSchedule',
      'scheduleErrorNotFound',
      'scheduleErrorOrphaned',
      'scheduleErrorPermissionDenied',
      'scheduleErrorInternal',
    };

    test('every Schedules screen key exists in en and ar', () {
      for (final path in ['lib/l10n/app_en.arb', 'lib/l10n/app_ar.arb']) {
        expect(
          required.difference(_keys(path)),
          isEmpty,
          reason: '$path is missing Schedules screen keys',
        );
      }
    });

    test('every schedule error code has its own copy in both locales', () {
      // A total mapping over ScheduleErrorCode is C4's typed-copy rule; the
      // unknown code deliberately renders a generic sentence instead.
      const codes = <String>[
        'scheduleErrorInvalidRequest',
        'scheduleErrorInvalidSchedule',
        'scheduleErrorNotFound',
        'scheduleExpired',
        'scheduleErrorOrphaned',
        'scheduleErrorPermissionDenied',
        'scheduleErrorInternal',
        'scheduleUnavailableHint',
      ];
      for (final path in ['lib/l10n/app_en.arb', 'lib/l10n/app_ar.arb']) {
        final keys = _keys(path);
        for (final code in codes) {
          expect(keys, contains(code), reason: '$path is missing $code');
        }
      }
    });
  });

  group('secrets screen strings', () {
    // Task 140 C4: every key the task names is authored in both locales.
    const required = <String>{
      'privacyAndSecurity',
      'secrets',
      'secretsEmpty',
      'addSecret',
      'secretName',
      'secretDescription',
      'secretDescriptionOptional',
      'secretValue',
      'secretValueHint',
      'secretValueShow',
      'secretValueHide',
      'saveSecret',
      'replaceSecret',
      'replaceSecretNote',
      'deleteSecret',
      'deleteSecretConfirm',
      'secretDeleted',
      'secretSaved',
      'secretUpdatedAt',
      'secretSourceUser',
      'secretSourceAgent',
      'secretNoDescription',
      'secretInvalidName',
      'secretReservedName',
      'secretValueRequired',
      'secretValueTooLong',
      'secretsUnavailable',
      'secretsLoadFailed',
      'secretsSaveFailed',
      'retry',
    };

    test('every Secrets screen key exists in en and ar', () {
      for (final path in ['lib/l10n/app_en.arb', 'lib/l10n/app_ar.arb']) {
        expect(
          required.difference(_keys(path)),
          isEmpty,
          reason: '$path is missing Secrets screen keys',
        );
      }
    });
  });
}

/// Reads key lists from checked-in fixtures so the parity test does not
/// depend on l10n codegen output paths.
Set<String> _keys(String assetPath) {
  final file = File(assetPath);
  if (!file.existsSync()) {
    fail('Missing parity fixture: $assetPath');
  }
  final body = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  return body.keys.where((k) => !k.startsWith('@')).toSet();
}
