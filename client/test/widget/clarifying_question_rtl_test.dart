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

  test('uses the first strong English character even with later Arabic', () {
    expect(
      TextUtils.getTextDirection('This is an English sentence with "مرحبا".'),
      TextDirection.ltr,
    );
  });

  test('uses the first strong Arabic character even when English is the majority', () {
    expect(
      TextUtils.getTextDirection('مرحبا this sentence continues mostly in English for a long time.'),
      TextDirection.rtl,
    );
  });

  test('detects RTL for Arabic sentence containing a long English URL', () {
    expect(
      TextUtils.getTextDirection(
        'يرجى زيارة الرابط التالي: https://github.com/flutter/flutter/issues/very/long/url/path',
      ),
      TextDirection.rtl,
    );
  });

  test('ignores neutral Markdown and numbers before the first strong character', () {
    expect(TextUtils.getTextDirection('1. # هذا title continues in English'), TextDirection.rtl);
    expect(TextUtils.getTextDirection('- [ ] مهمة الجديدة remains pending'), TextDirection.rtl);
    expect(TextUtils.getTextDirection('> 42... English ثم العربية'), TextDirection.ltr);
  });

  test('detects multi-line text direction based on first strong directional line', () {
    const arabicFirst = 'مرحبا بك في المساعد الذكي\n```bash\ngit status\n```';
    expect(TextUtils.getTextDirection(arabicFirst), TextDirection.rtl);

    const englishFirst = 'Here is the command output:\nنجحت العملية بالكامل';
    expect(TextUtils.getTextDirection(englishFirst), TextDirection.ltr);
  });

  test('defaults to LTR for empty, whitespace, and neutral punctuation/numbers', () {
    expect(TextUtils.getTextDirection(null), TextDirection.ltr);
    expect(TextUtils.getTextDirection(''), TextDirection.ltr);
    expect(TextUtils.getTextDirection('   '), TextDirection.ltr);
    expect(TextUtils.getTextDirection('12345!@#\$%^&*()'), TextDirection.ltr);
  });

  testWidgets('uses the first strong character for an ask_user event header', (tester) async {
    final event = CanonicalEvent(
      id: 'event-header-rtl',
      kind: EventKind.toolCall,
      timestamp: DateTime(2026),
      tool: {
        'name': 'system_ask_user',
        'input': {
          'questions': [
            {'question': 'ما هو استفسارك؟'},
          ],
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
      find
          .descendant(
            of: find.byType(InkWell),
            matching: find.byType(Directionality),
          )
          .first,
    );
    expect(headerDirectionality.textDirection, TextDirection.ltr);

    final richTexts = tester.widgetList<RichText>(
      find.descendant(
        of: find.byType(InkWell),
        matching: find.byType(RichText),
      ),
    );
    expect(richTexts.isNotEmpty, isTrue);
    expect(richTexts.first.textDirection, TextDirection.ltr);
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
