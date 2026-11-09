import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/driver/interaction_extensions.dart';
import 'package:sanad_client/driver/ui_bounds.dart';

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

  group('synthetic hover dwell', () {
    test('defaults to the shared dwell', () {
      final request = parseHoverMs(null);
      expect(request.error, isNull);
      expect(request.ms, hoverDefaultMs);
    });

    test('treats an empty value as the default', () {
      expect(parseHoverMs('   ').ms, hoverDefaultMs);
      expect(parseHoverMs('   ').error, isNull);
    });

    test('accepts an explicit dwell', () {
      final request = parseHoverMs('800');
      expect(request.error, isNull);
      expect(request.ms, 800);
    });

    test('accepts a zero dwell', () {
      expect(parseHoverMs('0').ms, 0);
      expect(parseHoverMs('0').error, isNull);
    });

    test('accepts the bound itself', () {
      expect(parseHoverMs('$maxHoverMs').ms, maxHoverMs);
      expect(parseHoverMs('$maxHoverMs').error, isNull);
    });

    test('rejects a dwell beyond the bound', () {
      final request = parseHoverMs('${maxHoverMs + 1}');
      expect(request.ms, hoverDefaultMs);
      expect(request.error, contains('$maxHoverMs'));
    });

    test('rejects a negative dwell', () {
      expect(parseHoverMs('-1').error, isNotNull);
    });

    test('rejects a non-numeric dwell', () {
      expect(parseHoverMs('long').error, isNotNull);
    });
  });

  group('synthetic hover dispatch', () {
    /// A hover probe that records both callbacks, so a test proves the pointer
    /// genuinely entered the frame's own mouse-tracking pipeline and left it
    /// again, rather than only that a helper was called.
    Widget probe(List<String> events) => MaterialApp(
      home: Scaffold(
        body: Center(
          child: MouseRegion(
            key: const ValueKey('hover_probe'),
            onEnter: (_) => events.add('enter'),
            onExit: (_) => events.add('exit'),
            child: const SizedBox(width: 80, height: 80),
          ),
        ),
      ),
    );

    testWidgets('entering and exiting fire onEnter and onExit', (tester) async {
      final events = <String>[];
      await tester.pumpWidget(probe(events));
      final center = tester.getCenter(find.byKey(const ValueKey('hover_probe')));

      dispatchSyntheticHoverEnter(41, center);
      await tester.pump();
      expect(events, ['enter']);

      dispatchSyntheticHoverExit(41);
      await tester.pump();
      expect(events, ['enter', 'exit']);
    });

    testWidgets('the scheduled exit releases the hover on its own', (
      tester,
    ) async {
      final events = <String>[];
      await tester.pumpWidget(probe(events));
      final center = tester.getCenter(find.byKey(const ValueKey('hover_probe')));

      dispatchSyntheticHoverEnter(42, center);
      await tester.pump();
      expect(events, ['enter']);

      scheduleSyntheticHoverExit(42, 300);
      expect(hasScheduledHoverExit(42), isTrue);

      await tester.pump(const Duration(milliseconds: 299));
      expect(events, ['enter']);

      await tester.pump(const Duration(milliseconds: 1));
      expect(events, ['enter', 'exit']);
      expect(hasScheduledHoverExit(42), isFalse);
    });

    testWidgets('an explicit exit cancels the automatic one', (tester) async {
      final events = <String>[];
      await tester.pumpWidget(probe(events));
      final center = tester.getCenter(find.byKey(const ValueKey('hover_probe')));

      dispatchSyntheticHoverEnter(43, center);
      await tester.pump();
      scheduleSyntheticHoverExit(43, 300);

      cancelSyntheticHoverExit(43);
      expect(hasScheduledHoverExit(43), isFalse);

      await tester.pump(const Duration(seconds: 1));
      // The pointer is still over the probe, so no exit fired and none is
      // pending: the caller owns releasing it from here.
      expect(events, ['enter']);

      dispatchSyntheticHoverExit(43);
      await tester.pump();
      expect(events, ['enter', 'exit']);
    });

    testWidgets('a reveal-only hover moves the projected bounds', (
      tester,
    ) async {
      // The desktop sidebar reveals its session menu with
      // `Visibility(maintainState: true)`, so the button stays mounted while it
      // is hidden and its key cannot distinguish the two states. What changes
      // is its layout, and projected bounds are part of the tree signature, so
      // this is the evidence a `hover --verify` on such a row can rely on.
      var hovered = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: StatefulBuilder(
                builder: (context, setState) => MouseRegion(
                  key: const ValueKey('reveal_row'),
                  onEnter: (_) => setState(() => hovered = true),
                  onExit: (_) => setState(() => hovered = false),
                  child: SizedBox(
                    width: 200,
                    height: 40,
                    child: Stack(
                      alignment: Alignment.centerRight,
                      children: [
                        Visibility(
                          visible: hovered,
                          maintainState: true,
                          maintainAnimation: true,
                          child: PopupMenuButton<String>(
                            key: const ValueKey('reveal_only_menu'),
                            tooltip: '',
                            itemBuilder: (context) => const [
                              PopupMenuItem(
                                value: 'rename',
                                child: Text('Rename'),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      // The button is mounted but offstage, so the projection still sees it in
      // both states; only its bounds differ.
      final menu = find.byKey(
        const ValueKey('reveal_only_menu'),
        skipOffstage: false,
      );
      expect(menu, findsOneWidget);
      final hiddenBounds = globalBoundsOf(tester.renderObject(menu));
      expect(hiddenBounds, isNotNull);

      final row = tester.getCenter(find.byKey(const ValueKey('reveal_row')));
      dispatchSyntheticHoverEnter(44, row);
      await tester.pumpAndSettle();

      expect(hovered, isTrue);
      final revealedBounds = globalBoundsOf(tester.renderObject(menu));
      expect(revealedBounds, isNotNull);
      expect(revealedBounds, isNot(hiddenBounds));

      dispatchSyntheticHoverExit(44);
      await tester.pumpAndSettle();

      expect(hovered, isFalse);
      expect(globalBoundsOf(tester.renderObject(menu)), hiddenBounds);
    });
  });

  group('hit-path ancestry', () {
    test('a null render root is never satisfied', () {
      expect(hitPathIncludesRenderSubtree(HitTestResult(), null), isFalse);
      expect(topmostHitObstruction(HitTestResult(), null), isNull);
    });
  });
}
