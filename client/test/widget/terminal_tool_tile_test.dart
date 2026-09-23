import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';
import 'package:sanad_client/features/conversations/presentation/utils/conversation_clock_scope.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/event_tile.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/tools/terminal_tool_tile.dart';

void main() {
  testWidgets('displays static runtime duration in tool header when completed without decimal seconds', (tester) async {
    final event = CanonicalEvent(
      id: 'tool-completed-1',
      kind: EventKind.toolCall,
      status: EventStatus.done,
      text: '',
      timestamp: DateTime(2026, 1, 1, 12, 0, 0),
      runtimeMs: 1450,
      tool: {
        'name': 'shell_execute',
        'input': jsonEncode({'command': 'ls -la', 'description': 'List directory contents'}),
        'output': 'file1.txt\nfile2.txt',
      },
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EventTile(event: event),
        ),
      ),
    );

    expect(find.byKey(const Key('tool_header_runtime')), findsOneWidget);
    // 1450ms rounds to 1s without fractions
    expect(find.text('1s'), findsOneWidget);
    // Terminal body itself does not contain duplicate runtime
    expect(find.byKey(const Key('terminal_tool_runtime')), findsNothing);
  });

  testWidgets('displays subsecond decimal for fast tool under 1 second', (tester) async {
    final event = CanonicalEvent(
      id: 'tool-completed-fast',
      kind: EventKind.toolCall,
      status: EventStatus.done,
      text: '',
      timestamp: DateTime(2026, 1, 1, 12, 0, 0),
      runtimeMs: 400,
      tool: {
        'name': 'shell_execute',
        'input': jsonEncode({'command': 'echo hi', 'description': 'Fast echo'}),
        'output': 'hi',
      },
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EventTile(event: event),
        ),
      ),
    );

    expect(find.byKey(const Key('tool_header_runtime')), findsOneWidget);
    expect(find.text('0.4s'), findsOneWidget);
  });

  testWidgets('displays and updates running timer in tool header via ConversationClockScope without decimals', (tester) async {
    final startTime = DateTime(2026, 1, 1, 12, 0, 0);
    final clockNotifier = ValueNotifier<DateTime>(startTime.add(const Duration(seconds: 3)));

    final event = CanonicalEvent(
      id: 'tool-running-1',
      kind: EventKind.toolCall,
      status: EventStatus.running,
      text: '',
      timestamp: startTime,
      tool: {
        'name': 'shell_execute',
        'input': {'command': 'sleep 10', 'description': 'Running sleep'},
      },
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ConversationClockScope(
            clock: clockNotifier,
            child: EventTile(event: event),
          ),
        ),
      ),
    );

    expect(find.byKey(const Key('tool_header_timer')), findsOneWidget);
    expect(find.text('3s'), findsOneWidget);

    // Advance the central clock
    clockNotifier.value = startTime.add(const Duration(seconds: 8));
    await tester.pump();

    expect(find.text('8s'), findsOneWidget);
  });

  testWidgets('TerminalToolTile renders command and output cleanly', (tester) async {
    final event = CanonicalEvent(
      id: 'tool-clean-1',
      kind: EventKind.toolCall,
      status: EventStatus.done,
      text: '',
      timestamp: DateTime(2026, 1, 1, 12, 0, 0),
      tool: {
        'name': 'shell_execute',
        'input': {'command': 'pwd'},
        'output': '/workspace',
      },
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalToolTile(event: event),
        ),
      ),
    );

    expect(find.text('pwd'), findsOneWidget);
    expect(find.text('/workspace'), findsOneWidget);
  });
}
