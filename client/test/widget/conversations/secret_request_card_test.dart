import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/core/di/injection.dart';
import 'package:sanad_client/features/conversations/domain/models/device_suspended_request.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/conversation_input_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/conversation_input_state.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/conversation_permission_card.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/secret_request_card.dart';

class _TestConversationInputCubit extends Cubit<ConversationInputState> implements ConversationInputCubit {
  final List<String> approvedScopes = [];
  final List<String?> deniedComments = [];
  final List<String> answers = [];

  _TestConversationInputCubit() : super(const ConversationInputState());

  @override
  Future<void> approvePendingSuspendedRequest({
    required DeviceSuspendedRequest request,
    required String scope,
  }) async {
    approvedScopes.add(scope);
  }

  @override
  Future<void> denyPendingSuspendedRequest({
    required DeviceSuspendedRequest request,
    String? comment,
  }) async {
    deniedComments.add(comment);
  }

  @override
  Future<void> answerPendingSuspendedRequest({
    required DeviceSuspendedRequest request,
    required String answer,
  }) async {
    answers.add(answer);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _TestConversationInputCubit inputCubit;

  setUp(() async {
    await getIt.reset();
    inputCubit = _TestConversationInputCubit();
  });

  tearDown(() async {
    await inputCubit.close();
  });

  Widget createSubject(DeviceSuspendedRequest request) {
    return MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: BlocProvider<ConversationInputCubit>.value(
            value: inputCubit,
            child: ConversationPermissionCard(
              request: request,
              borderColor: Colors.blueGrey,
            ),
          ),
        ),
      ),
    );
  }

  final sampleSecretRequest = DeviceSuspendedRequest(
    requestId: 'req-secret-123',
    sessionId: 'session-123',
    toolName: 'system_request_secret',
    permissionClass: 'system',
    scope: 'once',
    workspaceId: 'ws-1',
    workspaceName: 'desktop-agent',
    workspacePath: '/repo',
    toolInput: const {
      'reason': 'Database credentials required to connect to Postgres',
      'target_vault': 'custom:postgres_creds',
      'write_to_workspace_env': '.env',
      'fields': [
        {
          'id': 'username',
          'label': 'Username',
          'description': 'Database login username',
          'is_secret': false,
          'required': true,
          'default_value': 'postgres',
        },
        {
          'id': 'db_password',
          'label': 'Password',
          'description': 'Database master password',
          'is_secret': true,
          'required': true,
        },
        {
          'id': 'token',
          'label': 'Access Token',
          'description': 'Optional extra token',
          'is_secret': true,
          'required': false,
        },
      ],
    },
    tool: const {'name': 'system_request_secret'},
  );

  testWidgets('renders SecretRequestCard with fields, reason, and vault badge', (tester) async {
    await tester.pumpWidget(createSubject(sampleSecretRequest));
    await tester.pumpAndSettle();

    expect(find.byType(SecretRequestCard), findsOneWidget);
    expect(find.text('Credentials Required'), findsOneWidget);
    expect(find.text('custom:postgres_creds'), findsOneWidget);
    expect(find.text('Database credentials required to connect to Postgres'), findsOneWidget);
    expect(find.text('Username'), findsOneWidget);
    expect(find.text('Password'), findsOneWidget);
    expect(find.text('Access Token'), findsOneWidget);
    expect(find.byKey(const Key('save_to_vault_btn')), findsOneWidget);
    expect(find.byKey(const Key('skip_secret_request_btn')), findsOneWidget);
    expect(find.byKey(const Key('dismiss_secret_request_btn')), findsOneWidget);
  });

  testWidgets('toggles secret visibility with eye button', (tester) async {
    await tester.pumpWidget(createSubject(sampleSecretRequest));
    await tester.pumpAndSettle();

    final passwordFieldFinder = find.byKey(const Key('secret_input_db_password'));
    expect(passwordFieldFinder, findsOneWidget);

    TextField passwordField = tester.widget<TextField>(passwordFieldFinder);
    expect(passwordField.obscureText, isTrue);

    // Non-secret username field is NOT obscured
    final usernameFieldFinder = find.byKey(const Key('secret_input_username'));
    final usernameField = tester.widget<TextField>(usernameFieldFinder);
    expect(usernameField.obscureText, isFalse);
    expect(find.byKey(const Key('toggle_visibility_username')), findsNothing);

    // Toggle password visibility
    final toggleFinder = find.byKey(const Key('toggle_visibility_db_password'));
    expect(toggleFinder, findsOneWidget);
    await tester.tap(toggleFinder);
    await tester.pumpAndSettle();

    passwordField = tester.widget<TextField>(passwordFieldFinder);
    expect(passwordField.obscureText, isFalse);

    // Toggle back
    await tester.tap(toggleFinder);
    await tester.pumpAndSettle();
    passwordField = tester.widget<TextField>(passwordFieldFinder);
    expect(passwordField.obscureText, isTrue);
  });

  testWidgets('validates required fields before submitting', (tester) async {
    await tester.pumpWidget(createSubject(sampleSecretRequest));
    await tester.pumpAndSettle();

    // Password is required and initially empty
    await tester.tap(find.byKey(const Key('save_to_vault_btn')));
    await tester.pumpAndSettle();

    expect(find.text('Please fill in required field: Password'), findsOneWidget);
    expect(inputCubit.answers, isEmpty);
  });

  testWidgets('submits values when required fields are filled', (tester) async {
    await tester.pumpWidget(createSubject(sampleSecretRequest));
    await tester.pumpAndSettle();

    // Enter password
    await tester.enterText(find.byKey(const Key('secret_input_db_password')), 'secret123');
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('save_to_vault_btn')));
    await tester.pumpAndSettle();

    expect(inputCubit.answers.length, 1);
    final submitted = jsonDecode(inputCubit.answers.first) as Map<String, dynamic>;
    expect(submitted['username'], 'postgres');
    expect(submitted['db_password'], 'secret123');
    expect(submitted['token'], '');
  });

  testWidgets('clicking Skip button triggers denyPendingSuspendedRequest', (tester) async {
    await tester.pumpWidget(createSubject(sampleSecretRequest));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('skip_secret_request_btn')));
    await tester.pumpAndSettle();

    expect(inputCubit.deniedComments.length, 1);
    expect(inputCubit.deniedComments.first, contains('skipped'));
  });

  testWidgets('clicking Dismiss button triggers denyPendingSuspendedRequest', (tester) async {
    await tester.pumpWidget(createSubject(sampleSecretRequest));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('dismiss_secret_request_btn')));
    await tester.pumpAndSettle();

    expect(inputCubit.deniedComments.length, 1);
  });
}
