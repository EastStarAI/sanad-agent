import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';
import 'package:sanad_client/features/conversations/presentation/utils/conversation_timeline_projection.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/event_tile.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/tools/terminal_tool_tile.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/tools/tool_group_tile.dart';

void main() {
  testWidgets('completed ask-user renders content without generic tool header', (
    tester,
  ) async {
    final event = CanonicalEvent(
      id: 'ask-complete',
      kind: EventKind.toolCall,
      status: EventStatus.done,
      tool: {
        'name': 'system_ask_user',
        'input': {
          'questions': [
            {'question': 'Choose one'},
          ],
        },
        'output': jsonEncode([
          {'question': 'Choose one', 'answer': 'First'},
        ]),
      },
      timestamp: DateTime.utc(2026, 8, 14),
    );

    await tester.pumpWidget(_app(EventTile(event: event)));

    expect(find.text('Choose one'), findsOneWidget);
    expect(find.text('First'), findsOneWidget);
    expect(find.textContaining('Ask:'), findsNothing);
  });

  testWidgets('running ask-user renders no timeline chrome', (tester) async {
    final event = _tool(
      'ask-running',
      'system_ask_user',
      status: EventStatus.running,
    );

    await tester.pumpWidget(_app(EventTile(event: event)));

    expect(find.textContaining('Ask'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('terminal result without input unwraps output in terminal tile', (
    tester,
  ) async {
    final event = _tool(
      'terminal-result-first',
      'shell_execute',
      output: jsonEncode({
        'isError': false,
        'output': '153 104.0 180.0\n/tmp/result.jsonl\n',
      }),
    );

    await tester.pumpWidget(
      _app(EventTile(event: event, isExpanded: true)),
    );

    expect(find.byType(TerminalToolTile), findsOneWidget);
    expect(
      find.text('153 104.0 180.0\n/tmp/result.jsonl\n'),
      findsOneWidget,
    );
    expect(find.text('Output Result'), findsNothing);
    expect(find.textContaining('"isError"'), findsNothing);
  });

  testWidgets('group reuses tool styling and caps its independent scroll body', (
    tester,
  ) async {
    final item = projectConversationTimeline([
      _tool(
        'terminal-1',
        'shell_execute',
        output: List.generate(80, (index) => 'first $index').join('\n'),
      ),
      _tool(
        'terminal-2',
        'shell_execute',
        output: List.generate(80, (index) => 'second $index').join('\n'),
      ),
      for (var index = 3; index <= 20; index++) _tool('terminal-$index', 'shell_execute', output: 'done'),
    ]).single;

    await tester.pumpWidget(_toolGroupApp(item));

    expect(find.text('20 terminal runs'), findsOneWidget);
    expect(
      tester.widget<Text>(find.text('20 terminal runs')).style?.fontWeight,
      FontWeight.normal,
    );
    final titleRect = tester.getRect(find.text('20 terminal runs'));
    final chevronRect = tester.getRect(
      find.byKey(const Key('tool_group_chevron_terminal-1')),
    );
    expect(chevronRect.left - titleRect.right, lessThanOrEqualTo(8));
    expect(find.textContaining('Tool uses:'), findsNothing);
    expect(find.textContaining('first 79'), findsNothing);
    expect(find.byKey(const Key('tool_group_body_terminal-1')), findsNothing);

    await tester.tap(find.byKey(const Key('tool_group_header_terminal-1')));
    await tester.pumpAndSettle();

    expect(find.text('20 terminal runs'), findsOneWidget);
    expect(find.textContaining('first 79'), findsNothing);
    final body = find.byKey(const Key('tool_group_body_terminal-1'));
    expect(body, findsOneWidget);
    final contentPadding = tester.widget<Padding>(
      find.byKey(const Key('tool_group_content_padding_terminal-1')),
    );
    expect(
      contentPadding.padding,
      const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
    );
    final scrollFinder = find.byKey(
      const Key('tool_group_scroll_terminal-1'),
    );
    expect(tester.getSize(scrollFinder).height, lessThanOrEqualTo(500));

    final scrollView = tester.widget<SingleChildScrollView>(scrollFinder);
    expect(scrollView.controller, isNotNull);
    expect(scrollView.controller!.position.maxScrollExtent, greaterThan(0));
    expect(
      scrollView.controller!.offset,
      moreOrLessEquals(
        scrollView.controller!.position.maxScrollExtent,
        epsilon: 1,
      ),
    );
  });

  testWidgets('group and child expansion survive parent rebuilds', (tester) async {
    final item = projectConversationTimeline([
      _tool('terminal-a', 'shell_execute', output: 'first output'),
      _tool('terminal-b', 'shell_execute', output: 'second output'),
    ]).single;

    await tester.pumpWidget(_toolGroupApp(item));
    await tester.tap(find.byKey(const Key('tool_group_header_terminal-a')));
    await tester.pumpAndSettle();

    final firstChildHeader = find.descendant(
      of: find.byType(EventTile).first,
      matching: find.byType(InkWell),
    );
    await tester.tap(firstChildHeader);
    await tester.pumpAndSettle();
    expect(find.text('first output'), findsOneWidget);

    await tester.pumpWidget(_toolGroupApp(item));
    await tester.pump();
    expect(find.byKey(const Key('tool_group_body_terminal-a')), findsOneWidget);
    expect(find.text('first output'), findsOneWidget);
    expect(find.text('second output'), findsNothing);
  });

  testWidgets('group follow disables away from bottom and restores on return', (
    tester,
  ) async {
    ConversationTimelineItem itemWith(int count) => projectConversationTimeline([
      for (var index = 0; index < count; index++)
        _tool(
          'terminal-$index',
          'shell_execute',
          output: List.generate(
            50,
            (line) => 'tool $index line $line',
          ).join('\n'),
        ),
    ]).single;

    await tester.pumpWidget(_toolGroupApp(itemWith(20)));
    await tester.tap(find.byKey(const Key('tool_group_header_terminal-0')));
    await tester.pumpAndSettle();

    SingleChildScrollView scrollView() => tester.widget(
      find.byKey(const Key('tool_group_scroll_terminal-0')),
    );

    final scrollFinder = find.byKey(
      const Key('tool_group_scroll_terminal-0'),
    );
    final controller = scrollView().controller!;
    final notificationContext = scrollFinder.evaluate().single;
    UserScrollNotification(
      metrics: controller.position,
      context: notificationContext,
      direction: ScrollDirection.forward,
    ).dispatch(notificationContext);
    controller.jumpTo(controller.position.maxScrollExtent / 2);
    ScrollEndNotification(
      metrics: controller.position,
      context: notificationContext,
    ).dispatch(notificationContext);
    await tester.pump();
    final manualOffset = controller.offset;
    expect(manualOffset, lessThan(controller.position.maxScrollExtent));

    await tester.pumpWidget(_toolGroupApp(itemWith(21)));
    await tester.pumpAndSettle();
    expect(
      scrollView().controller!.offset,
      moreOrLessEquals(manualOffset, epsilon: 1),
    );

    UserScrollNotification(
      metrics: controller.position,
      context: notificationContext,
      direction: ScrollDirection.reverse,
    ).dispatch(notificationContext);
    controller.jumpTo(controller.position.maxScrollExtent);
    ScrollEndNotification(
      metrics: controller.position,
      context: notificationContext,
    ).dispatch(notificationContext);
    await tester.pump();
    expect(
      controller.offset,
      moreOrLessEquals(controller.position.maxScrollExtent, epsilon: 1),
    );

    await tester.pumpWidget(_toolGroupApp(itemWith(22)));
    await tester.pumpAndSettle();
    expect(
      scrollView().controller!.offset,
      moreOrLessEquals(
        scrollView().controller!.position.maxScrollExtent,
        epsilon: 1,
      ),
    );
  });

  testWidgets('terminal header reflects running and completed status', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        EventTile(
          event: _tool(
            'terminal-running',
            'shell_execute',
            status: EventStatus.running,
            input: const {'command': 'pwd'},
          ),
        ),
      ),
    );

    expect(find.text('Running: pwd', findRichText: true), findsOneWidget);
    expect(find.text('Ran: pwd', findRichText: true), findsNothing);

    await tester.pumpWidget(
      _app(
        EventTile(
          event: _tool(
            'terminal-done',
            'shell_execute',
            input: const {'command': 'pwd'},
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Running: pwd', findRichText: true), findsNothing);
    expect(find.text('Ran: pwd', findRichText: true), findsOneWidget);
  });

  testWidgets('cancelled tool shows terminal state without a spinner', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        EventTile(
          event: _tool(
            'search-cancelled',
            'web_search',
            status: EventStatus.cancelled,
            input: const {'query': 'Sanad'},
            output: 'Command cancelled by user.',
          ),
        ),
      ),
    );

    expect(
      find.text('Cancelled: "Sanad"', findRichText: true),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('tool_running_progress_indicator')),
      findsNothing,
    );
    expect(find.byIcon(Icons.cancel_outlined), findsOneWidget);
  });

  testWidgets('modified file and line impact wrap as one unit', (
    tester,
  ) async {
    final item = projectConversationTimeline([
      _tool(
        'read-1',
        'file_read',
        input: const {'path': 'lib/a.dart'},
      ),
      _tool(
        'edit-1',
        'file_edit',
        input: const {
          'path': 'lib/b.dart',
          'old_string': 'old',
          'new_string': 'new',
        },
      ),
    ]).single;

    await tester.pumpWidget(_toolGroupApp(item, width: 360));
    await tester.pumpAndSettle();

    final exploreTop = tester.getTopLeft(find.text('1 file explore')).dy;
    final modifiedTop = tester.getTopLeft(find.text('1 file modified')).dy;
    final addedTop = tester.getTopLeft(find.text('+1')).dy;
    final removedTop = tester.getTopLeft(find.text('-1')).dy;

    expect(modifiedTop, greaterThan(exploreTop));
    expect(addedTop, modifiedTop);
    expect(removedTop, modifiedTop);
  });

  testWidgets('group title animates cached file and line metrics', (
    tester,
  ) async {
    final firstItem = projectConversationTimeline([
      _tool(
        'read-1',
        'file_read',
        input: const {'path': 'lib/a.dart'},
      ),
      _tool(
        'edit-1',
        'file_edit',
        input: const {
          'path': 'lib/b.dart',
          'old_string': 'old',
          'new_string': 'new',
        },
      ),
    ]).single;

    await tester.pumpWidget(_toolGroupApp(firstItem));
    await tester.pumpAndSettle();
    expect(find.text('1 file explore'), findsOneWidget);
    expect(find.text('1 file modified'), findsOneWidget);
    expect(find.textContaining('Tool uses:'), findsNothing);
    expect(find.text('+1'), findsOneWidget);
    expect(find.text('-1'), findsOneWidget);
    expect(
      tester.widget<Text>(find.text('+1')).style?.fontWeight,
      FontWeight.normal,
    );
    expect(
      tester.widget<Text>(find.text('-1')).style?.fontWeight,
      FontWeight.normal,
    );

    final updatedItem = projectConversationTimeline([
      ...firstItem.events,
      _tool(
        'edit-2',
        'file_edit',
        input: const {
          'path': 'lib/b.dart',
          'old_string': 'one\ntwo',
          'new_string': 'one\ntwo\nthree',
        },
      ),
    ]).single;
    await tester.pumpWidget(_toolGroupApp(updatedItem));
    await tester.pump(const Duration(milliseconds: 10));

    expect(find.text('+4'), findsNothing);
    await tester.pumpAndSettle();
    expect(find.text('+4'), findsOneWidget);
    expect(find.text('-3'), findsOneWidget);
    expect(find.text('1 file modified'), findsOneWidget);
  });
}

Widget _app(Widget child, {double width = 800}) => MaterialApp(
  home: Scaffold(
    body: SizedBox(width: width, height: 700, child: child),
  ),
);
Widget _toolGroupApp(ConversationTimelineItem item, {double width = 800}) =>
    _app(_ToolGroupHarness(item: item), width: width);

class _ToolGroupHarness extends StatefulWidget {
  const _ToolGroupHarness({required this.item});

  final ConversationTimelineItem item;

  @override
  State<_ToolGroupHarness> createState() => _ToolGroupHarnessState();
}

class _ToolGroupHarnessState extends State<_ToolGroupHarness> {
  bool _isExpanded = false;
  final Set<String> _expandedChildren = {};

  @override
  Widget build(BuildContext context) {
    return ToolGroupTile(
      item: widget.item,
      isExpanded: _isExpanded,
      onToggleExpanded: (expanded) => setState(() => _isExpanded = expanded),
      expandedChildEventIds: _expandedChildren,
      onChildToggleExpanded: (eventId, expanded) {
        if (expanded) {
          _expandedChildren.add(eventId);
        } else {
          _expandedChildren.remove(eventId);
        }
      },
    );
  }
}

CanonicalEvent _tool(
  String id,
  String name, {
  EventStatus status = EventStatus.done,
  Map<String, dynamic>? input,
  Object? output,
}) => CanonicalEvent(
  id: id,
  kind: EventKind.toolCall,
  status: status,
  tool: {
    'name': name,
    if (input != null) 'input': input,
    if (output != null) 'output': output,
  },
  timestamp: DateTime.utc(2026, 8, 14),
);
