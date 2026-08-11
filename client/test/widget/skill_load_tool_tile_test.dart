import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/event_tile.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/tools/skill_load_tool_tile.dart';

void main() {
  testWidgets(
    'renders compact skill output as a File Read-like Markdown body',
    (tester) async {
      await _pumpEvent(
        tester,
        _event(
          output: '''Skill source: .agents/skills/review/SKILL.md

# Review Skill

Follow the **review** workflow.

- Inspect
- Verify''',
        ),
      );

      expect(find.byType(SkillLoadToolTile), findsOneWidget);
      expect(find.textContaining('Target Path:'), findsOneWidget);
      expect(
        find.textContaining('.agents/skills/review/SKILL.md'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('skill_markdown_body')), findsOneWidget);
      expect(find.text('Review Skill'), findsOneWidget);
      expect(find.text('Inspect'), findsOneWidget);
      expect(find.text('Input Parameters'), findsNothing);
      expect(find.text('Output Result'), findsNothing);
    },
  );

  testWidgets('renders the skill name while loading', (tester) async {
    await _pumpEvent(tester, _event(status: EventStatus.running));

    expect(find.byType(SkillLoadToolTile), findsOneWidget);
    expect(find.textContaining('Skill:'), findsOneWidget);
    expect(find.textContaining('review'), findsWidgets);
    expect(find.text('Loading skill...'), findsOneWidget);
  });

  testWidgets('renders skill load failures in the dedicated error state', (
    tester,
  ) async {
    await _pumpEvent(
      tester,
      _event(status: EventStatus.error, output: 'Unknown skill: review'),
    );

    expect(find.byType(SkillLoadToolTile), findsOneWidget);
    expect(find.text('Unknown skill: review'), findsOneWidget);
    expect(find.text('Output Result'), findsNothing);
  });
}

Future<void> _pumpEvent(WidgetTester tester, CanonicalEvent event) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 700,
          child: EventTile(event: event, isExpanded: true),
        ),
      ),
    ),
  );
  await tester.pump();
}

CanonicalEvent _event({EventStatus status = EventStatus.done, String? output}) {
  return CanonicalEvent(
    id: 'skill-load-event',
    kind: EventKind.toolCall,
    status: status,
    timestamp: DateTime.utc(2026, 8, 11),
    tool: {
      'name': 'skill_load',
      'input': {'skill': 'review'},
      if (output != null) 'output': output,
    },
  );
}
