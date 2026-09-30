import 'package:flutter/material.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/sidebar/sidebar_conversation_row.dart';

void main() {
  group('formatCompactRelativeTime', () {
    test('formats recent timestamp as now', () {
      final now = DateTime.now();
      expect(formatCompactRelativeTime(now, localeOverride: const Locale('en')), 'now');
      expect(formatCompactRelativeTime(now.subtract(const Duration(seconds: 5)), localeOverride: const Locale('en')), 'now');
    });

    test('formats seconds', () {
      final now = DateTime.now();
      expect(formatCompactRelativeTime(now.subtract(const Duration(seconds: 30)), localeOverride: const Locale('en')), '30s');
      expect(formatCompactRelativeTime(now.subtract(const Duration(seconds: 59)), localeOverride: const Locale('en')), '59s');
    });

    test('formats minutes', () {
      final now = DateTime.now();
      expect(formatCompactRelativeTime(now.subtract(const Duration(minutes: 1)), localeOverride: const Locale('en')), '1m');
      expect(formatCompactRelativeTime(now.subtract(const Duration(minutes: 45)), localeOverride: const Locale('en')), '45m');
    });

    test('formats hours', () {
      final now = DateTime.now();
      expect(formatCompactRelativeTime(now.subtract(const Duration(hours: 1)), localeOverride: const Locale('en')), '1h');
      expect(formatCompactRelativeTime(now.subtract(const Duration(hours: 23)), localeOverride: const Locale('en')), '23h');
    });

    test('formats days', () {
      final now = DateTime.now();
      expect(formatCompactRelativeTime(now.subtract(const Duration(days: 1)), localeOverride: const Locale('en')), '1d');
      expect(formatCompactRelativeTime(now.subtract(const Duration(days: 6)), localeOverride: const Locale('en')), '6d');
    });

    test('formats weeks', () {
      final now = DateTime.now();
      expect(formatCompactRelativeTime(now.subtract(const Duration(days: 7)), localeOverride: const Locale('en')), '1w');
      expect(formatCompactRelativeTime(now.subtract(const Duration(days: 21)), localeOverride: const Locale('en')), '3w');
    });

    test('formats months and years', () {
      final now = DateTime.now();
      expect(formatCompactRelativeTime(now.subtract(const Duration(days: 60)), localeOverride: const Locale('en')), '2mo');
      expect(formatCompactRelativeTime(now.subtract(const Duration(days: 400)), localeOverride: const Locale('en')), '1y');
    });
  });
}
