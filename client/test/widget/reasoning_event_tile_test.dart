import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_streaming_text_markdown/flutter_streaming_text_markdown.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/event_tile.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/markdown_style_helper.dart';
import 'package:sanad_client/shared/widgets/copy_button.dart';

void main() {
  testWidgets(
    'running thinking uses the streaming Markdown renderer with app styling',
    (tester) async {
      await _pumpEvent(
        tester,
        _event(
          kind: EventKind.thinking,
          status: EventStatus.running,
          text: '### Shared heading',
        ),
      );
      final rendererFinder = find.byType(StreamingTextMarkdown);
      final rendererContext = tester.element(rendererFinder);
      final finalStyle = MarkdownStyleHelper.getStyleSheet(
        rendererContext,
        isFinal: true,
      );
      final renderer = tester.widget<StreamingTextMarkdown>(rendererFinder);
      expect(renderer.markdownEnabled, isTrue);
      expect(renderer.animationsEnabled, isFalse);
      expect(renderer.autoScroll, isFalse);
      expect(renderer.styleSheet, finalStyle.p);
      expect(find.byKey(const Key('primary_markdown_thinking')), findsOneWidget);
    },
  );

  testWidgets('streaming thinking renders no header label or icon', (tester) async {
    await _pumpEvent(
      tester,
      _event(
        kind: EventKind.thinking,
        status: EventStatus.running,
        text: 'working through it',
      ),
    );

    expect(find.text('Thinking'), findsNothing);
    expect(find.text('Thoughts'), findsNothing);
    expect(find.byIcon(Icons.lightbulb_outline), findsNothing);
    expect(find.byKey(const Key('assistant_stream_label_thinking')), findsNothing);

    await _pumpEvent(
      tester,
      _event(kind: EventKind.thinking, text: 'completed thought'),
    );

    expect(find.text('Thinking'), findsNothing);
    expect(find.text('Thoughts'), findsNothing);
  });

  testWidgets('streaming thinking keeps a copy action and no final footer', (tester) async {
    await _pumpEvent(
      tester,
      _event(kind: EventKind.thinking, text: 'thought content'),
    );
    expect(find.byType(CopyButton), findsOneWidget);
  });

  testWidgets('reasoning renders a transient tool-like row, not a markdown bubble', (tester) async {
    await _pumpEvent(
      tester,
      _event(
        kind: EventKind.reasoning,
        status: EventStatus.running,
        text: 'the quick brown fox jumps over the lazy dog',
      ),
    );

    // Spinner for the running state.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    // Dim "Thinking:" prefix + first five words only (rendered via RichText).
    final rowText = _richTextContent(tester);
    expect(rowText, contains('Thinking:'));
    expect(rowText, contains('the quick brown fox jumps'));
    expect(rowText, isNot(contains('lazy dog')));
    // Not a full markdown bubble.
    expect(find.byKey(const Key('primary_markdown_reasoning')), findsNothing);
    expect(find.byType(MarkdownBody), findsNothing);
    // No copy action on the transient reasoning row.
    expect(find.byType(CopyButton), findsNothing);
  });

  testWidgets('reasoning running row has no expander disclosure', (tester) async {
    await _pumpEvent(
      tester,
      _event(
        kind: EventKind.reasoning,
        status: EventStatus.running,
        text: _lines(20),
      ),
    );

    expect(find.byKey(const Key('reasoning_disclosure')), findsNothing);
    expect(find.byKey(const Key('reasoning_scroll_viewport')), findsNothing);
    expect(find.byType(SingleChildScrollView), findsNothing);
  });
}

/// Flattens the visible text of the transient reasoning `RichText` row.
String _richTextContent(WidgetTester tester) {
  final richText = tester.widget<RichText>(find.byType(RichText));
  final buffer = StringBuffer();
  void walk(InlineSpan span) {
    if (span is TextSpan) {
      buffer.write(span.text ?? '');
      span.children?.forEach(walk);
    }
  }

  walk(richText.text);
  return buffer.toString();
}

Future<void> _pumpEvent(WidgetTester tester, CanonicalEvent event) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 600,
            child: EventTile(
              key: const ValueKey('event-tile'),
              event: event,
            ),
          ),
        ),
      ),
    ),
  );
}

CanonicalEvent _event({
  required EventKind kind,
  required String text,
  EventStatus status = EventStatus.done,
}) {
  return CanonicalEvent(
    id: 'event-1',
    kind: kind,
    status: status,
    text: text,
    timestamp: DateTime.utc(2026, 7, 25),
    runId: 'run-1',
    modelStepId: 'step-1',
  );
}

String _lines(int count) => List.generate(
  count,
  (index) => 'line ${index + 1}',
).join('  \n');
