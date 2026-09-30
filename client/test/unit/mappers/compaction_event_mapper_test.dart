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
}
