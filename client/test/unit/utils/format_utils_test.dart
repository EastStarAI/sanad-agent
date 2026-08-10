import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/utils/format_utils.dart';

void main() {
  group('EventMetadataFormatter.formatRuntime', () {
    test('returns empty string when runtime is not a number', () {
      expect(EventMetadataFormatter.formatRuntime(null), '');
      expect(EventMetadataFormatter.formatRuntime('abc'), '');
    });

    test('formats millisecond durations under 1 second', () {
      expect(EventMetadataFormatter.formatRuntime(250), '250ms');
      expect(EventMetadataFormatter.formatRuntime(999), '999ms');
    });

    test('formats second durations under 1 minute', () {
      expect(EventMetadataFormatter.formatRuntime(1500), '1.5s');
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
}
