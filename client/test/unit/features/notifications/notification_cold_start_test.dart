import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/domain/models/device_suspended_request.dart';
import 'package:sanad_client/features/notifications/application/notification_action_router.dart';
import 'package:sanad_client/features/notifications/application/notification_service.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_action.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_copy.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_deep_link.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_kind.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_payload.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_permission_status.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_platform_adapter.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_preferences.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_presence.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_urgency.dart';
import 'package:sanad_client/features/notifications/domain/services/notification_quiet_window.dart';

/// A platform that reports the interaction which started the process.
class _LaunchAdapter implements NotificationPlatformAdapter {
  _LaunchAdapter({this.launch, this.failsToRead = false});

  NotificationPlatformResponse? launch;
  final bool failsToRead;
  final List<String> calls = <String>[];
  final List<NotificationPresentationRequest> shown = <NotificationPresentationRequest>[];
  NotificationPlatformResponseCallback? onResponse;

  @override
  bool get isSupported => true;

  @override
  bool get supportsApprovalActions => true;

  @override
  Future<void> initialize({
    NotificationPlatformResponseCallback? onResponse,
    Map<NotificationActionIntent, String> approvalActionLabels =
        const <NotificationActionIntent, String>{},
  }) async {
    calls.add('initialize');
    this.onResponse = onResponse;
  }

  @override
  Future<NotificationPermissionStatus> checkPermission() async =>
      NotificationPermissionStatus.granted;

  @override
  Future<NotificationPermissionStatus> requestPermission() async =>
      NotificationPermissionStatus.granted;

  @override
  Future<NotificationPlatformResponse?> readLaunchResponse() async {
    calls.add('launch');
    if (failsToRead) throw StateError('launch details unavailable');
    return launch;
  }

  @override
  Future<void> show(NotificationPresentationRequest request) async => shown.add(request);

  @override
  Future<bool> cancel(int notificationId) async => true;

  @override
  Future<void> cancelAll() async {}

  @override
  Future<bool> openSystemSettings() async => false;

  @override
  Future<void> dispose() async {}
}

final NotificationCopy _copy = NotificationCopy(
  title: 'Fallback title',
  body: 'Fallback body',
  actionLabels: <NotificationActionIntent, String>{
    NotificationActionIntent.allowOnce: 'Allow once',
    NotificationActionIntent.allowSession: 'Allow for this session',
    NotificationActionIntent.deny: 'Deny',
    NotificationActionIntent.open: 'Open',
  },
);

final NotificationPayload _askPayload = NotificationPayload(
  eventId: 'evt-1',
  kind: NotificationKind.permissionRequest,
  urgency: NotificationUrgency.high,
  deepLink: const NotificationDeepLink(sessionId: 's1', requestId: 'r1'),
  collapseKey: 's1:permission_request',
  notificationId: 1,
  title: 'Approve the command?',
  body: 'shell wants to run ls',
  actions: NotificationAction.approvalActions,
);

NotificationPlatformResponse _launchResponse({
  String actionId = NotificationAction.allowOnceId,
  bool readablePayload = true,
}) {
  return NotificationPlatformResponse(
    payload: readablePayload ? jsonEncode(_askPayload.toPresentationPayload()) : 'not json',
    actionId: actionId,
  );
}

/// Records everything the Client could have done with a launch interaction.
class _Recorder {
  DeviceSuspendedRequest? pending;
  final List<NotificationActionIntent> responses = <NotificationActionIntent>[];
  final List<NotificationPayload> opened = <NotificationPayload>[];

  NotificationActionRouter get router => NotificationActionRouter(
        readPendingAsk: (String sessionId) => pending?.sessionId == sessionId ? pending : null,
        openSession: (payload) async => opened.add(payload),
        respondToAsk: (request, intent, payload) async => responses.add(intent),
        clock: () => DateTime.utc(2026, 1, 1, 12),
      );
}

NotificationService _service(_LaunchAdapter adapter, _Recorder recorder) {
  return NotificationService(
    adapter: adapter,
    eventStreams: const <Stream<Map<String, dynamic>>>[],
    copyResolver: (NotificationKind kind) => _copy,
    readPreferences: () => const NotificationPreferences(),
    readPermission: () => NotificationPermissionStatus.granted,
    readPresence: () => NotificationPresence.none,
    actionRouter: recorder.router,
    quietWindow: NotificationQuietWindow(
      duration: Duration.zero,
      clock: () => DateTime.utc(2026, 1, 1, 12),
    ),
    clock: () => DateTime.utc(2026, 1, 1, 12),
  );
}

