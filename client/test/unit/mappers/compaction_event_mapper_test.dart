import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/data/mappers/unified_device_mapper.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';

void main() {
  final mapper = UnifiedDeviceMapper();

  test('maps compaction lifecycle events to informational timeline rows', () {
    final event = mapper.mapLiveEvent({
      'event': 'context_compaction.started',
      'payload': {
        'session_id': 'session-1',
        'compaction_id': 'cmp-1',
        'trigger': 'manual',
        'status': 'started',
        'started_at': '2026-08-29T02:00:00.000Z',
      },
    });

    expect(event, isNotNull);
    expect(event!.kind, EventKind.informational);
    expect(event.status, EventStatus.running);
    expect(event.text, 'Context compacting');
    expect(event.metadata?['compaction_event'], isTrue);
    expect(event.id, 'compaction_cmp-1');
  });

  test('maps auto completed compaction with metrics', () {
    final event = mapper.mapLiveEvent({
      'event': 'context_compaction.completed',
      'payload': {
        'session_id': 'session-1',
        'compaction_id': 'cmp-auto',
        'trigger': 'auto',
        'status': 'completed',
        'started_at': '2026-08-29T02:00:00.000Z',
        'completed_at': '2026-08-29T02:00:02.000Z',
        'context_window_tokens': 128000,
        'estimated_request_tokens_before': 90000,
        'estimated_request_tokens_after': 25000,
        'before_measurement_kind': 'mixed',
        'provider_confirmed_request_tokens_after': 22000,
        'retained_tail_tokens': 5000,
      },
    });

    expect(event!.text, 'Auto context compacted');
    expect(event.status, EventStatus.done);
    expect(event.metadata?['compaction_trigger'], 'auto');
    expect(event.metadata?['estimated_request_tokens_before'], 90000);
    expect(event.metadata?['estimated_request_tokens_after'], 25000);
    expect(event.metadata?['before_measurement_kind'], 'mixed');
    expect(event.metadata?['provider_confirmed_request_tokens_after'], 22000);
    expect(event.contextUsage?.inputTokens, 22000);
    expect(event.contextUsage?.contextWindowTokens, 128000);
    expect(event.contextUsage?.cachedTokens, isNull);
  });

  test('completed compaction falls back to estimated after for context usage', () {
    final before = mapper.mapLiveEvent({
      'event': 'tool_use',
      'payload': {
        'tool': 'search',
        'context_usage': {
          'input_tokens': 136000,
          'cached_tokens': 135000,
          'context_window_tokens': 400000,
        },
      },
    })!;
    final completed = mapper.mapLiveEvent({
      'event': 'context_compaction.completed',
      'payload': {
        'session_id': 'session-1',
        'compaction_id': 'cmp-manual',
        'trigger': 'manual',
        'status': 'completed',
        'completed_at': '2026-08-31T08:30:37.072Z',
        'context_window_tokens': 128000,
        'estimated_request_tokens_after': 8977,
      },
    })!;

    final usage = latestContextUsage([before, completed]);
    expect(usage?.inputTokens, 8977);
    expect(usage?.contextWindowTokens, 400000);
    expect(usage?.cachedTokens, isNull);
  });

  test('maps overflow failed compaction as auto-like terminal error', () {
    final event = mapper.mapLiveEvent({
      'event': 'context_compaction.failed',
      'payload': {
        'session_id': 'session-1',
        'compaction_id': 'cmp-overflow',
        'trigger': 'overflow',
        'status': 'failed',
        'failure_reason': 'continuity_validation_failed',
        'started_at': '2026-08-29T03:00:00.000Z',
        'completed_at': '2026-08-29T03:00:01.000Z',
      },
    });

    expect(event!.text, 'Auto context compaction failed');
    expect(event.status, EventStatus.error);
    expect(event.metadata?['failure_reason'], 'continuity_validation_failed');
    expect(event.contextUsage, isNull);
  });

  test('history and live mapping share stable logical ids per status', () {
    final payload = {
      'session_id': 'session-1',
      'compaction_id': 'cmp-stable',
      'event_id': 'context_compaction:cmp-stable:completed',
      'trigger': 'manual',
      'status': 'completed',
      'started_at': '2026-08-29T04:00:00.000Z',
      'completed_at': '2026-08-29T04:00:03.000Z',
    };

    final live = mapper.mapLiveEvent({
      'event': 'context_compaction.completed',
      'payload': payload,
    });
    final history = mapper.mapHistory([
      {
        'type': 'context_compaction.completed',
        'created_at': '2026-08-29T04:00:03.000Z',
        ...payload,
      },
    ]).single;

    expect(live!.id, history.id);
    expect(live.id, 'compaction_cmp-stable');
    expect(live.eventId, history.eventId);
    expect(live.eventId, 'context_compaction:cmp-stable:completed');
  });

  test('history compaction row restores the post-compaction context usage', () {
    final event = mapper.mapHistory([
      {
        'id': 'context_compaction:cmp-history:completed',
        'type': 'context_compaction.completed',
        'session_id': 'session-1',
        'compaction_id': 'cmp-history',
        'trigger': 'manual',
        'status': 'completed',
        'context_window_tokens': 128000,
        'estimated_request_tokens_after': 8977,
        'completed_at': '2026-08-31T08:30:37.072Z',
        'created_at': '2026-08-31T08:30:37.072Z',
      },
    ]).single;

    expect(event.contextUsage?.inputTokens, 8977);
    expect(event.contextUsage?.contextWindowTokens, 128000);
  });

  // Task 118b D2: after a restart and reopen the tile is rebuilt from the
  // history row, which must keep the threshold the operation row holds.
  test('history and confirmed live rows keep the automatic threshold', () {
    final payload = {
      'session_id': 'session-1',
      'compaction_id': 'cmp-threshold',
      'trigger': 'manual',
      'status': 'completed',
      'context_window_tokens': 1000000,
      'auto_threshold_tokens': 900000,
      'estimated_request_tokens_before': 108235,
      'estimated_request_tokens_after': 54800,
      'provider_confirmed_request_tokens_after': 63687,
      'completed_at': '2026-10-21T18:10:00.000Z',
    };
    final history = mapper.mapHistory([
      {
        'id': 'context_compaction:cmp-threshold:completed',
        'type': 'context_compaction.completed',
        'created_at': '2026-10-21T18:10:00.000Z',
        ...payload,
      },
    ]).single;
    final live = mapper.mapLiveEvent({
      'event': 'context_compaction.completed',
      'payload': payload,
    })!;

    expect(history.metadata?['auto_threshold_tokens'], 900000);
    expect(live.metadata?['auto_threshold_tokens'], 900000);
  });

  test('maps live failure event with failure_stage and failure_cause', () {
    final live = mapper.mapLiveEvent({
      'event': 'context_compaction.failed',
      'payload': {
        'session_id': 'session-1',
        'compaction_id': 'cmp-failed-live',
        'trigger': 'manual',
        'status': 'failed',
        'failure_reason': 'summarization_failed',
        'failure_stage': 'preparation',
        'failure_cause': 'thinking_capability_unsupported',
        'started_at': '2026-08-29T05:00:00.000Z',
        'completed_at': '2026-08-29T05:00:01.000Z',
      },
    });

    expect(live, isNotNull);
    expect(live!.status, EventStatus.error);
    expect(live.metadata?['failure_reason'], 'summarization_failed');
    expect(live.metadata?['failure_stage'], 'preparation');
    expect(live.metadata?['failure_cause'], 'thinking_capability_unsupported');
  });

  test('history hydration and live mapping preserve failure_stage and failure_cause with parity', () {
    final payload = {
      'session_id': 'session-1',
      'compaction_id': 'cmp-parity',
      'event_id': 'context_compaction:cmp-parity:failed',
      'trigger': 'auto',
      'status': 'failed',
      'failure_reason': 'summarization_failed',
      'failure_stage': 'provider',
      'failure_cause': 'timeout',
      'started_at': '2026-08-29T06:00:00.000Z',
      'completed_at': '2026-08-29T06:00:05.000Z',
    };

    final live = mapper.mapLiveEvent({
      'event': 'context_compaction.failed',
      'payload': payload,
    });
    final history = mapper.mapHistory([
      {
        'type': 'context_compaction.failed',
        'created_at': '2026-08-29T06:00:05.000Z',
        ...payload,
      },
    ]).single;

    expect(live!.id, history.id);
    expect(live.eventId, history.eventId);
    expect(live.metadata?['failure_stage'], history.metadata?['failure_stage']);
    expect(live.metadata?['failure_cause'], history.metadata?['failure_cause']);
    expect(live.metadata?['failure_reason'], history.metadata?['failure_reason']);
    expect(history.metadata?['failure_stage'], 'provider');
    expect(history.metadata?['failure_cause'], 'timeout');
  });

  test('history hydration decodes camelCase failureStage and failureCause', () {
    final event = mapper.mapHistory([
      {
        'id': 'context_compaction:cmp-camel:failed',
        'type': 'context_compaction.failed',
        'session_id': 'session-1',
        'compaction_id': 'cmp-camel',
        'trigger': 'overflow',
        'status': 'failed',
        'failureReason': 'summarizationFailed',
        'failureStage': 'pruning',
        'failureCause': 'toolResultMalformed',
        'completed_at': '2026-08-29T07:00:00.000Z',
        'created_at': '2026-08-29T07:00:00.000Z',
      },
    ]).single;

    expect(event.metadata?['failure_stage'], 'pruning');
    expect(event.metadata?['failure_cause'], 'toolResultMalformed');
    expect(event.metadata?['failure_reason'], 'summarizationFailed');
  });
}
