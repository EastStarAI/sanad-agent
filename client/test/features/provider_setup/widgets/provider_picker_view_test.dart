import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/provider_setup/data/models/provider_dto.dart';
import 'package:sanad_client/features/provider_setup/data/provider_setup_client.dart';
import 'package:sanad_client/features/provider_setup/presentation/bloc/provider_setup_cubit.dart';
import 'package:sanad_client/features/provider_setup/presentation/bloc/provider_setup_state.dart';
import 'package:sanad_client/features/provider_setup/presentation/widgets/provider_picker_view.dart';
import 'package:sanad_client/l10n/app_localizations.dart';

const _searchFieldKey = Key('provider_picker_search_field');
const _clearKey = Key('provider_picker_search_clear');
const _emptyResultsKey = Key('provider_picker_empty_results');

Key _cardKey(String id) => Key('provider_card_item_$id');

/// The picker only reads the cubit for template selection on tap, so the search
/// tests never place a request on the wire.
class _NoopProviderSetupClient implements ProviderSetupClient {
  @override
  noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

/// Exposes state seeding so widget tests can present an authoritative picker
/// snapshot without running the flow's load path.
class _SeedableProviderSetupCubit extends ProviderSetupCubit {
  _SeedableProviderSetupCubit() : super(client: _NoopProviderSetupClient());

  void seed(ProviderSetupState state) => emit(state);
}

ProviderDto _provider({
  required String id,
  required String displayName,
  List<String> aliases = const [],
}) => ProviderDto(
  id: id,
  name: id,
  displayName: displayName,
  description: '',
  authType: 'api_key',
  authFlow: 'api_key',
  apiMode: 'chat_completions',
  supportsModelFetch: false,
  disconnectable: true,
  fallbackModels: const [],
  aliases: aliases,
  configured: false,
  authenticated: false,
  isCurrent: false,
  models: const [],
  authStatus: 'missing',
);

List<ProviderDto> _catalog() => [
  _provider(id: 'openai', displayName: 'OpenAI', aliases: const ['gpt', 'chatgpt']),
  _provider(id: 'anthropic', displayName: 'Anthropic', aliases: const ['claude']),
  _provider(id: 'ollama-local', displayName: 'Local Ollama'),
];

Widget _wrap(ProviderSetupCubit cubit, {Locale locale = const Locale('en')}) => MaterialApp(
  locale: locale,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: const [Locale('en'), Locale('ar')],
  home: Scaffold(
    body: BlocProvider<ProviderSetupCubit>.value(
      value: cubit,
      child: const SingleChildScrollView(
        padding: EdgeInsets.all(16),
        child: ProviderPickerView(),
      ),
    ),
  ),
);

Future<void> _pumpPicker(
  WidgetTester tester, {
  List<ProviderDto>? providers,
  Locale locale = const Locale('en'),
}) async {
  final cubit = _SeedableProviderSetupCubit();
  addTearDown(cubit.close);
  cubit.seed(
    ProviderSetupState(
      status: ProviderSetupStatus.picker,
      providers: providers ?? _catalog(),
    ),
  );
  await tester.pumpWidget(_wrap(cubit, locale: locale));
  await tester.pump();
}

Future<void> _search(WidgetTester tester, String query) async {
  await tester.enterText(find.byKey(_searchFieldKey), query);
  await tester.pump();
}

/// Rendered card ids in visual order, top to bottom.
List<String> _renderedOrder(WidgetTester tester, List<String> ids) {
  final offsets = {for (final id in ids) id: tester.getTopLeft(find.byKey(_cardKey(id))).dy};
  return offsets.keys.toList()..sort((a, b) => offsets[a]!.compareTo(offsets[b]!));
}

void main() {
  testWidgets('renders the full provider list and an empty search field', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pumpPicker(tester);

    for (final id in ['openai', 'anthropic', 'ollama-local']) {
      expect(find.byKey(_cardKey(id)), findsOneWidget, reason: 'every provider must render for an empty query');
    }
    expect(find.byKey(_searchFieldKey), findsOneWidget);
    expect(find.byKey(_emptyResultsKey), findsNothing);
    expect(find.byKey(_clearKey), findsNothing, reason: 'there is nothing to clear yet');
    expect(tester.widget<TextField>(find.byKey(_searchFieldKey)).focusNode?.hasFocus ?? false, isFalse);
    expect(find.byType(ProviderPickerView), findsOneWidget);
  });

  testWidgets('filters by display name as the user types', (tester) async {
    await _pumpPicker(tester);
    await _search(tester, 'anthropic');

    expect(find.byKey(_cardKey('anthropic')), findsOneWidget);
    expect(find.byKey(_cardKey('openai')), findsNothing);
    expect(find.byKey(_cardKey('ollama-local')), findsNothing);
    expect(find.byKey(_emptyResultsKey), findsNothing);
    expect(find.byKey(_clearKey), findsOneWidget);
  });

