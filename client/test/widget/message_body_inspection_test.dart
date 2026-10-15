import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/driver/ui_inspection_text.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/event_tile.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/user_message_tile.dart';

void main() {
  testWidgets('user Markdown has an event-scoped body key and plain text', (
    tester,
  ) async {
    const eventId = 'user-event-1';
    const markdown = '**User** message with `code`.';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UserMessageTile(
            event: CanonicalEvent(
              id: eventId,
              kind: EventKind.userMessage,
              text: markdown,
              timestamp: DateTime.utc(2026, 9, 22),
            ),
          ),
        ),
      ),
    );

    final finder = find.byKey(const Key('user_message_body:$eventId'));
    expect(finder, findsOneWidget);
    expect(
      firstInspectableDescendantText(tester.element(finder)),
      contains('User'),
    );
    expect(
      firstInspectableDescendantText(tester.element(finder)),
      contains('message with'),
    );
  });

  testWidgets(
    'assistant Markdown has an event-scoped body key and plain text',
    (tester) async {
      const eventId = 'assistant-event-1';
      const markdown = '## Result\n\nJEV_SANAD_GENERAL_OK';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 600,
              child: EventTile(
                event: CanonicalEvent(
                  id: eventId,
                  kind: EventKind.finalAnswer,
                  status: EventStatus.done,
                  text: markdown,
                  timestamp: DateTime.utc(2026, 9, 22),
                ),
              ),
            ),
          ),
        ),
      );

      final finder = find.byKey(const Key('assistant_message_body:$eventId'));
      expect(finder, findsOneWidget);
      final text = allInspectableDescendantText(tester.element(finder));
      expect(text, contains('Result'));
      expect(text, contains('JEV_SANAD_GENERAL_OK'));
    },
  );

  testWidgets('Text.rich and SelectableText.rich expose plain text', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Column(
          children: [
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: 'rich '),
                  TextSpan(text: 'text'),
                ],
              ),
            ),
            SelectableText.rich(
              TextSpan(
                children: [
                  TextSpan(text: 'selectable '),
                  TextSpan(text: 'text'),
                ],
              ),
            ),
          ],
        ),
      ),
    );

    expect(
      inspectableWidgetText(tester.widget<Text>(find.byType(Text).first)),
      'rich text',
    );
    expect(
      inspectableWidgetText(
        tester.widget<SelectableText>(find.byType(SelectableText)),
      ),
      'selectable text',
    );
  });
}
