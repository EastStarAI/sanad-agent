import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/dictation/presentation/dictation_model_text.dart';
import 'package:sanad_client/l10n/app_localizations.dart';

/// A channel refusal is the one reason the model sheet may state on its own.
///
/// These codes are raised by the transport boundary before a command reaches the
/// daemon, so the catalog is unknown rather than empty. Every one of them must
/// own a distinct localized sentence in both locales, and every other code must
/// map to nothing here — its surface is the notice, the readiness banner, or the
/// sheet's install sentence.
void main() {
  const channelCodes = <String>[
    'dictation_unavailable',
    'relay_unavailable',
    'relay_forbidden',
    'relay_invalid_request',
    'update_required',
  ];

  const otherCodes = <String>[
    'model_not_installed',
    'native_runtime_missing',
    'native_runtime_preparing',
    'sherpa_runtime_missing',
    'dictation_disabled',
    'unsupported_platform',
    'dictation_busy',
    'no_speech',
    'session_limit',
    'microphone_denied',
    'connect_failed',
    'start_failed',
    '',
  ];

  for (final locale in const [Locale('en'), Locale('ar')]) {
    test('every channel refusal owns a sentence in ${locale.languageCode}', () async {
      final l10n = await AppLocalizations.delegate.load(locale);
      final sentences = <String>{};
      for (final code in channelCodes) {
        final label = dictationChannelRefusalLabel(l10n, code);
        expect(label, isNotNull, reason: code);
        expect(label, isNotEmpty, reason: code);
        sentences.add(label!);
      }
      // Distinct copy: "malformed" is not "cannot relay", and neither is "update".
      expect(sentences, hasLength(channelCodes.length));
    });

    test('a non-channel code never borrows the channel reason', () async {
      final l10n = await AppLocalizations.delegate.load(locale);
      for (final code in otherCodes) {
        expect(dictationChannelRefusalLabel(l10n, code), isNull, reason: code);
      }
      expect(dictationChannelRefusalLabel(l10n, null), isNull);
    });
  }
}
