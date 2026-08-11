import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/sidebar/sidebar_conversation_row.dart';

void main() {
  group('formatCompactRelativeTime', () {
    test('formats recent timestamp as now', () {
      final now = DateTime.now();
      expect(formatCompactRelativeTime(now), 'now');
      expect(formatCompactRelativeTime(now.subtract(const Duration(seconds: 5))), 'now');
    });

    test('formats seconds', () {
      final now = DateTime.now();
      expect(formatCompactRelativeTime(now.subtract(const Duration(seconds: 30))), '30s');
      expect(formatCompactRelativeTime(now.subtract(const Duration(seconds: 59))), '59s');
    });

    test('formats minutes', () {
      final now = DateTime.now();
      expect(formatCompactRelativeTime(now.subtract(const Duration(minutes: 1))), '1m');
      expect(formatCompactRelativeTime(now.subtract(const Duration(minutes: 45))), '45m');
    });

    test('formats hours', () {
      final now = DateTime.now();
      expect(formatCompactRelativeTime(now.subtract(const Duration(hours: 1))), '1h');
      expect(formatCompactRelativeTime(now.subtract(const Duration(hours: 23))), '23h');
    });

    test('formats days', () {
      final now = DateTime.now();
      expect(formatCompactRelativeTime(now.subtract(const Duration(days: 1))), '1d');
      expect(formatCompactRelativeTime(now.subtract(const Duration(days: 6))), '6d');
    });

    test('formats weeks', () {
      final now = DateTime.now();
      expect(formatCompactRelativeTime(now.subtract(const Duration(days: 7))), '1w');
      expect(formatCompactRelativeTime(now.subtract(const Duration(days: 21))), '3w');
    });

    test('formats months and years', () {
      final now = DateTime.now();
      expect(formatCompactRelativeTime(now.subtract(const Duration(days: 60))), '2mo');
      expect(formatCompactRelativeTime(now.subtract(const Duration(days: 400))), '1y');
    });
  });
}