  testWidgets('filters by template id', (tester) async {
    await _pumpPicker(tester);
    await _search(tester, 'ollama-local');

    expect(find.byKey(_cardKey('ollama-local')), findsOneWidget);
    expect(find.byKey(_cardKey('openai')), findsNothing);
    expect(find.byKey(_cardKey('anthropic')), findsNothing);
  });

  testWidgets('filters by a template alias', (tester) async {
    await _pumpPicker(tester);
    await _search(tester, 'claude');

    expect(find.byKey(_cardKey('anthropic')), findsOneWidget);
    expect(find.byKey(_cardKey('openai')), findsNothing);
    expect(find.byKey(_cardKey('ollama-local')), findsNothing);
  });

  testWidgets('ignores case and surrounding whitespace', (tester) async {
    await _pumpPicker(tester);
    await _search(tester, '  OPENAI  ');

    expect(find.byKey(_cardKey('openai')), findsOneWidget);
    expect(find.byKey(_cardKey('anthropic')), findsNothing);
    expect(find.byKey(_cardKey('ollama-local')), findsNothing);
  });

  testWidgets('clear button restores the full list and the hint', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pumpPicker(tester);
    await _search(tester, 'openai');
    expect(find.byKey(_cardKey('anthropic')), findsNothing);

    await tester.tap(find.byKey(_clearKey));
    await tester.pump();

    for (final id in ['openai', 'anthropic', 'ollama-local']) {
      expect(find.byKey(_cardKey(id)), findsOneWidget);
    }
    expect(tester.widget<TextField>(find.byKey(_searchFieldKey)).controller?.text, isEmpty);
    expect(find.byKey(_clearKey), findsNothing);
    expect(find.text('Search providers'), findsOneWidget);
  });

  testWidgets('shows the localized empty state when nothing matches', (tester) async {
    await _pumpPicker(tester);
    await _search(tester, 'not-a-real-provider');

    expect(find.byKey(_emptyResultsKey), findsOneWidget);
    expect(find.text('No providers match your search.'), findsOneWidget);
    for (final id in ['openai', 'anthropic', 'ollama-local']) {
      expect(find.byKey(_cardKey(id)), findsNothing);
    }
    expect(find.byKey(_clearKey), findsOneWidget, reason: 'the user must still be able to clear a failed search');
  });

  testWidgets('preserves the authoritative provider order while filtering', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final providers = [
      _provider(id: 'zeta', displayName: 'Zeta Cloud', aliases: const ['llm']),
      _provider(id: 'alpha', displayName: 'Alpha Cloud', aliases: const ['llm']),
      _provider(id: 'mike', displayName: 'Mike Cloud', aliases: const ['llm']),
    ];
    await _pumpPicker(tester, providers: providers);
    expect(_renderedOrder(tester, ['zeta', 'alpha', 'mike']), ['zeta', 'alpha', 'mike']);

    await _search(tester, 'cloud');

    expect(_renderedOrder(tester, ['zeta', 'alpha', 'mike']), ['zeta', 'alpha', 'mike']);
  });

  testWidgets('renders right-to-left and filters Arabic input', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final providers = [
      _provider(id: 'openai', displayName: 'OpenAI', aliases: const ['gpt']),
      _provider(id: 'arabic-vendor', displayName: 'Arabic Vendor', aliases: const ['مزوّد']),
    ];
    await _pumpPicker(tester, providers: providers, locale: const Locale('ar'));

    final l10n = AppLocalizations.of(tester.element(find.byType(ProviderPickerView)))!;
    expect(Directionality.of(tester.element(find.byKey(_searchFieldKey))), TextDirection.rtl);
    expect(find.text(l10n.providerPickerSearchHint), findsOneWidget);

    await _search(tester, 'مزوّد');

    expect(tester.takeException(), isNull);
    expect(find.byKey(_cardKey('arabic-vendor')), findsOneWidget);
    expect(find.byKey(_cardKey('openai')), findsNothing);
    expect(Directionality.of(tester.element(find.byKey(_cardKey('arabic-vendor')))), TextDirection.rtl);
  });

  testWidgets('an Arabic query with no match shows the Arabic empty state', (tester) async {
    await _pumpPicker(tester, locale: const Locale('ar'));
    await _search(tester, 'غير موجود');

    final l10n = AppLocalizations.of(tester.element(find.byType(ProviderPickerView)))!;
    expect(tester.takeException(), isNull);
    expect(find.byKey(_emptyResultsKey), findsOneWidget);
    expect(find.text(l10n.providerPickerEmptyResults), findsOneWidget);
  });
}
