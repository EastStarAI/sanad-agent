import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:sanad_client/core/di/injection.dart';
import 'package:sanad_client/features/conversations/domain/models/device_suspended_request.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/conversation_permission_card.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/conversation_input_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/conversation_input_state.dart';
import 'package:sanad_client/utils/app_platform.dart';

class _TestConversationInputCubit extends Cubit<ConversationInputState> implements ConversationInputCubit {
  @override
  void reportRouteThinkingAdmission({
    required String? providerId,
    required String? modelId,
    required bool admitsSelection,
  }) {}

  final List<String> approvedScopes = [];
  final List<String?> deniedComments = [];
  final List<String> answers = [];

  _TestConversationInputCubit()
    : super(
        const ConversationInputState(),
      );

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
    AppPlatform.overrideIsMobile = null;
    await getIt.reset();
    inputCubit = _TestConversationInputCubit();
  });

  tearDown(() async {
    AppPlatform.overrideIsMobile = null;
    await inputCubit.close();
  });

  testWidgets('pressing digit keys triggers the correct clarifying question answer', (tester) async {
    final request = DeviceSuspendedRequest(
      requestId: 'question-1',
      sessionId: 'session-1',
      toolName: 'system_ask_user',
      permissionClass: 'clarification',
      scope: 'session',
      workspaceId: 'workspace-1',
      workspaceName: 'desktop-agent',
      workspacePath: '/repo',
      toolInput: const {
        'questions': [
          {
            'question': 'Pick a speed',
            'options': ['Fast', 'Slow'],
          },
        ],
      },
      tool: const {'name': 'system_ask_user'},
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BlocProvider<ConversationInputCubit>.value(
            value: inputCubit,
            child: ConversationPermissionCard(
              request: request,
              borderColor: Colors.grey,
            ),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    // Verify option text shows digit prefixes on desktop/tester mode
    expect(find.text('1  Fast'), findsOneWidget);
    expect(find.text('2  Slow'), findsOneWidget);

    // Simulate pressing English digit '1'
    await tester.sendKeyEvent(LogicalKeyboardKey.digit1, character: '1');
    await tester.pumpAndSettle();

    expect(inputCubit.answers.length, 1);
    expect(inputCubit.answers.first, contains('Fast'));
  });

  testWidgets('Enter submits a custom clarifying answer', (tester) async {
    final request = _customAnswerRequest();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BlocProvider<ConversationInputCubit>.value(
            value: inputCubit,
            child: ConversationPermissionCard(
              request: request,
              borderColor: Colors.grey,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('clarifying_question_input')), 'Custom answer');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(inputCubit.answers, hasLength(1));
    expect(inputCubit.answers.single, contains('Custom answer'));
  });

  testWidgets('Shift+Enter inserts a custom clarifying answer line break', (tester) async {
    final request = _customAnswerRequest();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BlocProvider<ConversationInputCubit>.value(
            value: inputCubit,
            child: ConversationPermissionCard(
              request: request,
              borderColor: Colors.grey,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('clarifying_question_input')), 'First line');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();

    expect(inputCubit.answers, isEmpty);
    final input = tester.widget<TextField>(find.byKey(const Key('clarifying_question_input')));
    expect(input.controller?.text, 'First line\n');
  });

  testWidgets('mobile Enter keeps a custom answer open for multiline input', (tester) async {
    AppPlatform.overrideIsMobile = true;
    final request = _customAnswerRequest();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BlocProvider<ConversationInputCubit>.value(
            value: inputCubit,
            child: ConversationPermissionCard(
              request: request,
              borderColor: Colors.grey,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final inputFinder = find.byKey(const Key('clarifying_question_input'));
    await tester.enterText(inputFinder, 'first line');
    await tester.tap(inputFinder);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.enterText(inputFinder, 'first line\nsecond line');
    await tester.pump();

    final input = tester.widget<TextField>(inputFinder);
    expect(input.keyboardType, TextInputType.multiline);
    expect(input.textInputAction, TextInputAction.newline);
    expect(input.controller?.text, 'first line\nsecond line');
    expect(inputCubit.answers, isEmpty);
  });

  testWidgets('pressing Arabic digit keys triggers the correct permission response', (tester) async {
    final request = DeviceSuspendedRequest(
      requestId: 'permission-1',
      sessionId: 'session-1',
      toolName: 'execute_command',
      permissionClass: 'command',
      scope: 'once',
      workspaceId: 'workspace-1',
      workspaceName: 'desktop-agent',
      workspacePath: '/repo',
      toolInput: const {
        'command': 'git commit -m "feat: done"',
      },
      tool: const {'name': 'execute_command'},
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BlocProvider<ConversationInputCubit>.value(
            value: inputCubit,
            child: ConversationPermissionCard(
              request: request,
              borderColor: Colors.grey,
            ),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('1  Yes, allow this time'), findsOneWidget);
    expect(find.text('2  Yes, allow for this session'), findsOneWidget);

    // Simulate pressing Arabic digit '٢' (meaning Option 2: Yes, allow for this session)
    await tester.sendKeyEvent(LogicalKeyboardKey.digit2, character: '٢');
    await tester.pumpAndSettle();

    expect(inputCubit.approvedScopes.length, 1);
    expect(inputCubit.approvedScopes.first, 'session');
  });
}

DeviceSuspendedRequest _customAnswerRequest() {
  return const DeviceSuspendedRequest(
    requestId: 'custom-question-1',
    sessionId: 'session-1',
    toolName: 'system_ask_user',
    permissionClass: 'clarification',
    scope: 'session',
    workspaceId: 'workspace-1',
    workspaceName: 'desktop-agent',
    workspacePath: '/repo',
    toolInput: {
      'questions': [
        {
          'question': 'Add details',
          'options': <String>[],
        },
      ],
    },
    tool: {'name': 'system_ask_user'},
  );
}
