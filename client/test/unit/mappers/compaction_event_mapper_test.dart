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
        'retained_tail_tokens': 5000,
      },
    });

    expect(event!.text, 'Auto context compacted');
    expect(event.status, EventStatus.done);
    expect(event.metadata?['compaction_trigger'], 'auto');
    expect(event.metadata?['estimated_request_tokens_before'], 90000);
    expect(event.metadata?['estimated_request_tokens_after'], 25000);
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
  });

  test('history and live mapping share stable logical ids per status', () {
    final payload = {
      'session_id': 'session-1',
      'compaction_id': 'cmp-stable',
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
  });
}
