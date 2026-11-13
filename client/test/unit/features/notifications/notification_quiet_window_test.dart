import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/notifications/domain/services/notification_quiet_window.dart';

void main() {
  group('NotificationQuietWindow', () {
    test('is closed until a connect arms it', () {
      final window = NotificationQuietWindow(clock: () => DateTime.utc(2026, 1, 1));

      expect(window.isOpen, isFalse);
      expect(window.remaining, Duration.zero);
    });

    test('open after arming and closed once the duration elapses', () {
      var now = DateTime.utc(2026, 1, 1, 12);
      final window = NotificationQuietWindow(
        duration: const Duration(seconds: 10),
        clock: () => now,
      );

      window.arm();
      expect(window.isOpen, isTrue);
      expect(window.remaining, const Duration(seconds: 10));

      now = now.add(const Duration(seconds: 9, milliseconds: 999));
      expect(window.isOpen, isTrue);

      now = now.add(const Duration(milliseconds: 1));
      expect(window.isOpen, isFalse);
      expect(window.remaining, Duration.zero);
    });

    test('a second connect restarts the window', () {
      var now = DateTime.utc(2026, 1, 1, 12);
      final window = NotificationQuietWindow(
        duration: const Duration(seconds: 10),
        clock: () => now,
      );

      window.arm();
      now = now.add(const Duration(seconds: 8));
      window.arm();
      now = now.add(const Duration(seconds: 8));

      expect(window.isOpen, isTrue, reason: 'the replay window restarted at the second connect');
      now = now.add(const Duration(seconds: 3));
      expect(window.isOpen, isFalse);
    });

    test('clear closes an open window', () {
      final window = NotificationQuietWindow(
        duration: const Duration(seconds: 10),
        clock: () => DateTime.utc(2026, 1, 1, 12),
      );

      window.arm();
      expect(window.isOpen, isTrue);
      window.clear();
      expect(window.isOpen, isFalse);
    });
  });
}
