import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/data/mappers/unified_device_mapper.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';
import 'package:sanad_client/features/conversations/domain/stores/canonical_timeline_reconciler.dart';

/// Task 78: an automatic-failover notice renders with the same identity,
/// text, classification and position live and after a history reload.
void main() {
  final mapper = UnifiedDeviceMapper();
  const sessionId = 'session-1';

  // The agent's `session_preferences_updated` payload for the failover.
  const routePayload = {
    'session_id': sessionId,
    'source': 'auto_failover',
    'previous_provider_instance_id': 'provider-a',
    'previous_provider_display_name': 'Provider A',
    'provider_instance_id': 'provider-b',
    'provider_display_name': 'Provider B',
    'model': 'model-x',
    'reason': 'rate_limit',
    'request_id': 'req-1',
    'route_revision': 2,
    'updated_at': '2026-10-21T10:00:20.000Z',
  };

  List<CanonicalEvent> liveTimeline() => [
    for (final event in [
      {
        'event': 'tool_use',
        'payload': {
          'tool': 'search',
          'input': '{}',
          'session_id': sessionId,
          'run_id': 'run-1',
          'model_step_id': 'step-1',
          'tool_call_id': 'call-1',
        },
      },
      {
        'event': 'tool_result',
        'payload': {
          'tool': 'search',
          'output': 'found',
          'session_id': sessionId,
          'run_id': 'run-1',
          'model_step_id': 'step-1',
          'tool_call_id': 'call-1',
          'terminal_at': '2026-10-21T10:00:10.000Z',
        },
      },
      // What ConversationEventHandler maps for an auto-failover confirmation.
      {'event': 'session_route_transition', 'payload': routePayload},
      {
        'event': 'final_answer',
        'payload': {
          'content': 'done',
          'session_id': sessionId,
          'run_id': 'run-1',
          'model_step_id': 'step-2',
        },
      },
    ])
      mapper.mapLiveEvent(event)!,
  ];

  // The rows the agent's history projection emits for the same turn.
  List<CanonicalEvent> historyTimeline() => mapper.mapHistory([
    {
      'id': 'history:$sessionId:2:tool_use:0',
      'sender': 'ai',
      'type': 'tool_use',
      'tool': 'search',
      'input': '{}',
      'session_id': sessionId,
      'run_id': 'run-1',
      'model_step_id': 'step-1',
      'tool_call_id': 'call-1',
      'source_message_row_id': 2,
    },
    {
      'id': 'history:$sessionId:3:tool_result:0',
      'sender': 'ai',
      'type': 'tool_result',
      'tool': 'search',
      'output': 'found',
      'session_id': sessionId,
      'run_id': 'run-1',
      'model_step_id': 'step-1',
      'tool_call_id': 'call-1',
      'terminal_at': '2026-10-21T10:00:10.000Z',
      'source_message_row_id': 3,
    },
    {
      'id': 'evt_7d0b3f2e',
      'event_id': 'evt_7d0b3f2e',
      'sender': 'system',
      'type': 'session_route_transition',
      'content':
          'Switched automatically from Provider A to Provider B because rate '
          'limit. Continuing with model-x.',
      ...routePayload,
      'created_at': '2026-10-21T10:00:20.000Z',
    },
    {
      'id': 'history:$sessionId:4:final_answer:0',
      'sender': 'ai',
      'type': 'final_answer',
      'content': 'done',
      'status': 'done',
      'session_id': sessionId,
      'run_id': 'run-1',
      'model_step_id': 'step-2',
      'source_message_row_id': 4,
    },
  ]);

  List<String> labels(List<CanonicalEvent> events) => [
    for (final event in CanonicalTimelineReconciler.fold(events))
      event.kind == EventKind.informational ? 'info:${event.id}' : event.kind.name,
  ];

  test('reload yields the live order and classification', () {
    expect(labels(historyTimeline()), labels(liveTimeline()));
    expect(labels(liveTimeline()), [
      'toolCall',
      'info:route_${sessionId}_2',
      'finalAnswer',
    ]);
  });

  test('the notice text and source match live and history', () {
    final live = liveTimeline().singleWhere((e) => e.kind == EventKind.informational);
    final history = historyTimeline().singleWhere((e) => e.kind == EventKind.informational);

    expect(history.id, live.id);
    expect(history.text, live.text);
    expect(history.metadata?['source'], live.metadata?['source']);
    expect(history.metadata?['route_revision'], live.metadata?['route_revision']);
  });

  test('merging a live timeline with its reload keeps one notice in place', () {
    final merged = CanonicalTimelineReconciler.mergeAuthoritativeSlice(
      liveTimeline(),
      historyTimeline(),
    );

    expect(labels(merged), labels(liveTimeline()));
  });
}
