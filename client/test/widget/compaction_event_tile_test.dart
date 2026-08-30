import 'package:flutter/material.dart';
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
}