void main() {
  group('cold-start notification interaction', () {
    test('an approval that started the process is recorded and never answered', () async {
      final adapter = _LaunchAdapter(launch: _launchResponse());
      final recorder = _Recorder();
      final service = _service(adapter, recorder);
      addTearDown(service.dispose);

      await service.start();

      expect(service.coldStartOutcome, NotificationColdStartOutcome.dropped);
      // The launch is read only after the platform channel exists.
      expect(adapter.calls, <String>['initialize', 'launch']);
      // Fail closed: no response, no navigation, no answer built from the payload.
      expect(recorder.responses, isEmpty);
      expect(recorder.opened, isEmpty);
      expect(adapter.shown, isEmpty);
      expect(service.presentedCount, 0);
    });

    test('a click that started the process does not navigate without replayed state',
        () async {
      final adapter = _LaunchAdapter(
        launch: _launchResponse(actionId: NotificationAction.openId),
      );
      final recorder = _Recorder();
      final service = _service(adapter, recorder);
      addTearDown(service.dispose);

      await service.start();

      expect(service.coldStartOutcome, NotificationColdStartOutcome.dropped);
      expect(recorder.opened, isEmpty);
      expect(recorder.responses, isEmpty);
    });

    test('an unreadable launch payload is recorded as unreadable', () async {
      final adapter = _LaunchAdapter(launch: _launchResponse(readablePayload: false));
      final recorder = _Recorder();
      final service = _service(adapter, recorder);
      addTearDown(service.dispose);

      await service.start();

      expect(service.coldStartOutcome, NotificationColdStartOutcome.unreadable);
      expect(recorder.opened, isEmpty);
      expect(recorder.responses, isEmpty);
    });

    test('no launch interaction leaves the outcome none', () async {
      final adapter = _LaunchAdapter();
      final recorder = _Recorder();
      final service = _service(adapter, recorder);
      addTearDown(service.dispose);

      await service.start();

      expect(service.coldStartOutcome, NotificationColdStartOutcome.none);
      expect(recorder.opened, isEmpty);
      expect(recorder.responses, isEmpty);
    });

    test('a platform that cannot report launch details fails closed', () async {
      final adapter = _LaunchAdapter(failsToRead: true);
      final recorder = _Recorder();
      final service = _service(adapter, recorder);
      addTearDown(service.dispose);

      await service.start();

      expect(service.coldStartOutcome, NotificationColdStartOutcome.none);
      expect(recorder.responses, isEmpty);
    });

    test('a live interaction still routes normally after a dropped launch interaction',
        () async {
      final adapter = _LaunchAdapter(launch: _launchResponse());
      final recorder = _Recorder();
      final service = _service(adapter, recorder);
      addTearDown(service.dispose);
      await service.start();

      // The reconnect replay that arrives after startup is what makes an ask
      // answerable; from then on the same notification path is live.
      await service.handleEvent(<String, dynamic>{
        'type': 'device_event',
        'event': 'tool_permission_request',
        'event_id': 'evt-ask',
        'session_id': 's1',
        'request_id': 'r1',
        'payload': <String, dynamic>{
          'request_id': 'r1',
          'session_id': 's1',
          'tool_name': 'shell',
          'permission_class': 'execute',
          'scope': 'once',
        },
      });
      recorder.pending = DeviceSuspendedRequest.fromJson(<String, dynamic>{
        'request_id': 'r1',
        'session_id': 's1',
        'tool_name': 'shell',
        'permission_class': 'execute',
        'scope': 'once',
      });
      await service.handleEvent(<String, dynamic>{
        'type': 'device_event',
        'event': 'notification',
        'event_id': 'evt-1',
        'session_id': 's1',
        'request_id': 'r1',
        'payload': <String, dynamic>{
          'kind': 'permission_request',
          'urgency': 'high',
          'title': 'Approve the command?',
          'body': 'shell wants to run ls',
        },
      });
      final presented = adapter.shown.single;

      adapter.onResponse!(
        NotificationPlatformResponse(
          payload: presented.payload,
          actionId: NotificationAction.allowSessionId,
        ),
      );
      // The router's response is asynchronous behind the platform callback.
      await Future<void>.delayed(Duration.zero);

      expect(recorder.responses, <NotificationActionIntent>[NotificationActionIntent.allowSession]);
    });
  });
}
