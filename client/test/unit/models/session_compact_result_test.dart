import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/domain/models/compaction_event_snapshot.dart';

void main() {
  group('SessionCompactResult', () {
    test('parses accepted outcome', () {
      final result = SessionCompactResult.fromJson(const {
        'outcome': 'accepted',
        'compaction_id': 'cmp-1',
      });
      expect(result.accepted, isTrue);
      expect(result.sessionBusy, isFalse);
      expect(result.compactionInProgress, isFalse);
      expect(result.compactionId, 'cmp-1');
    });

    test('detects session busy outcome', () {
      final result = SessionCompactResult.fromJson(const {
        'outcome': 'session_busy',
      });
      expect(result.accepted, isFalse);
      expect(result.sessionBusy, isTrue);
    });

    test('detects compaction in progress outcome', () {
      final result = SessionCompactResult.fromJson(const {
        'outcome': 'compaction_in_progress',
      });
      expect(result.compactionInProgress, isTrue);
    });

    test('defaults unknown payload to failed', () {
      final result = SessionCompactResult.fromJson(const {});
      expect(result.outcome, 'failed');
      expect(result.accepted, isFalse);
    });
  });
}
