import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/domain/models/compaction_event_snapshot.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/compaction_event_tile.dart';

void main() {
  testWidgets('shows centered manual compacting label while started', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CompactionEventTile(
            snapshot: CompactionEventSnapshot(
              sessionId: 'session-1',
              compactionId: 'cmp-1',
              status: CompactionLifecycleStatus.started,
              trigger: CompactionTriggerKind.manual,
            ),
          ),
        ),
      ),
    );

    expect(find.text('Context compacting'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('shows auto completed label with check icon', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CompactionEventTile(
            snapshot: CompactionEventSnapshot(
              sessionId: 'session-1',
              compactionId: 'cmp-2',
              status: CompactionLifecycleStatus.completed,
              trigger: CompactionTriggerKind.auto,
            ),
          ),
        ),
      ),
    );

    expect(find.text('Auto context compacted'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
  });

  testWidgets('dividers consume the full row around the intrinsic label', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 800,
            child: CompactionEventTile(
              snapshot: CompactionEventSnapshot(
                sessionId: 'session-1',
                compactionId: 'cmp-wide',
                status: CompactionLifecycleStatus.completed,
                trigger: CompactionTriggerKind.auto,
              ),
            ),
          ),
        ),
      ),
    );

    final dividers = find.byType(Divider);
    expect(dividers, findsNWidgets(2));
    final widths = [
      tester.getSize(dividers.at(0)).width,
      tester.getSize(dividers.at(1)).width,
    ];
    expect(widths[0], greaterThan(200));
    expect((widths[0] - widths[1]).abs(), lessThan(1));
  });

  testWidgets('replaces the provisional after estimate when confirmed', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CompactionEventTile(
            snapshot: CompactionEventSnapshot(
              sessionId: 'session-1',
              compactionId: 'cmp-confirmed',
              status: CompactionLifecycleStatus.completed,
              trigger: CompactionTriggerKind.auto,
              contextWindowTokens: 400000,
              effectiveInputBudgetTokens: 394880,
              autoThresholdTokens: 315904,
              estimatedRequestTokensBefore: 318066,
              estimatedRequestTokensAfter: 57630,
              beforeMeasurementKind: 'mixed',
              providerConfirmedRequestTokensAfter: 34922,
              retainedTailTokens: 38073,
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byType(InkWell));
    await tester.pump();
    expect(
      find.textContaining('After compaction: 34,922 tokens (8.8%) ✓ Confirmed'),
      findsOneWidget,
    );
    expect(find.textContaining('57,630'), findsNothing);
    expect(
      find.textContaining('Context reclaimed: 283,144 tokens (89.0%)'),
      findsOneWidget,
    );
    expect(find.textContaining('Before compaction: 318,066 tokens (80.5%)'), findsOneWidget);
    expect(find.textContaining('Retained tail: ~38,073 tokens'), findsOneWidget);
    expect(find.textContaining('Auto threshold: 315,904 tokens (80.0%)'), findsOneWidget);
    expect(find.textContaining('Usable input: 394,880 tokens'), findsOneWidget);
    expect(find.textContaining('Context window: 400,000 tokens'), findsOneWidget);
    expect(find.textContaining('Trigger:'), findsNothing);
    expect(find.textContaining('Status:'), findsNothing);
  });

  testWidgets('keeps the timeline interaction at least 44 logical pixels high', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CompactionEventTile(
            snapshot: CompactionEventSnapshot(
              sessionId: 'session-1',
              compactionId: 'cmp-touch-target',
              status: CompactionLifecycleStatus.failed,
              trigger: CompactionTriggerKind.overflow,
              failureReason: 'projection_still_over_budget',
            ),
          ),
        ),
      ),
    );

    expect(tester.getSize(find.byType(InkWell)).height, greaterThanOrEqualTo(44));
  });

  testWidgets('tap and keyboard focus expose the same redacted details', (
    tester,
  ) async {
    const details =
        'Before compaction: 80,000 tokens (80.0%)\n'
        'After compaction: 20,000 tokens (20.0%)\n'
        'Context reclaimed: 60,000 tokens (75.0%)\n'
        'Retained tail: ~5,000 tokens\n'
        'Context window: 100,000 tokens\n'
        'Failure: projection_still_over_budget';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CompactionEventTile(
            snapshot: CompactionEventSnapshot(
              sessionId: 'session-1',
              compactionId: 'cmp-details',
              status: CompactionLifecycleStatus.failed,
              trigger: CompactionTriggerKind.overflow,
              contextWindowTokens: 100000,
              estimatedRequestTokensBefore: 80000,
              estimatedRequestTokensAfter: 20000,
              retainedTailTokens: 5000,
              startedAt: DateTime.utc(2026, 8, 29, 2),
              completedAt: DateTime.utc(2026, 8, 29, 2, 0, 2),
              durationMs: 2000,
              failureReason: 'projection_still_over_budget',
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byType(InkWell));
    await tester.pump();
    expect(find.text(details), findsOneWidget);
    expect(find.textContaining('N/A'), findsNothing);
    expect(find.textContaining('summary'), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer();
    await mouse.moveTo(tester.getCenter(find.byType(InkWell)));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text(details), findsOneWidget);

    await mouse.moveTo(Offset.zero);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    tester.binding.focusManager.primaryFocus?.unfocus();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(find.text(details), findsOneWidget);
  });

  testWidgets('only the centered label opens details, not the divider row', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 800,
            child: CompactionEventTile(
              snapshot: CompactionEventSnapshot(
                sessionId: 'session-1',
                compactionId: 'cmp-hit-target',
                status: CompactionLifecycleStatus.completed,
                trigger: CompactionTriggerKind.auto,
                contextWindowTokens: 400000,
              ),
            ),
          ),
        ),
      ),
    );

    final row = find.byType(CompactionEventTile);
    final rowRect = tester.getRect(row);
    await tester.tapAt(Offset(rowRect.left + 20, rowRect.center.dy));
    await tester.pump();
    expect(find.textContaining('Context window: 400,000 tokens'), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey('compaction-label-cmp-hit-target')),
    );
    await tester.pump();
    expect(find.textContaining('Context window: 400,000 tokens'), findsOneWidget);
  });

  testWidgets('renders all terminal labels without narrow-layout overflow', (
    tester,
  ) async {
    final cases = <(CompactionLifecycleStatus, CompactionTriggerKind, String)>[
      (
        CompactionLifecycleStatus.started,
        CompactionTriggerKind.manual,
        'Context compacting',
      ),
      (
        CompactionLifecycleStatus.started,
        CompactionTriggerKind.auto,
        'Auto context compacting',
      ),
      (
        CompactionLifecycleStatus.completed,
        CompactionTriggerKind.manual,
        'Context compacted',
      ),
      (
        CompactionLifecycleStatus.completed,
        CompactionTriggerKind.auto,
        'Auto context compacted',
      ),
      (
        CompactionLifecycleStatus.failed,
        CompactionTriggerKind.manual,
        'Context compaction failed',
      ),
      (
        CompactionLifecycleStatus.failed,
        CompactionTriggerKind.overflow,
        'Auto context compaction failed',
      ),
    ];

    for (final (status, trigger, label) in cases) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 280,
                child: CompactionEventTile(
                  snapshot: CompactionEventSnapshot(
                    sessionId: 'session-1',
                    compactionId: 'cmp-$label',
                    status: status,
                    trigger: trigger,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text(label), findsOneWidget);
      expect(tester.takeException(), isNull);
      if (status != CompactionLifecycleStatus.started) {
        expect(find.byType(CircularProgressIndicator), findsNothing);
      }
    }
  });

  testWidgets('supports large text on a narrow timeline', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 280,
                child: CompactionEventTile(
                  snapshot: CompactionEventSnapshot(
                    sessionId: 'session-1',
                    compactionId: 'cmp-large-text',
                    status: CompactionLifecycleStatus.failed,
                    trigger: CompactionTriggerKind.overflow,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Auto context compaction failed'), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byType(InkWell)).height, greaterThanOrEqualTo(44));
  });
}
