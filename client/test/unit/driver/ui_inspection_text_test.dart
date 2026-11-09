import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/driver/ui_inspection_text.dart';

void main() {
  group('tooltip bounding', () {
    test('ignores an absent or blank message', () {
      expect(boundTooltipMessage(null), isNull);
      expect(boundTooltipMessage('   '), isNull);
    });

    test('keeps a short message unchanged', () {
      final bounded = boundTooltipMessage('Press to start dictation.');
      expect(bounded, isNotNull);
      expect(bounded!.text, 'Press to start dictation.');
      expect(bounded.truncated, isFalse);
    });

    test('keeps a message at the exact bound', () {
      final message = 'x' * maxTooltipMessageLength;
      final bounded = boundTooltipMessage(message);
      expect(bounded!.text.length, maxTooltipMessageLength);
      expect(bounded.truncated, isFalse);
    });

    test('cuts a longer message and reports truncation', () {
      final bounded = boundTooltipMessage('y' * (maxTooltipMessageLength + 40));
      expect(bounded!.text.length, maxTooltipMessageLength);
      expect(bounded.truncated, isTrue);
    });

    test('preserves multi-line tooltip copy', () {
      final bounded = boundTooltipMessage(
        'Press to stop dictation.\nLong-press for dictation settings.',
      );
      expect(bounded!.text, contains('\n'));
      expect(bounded.truncated, isFalse);
    });
  });

  group('descendant tooltip discovery', () {
    testWidgets('reads the tooltip an icon button builds as its own child', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: IconButton(
                key: const ValueKey('dictation_mic_btn'),
                tooltip: 'Press to start dictation.',
                onPressed: () {},
                icon: const Icon(Icons.mic),
              ),
            ),
          ),
        ),
      );

      final button = tester.element(
        find.byKey(const ValueKey('dictation_mic_btn')),
      );
      // The `Tooltip` is a descendant, which is why ancestor-only propagation
      // never reached this row.
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('dictation_mic_btn')),
          matching: find.byType(Tooltip),
        ),
        findsOneWidget,
      );
      expect(
        firstDescendantTooltipMessage(button),
        'Press to start dictation.',
      );
    });

    testWidgets('returns null when no tooltip is beneath the element', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(child: Text('plain row', key: ValueKey('plain_row'))),
          ),
        ),
      );

      expect(
        firstDescendantTooltipMessage(
          tester.element(find.byKey(const ValueKey('plain_row'))),
        ),
        isNull,
      );
    });

    testWidgets('stops at the probe bound', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: IconButton(
                key: const ValueKey('bounded_mic_btn'),
                tooltip: 'Tooltip below the bound',
                onPressed: () {},
                icon: const Icon(Icons.mic),
              ),
            ),
          ),
        ),
      );

      expect(
        firstDescendantTooltipMessage(
          tester.element(find.byKey(const ValueKey('bounded_mic_btn'))),
          maxVisited: 1,
        ),
        isNull,
      );
    });
  });

  group('projected tooltip', () {
    testWidgets('prefers the tooltip inherited from an ancestor', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Tooltip(
              message: 'Ancestor tooltip',
              child: Center(
                child: IconButton(
                  key: const ValueKey('nested_btn'),
                  tooltip: 'Child tooltip',
                  onPressed: () {},
                  icon: const Icon(Icons.mic),
                ),
              ),
            ),
          ),
        ),
      );

      final projected = inspectableTooltip(
        tester.element(find.byKey(const ValueKey('nested_btn'))),
        inherited: 'Ancestor tooltip',
      );
      expect(projected!.text, 'Ancestor tooltip');
    });

    testWidgets('falls back to the tooltip inside the element', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: IconButton(
                key: const ValueKey('child_tooltip_btn'),
                tooltip: 'Child tooltip',
                onPressed: () {},
                icon: const Icon(Icons.mic),
              ),
            ),
          ),
        ),
      );

      final projected = inspectableTooltip(
        tester.element(find.byKey(const ValueKey('child_tooltip_btn'))),
      );
      expect(projected!.text, 'Child tooltip');
      expect(projected.truncated, isFalse);
    });

    testWidgets('reports no tooltip when the element declares none', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: Text('no tooltip row', key: ValueKey('no_tooltip_row')),
            ),
          ),
        ),
      );

      expect(
        inspectableTooltip(
          tester.element(find.byKey(const ValueKey('no_tooltip_row'))),
        ),
        isNull,
      );
    });
  });
}
