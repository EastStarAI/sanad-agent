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

    test('detects session busy outcome in snake_case and camelCase', () {
      final snake = SessionCompactResult.fromJson(const {
        'outcome': 'session_busy',
      });
      expect(snake.accepted, isFalse);
      expect(snake.sessionBusy, isTrue);
      expect(snake.failureReason, 'session_busy');

      final camel = SessionCompactResult.fromJson(const {
        'outcome': 'sessionBusy',
      });
      expect(camel.accepted, isFalse);
      expect(camel.sessionBusy, isTrue);
      expect(camel.failureReason, 'sessionBusy');
    });

    test('detects compaction in progress outcome in snake_case and camelCase', () {
      final snake = SessionCompactResult.fromJson(const {
        'outcome': 'compaction_in_progress',
      });
      expect(snake.compactionInProgress, isTrue);
      expect(snake.failureReason, 'compaction_in_progress');

      final camel = SessionCompactResult.fromJson(const {
        'outcome': 'compactionInProgress',
      });
      expect(camel.compactionInProgress, isTrue);
      expect(camel.failureReason, 'compactionInProgress');
    });

    test('defaults unknown payload to failed and populates failureReason', () {
      final result = SessionCompactResult.fromJson(const {});
      expect(result.outcome, 'failed');
      expect(result.failureReason, 'failed');
      expect(result.accepted, isFalse);
    });

    test('retains explicit failure_reason when provided', () {
      final result = SessionCompactResult.fromJson(const {
        'outcome': 'failed',
        'failure_reason': 'source_revision_stale',
      });
      expect(result.accepted, isFalse);
      expect(result.failureReason, 'source_revision_stale');
    });

    test('parses failure_stage and failure_cause in snake_case and camelCase', () {
      final snake = SessionCompactResult.fromJson(const {
        'outcome': 'failed',
        'failure_reason': 'summarization_failed',
        'failure_stage': 'preparation',
        'failure_cause': 'thinking_capability_unsupported',
      });
      expect(snake.failureStage, 'preparation');
      expect(snake.failureCause, 'thinking_capability_unsupported');

      final camel = SessionCompactResult.fromJson(const {
        'outcome': 'failed',
        'failureReason': 'summarizationFailed',
        'failureStage': 'pruning',
        'failureCause': 'toolResultMalformed',
      });
      expect(camel.failureStage, 'pruning');
      expect(camel.failureCause, 'toolResultMalformed');
    });

    test('detects busy and in_progress from failure_cause in claim rejections', () {
      final busyCause = SessionCompactResult.fromJson(const {
        'outcome': 'failed',
        'failure_cause': 'session_busy',
      });
      expect(busyCause.sessionBusy, isTrue);

      final progressCause = SessionCompactResult.fromJson(const {
        'outcome': 'failed',
        'failureCause': 'compactionInProgress',
      });
      expect(progressCause.compactionInProgress, isTrue);
    });
  });
}
