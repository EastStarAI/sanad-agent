import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/event_tile.dart';
import 'package:sanad_client/utils/app_platform.dart';

void main() {
  setUp(() => AppPlatform.overrideIsMobile = null);
  tearDown(() => AppPlatform.overrideIsMobile = null);

  final event = CanonicalEvent(
    id: 'user-request-1',
    kind: EventKind.userMessage,
    text: 'original message',
    timestamp: DateTime.utc(2026, 7, 18),
    metadata: const {'request_id': 'request-1'},
  );

  testWidgets('eligible user message exposes edit and retry actions', (
    tester,
  ) async {
    var editPressed = false;
    var retryPressed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EventTile(
            event: event,
            canReplay: true,
            onBeginEdit: () => editPressed = true,
            onRetry: () async => retryPressed = true,
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('Edit message'));
    await tester.tap(find.byTooltip('Retry message'));
    await tester.pump();

    expect(editPressed, isTrue);
    expect(retryPressed, isTrue);
  });

  testWidgets('steer bubbles do not expose edit or retry', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EventTile(
            event: CanonicalEvent(
              id: 'steer-1',
              kind: EventKind.userMessage,
              text: 'nudge',
              timestamp: DateTime.utc(2026, 7, 18),
              metadata: const {
                'request_id': 'steer-1',
                'input_kind': 'steer',
                'steer': true,
              },
            ),
          ),
        ),
      ),
    );

    expect(find.byTooltip('Edit message'), findsNothing);
    expect(find.byTooltip('Retry message'), findsNothing);
  });

  testWidgets('inline editor renders Send and Cancel below the input', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'edited message');
    addTearDown(controller.dispose);
    var sent = false;
    var cancelled = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EventTile(
            event: event,
            canReplay: true,
            isEditing: true,
            editController: controller,
            onSubmitEdit: () async => sent = true,
            onCancelEdit: () => cancelled = true,
          ),
        ),
      ),
    );

    expect(find.byKey(const Key('inline_message_editor')), findsOneWidget);
    expect(find.text('Send'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);

    await tester.tap(find.text('Send'));
    await tester.tap(find.text('Cancel'));
    await tester.pump();

    expect(sent, isTrue);
    expect(cancelled, isTrue);
  });

  testWidgets('desktop inline editor submits with Enter and adds a line with Shift+Enter', (tester) async {
    final controller = TextEditingController(text: 'first line');
    controller.selection = TextSelection.collapsed(offset: controller.text.length);
    addTearDown(controller.dispose);
    var submissions = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EventTile(
            event: event,
            canReplay: true,
            isEditing: true,
            editController: controller,
            onSubmitEdit: () async => submissions += 1,
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();

    expect(controller.text, 'first line\n');
    expect(submissions, 0);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(submissions, 1);
  });

  testWidgets('mobile inline editor Enter stays multiline without submitting', (tester) async {
    AppPlatform.overrideIsMobile = true;
    final controller = TextEditingController(text: 'first line');
    addTearDown(controller.dispose);
    var submissions = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EventTile(
            event: event,
            canReplay: true,
            isEditing: true,
            editController: controller,
            onSubmitEdit: () async => submissions += 1,
          ),
        ),
      ),
    );
    await tester.pump();

    final inputFinder = find.byKey(const Key('inline_message_editor'));
    await tester.tap(inputFinder);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.enterText(inputFinder, 'first line\nsecond line');
    await tester.pump();

    final input = tester.widget<TextField>(inputFinder);
    expect(input.keyboardType, TextInputType.multiline);
    expect(input.textInputAction, TextInputAction.newline);
    expect(controller.text, 'first line\nsecond line');
    expect(submissions, 0);
  });
}
