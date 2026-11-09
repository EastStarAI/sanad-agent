// The provider instance form's footer must fit an iPhone-width dialog.
//
// The live iOS pass found the footer row overflowing by 20 px at 338 logical
// px once a provisional instance exists (Cancel + back-to-list + Continue share
// one row). The rule under test: the footer never overflows at a phone width,
// and at desktop width it keeps today's single-row layout with the primary
// action on the right.

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/core/presentation/bloc/appearance/appearance_cubit.dart';
import 'package:sanad_client/core/presentation/bloc/appearance/appearance_state.dart';
import 'package:sanad_client/core/presentation/bloc/locale/locale_cubit.dart' show kSupportedLocales;
import 'package:sanad_client/features/provider_setup/data/models/provider_instance_dto.dart';
import 'package:sanad_client/features/provider_setup/data/models/provider_template_dto.dart';
import 'package:sanad_client/features/provider_setup/presentation/bloc/provider_setup_cubit.dart';
import 'package:sanad_client/features/provider_setup/presentation/bloc/provider_setup_state.dart';
import 'package:sanad_client/features/provider_setup/presentation/widgets/provider_instance_form_view.dart';
import 'package:sanad_client/l10n/app_localizations.dart';

/// The live form state: a provisional custom instance is already persisted, so
/// the footer carries its third (back-to-list) action.
const _provisionalState = ProviderSetupState(
  selectedTemplate: ProviderTemplateDto(
    name: 'custom',
    displayName: 'Custom Provider',
    description: 'Any OpenAI-compatible endpoint',
    defaultBaseUrl: 'https://api.example.com/v1',
    authType: 'api_key',
    authFlow: 'api_key',
    apiMode: 'openai',
    supportsModelFetch: true,
    disconnectable: true,
    fallbackModels: [],
    aliases: [],
  ),
  selectedInstance: ProviderInstanceDto(
    id: 'inst-provisional',
    templateId: 'custom',
    displayName: 'Local Test Gateway',
    protocol: 'openai_compatible',
    authMethod: 'api_key',
    status: 'provisional',
    isDefault: false,
    configRevision: 1,
    credentialRevision: 1,
  ),
  provisionalInstanceId: 'inst-provisional',
);

void main() {
  Future<void> pumpForm(WidgetTester tester, Size size, {Locale locale = const Locale('en')}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider<ProviderSetupCubit>.value(value: _StubProviderSetupCubit()),
          BlocProvider<AppearanceCubit>.value(value: _StubAppearanceCubit()),
        ],
        child: MaterialApp(
          locale: locale,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: kSupportedLocales,
          home: const Scaffold(body: ProviderInstanceFormView()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Every footer action must be laid out inside the dialog it belongs to.
  ///
  /// Asserted as geometry rather than as "no exception anywhere", because the
  /// form body's protocol dropdown is wider than the test font allows at this
  /// width and is a separate, pre-existing case outside this footer fix.
  void expectFooterInsideViewport(WidgetTester tester, double width) {
    for (final finder in <Finder>[
      find.byKey(const Key('provider_form_submit')),
      find.byKey(const Key('provider_form_back_to_list')),
      find.text('Cancel'),
    ]) {
      expect(finder, findsOneWidget);
      final rect = tester.getRect(finder);
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(width));
    }
    while (tester.takeException() != null) {}
  }

  testWidgets('footer fits an iPhone width with a provisional instance', (tester) async {
    await pumpForm(tester, const Size(338, 700));

    expectFooterInsideViewport(tester, 338);
  });

  testWidgets('footer fits an iPhone width in the right-to-left locale', (tester) async {
    await pumpForm(tester, const Size(338, 700), locale: const Locale('ar'));

    expectFooterInsideViewport(tester, 338);
  });

  testWidgets('footer keeps one row with the primary action on the right at desktop width', (tester) async {
    await pumpForm(tester, const Size(1400, 1000));

    expect(tester.takeException(), isNull);
    final submit = tester.getRect(find.byKey(const Key('provider_form_submit')));
    final backToList = tester.getRect(find.byKey(const Key('provider_form_back_to_list')));
    final cancel = tester.getRect(find.text('Cancel'));

    // One row: identical vertical center for every footer action.
    expect(submit.center.dy, moreOrLessEquals(backToList.center.dy, epsilon: 0.5));
    expect(submit.center.dy, moreOrLessEquals(cancel.center.dy, epsilon: 0.5));
    // Cancel is the left-most action and Continue the right-most.
    expect(cancel.left, lessThan(backToList.left));
    expect(submit.left, greaterThan(backToList.right));
  });
}

class _StubProviderSetupCubit extends Fake implements ProviderSetupCubit {
  @override
  ProviderSetupState get state => _provisionalState;

  @override
  Stream<ProviderSetupState> get stream => const Stream<ProviderSetupState>.empty();

  @override
  String? get draftDisplayName => null;

  @override
  String? get draftBaseUrl => null;

  @override
  String? get draftApiKey => '';

  @override
  String? get draftProtocol => null;

  @override
  bool? get draftAllowAutoFailover => null;
}

class _StubAppearanceCubit extends Fake implements AppearanceCubit {
  @override
  AppearanceState get state => const AppearanceState();

  @override
  Stream<AppearanceState> get stream => const Stream<AppearanceState>.empty();
}
