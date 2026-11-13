import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/domain/models/device_suspended_request.dart';
import 'package:sanad_client/features/notifications/application/notification_action_router.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_action.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_collapse_key.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_deep_link.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_kind.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_payload.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_urgency.dart';

final DateTime _now = DateTime.utc(2026, 1, 1, 12);

DeviceSuspendedRequest _request({String sessionId = 's1', String requestId = 'r1'}) {
  return DeviceSuspendedRequest(
    requestId: requestId,
    sessionId: sessionId,
    toolName: 'shell',
    permissionClass: 'execute',
    scope: 'once',
    workspaceId: 'w1',
    workspaceName: 'repo',
    workspacePath: '/repo',
    toolInput: const <String, dynamic>{'command': 'ls'},
    tool: const <String, dynamic>{'name': 'shell'},
  );
}

NotificationPayload _payload({
  String sessionId = 's1',
  String? requestId = 'r1',
  NotificationKind kind = NotificationKind.permissionRequest,
  DateTime? expiresAt,
}) {
  final collapseKey = NotificationCollapseKey.forAsk(sessionId: sessionId, kind: kind);
  return NotificationPayload(
    eventId: 'evt-1',
    kind: kind,
    urgency: NotificationUrgency.high,
    deepLink: NotificationDeepLink(sessionId: sessionId, requestId: requestId),
    collapseKey: collapseKey,
    notificationId: NotificationCollapseKey.notificationId(collapseKey),
    expiresAt: expiresAt,
  );
}

class _Recorder {
  final List<NotificationPayload> opened = <NotificationPayload>[];
  final List<({DeviceSuspendedRequest request, NotificationActionIntent intent})> responses = [];

  late final NotificationActionRouter router = NotificationActionRouter(
    readPendingAsk: (sessionId) => pending,
    openSession: (payload) async => opened.add(payload),
    respondToAsk: (request, intent, payload) async => responses.add((request: request, intent: intent)),
    clock: () => _now,
  );

  DeviceSuspendedRequest? pending = _request();
}

void main() {
  group('NotificationActionRouter', () {
    test('a click opens the session and sends nothing', () async {
      final recorder = _Recorder();

      final outcome = await recorder.router.handle(_payload(), null);

      expect(outcome, NotificationActionOutcome.opened);
      expect(recorder.opened.single.sessionId, 's1');
      expect(recorder.responses, isEmpty);
    });

    test('an unmappable action id falls back to opening the session', () async {
      final recorder = _Recorder();

      final outcome = await recorder.router.handle(_payload(), '{"session_id":"s1"}');

      expect(outcome, NotificationActionOutcome.opened);
      expect(recorder.responses, isEmpty);
    });

    test('an approval for the pending request is sent through the ask', () async {
      final recorder = _Recorder();

      final outcome = await recorder.router.handle(
        _payload(),
        NotificationAction.allowSessionId,
      );

      expect(outcome, NotificationActionOutcome.responded);
      expect(recorder.responses.single.intent, NotificationActionIntent.allowSession);
      expect(recorder.responses.single.request.requestId, 'r1');
      expect(recorder.opened, isEmpty);
    });

    test('a denial is sent as a denial intent', () async {
      final recorder = _Recorder();

      await recorder.router.handle(_payload(), NotificationAction.denyId);

      expect(recorder.responses.single.intent, NotificationActionIntent.deny);
    });

    test('fails closed when no ask is pending any more', () async {
      final recorder = _Recorder()..pending = null;

      final outcome = await recorder.router.handle(_payload(), NotificationAction.allowOnceId);

      expect(outcome, NotificationActionOutcome.stale);
      expect(recorder.responses, isEmpty);
    });

    test('fails closed when the pending ask is a different request', () async {
      final recorder = _Recorder()..pending = _request(requestId: 'r2');

      final outcome = await recorder.router.handle(_payload(), NotificationAction.allowOnceId);

      expect(outcome, NotificationActionOutcome.stale);
      expect(recorder.responses, isEmpty);
    });

    test('fails closed after the payload expiry', () async {
      final recorder = _Recorder();
      final expired = _payload(expiresAt: _now.subtract(const Duration(seconds: 1)));

      final outcome = await recorder.router.handle(expired, NotificationAction.allowOnceId);

      expect(outcome, NotificationActionOutcome.stale);
      expect(recorder.responses, isEmpty);
    });

    test('never turns an approval into a decision for a non-approval kind', () async {
      final recorder = _Recorder();
      final completed = _payload(kind: NotificationKind.completed, requestId: null);

      final outcome = await recorder.router.handle(completed, NotificationAction.allowOnceId);

      expect(outcome, NotificationActionOutcome.dropped);
      expect(recorder.responses, isEmpty);
      expect(recorder.opened, isEmpty);
    });
  });
}
