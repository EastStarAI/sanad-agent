import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/utils/format_utils.dart';

void main() {
  group('EventMetadataFormatter.formatRuntime', () {
    test('returns empty string when runtime is not a number', () {
      expect(EventMetadataFormatter.formatRuntime(null), '');
      expect(EventMetadataFormatter.formatRuntime('abc'), '');
    });

    test('formats subsecond durations under 1 second with fractions', () {
      expect(EventMetadataFormatter.formatRuntime(250), '0.3s');
      expect(EventMetadataFormatter.formatRuntime(400), '0.4s');
      expect(EventMetadataFormatter.formatRuntime(999), '1s');
    });

    test('formats durations >= 1 second without fractions', () {
      expect(EventMetadataFormatter.formatRuntime(1000), '1s');
      expect(EventMetadataFormatter.formatRuntime(1500), '2s');
      expect(EventMetadataFormatter.formatRuntime(12500), '13s');
      expect(EventMetadataFormatter.formatRuntime(59000), '59s');
    });

    test('formats minutes and seconds when duration is less than 1 hour', () {
      // 5 minutes and 12 seconds
      expect(EventMetadataFormatter.formatRuntime((5 * 60 + 12) * 1000), '5m 12s');
      // 59 minutes and 59 seconds
      expect(EventMetadataFormatter.formatRuntime((59 * 60 + 59) * 1000), '59m 59s');
    });

    test('formats hours and minutes without seconds when duration is 1 hour or more', () {
      // 3 hours and 20 minutes (200 minutes)
      expect(EventMetadataFormatter.formatRuntime(200 * 60 * 1000), '3h 20m');
      // 1 hour, 5 minutes, 30 seconds -> 1h 5m
      expect(EventMetadataFormatter.formatRuntime((1 * 3600 + 5 * 60 + 30) * 1000), '1h 5m');
    });
  });

  group('EventMetadataFormatter.timestampText & dateTooltip', () {
    testWidgets('timestampText shows only time', (tester) async {
      final timestamp = DateTime(2026, 5, 10, 14, 0);

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              final formatted = EventMetadataFormatter.timestampText(timestamp, context);
              expect(formatted, contains('2:00'));
              expect(formatted, isNot(contains('2026')));
              return const SizedBox.shrink();
            },
          ),
        ),
      );
    });

    testWidgets('dateTooltip shows full date for tooltip display', (tester) async {
      final timestamp = DateTime(2026, 5, 8, 14, 0);

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              final tooltip = EventMetadataFormatter.dateTooltip(timestamp, context);
              expect(tooltip, contains('2026'));
              expect(tooltip, contains('8'));
              return const SizedBox.shrink();
            },
          ),
        ),
      );
    });
  });
}
