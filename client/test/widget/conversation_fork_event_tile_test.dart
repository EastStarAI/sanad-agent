import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/data/mappers/unified_device_mapper.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/event_tile.dart';
import 'package:sanad_client/shared/widgets/copy_button.dart';
import 'package:sanad_client/utils/app_platform.dart';

void main() {
  setUp(() => AppPlatform.overrideIsMobile = null);
  tearDown(() => AppPlatform.overrideIsMobile = null);

  CanonicalEvent answer({
    required String id,
    required String messageId,
    required String turnId,
  }) {
    return CanonicalEvent(
      id: id,
      kind: EventKind.finalAnswer,
      status: EventStatus.done,
      text: 'answer $id',
      timestamp: DateTime.utc(2026, 8, 30),
      metadata: {'message_id': messageId, 'turn_id': turnId},
    );
  }

  testWidgets('every eligible final answer exposes Fork', (tester) async {
    final first = answer(id: 'a1', messageId: 'm-1', turnId: 't-1');
    final second = answer(id: 'a2', messageId: 'm-2', turnId: 't-2');
    final forked = <String>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 600,
              child: Column(
                children: [
                  EventTile(
                    event: first,
                    canFork: first.isForkableFinalAnswer,
                    onFork: () async => forked.add(first.id),
                  ),
                  EventTile(
                    event: second,
                    canFork: second.isForkableFinalAnswer,
                    onFork: () async => forked.add(second.id),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.byKey(const Key('fork_conversation_button')), findsNWidgets(2));
    expect(
      find.descendant(
        of: find.byKey(const Key('fork_conversation_button')),
        matching: find.byIcon(Icons.account_tree_outlined),
      ),
      findsNWidgets(2),
    );
    expect(find.text('Fork'), findsNothing);

    final forkFinder = find.byKey(const Key('fork_conversation_button')).first;
    final forkButton = tester.widget<IconButton>(forkFinder);
    final copyButton = tester.widget<IconButton>(
      find.descendant(
        of: find.byType(CopyButton).first,
        matching: find.byType(IconButton),
      ),
    );
    final forkIcon = tester.widget<Icon>(
      find.descendant(
        of: forkFinder,
        matching: find.byIcon(Icons.account_tree_outlined),
      ),
    );
    final expectedColor =
        Theme.of(
          tester.element(forkFinder),
        ).colorScheme.onSurfaceVariant.withValues(
          alpha: ConversationActionStyle.iconAlpha,
        );
    expect(forkButton.constraints, ConversationActionStyle.constraints);
    expect(copyButton.constraints, ConversationActionStyle.constraints);
    expect(forkIcon.size, ConversationActionStyle.iconSize);
    expect(forkIcon.color, expectedColor);

    await tester.tap(forkFinder);
    await tester.tap(find.byKey(const Key('fork_conversation_button')).last);
    await tester.pump();
    expect(forked, ['a1', 'a2']);
  });

  testWidgets('in-flight Fork ignores a second press', (tester) async {
    var presses = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 600,
              child: EventTile(
                event: answer(id: 'a1', messageId: 'm-1', turnId: 't-1'),
                canFork: true,
                isForkPending: true,
                onFork: () async => presses++,
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('fork_conversation_button')));
    await tester.pump();
    expect(presses, 0);
  });

  testWidgets('history-only fork event uses the compaction marker layout', (
    tester,
  ) async {
    final event = UnifiedDeviceMapper().mapHistory([
      {
        'id': 'fork_child-1',
        'event_id': 'fork_child-1',
        'type': 'session.forked',
        'content': 'Conversation forked',
        'session_id': 'child-1',
        'created_at': '2026-08-31T12:00:00Z',
        'metadata': {
          'informational_kind': 'session_fork',
          'fork_sequence': 1,
        },
      },
    ]).single;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(width: 600, child: EventTile(event: event)),
        ),
      ),
    );

    expect(find.byKey(const Key('conversation-fork-event')), findsOneWidget);
    expect(find.text('Conversation forked'), findsOneWidget);
    expect(find.byIcon(Icons.account_tree_outlined), findsOneWidget);
    expect(find.byType(Divider), findsNWidgets(2));

    await tester.tap(find.byKey(const Key('conversation-fork-event')));
    await tester.pump();
    expect(
      find.text('Fork 1\nThis conversation continues independently.'),
      findsOneWidget,
    );
  });

  testWidgets('user messages do not expose Fork', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EventTile(
            event: CanonicalEvent(
              id: 'u1',
              kind: EventKind.userMessage,
              text: 'hello',
              timestamp: DateTime.utc(2026, 8, 30),
              metadata: const {
                'request_id': 'req-1',
                'message_id': 'm-u',
                'turn_id': 't-1',
              },
            ),
            canReplay: true,
          ),
        ),
      ),
    );

    expect(find.byKey(const Key('fork_conversation_button')), findsNothing);
  });

  testWidgets('steer-superseded thoughts do not expose Fork', (tester) async {
    final event = CanonicalEvent(
      id: 'thought-1',
      kind: EventKind.finalAnswer,
      status: EventStatus.done,
      text: 'pre-steer thought',
      timestamp: DateTime.utc(2026, 8, 30),
      metadata: const {
        'message_id': 'm-thought',
        'turn_id': 't-1',
        'superseded_by_steer': true,
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 600,
              child: EventTile(event: event, canFork: event.isForkableFinalAnswer),
            ),
          ),
        ),
      ),
    );

    expect(find.byKey(const Key('fork_conversation_button')), findsNothing);
  });

  testWidgets('superseded final answers do not expose Fork', (tester) async {
    final event = CanonicalEvent(
      id: 'a1',
      kind: EventKind.finalAnswer,
      status: EventStatus.done,
      text: 'old',
      timestamp: DateTime.utc(2026, 8, 30),
      metadata: const {
        'message_id': 'm-1',
        'turn_id': 't-1',
        'history_status': 'superseded',
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 600,
              child: EventTile(event: event, canFork: event.isForkableFinalAnswer),
            ),
          ),
        ),
      ),
    );

    expect(find.byKey(const Key('fork_conversation_button')), findsNothing);
  });
}
