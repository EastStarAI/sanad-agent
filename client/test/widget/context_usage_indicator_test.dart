import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/domain/models/llm_usage_snapshot.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/context_usage_indicator.dart';

void main() {
  testWidgets('shows latest cached input and never cache write', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: ContextUsageIndicator(
              usage: LlmUsageSnapshot(
                inputTokens: 194000,
                outputTokens: 2500,
                totalTokens: 196500,
                cachedTokens: 120000,
                contextWindowTokens: 258000,
                modelId: 'model-1',
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.byKey(const Key('context_usage_indicator')), findsOneWidget);
    await tester.tap(find.byKey(const Key('context_usage_indicator')));
    await tester.pump();

    expect(find.textContaining('Cached input: 120k tokens'), findsOneWidget);
    expect(find.textContaining('Provider confirmed'), findsOneWidget);
    expect(find.textContaining('Cache write'), findsNothing);
  });

  testWidgets('stays hidden when context occupancy is unavailable', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: ContextUsageIndicator(
          usage: LlmUsageSnapshot(cachedTokens: 120000),
        ),
      ),
    );

    expect(find.byKey(const Key('context_usage_indicator')), findsNothing);
  });
}
