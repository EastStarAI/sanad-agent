import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/domain/models/device_suspended_request.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/conversation_input_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/conversation_input_state.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/conversation_permission_card.dart';
import 'package:sanad_client/l10n/app_localizations.dart';

class _RecordingInputCubit extends Cubit<ConversationInputState> implements ConversationInputCubit {
  _RecordingInputCubit() : super(const ConversationInputState());

  final List<Map<String, String>> submitted = [];
  int skips = 0;
  int answers = 0;

  @override
  Future<void> submitSecretRequest({
    required DeviceSuspendedRequest request,
    required Map<String, String> values,
  }) async {
    submitted.add(Map.of(values));
  }

  @override
  Future<void> denyPendingSuspendedRequest({
    required DeviceSuspendedRequest request,
    String? comment,
  }) async {
    skips++;
  }

  @override
  Future<void> answerPendingSuspendedRequest({
    required DeviceSuspendedRequest request,
    required String answer,
  }) async {
    answers++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

DeviceSuspendedRequest _request({List<String> replaces = const []}) => DeviceSuspendedRequest.fromJson({
  'request_id': 'secret-req-1',
  'session_id': 'session-1',
  'tool_name': 'system_request_secret',
  'reason': 'Connect to the demo database',
  'fields': [
    {'name': 'DEMO_DB_PASSWORD', 'label': 'Password', 'masked': true, 'required': true},
    {'name': 'DEMO_DB_USER', 'label': 'User', 'masked': false, 'required': false},
  ],
  'replaces': replaces,
});

void main() {
  late _RecordingInputCubit cubit;

  setUp(() => cubit = _RecordingInputCubit());
  tearDown(() => cubit.close());

  Future<void> pump(WidgetTester tester, DeviceSuspendedRequest request, {Locale locale = const Locale('en')}) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: BlocProvider<ConversationInputCubit>.value(
            value: cubit,
            child: SingleChildScrollView(
              child: ConversationPermissionCard(request: request, borderColor: Colors.grey),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  TextField field(WidgetTester tester, String name) => tester.widget<TextField>(find.byKey(Key('secret_input_$name')));

  testWidgets('renders the secret form for system_request_secret with masked input', (tester) async {
    await pump(tester, _request());
    final en = lookupAppLocalizations(const Locale('en'));

    expect(find.byKey(const Key('secret_request_card')), findsOneWidget);
    expect(find.text(en.secretRequestTitle), findsOneWidget);
    expect(find.text('Connect to the demo database'), findsOneWidget);
    expect(field(tester, 'DEMO_DB_PASSWORD').obscureText, isTrue);
    expect(field(tester, 'DEMO_DB_PASSWORD').enableSuggestions, isFalse);
    expect(field(tester, 'DEMO_DB_PASSWORD').autocorrect, isFalse);
    expect(field(tester, 'DEMO_DB_USER').obscureText, isFalse);
    expect(find.byKey(const Key('secret_toggle_visibility_DEMO_DB_USER')), findsNothing);

    await tester.tap(find.byKey(const Key('secret_toggle_visibility_DEMO_DB_PASSWORD')));
    await tester.pump();
    expect(field(tester, 'DEMO_DB_PASSWORD').obscureText, isFalse);
  });

  testWidgets('a missing required value blocks submission with a localized error', (tester) async {
    await pump(tester, _request());
    await tester.enterText(find.byKey(const Key('secret_input_DEMO_DB_USER')), 'dummy-user');
    await tester.tap(find.byKey(const Key('secret_request_save_btn')));
    await tester.pump();

    expect(cubit.submitted, isEmpty);
    expect(
      find.text(lookupAppLocalizations(const Locale('en')).secretRequestRequiredField('Password')),
      findsOneWidget,
    );
  });

  testWidgets('save sends values as typed through the secret channel and clears the inputs', (tester) async {
    await pump(tester, _request());
    await tester.enterText(find.byKey(const Key('secret_input_DEMO_DB_PASSWORD')), ' dummy pass ');
    await tester.tap(find.byKey(const Key('secret_request_save_btn')));
    await tester.pump();

    expect(cubit.submitted, [
      {'DEMO_DB_PASSWORD': ' dummy pass '},
    ]);
    expect(cubit.answers, 0);
    expect(field(tester, 'DEMO_DB_PASSWORD').controller!.text, isEmpty);
    expect(find.text(' dummy pass '), findsNothing);

    await tester.tap(find.byKey(const Key('secret_request_save_btn')));
    await tester.pump();
    expect(cubit.submitted, hasLength(1));
  });

  testWidgets('skip denies without sending values', (tester) async {
    await pump(tester, _request());
    await tester.enterText(find.byKey(const Key('secret_input_DEMO_DB_PASSWORD')), 'dummy-pass');
    await tester.tap(find.byKey(const Key('secret_request_skip_btn')));
    await tester.pump();

    expect(cubit.skips, 1);
    expect(cubit.submitted, isEmpty);
    expect(field(tester, 'DEMO_DB_PASSWORD').controller!.text, isEmpty);
  });

  testWidgets('announces a replaced value and renders Arabic right-to-left', (tester) async {
    await pump(tester, _request(replaces: ['DEMO_DB_PASSWORD']), locale: const Locale('ar'));
    final ar = lookupAppLocalizations(const Locale('ar'));

    expect(find.text(ar.secretRequestTitle), findsOneWidget);
    expect(find.text(ar.secretRequestSave), findsOneWidget);
    expect(find.byKey(const Key('secret_replaces_DEMO_DB_PASSWORD')), findsOneWidget);
    expect(find.byKey(const Key('secret_replaces_DEMO_DB_USER')), findsNothing);
    expect(
      Directionality.of(tester.element(find.byKey(const Key('secret_request_card')))),
      TextDirection.rtl,
    );
  });
}
