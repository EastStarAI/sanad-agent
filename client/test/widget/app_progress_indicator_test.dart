import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/core/presentation/widgets/app_progress_indicator.dart';
import 'package:sanad_client/core/theme/activity_animation_policy.dart';

void main() {
  group('AppProgressIndicator', () {
    testWidgets('renders standard CircularProgressIndicator when continuous motion is allowed', (
      tester,
    ) async {
      await ActivityAnimationPolicy.withContinuousActivityAnimationOverrideAsync(true, () async {
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: AppProgressIndicator(),
            ),
          ),
        );

        expect(find.byType(CircularProgressIndicator), findsOneWidget);
      });
    });

    testWidgets('renders static CustomPaint ring without CircularProgressIndicator when continuous motion is disabled', (
      tester,
    ) async {
      await ActivityAnimationPolicy.withContinuousActivityAnimationOverrideAsync(false, () async {
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: AppProgressIndicator(
                strokeWidth: 3.5,
                color: Colors.green,
                semanticsLabel: 'Loading data',
              ),
            ),
          ),
        );

        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(find.byType(CustomPaint), findsWidgets);
        expect(find.bySemanticsLabel('Loading data'), findsOneWidget);
      });
    });

    testWidgets('renders CircularProgressIndicator when determinate value is provided even if continuous motion is disabled', (
      tester,
    ) async {
      await ActivityAnimationPolicy.withContinuousActivityAnimationOverrideAsync(false, () async {
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: AppProgressIndicator(value: 0.75),
            ),
          ),
        );

        expect(find.byType(CircularProgressIndicator), findsOneWidget);
      });
    });
  });
}
