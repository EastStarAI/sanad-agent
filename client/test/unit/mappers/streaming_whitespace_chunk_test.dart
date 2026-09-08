import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/data/mappers/unified_device_mapper.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';

void main() {
  group('UnifiedDeviceMapper streaming whitespace preservation', () {
    final mapper = UnifiedDeviceMapper();

    test('preserves whitespace-only chunks in thought_stream (newlines and spaces)', () {
      final newlineEvent = mapper.mapLiveEvent({
        'event': 'thought_stream',
        'payload': {
          'session_id': 'session-1',
          'run_id': 'run-1',
          'model_step_id': 'step-1',
          'content': '\n\n',
        },
      });

      expect(newlineEvent, isNotNull);
      expect(newlineEvent!.kind, EventKind.thinking);
      expect(newlineEvent.text, '\n\n');

      final spaceEvent = mapper.mapLiveEvent({
        'event': 'thought_stream',
        'payload': {
          'session_id': 'session-1',
          'run_id': 'run-1',
          'model_step_id': 'step-1',
          'content': ' ',
        },
      });

      expect(spaceEvent, isNotNull);
      expect(spaceEvent!.kind, EventKind.thinking);
      expect(spaceEvent.text, ' ');
    });

    test('drops truly empty string chunks with length zero', () {
      final emptyEvent = mapper.mapLiveEvent({
        'event': 'thought_stream',
        'payload': {
          'session_id': 'session-1',
          'run_id': 'run-1',
          'model_step_id': 'step-1',
          'content': '',
        },
      });

      expect(emptyEvent, isNull);
    });

    test('preserves whitespace-only chunks in reasoning_stream', () {
      final reasoningEvent = mapper.mapLiveEvent({
        'event': 'reasoning_stream',
        'payload': {
          'session_id': 'session-1',
          'run_id': 'run-1',
          'model_step_id': 'step-1',
          'content': '\n',
        },
      });

      expect(reasoningEvent, isNotNull);
      expect(reasoningEvent!.kind, EventKind.reasoning);
      expect(reasoningEvent.text, '\n');
    });
  });
}
