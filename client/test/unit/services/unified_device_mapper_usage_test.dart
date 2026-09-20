import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/data/mappers/unified_device_mapper.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';
import 'package:sanad_client/features/conversations/domain/models/llm_usage_snapshot.dart';

void main() {
  test('maps latest context usage and cached input without cache write', () {
    final event = UnifiedDeviceMapper().mapLiveEvent({
      'event': 'tool_use',
      'payload': {
        'session_id': 'session-1',
        'run_id': 'run-1',
        'model_step_id': 'step-1',
        'tool_call_id': 'tool-1',
        'tool': 'search',
        'context_usage': {
          'input_tokens': 194000,
          'output_tokens': 2500,
          'total_tokens': 196500,
          'cached_tokens': 120000,
          'context_window_tokens': 258000,
          'model_id': 'model-1',
        },
      },
    });

    expect(event, isNotNull);
    expect(event!.contextUsage!.inputTokens, 194000);
    expect(event.contextUsage!.cachedTokens, 120000);
    expect(event.contextUsage!.contextWindowTokens, 258000);
    expect(event.contextUsage!.usageFraction, closeTo(194000 / 258000, 0.0001));
  });

  test('latest context usage selects the last available invocation', () {
    final mapper = UnifiedDeviceMapper();
    final events = [
      mapper.mapLiveEvent({
        'event': 'tool_use',
        'payload': {
          'tool': 'first',
          'context_usage': {
            'input_tokens': 100,
            'context_window_tokens': 1000,
          },
        },
      })!,
      mapper.mapLiveEvent({
        'event': 'tool_use',
        'payload': {
          'tool': 'second',
          'context_usage': {
            'input_tokens': 250,
            'context_window_tokens': 1000,
          },
        },
      })!,
    ];

    expect(latestContextUsage(events)!.inputTokens, 250);
  });

  test('history rows restore context usage', () {
    final events = UnifiedDeviceMapper().mapHistory([
      {
        'id': 'answer-1',
        'type': 'final_answer',
        'session_id': 'session-1',
        'content': 'Done',
        'created_at': '2026-07-18T10:00:00Z',
        'context_usage': {
          'input_tokens': 500,
          'cached_tokens': 320,
          'context_window_tokens': 1000,
        },
      },
    ]);

    expect(events.single.contextUsage!.inputTokens, 500);
    expect(events.single.contextUsage!.cachedTokens, 320);
  });

  test('latest usage falls back to completed compaction metadata', () {
    final usage = latestContextUsage([
      CanonicalEvent(
        id: 'old-usage',
        kind: EventKind.finalAnswer,
        timestamp: DateTime.utc(2026, 8, 31, 8, 0),
        contextUsage: const LlmUsageSnapshot(
          inputTokens: 136000,
          cachedTokens: 135000,
          contextWindowTokens: 400000,
          modelId: 'gpt-5.6-sol',
        ),
      ),
      CanonicalEvent(
        id: 'compaction-1',
        kind: EventKind.informational,
        timestamp: DateTime.utc(2026, 8, 31, 8, 30),
        metadata: const {
          'compaction_event': true,
          'compaction_status': 'completed',
          'context_window_tokens': 128000,
          'estimated_request_tokens_after': 8977,
          'model_id': 'gpt-5.6-sol',
        },
      ),
    ]);

    expect(usage?.inputTokens, 8977);
    expect(usage?.contextWindowTokens, 400000);
    expect(usage?.cachedTokens, isNull);
    expect(usage?.modelId, 'gpt-5.6-sol');
  });
}
