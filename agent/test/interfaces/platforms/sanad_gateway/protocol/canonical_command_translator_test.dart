import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_command_translator.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';
import 'package:test/test.dart';

void main() {
  group('CanonicalCommandTranslator', () {
    test('translates secrets.list into a payload canonical event', () {
      final event = CanonicalCommandTranslator.translate({
        'command': CanonicalEventTypes.secretsList,
        'payload': {'request_id': 'req-list-1'},
      });

      expect(event, isNotNull);
      expect(event!.type, CanonicalEventTypes.secretsList);
      expect(event.payload['request_id'], 'req-list-1');
    });

    test('translates secret.set into a payload canonical event', () {
      final event = CanonicalCommandTranslator.translate({
        'command': CanonicalEventTypes.secretSet,
        'payload': {
          'request_id': 'req-set-1',
          'name': 'API_KEY',
          'value': 'val-123',
          'description': 'test key',
        },
      });

      expect(event, isNotNull);
      expect(event!.type, CanonicalEventTypes.secretSet);
      expect(event.payload['name'], 'API_KEY');
      expect(event.payload['value'], 'val-123');
      expect(event.payload['description'], 'test key');
    });

    test('translates secret.delete into a payload canonical event', () {
      final event = CanonicalCommandTranslator.translate({
        'command': CanonicalEventTypes.secretDelete,
        'payload': {
          'request_id': 'req-del-1',
          'name': 'API_KEY',
          'confirm': true,
        },
      });

      expect(event, isNotNull);
      expect(event!.type, CanonicalEventTypes.secretDelete);
      expect(event.payload['name'], 'API_KEY');
      expect(event.payload['confirm'], isTrue);
    });

    test('returns null for unhandled commands', () {
      final event = CanonicalCommandTranslator.translate({
        'command': 'secret.get',
        'payload': {'name': 'API_KEY'},
      });

      expect(event, isNull);
    });

    test('translates every schedule command into a payload canonical event',
        () {
      const commands = [
        CanonicalEventTypes.scheduleList,
        CanonicalEventTypes.schedulePreview,
        CanonicalEventTypes.scheduleCreate,
        CanonicalEventTypes.scheduleUpdate,
        CanonicalEventTypes.schedulePause,
        CanonicalEventTypes.scheduleResume,
        CanonicalEventTypes.scheduleRunNow,
        CanonicalEventTypes.scheduleDelete,
        CanonicalEventTypes.scheduleRuns,
      ];

      for (final command in commands) {
        final event = CanonicalCommandTranslator.translate({
          'command': command,
          'payload': {'request_id': 'req-1', 'id': 'task_1'},
        });

        expect(event, isNotNull, reason: command);
        expect(event!.type, command);
        expect(event.payload['request_id'], 'req-1');
        expect(event.payload['id'], 'task_1');
      }
    });

    test('keeps schedule run history off the unsupported list', () {
      final event = CanonicalCommandTranslator.translate({
        'command': 'schedule.unknown',
        'payload': {'schedule_id': 'task_1'},
      });

      expect(event, isNull);
    });
  });
}
