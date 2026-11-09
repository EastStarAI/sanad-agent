import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/driver/interaction_extensions.dart';

void main() {
  group('tap hold request', () {
    test('defaults to the short press delay', () {
      final request = parseTapHoldMs(null);
      expect(request.error, isNull);
      expect(request.holdMs, tapPressDelayMs);
    });

    test('accepts a bounded long press', () {
      final request = parseTapHoldMs('800');
      expect(request.error, isNull);
      expect(request.holdMs, 800);
    });

    test('accepts an explicit zero hold', () {
      expect(parseTapHoldMs('0').holdMs, 0);
    });

    test('accepts the bound itself', () {
      expect(parseTapHoldMs('$maxTapHoldMs').holdMs, maxTapHoldMs);
    });

    test('rejects a hold beyond the bound', () {
      final request = parseTapHoldMs('${maxTapHoldMs + 1}');
      expect(request.holdMs, tapPressDelayMs);
      expect(request.error, contains('$maxTapHoldMs'));
    });

    test('rejects a negative hold', () {
      expect(parseTapHoldMs('-1').error, isNotNull);
    });

    test('rejects a non-numeric hold', () {
      expect(parseTapHoldMs('long').error, isNotNull);
    });
  });

  group('obscured target detection', () {
    /// A keyed button with an optional opaque overlay painted above it.
    Widget scene({required bool covered}) => MaterialApp(
      home: Scaffold(
        body: Stack(
          children: [
            Center(
              child: FilledButton(
                key: const ValueKey('target_btn'),
                onPressed: () {},
                child: const Text('Target'),
              ),
            ),
            if (covered)
              const Positioned.fill(
                child: ColoredBox(
                  key: ValueKey('settings_overlay'),
                  color: Color(0xFFFFFFFF),
                ),
              ),
          ],
        ),
      ),
    );

    testWidgets('a covered target is outside the hit-test path', (
      tester,
    ) async {
      await tester.pumpWidget(scene(covered: true));

      final target = tester.element(find.byKey(const ValueKey('target_btn')));
      final position = tester.getCenter(find.byKey(const ValueKey('target_btn')));
      final hitPath = hitTestElementAt(target, position)!;

      expect(
        hitPathIncludesRenderSubtree(hitPath, target.renderObject),
        isFalse,
      );
      expect(topmostHitObstruction(hitPath, target.renderObject), isNotNull);
    });

    testWidgets('an uncovered target is inside the hit-test path', (
      tester,
    ) async {
      await tester.pumpWidget(scene(covered: false));

      final target = tester.element(find.byKey(const ValueKey('target_btn')));
      final position = tester.getCenter(find.byKey(const ValueKey('target_btn')));
      final hitPath = hitTestElementAt(target, position)!;

      expect(
        hitPathIncludesRenderSubtree(hitPath, target.renderObject),
        isTrue,
      );
      expect(topmostHitObstruction(hitPath, target.renderObject), isNull);
    });

    testWidgets('an empty hit path is treated as obscured', (tester) async {
      await tester.pumpWidget(scene(covered: false));

      final target = tester.element(find.byKey(const ValueKey('target_btn')));
      // A point outside the window cannot reach the target at all.
      final blockage = describeObstruction(target, const Offset(-1, -1));

      expect(blockage, isNotNull);
      expect(blockage!['obscured'], isTrue);
    });

    testWidgets('describes the topmost blocker by key and bounds', (
      tester,
    ) async {
      await tester.pumpWidget(scene(covered: true));

      final target = tester.element(find.byKey(const ValueKey('target_btn')));
      final position = tester.getCenter(find.byKey(const ValueKey('target_btn')));
      final blockage = describeObstruction(target, position);

      expect(blockage, isNotNull);
      expect(blockage!['obscured'], isTrue);
      expect(blockage['blocker_key'], 'settings_overlay');
      expect(blockage['blocker_probe_truncated'], isNull);
      final blocker = blockage['blocker'] as Map<String, dynamic>;
      expect(blocker['type'], isNotEmpty);
      expect(blocker['bounds'], isA<Map<String, dynamic>>());
      expect(blockage['target_bounds'], isA<Map<String, dynamic>>());
    });

    testWidgets('reports no blockage for a hit that reaches the target', (
      tester,
    ) async {
      await tester.pumpWidget(scene(covered: false));

      final target = tester.element(find.byKey(const ValueKey('target_btn')));
      final position = tester.getCenter(find.byKey(const ValueKey('target_btn')));

      expect(describeObstruction(target, position), isNull);
    });
  });

  group('blocker probing', () {
    testWidgets('finds the element that owns a render object', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                key: const ValueKey('probe_target'),
                width: 40,
                height: 40,
              ),
            ),
          ),
        ),
      );

      final element = tester.element(find.byKey(const ValueKey('probe_target')));
      final probe = probeElementForRenderObject(
        tester.element(find.byType(Scaffold)),
        element.renderObject!,
      );

      expect(probe.element, same(element));
      expect(probe.truncated, isFalse);
    });

    testWidgets('reports truncation when the bound is reached', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                key: const ValueKey('far_target'),
                width: 40,
                height: 40,
              ),
            ),
          ),
        ),
      );

      final element = tester.element(find.byKey(const ValueKey('far_target')));
      final probe = probeElementForRenderObject(
        tester.element(find.byType(Scaffold)),
        element.renderObject!,
        maxVisited: 1,
      );

      expect(probe.element, isNull);
      expect(probe.truncated, isTrue);
    });

    testWidgets('names the nearest keyed ancestor', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                key: const ValueKey('outer_key'),
                width: 40,
                height: 40,
                child: const Padding(
                  padding: EdgeInsets.all(2),
                  child: SizedBox(key: ValueKey('inner_key'), width: 10, height: 10),
                ),
              ),
            ),
          ),
        ),
      );

      final inner = tester.element(find.byKey(const ValueKey('inner_key')));
      expect(nearestKeyedLabel(inner), 'inner_key');

      final unkeyed = tester.element(
        find
            .descendant(
              of: find.byKey(const ValueKey('outer_key')),
              matching: find.byType(Padding),
            )
            .first,
      );
      expect(nearestKeyedLabel(unkeyed), 'outer_key');
    });
  });

  group('hit-path ancestry', () {
    test('a null render root is never satisfied', () {
      expect(hitPathIncludesRenderSubtree(HitTestResult(), null), isFalse);
      expect(topmostHitObstruction(HitTestResult(), null), isNull);
    });
  });
}
