import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/provider_setup/data/models/provider_discovery_error_dto.dart';
import 'package:sanad_client/features/provider_setup/presentation/widgets/provider_discovery_notice.dart';
import 'package:sanad_client/l10n/app_localizations.dart';

Widget _host({
  ProviderDiscoveryErrorDto? error,
  ProviderModelCacheDto? modelCache,
  String locale = 'en',
}) {
  return MaterialApp(
    locale: Locale(locale),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: ProviderDiscoveryNotice(
        instanceId: 'inst-1',
        error: error,
        modelCache: modelCache,
      ),
    ),
  );
}

Future<AppLocalizations> _l10nFor(String locale) =>
    AppLocalizations.delegate.load(Locale(locale));

const _authError = ProviderDiscoveryErrorDto(
  kind: 'invalid_credential',
  statusCode: 401,
  message: 'Invalid credential (HTTP 401)',
  endpoint: 'https://opencode.ai/zen/go/v1/models',
);

void main() {
  testWidgets('a rejected credential is an actionable message in English', (
    tester,
  ) async {
    final l10n = await _l10nFor('en');
    await tester.pumpWidget(_host(error: _authError));

    expect(
      find.byKey(const Key('provider_discovery_message_inst-1')),
      findsOneWidget,
    );
    expect(find.text(l10n.providerDiscoveryInvalidCredential), findsOneWidget);
    expect(
      find.text(
        l10n.providerDiscoveryEndpoint('https://opencode.ai/zen/go/v1/models'),
      ),
      findsOneWidget,
    );
    // The daemon's English summary is not echoed for a classified kind; only
    // the localized sentence and the endpoint are shown.
    expect(find.text('Invalid credential (HTTP 401)'), findsNothing);
  });

  testWidgets('the same message is localized in Arabic', (tester) async {
    final en = await _l10nFor('en');
    final ar = await _l10nFor('ar');
    await tester.pumpWidget(_host(error: _authError, locale: 'ar'));

    expect(find.text(ar.providerDiscoveryInvalidCredential), findsOneWidget);
    expect(find.text(ar.providerDiscoveryInvalidCredential), isNot(find.text(en.providerDiscoveryInvalidCredential)));
    expect(
      find.text(
        ar.providerDiscoveryEndpoint('https://opencode.ai/zen/go/v1/models'),
      ),
      findsOneWidget,
    );
    expect(ar.providerDiscoveryInvalidCredential.trim(), isNotEmpty);
  });

  testWidgets('a non-auth HTTP failure names its status', (tester) async {
    final l10n = await _l10nFor('en');
    await tester.pumpWidget(
      _host(
        error: const ProviderDiscoveryErrorDto(
          kind: 'http',
          statusCode: 429,
          message: 'Rate limited (HTTP 429)',
        ),
      ),
    );

    expect(
      find.text(l10n.providerDiscoveryHttp(429)),
      findsOneWidget,
    );
    // No endpoint line when the daemon had no endpoint to report.
    expect(
      find.byKey(const Key('provider_discovery_endpoint_inst-1')),
      findsNothing,
    );
  });

  testWidgets('network and malformed-list failures use their own sentences', (
    tester,
  ) async {
    final l10n = await _l10nFor('en');

    await tester.pumpWidget(
      _host(error: const ProviderDiscoveryErrorDto(kind: 'network')),
    );
    expect(find.text(l10n.providerDiscoveryNetwork), findsOneWidget);

    await tester.pumpWidget(
      _host(error: const ProviderDiscoveryErrorDto(kind: 'no_models')),
    );
    expect(
      find.text(l10n.providerDiscoveryNoModels),
      findsOneWidget,
    );
  });

  testWidgets('a fallback list is labelled unverified', (tester) async {
    final l10n = await _l10nFor('en');
    await tester.pumpWidget(
      _host(
        error: _authError,
        modelCache: const ProviderModelCacheDto(
          source: 'fallback',
          verified: false,
        ),
      ),
    );

    expect(
      find.byKey(const Key('provider_discovery_fallback_inst-1')),
      findsOneWidget,
    );
    expect(find.text(l10n.providerModelCacheUnverified), findsOneWidget);
  });

  testWidgets('a verified live list is never labelled as a fallback', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        modelCache: const ProviderModelCacheDto(source: 'live', verified: true),
      ),
    );

    expect(
      find.byKey(const Key('provider_discovery_notice_inst-1')),
      findsNothing,
    );
  });

  testWidgets('an instance without a discovery failure renders nothing', (
    tester,
  ) async {
    await tester.pumpWidget(_host());

    expect(
      find.byKey(const Key('provider_discovery_notice_inst-1')),
      findsNothing,
    );
  });

  testWidgets(
    'a non-definitive cause warns beside READY in English and Arabic',
    (tester) async {
      // A provider outage over a still-usable saved list: the card stays
      // READY, so the notice must read as a warning, not as an error
      // (issue 339 review 2).
      const warning = ProviderDiscoveryErrorDto(
        kind: 'network',
        message: 'Could not reach the provider endpoint',
        definitive: false,
      );
      final en = await _l10nFor('en');
      final ar = await _l10nFor('ar');

      for (final locale in ['en', 'ar']) {
        final l10n = locale == 'en' ? en : ar;
        await tester.pumpWidget(_host(error: warning, locale: locale));

        final expected = l10n.providerLastCheckFailed(
          l10n.providerDiscoveryNetwork,
        );
        expect(
          find.text(expected),
          findsOneWidget,
          reason: 'warning copy must name the cause in $locale',
        );
        // The bare error sentence must not appear alone: that is the READY +
        // error contradiction.
        expect(find.text(l10n.providerDiscoveryNetwork), findsNothing);
        if (locale == 'ar') {
          expect(expected, isNot(en.providerLastCheckFailed(
            en.providerDiscoveryNetwork,
          )));
        }
      }
    },
  );

  testWidgets('an older daemon payload cannot produce an error beside READY', (
    tester,
  ) async {
    final l10n = await _l10nFor('en');
    // No `definitive` field: weight follows the category, so a transport cause
    // is a warning while a rejected credential is still an error.
    final network = ProviderDiscoveryErrorDto.fromJson({
      'kind': 'network',
      'message': 'Model discovery failed',
    })!;
    await tester.pumpWidget(_host(error: network));

    expect(
      find.text(l10n.providerLastCheckFailed(l10n.providerDiscoveryNetwork)),
      findsOneWidget,
    );

    final unauthorized = ProviderDiscoveryErrorDto.fromJson({
      'kind': 'http',
      'status_code': 401,
    })!;
    expect(unauthorized.definitive, isTrue);
  });
}
