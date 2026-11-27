import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/provider_setup/data/models/provider_discovery_error_dto.dart';
import 'package:sanad_client/features/provider_setup/data/models/provider_instance_dto.dart';
import 'package:sanad_client/features/provider_setup/data/models/provider_instance_test_result_dto.dart';
import 'package:sanad_client/features/provider_setup/presentation/widgets/provider_connection_notices.dart';
import 'package:sanad_client/l10n/app_localizations.dart';

const _offline = ProviderDiscoveryErrorDto(
  kind: 'network', endpoint: 'http://localhost:9000/v1/models', definitive: false,
);
const _failure = ProviderInstanceTestResultDto(
  success: false, modelsCount: 0, failure: _offline,
);

Widget _card({ProviderInstanceTestResultDto? test, bool offline = true}) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: ProviderConnectionNotices(
    instance: ProviderInstanceDto(
      id: 'provider', templateId: 'custom', displayName: 'Provider',
      protocol: 'openai_compatible', authMethod: 'api_key',
      defaultModel: 'model-b', status: 'ready', isDefault: false,
      configRevision: 1, credentialRevision: 1,
      discoveryError: offline ? _offline : null,
      modelCache: ProviderModelCacheDto(source: offline ? 'cache_stale' : 'live'),
    ), latestTest: test,
  )),
);

void main() {
  testWidgets('repeated Test and reopened Settings show one offline warning', (tester) async {
    for (final test in [_failure, null, _failure]) {
      await tester.pumpWidget(_card(test: test));
      expect(find.byKey(const Key('provider_discovery_notice_provider')), findsOneWidget);
      expect(find.byKey(const Key('provider_discovery_fallback_provider')), findsOneWidget);
      expect(find.byKey(const Key('provider_test_failure_notice_provider')), findsNothing);
    }
    await tester.pumpWidget(_card(offline: false, test: const ProviderInstanceTestResultDto(
      success: true, modelsCount: 13, probeState: 'passed', model: 'model-b',
    )));
    expect(find.byKey(const Key('provider_discovery_notice_provider')), findsNothing);
    expect(find.byKey(const Key('provider_test_result_provider')), findsOneWidget);
  });

  testWidgets('a different current failure is not suppressed', (tester) async {
    await tester.pumpWidget(_card(test: const ProviderInstanceTestResultDto(
      success: false, modelsCount: 1, model: 'model-b',
      failure: ProviderDiscoveryErrorDto(kind: 'invalid_credential', statusCode: 401),
    )));
    expect(find.byKey(const Key('provider_discovery_notice_provider')), findsOneWidget);
    expect(find.byKey(const Key('provider_test_failure_notice_provider')), findsOneWidget);
  });

  testWidgets('a verdict for the previous model is not shown on the current model', (tester) async {
    await tester.pumpWidget(_card(offline: false, test: const ProviderInstanceTestResultDto(
      success: true, modelsCount: 13, probeState: 'warning', model: 'model-a',
    )));
    expect(find.byKey(const Key('provider_test_result_provider')), findsNothing);
  });
}
