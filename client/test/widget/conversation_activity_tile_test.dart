import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';
import 'package:sanad_client/features/conversations/domain/models/session_execution_snapshot.dart';
import 'package:sanad_client/features/conversations/presentation/utils/conversation_timeline_projection.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_activity_tile.dart';

void main() {
  testWidgets('debounces burst updates and keeps the confirmed row visible', (
    tester,
  ) async {
    var displayedCount = 0;
    final reasoning = ConversationActivity.reasoning(
      _event(
        id: 'reasoning',
        kind: EventKind.reasoning,
        text: 'checking the next action carefully',
      ),
    );

    await tester.pumpWidget(
      _app(reasoning, onDisplayed: () => displayedCount++),
    );
    expect(find.textContaining('Thinking:'), findsNothing);

    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.textContaining('Thinking:'), findsOneWidget);
    expect(displayedCount, 1);

    await tester.pumpWidget(
      _app(
        ConversationActivity.runningTool(
          _tool('tool-1', 'first command'),
        ),
        onDisplayed: () => displayedCount++,
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpWidget(
      _app(
        ConversationActivity.runningTool(
          _tool('tool-2', 'latest command'),
        ),
        onDisplayed: () => displayedCount++,
      ),
    );

    expect(find.textContaining('Thinking:'), findsOneWidget);
    expect(find.textContaining('first command'), findsNothing);
    expect(find.textContaining('latest command'), findsNothing);

    await tester.pump(const Duration(milliseconds: 999));
    expect(find.textContaining('Thinking:'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();

    expect(find.textContaining('Thinking:'), findsNothing);
    expect(find.textContaining('first command'), findsNothing);
    expect(find.textContaining('latest command'), findsOneWidget);
    expect(displayedCount, 2);
    expect(
      find.descendant(
        of: find.byType(ConversationActivityTile),
        matching: find.byType(SlideTransition),
      ),
      findsNothing,
    );
  });

  testWidgets('uses Working for the generic active gap', (tester) async {
    await tester.pumpWidget(
      _app(const ConversationActivity.thinking()),
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();

    expect(find.text('Working…'), findsOneWidget);
    expect(find.text('Thinking…'), findsNothing);
  });

  testWidgets('renders and advances a sub-hour authoritative baseline', (
    tester,
  ) async {
    var now = DateTime.utc(2026, 8, 16, 10);
    await tester.pumpWidget(
      _app(
        const ConversationActivity.thinking(),
        executionSnapshot: _executionSnapshot(
          elapsed: const Duration(minutes: 1, seconds: 25),
          receivedAt: now,
        ),
        now: () => now,
      ),
    );
    now = now.add(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();

    expect(find.text('Working for 1m, 26s'), findsOneWidget);
    final elapsedFinder = find.byKey(
      const Key('conversation_activity_elapsed'),
    );
    expect(elapsedFinder, findsOneWidget);
    final elapsedText = tester.widget<Text>(elapsedFinder);
    expect(
      elapsedText.style?.fontFeatures?.single.feature,
      'tnum',
    );
  });

  testWidgets('shows hours and minutes without ticking visible seconds', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        const ConversationActivity.thinking(),
        executionSnapshot: _executionSnapshot(
          elapsed: const Duration(hours: 1, minutes: 35),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();

    expect(find.text('Working for 1h, 35m'), findsOneWidget);
  });
}

Widget _app(
  ConversationActivity activity, {
  SessionExecutionSnapshot? executionSnapshot,
  DateTime Function()? now,
  VoidCallback? onDisplayed,
}) => MaterialApp(
  home: Scaffold(
    body: ConversationActivityTile(
      activity: activity,
      executionSnapshot: executionSnapshot,
      now: now,
      onDisplayed: onDisplayed,
    ),
  ),
);

SessionExecutionSnapshot _executionSnapshot({
  required Duration elapsed,
  DateTime? receivedAt,
}) {
  receivedAt ??= DateTime.now().toUtc();
  return SessionExecutionSnapshot(
    sessionId: 'session-a',
    state: SessionExecutionState.running,
    workItemId: 'work-a',
    requestId: 'request-a',
    revision: 1,
    updatedAt: receivedAt,
    turnStartedAt: receivedAt.subtract(elapsed),
    elapsedMs: elapsed.inMilliseconds,
    baselineReceivedAt: receivedAt,
  );
}

CanonicalEvent _tool(String id, String command) => CanonicalEvent(
  id: id,
  kind: EventKind.toolCall,
  status: EventStatus.running,
  tool: {
    'name': 'shell_execute',
    'input': {'command': command},
  },
  timestamp: DateTime.utc(2026, 8, 16),
);

CanonicalEvent _event({
  required String id,
  required EventKind kind,
  required String text,
}) => CanonicalEvent(
  id: id,
  kind: kind,
  status: EventStatus.running,
  text: text,
  timestamp: DateTime.utc(2026, 8, 16),
);
