import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/event_tile.dart';

void main() {
  testWidgets('permission suspension replaces the running spinner with a shield', (
    tester,
  ) async {
    await pumpEvent(
      tester,
      toolName: 'mcp__context7__resolve-library-id',
      waitingIndicator: ToolWaitingIndicator.permission,
    );

    expect(find.byKey(const Key('tool_waiting_permission_icon')), findsOneWidget);
    expect(find.byKey(const Key('tool_running_progress_indicator')), findsNothing);
  });

  testWidgets('clarifying question replaces the running state with a question icon', (
    tester,
  ) async {
    await pumpEvent(
      tester,
      toolName: 'system_ask_user',
      waitingIndicator: ToolWaitingIndicator.question,
    );

    expect(find.byKey(const Key('tool_waiting_question_icon')), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('ordinary running tools retain the progress indicator', (tester) async {
    await pumpEvent(
      tester,
      toolName: 'web_search',
      waitingIndicator: ToolWaitingIndicator.none,
    );

    expect(find.byKey(const Key('tool_running_progress_indicator')), findsOneWidget);
    expect(find.byKey(const Key('tool_waiting_permission_icon')), findsNothing);
  });
}

Future<void> pumpEvent(
  WidgetTester tester, {
  required String toolName,
  required ToolWaitingIndicator waitingIndicator,
}) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: EventTile(
          event: CanonicalEvent(
            id: 'tool-event',
            kind: EventKind.toolCall,
            timestamp: DateTime(2026),
            status: EventStatus.running,
            tool: {
              'name': toolName,
              'input': const {'query': 'test'},
            },
          ),
          waitingIndicator: waitingIndicator,
        ),
      ),
    ),
  );
}
