import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/event_tile.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/markdown_style_helper.dart';
import 'package:sanad_client/shared/widgets/copy_button.dart';

void main() {
  testWidgets(
    'running thinking uses the final-answer Markdown renderer and styling',
    (tester) async {
      await _pumpEvent(
        tester,
        _event(
          kind: EventKind.thinking,
          status: EventStatus.running,
          text: '### Shared heading',
        ),
      );
      final rendererFinder = find.byType(MarkdownBody);
      final rendererContext = tester.element(rendererFinder);
      final finalStyle = MarkdownStyleHelper.getStyleSheet(
        rendererContext,
        isFinal: true,
      );
      final renderer = tester.widget<MarkdownBody>(rendererFinder);
      expect(renderer.data, '### Shared heading');
      expect(renderer.styleSheet, finalStyle);
      expect(renderer.builders, isNotNull);
      expect(renderer.builders.keys, contains('code'));
      expect(find.byKey(const Key('primary_markdown_thinking')), findsOneWidget);
    },
  );

  testWidgets(
    'running and completed text use the same MarkdownBody configuration',
    (tester) async {
      await _pumpEvent(
        tester,
        _event(
          kind: EventKind.thinking,
          status: EventStatus.running,
          text: '**Shared content**',
        ),
      );
      final runningRenderer = tester.widget<MarkdownBody>(
        find.byType(MarkdownBody),
      );

      await _pumpEvent(
        tester,
        _event(
          kind: EventKind.thinking,
          status: EventStatus.done,
          text: '**Shared content**',
        ),
      );
      final completedRenderer = tester.widget<MarkdownBody>(
        find.byType(MarkdownBody),
      );
      final runningStyle = runningRenderer.styleSheet!;
      final completedStyle = completedRenderer.styleSheet!;

      expect(runningStyle.p, completedStyle.p);
      expect(runningStyle.code, completedStyle.code);
      expect(runningStyle.blockquote, completedStyle.blockquote);
      expect(
        runningStyle.codeblockDecoration,
        completedStyle.codeblockDecoration,
      );
      expect(runningRenderer.builders.keys, completedRenderer.builders.keys);
      expect(
        runningRenderer.builders['code'].runtimeType,
        completedRenderer.builders['code'].runtimeType,
      );
    },
  );

  testWidgets(
    'MarkdownBody key uses balanced milestone keys during streaming and stable final key on completion',
    (tester) async {
      // 1. Single line short running stream -> stream_1_0
      await _pumpEvent(
        tester,
        _event(
          kind: EventKind.thinking,
          status: EventStatus.running,
          text: 'thinking step 1',
        ),
      );
      expect(
        find.byKey(const ValueKey('event-1_stream_1_0')),
        findsOneWidget,
      );

      // 2. Intra-word addition in same line & bucket does not thrash key
      await _pumpEvent(
        tester,
        _event(
          kind: EventKind.thinking,
          status: EventStatus.running,
          text: 'thinking step 1 with extra words',
        ),
      );
      expect(
        find.byKey(const ValueKey('event-1_stream_1_0')),
        findsOneWidget,
      );

      // 3. Newline milestone advances stream key to rebuild AST cleanly
      await _pumpEvent(
        tester,
        _event(
          kind: EventKind.thinking,
          status: EventStatus.running,
          text: 'thinking step 1\nstep 2',
        ),
      );
      expect(
        find.byKey(const ValueKey('event-1_stream_2_0')),
        findsOneWidget,
      );

      // 4. Completed event uses stable final key
      await _pumpEvent(
        tester,
        _event(
          kind: EventKind.finalAnswer,
          status: EventStatus.done,
          text: 'final answer content',
        ),
      );
      expect(
        find.byKey(const ValueKey('event-1_final')),
        findsOneWidget,
      );
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
