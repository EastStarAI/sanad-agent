import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/provider_setup/data/models/provider_discovery_error_dto.dart';
import 'package:sanad_client/features/provider_setup/data/models/provider_instance_test_result_dto.dart';
import 'package:sanad_client/features/provider_setup/presentation/widgets/provider_instance_test_notice.dart';
import 'package:sanad_client/l10n/app_localizations.dart';

Widget _host(ProviderInstanceTestResultDto result, {String locale = 'en'}) {
  return MaterialApp(
    locale: Locale(locale),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: Center(
        child: ProviderInstanceTestNotice(instanceId: 'inst-1', result: result),
      ),
    ),
  );
}

Future<AppLocalizations> _l10nFor(String locale) =>
    AppLocalizations.delegate.load(Locale(locale));

const _pass = ProviderInstanceTestResultDto(
  success: true,
  modelsCount: 12,
  model: 'gpt-4o',
  latencyMs: 840,
);

const _rejected = ProviderInstanceTestResultDto(
  success: false,
  modelsCount: 0,
  failure: ProviderDiscoveryErrorDto(
    kind: 'invalid_credential',
    statusCode: 401,
    message: 'Invalid credential (HTTP 401)',
    endpoint: 'https://opencode.ai/zen/go/v1/models',
  ),
);

void main() {
  testWidgets('a passing test names the models and probe latency', (
    tester,
  ) async {
    final l10n = await _l10nFor('en');
    await tester.pumpWidget(_host(_pass));

    expect(
      find.text(l10n.providerTestWorksWithProbe(12, 'gpt-4o', '0.8')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('provider_test_result_inst-1')), findsOneWidget);
  });

  testWidgets('the passing summary is localized in Arabic', (tester) async {
    final en = await _l10nFor('en');
    final ar = await _l10nFor('ar');
    await tester.pumpWidget(_host(_pass, locale: 'ar'));

    expect(
      find.text(ar.providerTestWorksWithProbe(12, 'gpt-4o', '0.8')),
      findsOneWidget,
    );
    expect(
      find.text(ar.providerTestWorksWithProbe(12, 'gpt-4o', '0.8')),
      isNot(find.text(en.providerTestWorksWithProbe(12, 'gpt-4o', '0.8'))),
    );
  });

  testWidgets('a failing test renders the categorized localized cause', (
    tester,
  ) async {
    final l10n = await _l10nFor('en');
    await tester.pumpWidget(_host(_rejected));

    expect(find.text(l10n.providerDiscoveryInvalidCredential), findsOneWidget);
    expect(
      find.text(
        l10n.providerDiscoveryEndpoint('https://opencode.ai/zen/go/v1/models'),
      ),
      findsOneWidget,
    );
    // The daemon's English summary is not echoed for a classified category.
    expect(find.text('Invalid credential (HTTP 401)'), findsNothing);
  });

  testWidgets('a failing test is localized in Arabic', (tester) async {
    final ar = await _l10nFor('ar');
    await tester.pumpWidget(_host(_rejected, locale: 'ar'));

    expect(find.text(ar.providerDiscoveryInvalidCredential), findsOneWidget);
    expect(
      find.text(
        ar.providerDiscoveryEndpoint('https://opencode.ai/zen/go/v1/models'),
      ),
      findsOneWidget,
    );
  });
}
