import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/tools/file_tool_tile.dart';

void main() {
  testWidgets('Markdown file reads default to rendered MD and switch to Raw', (
    tester,
  ) async {
    await _pumpTile(
      tester,
      _event(
        path: 'docs/guide.md',
        content: '# Guide\n\nUse the **safe** workflow.',
      ),
    );

    expect(find.byKey(const Key('file_read_raw_toggle')), findsOneWidget);
    expect(find.byKey(const Key('file_read_md_toggle')), findsOneWidget);
    expect(find.byKey(const Key('file_read_markdown_body')), findsOneWidget);
    expect(find.byKey(const Key('file_read_raw_body')), findsNothing);
    expect(find.text('Guide'), findsOneWidget);
    final switchWidget = tester.widget<SegmentedButton<bool>>(
      find.byType(SegmentedButton<bool>),
    );
    expect(switchWidget.selected, {true});
    expect(
      tester.getSize(find.byKey(const Key('file_read_content_viewport'))).height,
      350,
    );
    final selectedShape = switchWidget.style?.shape?.resolve({
      WidgetState.selected,
    });
    expect(
      (selectedShape as RoundedRectangleBorder).borderRadius,
      BorderRadius.circular(8),
    );
    final colorScheme = Theme.of(
      tester.element(find.byType(SegmentedButton<bool>)),
    ).colorScheme;
    expect(
      switchWidget.style?.backgroundColor?.resolve({WidgetState.selected}),
      colorScheme.primary.withValues(alpha: 0.2),
    );
    expect(
      switchWidget.style?.side?.resolve({WidgetState.selected})?.color,
      colorScheme.onSurface.withValues(alpha: 0.05),
    );

    await tester.tap(find.byKey(const Key('file_read_raw_toggle')));
    await tester.pump();

    expect(find.byKey(const Key('file_read_markdown_body')), findsNothing);
    expect(find.byKey(const Key('file_read_raw_body')), findsOneWidget);
    expect(tester.widget<SegmentedButton<bool>>(find.byType(SegmentedButton<bool>)).selected, {false});
    expect(
      tester.getSize(find.byKey(const Key('file_read_content_viewport'))).height,
      350,
    );

    await tester.tap(find.byKey(const Key('file_read_md_toggle')));
    await tester.pump();

    expect(find.byKey(const Key('file_read_markdown_body')), findsOneWidget);
    expect(find.byKey(const Key('file_read_raw_body')), findsNothing);
  });

  testWidgets('non-Markdown file reads keep the raw presentation', (
    tester,
  ) async {
    await _pumpTile(
      tester,
      _event(path: 'lib/example.dart', content: 'void main() {}'),
    );

    expect(find.byType(SegmentedButton<bool>), findsNothing);
    expect(find.byKey(const Key('file_read_markdown_body')), findsNothing);
    expect(find.byKey(const Key('file_read_raw_body')), findsOneWidget);
  });
}

Future<void> _pumpTile(WidgetTester tester, CanonicalEvent event) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 700,
          child: FileToolTile(event: event),
        ),
      ),
    ),
  );
  await tester.pump();
}

CanonicalEvent _event({required String path, required String content}) {
  return CanonicalEvent(
    id: 'file-read-$path',
    kind: EventKind.toolCall,
    timestamp: DateTime.utc(2026, 8, 11),
    tool: {
      'name': 'file_read',
      'input': {'path': path},
      'output': jsonEncode({
        'type': 'text',
        'file': {'content': content},
      }),
    },
  );
}
