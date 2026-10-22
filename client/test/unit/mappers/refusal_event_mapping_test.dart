import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/data/mappers/unified_device_mapper.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';

/// The refusal envelope the daemon publishes is the wire→domain input for the
/// acceptance-wait release (Task 125 G2 round 3). The mapping must keep both
/// the request the refusal answers and its typed reason, otherwise a client
/// cannot tell which waiting send the answer belongs to.
void main() {
  final mapper = UnifiedDeviceMapper();

  test('a refused final answer keeps its request identity and error code', () {
    final canonical = mapper.mapLiveEvent({
      'device_id': 'hardware-1',
      'type': 'event',
      'event': 'final_answer',
      'session_id': 'session-1',
      'run_id': 'run-1',
      'request_id': 'req-refused',
      'event_id': 'evt-1',
      'payload': {
        'session_id': 'session-1',
        'run_id': 'run-1',
        'request_id': 'req-refused',
        'content':
            'Error: turn_failed: Bad state: Workspace folder is unavailable.',
        'error_code': 'turn_failed',
        'status': 'done',
      },
    });

    expect(canonical, isNotNull);
    expect(canonical!.kind, EventKind.finalAnswer);
    expect(canonical.requestId, 'req-refused');
    expect(canonical.metadata?['error_code'], 'turn_failed');
    expect(canonical.sessionId, 'session-1');
  });

  test('an answer that names no request maps no request identity', () {
    final canonical = mapper.mapLiveEvent({
      'type': 'event',
      'event': 'final_answer',
      'session_id': 'session-1',
      'payload': {
        'session_id': 'session-1',
        'content': 'Done.',
        'status': 'done',
      },
    });

    expect(canonical?.requestId, isNull);
    expect(canonical?.metadata?['error_code'], isNull);
  });
}
