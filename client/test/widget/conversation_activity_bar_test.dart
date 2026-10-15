import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';
import 'package:sanad_client/features/conversations/presentation/utils/conversation_timeline_projection.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_activity_bar.dart';

class _FakeRandom implements Random {
  final int fixedValue;
  const _FakeRandom(this.fixedValue);

  @override
  int nextInt(int max) => fixedValue;

  @override
  bool nextBool() => false;

  @override
  double nextDouble() => 0.0;
}

void main() {
  testWidgets('displays first line of reasoning when activity is reasoning', (tester) async {
    final reasoningEvent = CanonicalEvent(
      id: 'reasoning-1',
      kind: EventKind.reasoning,
      text: 'First line of model reasoning\nSecond line of model reasoning',
      status: EventStatus.running,
      timestamp: DateTime(2026, 1, 1),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ConversationActivityBar(
            activity: ConversationActivity.reasoning(reasoningEvent),
            latestDescription: 'Some tool description',
          ),
        ),
      ),
    );

    // Priority 1: reasoning first line must be displayed
    expect(find.text('First line of model reasoning'), findsOneWidget);
    expect(find.text('Some tool description'), findsNothing);
  });

  testWidgets('displays latest description when reasoning is absent', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ConversationActivityBar(
            latestDescription: 'Opening terminal to list files',
          ),
        ),
      ),
    );

    expect(find.text('Opening terminal to list files'), findsOneWidget);
    expect(find.byKey(const Key('conversation_activity_progress')), findsOneWidget);
  });

  testWidgets('displays rotating English phrases when app locale is English', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ConversationActivityBar(
            random: _FakeRandom(0), // 0 + 3 = 3s
          ),
        ),
      ),
    );

    expect(find.text(ConversationActivityBar.englishPhrases[0]), findsOneWidget);

    // Advance 3 seconds for phrase cycle
    await tester.pump(const Duration(seconds: 3));
    expect(find.text(ConversationActivityBar.englishPhrases[1]), findsOneWidget);
  });

  testWidgets('displays rotating Arabic phrases when app locale is Arabic', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Localizations(
          locale: Locale('ar'),
          delegates: [
            DefaultWidgetsLocalizations.delegate,
            DefaultMaterialLocalizations.delegate,
          ],
          child: Scaffold(
            body: ConversationActivityBar(
              random: _FakeRandom(0), // 0 + 3 = 3s
            ),
          ),
        ),
      ),
    );

    expect(find.text(ConversationActivityBar.arabicPhrases[0]), findsOneWidget);

    // Advance 3 seconds for phrase cycle
    await tester.pump(const Duration(seconds: 3));
    expect(find.text(ConversationActivityBar.arabicPhrases[1]), findsOneWidget);
  });

  testWidgets('truncates model reasoning first line to max 7 words with ellipsis', (tester) async {
    final reasoningEvent = CanonicalEvent(
      id: 'reasoning-long',
      kind: EventKind.reasoning,
      text: 'One two three four five six seven eight nine ten\nSecond line',
      status: EventStatus.running,
      timestamp: DateTime(2026, 1, 1),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ConversationActivityBar(
            activity: ConversationActivity.reasoning(reasoningEvent),
          ),
        ),
      ),
    );

    expect(find.text('One two three four five six seven...'), findsOneWidget);
  });

  test('formatElapsed keeps seconds visible across seconds, minutes, and hours', () {
    expect(ConversationActivityBar.formatElapsed(const Duration(seconds: 1)), '1s');
    expect(ConversationActivityBar.formatElapsed(const Duration(minutes: 1, seconds: 1)), '1m 1s');
    expect(ConversationActivityBar.formatElapsed(const Duration(hours: 1, minutes: 1, seconds: 1)), '1h 1m 1s');
  });
}
