import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';
import 'package:sanad_client/features/conversations/domain/models/device_suspended_request.dart';
import 'package:sanad_client/features/conversations/presentation/utils/text_utils.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/clarifying_question_card.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/event_tile.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/tools/ask_user_tool_tile.dart';

void main() {
  test('detects Arabic extended Unicode blocks as RTL', () {
    expect(TextUtils.getTextDirection('\u0870'), TextDirection.rtl);
    expect(TextUtils.getTextDirection('\u08A0'), TextDirection.rtl);
  });

  testWidgets('renders EventTile header for Arabic ask_user event as RTL', (tester) async {
    final event = CanonicalEvent(
      id: 'event-header-rtl',
      kind: EventKind.toolCall,
      timestamp: DateTime(2026),
      tool: {
        'name': 'system_ask_user',
        'input': {
          'questions': [
            {'question': 'ما هو استفسارك؟'}
          ]
        },
      },
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EventTile(event: event),
        ),
      ),
    );

    final headerDirectionality = tester.widget<Directionality>(
      find.descendant(
        of: find.byType(InkWell),
        matching: find.byType(Directionality),
      ).first,
    );
    expect(headerDirectionality.textDirection, TextDirection.rtl);

    final richTexts = tester.widgetList<RichText>(
      find.descendant(
        of: find.byType(InkWell),
        matching: find.byType(RichText),
      ),
    );
    expect(richTexts.isNotEmpty, isTrue);
    expect(richTexts.first.textDirection, TextDirection.rtl);
  });

  testWidgets('resolves every clarifying question string direction independently', (tester) async {
    await _pumpClarifyingCard(
      tester,
      const DeviceSuspendedRequest(
        requestId: 'request-1',
        sessionId: 'session-1',
        toolName: 'system_ask_user',
        permissionClass: 'clarification',
        scope: 'session',
        workspaceId: null,
        workspaceName: null,
        workspacePath: null,
        toolInput: {
          'questions': [
            {
              'question': 'ما الوضع الذي تفضله؟',
              'options': ['سريع', 'Safe'],
            },
          ],
        },
        tool: {'name': 'system_ask_user'},
      ),
    );

    _expectDirection(tester, 'ما الوضع الذي تفضله؟', TextDirection.rtl, TextAlign.right);
    _expectDirection(tester, '1  سريع', TextDirection.rtl, TextAlign.right);
    _expectDirection(tester, '2  Safe', TextDirection.ltr, TextAlign.left);
  });

  testWidgets('switches custom answer input direction while typing Arabic', (tester) async {
    await _pumpClarifyingCard(
      tester,
      const DeviceSuspendedRequest(
        requestId: 'request-2',
        sessionId: 'session-1',
        toolName: 'system_ask_user',
        permissionClass: 'clarification',
        scope: 'session',
        workspaceId: null,
        workspaceName: null,
        workspacePath: null,
        toolInput: {
          'questions': [
            {
              'question': 'اكتب إجابتك',
              'options': <String>[],
            },
          ],
        },
        tool: {'name': 'system_ask_user'},
      ),
    );

    await tester.enterText(find.byKey(const Key('clarifying_question_input')), 'هذه إجابتي');
    await tester.pump();

    final input = tester.widget<TextField>(find.byKey(const Key('clarifying_question_input')));
    expect(input.textDirection, TextDirection.rtl);
    expect(input.textAlign, TextAlign.right);
  });

  testWidgets('renders completed Arabic questions and answers as RTL', (tester) async {
    final event = CanonicalEvent(
      id: 'event-1',
      kind: EventKind.toolCall,
      timestamp: DateTime(2026),
      tool: {
        'name': 'system_ask_user',
        'output': jsonEncode([
          {
            'question': 'ما اللون المفضل؟',
            'answer': 'الأزرق',
          },
        ]),
      },
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AskUserToolTile(event: event),
        ),
      ),
    );

    _expectDirection(tester, 'ما اللون المفضل؟', TextDirection.rtl, TextAlign.right);
    _expectDirection(tester, 'الأزرق', TextDirection.rtl, TextAlign.right);

    final rows = tester.widgetList<Row>(find.byType(Row));
    expect(rows.length, 2);
    expect(rows.first.textDirection, TextDirection.rtl);
    expect(rows.last.textDirection, TextDirection.rtl);
  });
}

Future<void> _pumpClarifyingCard(
  WidgetTester tester,
  DeviceSuspendedRequest request,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ClarifyingQuestionCard(
          request: request,
          borderColor: Colors.blue,
        ),
      ),
    ),
  );
  await tester.pump();
}

void _expectDirection(
  WidgetTester tester,
  String text,
  TextDirection direction,
  TextAlign alignment,
) {
  final widget = tester.widget<Text>(find.text(text));
  expect(widget.textDirection, direction);
  expect(widget.textAlign, alignment);
}
