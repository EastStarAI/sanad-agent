import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/domain/models/device_suspended_request.dart';
import 'package:sanad_client/features/notifications/application/notification_action_router.dart';
import 'package:sanad_client/features/notifications/application/notification_service.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_action.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_copy.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_kind.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_payload.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_permission_status.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_platform_adapter.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_preferences.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_presence.dart';
import 'package:sanad_client/features/notifications/domain/services/notification_quiet_window.dart';

/// Records what the operating system was actually asked to present.
class _FakeAdapter implements NotificationPlatformAdapter {
  _FakeAdapter();

  final List<NotificationPresentationRequest> shown = <NotificationPresentationRequest>[];
  final List<int> cancelled = <int>[];
  NotificationPermissionStatus permission = NotificationPermissionStatus.granted;
  bool initialized = false;
  NotificationPlatformResponseCallback? onResponse;

  @override
  bool get isSupported => true;

  @override
  bool get supportsApprovalActions => true;

  @override
  bool get canOpenSystemSettings => false;

  @override
  Future<void> initialize({
    NotificationPlatformResponseCallback? onResponse,
    Map<NotificationActionIntent, String> approvalActionLabels =
        const <NotificationActionIntent, String>{},
    Map<NotificationKind, String> kindLabels = const <NotificationKind, String>{},
  }) async {
    initialized = true;
    this.onResponse = onResponse;
  }

  @override
  Future<NotificationPermissionStatus> checkPermission() async => permission;

  @override
  Future<NotificationPermissionStatus> requestPermission() async => permission;

  @override
  Future<void> show(NotificationPresentationRequest request) async => shown.add(request);

  @override
  Future<bool> cancel(int notificationId) async {
    cancelled.add(notificationId);
    return true;
  }

  @override
  Future<void> cancelAll() async {}

  @override
  Future<bool> openSystemSettings() async => false;

  @override
  Future<void> dispose() async {}
}

/// The pipeline under test never routes an interaction; the action tests own
/// that path with their own recorder.
NotificationActionRouter _idleActionRouter(DateTime Function() clock) {
  return NotificationActionRouter(
    readPendingAsk: (String sessionId) => null,
    openSession: (payload) async {},
    respondToAsk: (DeviceSuspendedRequest request, NotificationActionIntent intent, NotificationPayload payload) async {},
    clock: clock,
  );
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

Map<String, dynamic> _ask({
  String eventId = 'evt-1',
  String sessionId = 's1',
  String requestId = 'r1',
  String? name = 'notification',
}) {
  return <String, dynamic>{
    'type': 'device_event',
    'event': name,
    'event_id': eventId,
    'session_id': sessionId,
    'request_id': requestId,
    'payload': <String, dynamic>{
      'kind': 'permission_request',
      'urgency': 'high',
      'title': 'Approve the command?',
      'body': 'shell wants to run ls',
      'deep_link': <String, dynamic>{'session_id': sessionId, 'request_id': requestId},
    },
  };
}

/// The existing canonical ask event. It never raises a notification by itself;
/// it is what makes the Client consider the request answerable.
Map<String, dynamic> _permissionRequest({
  String eventId = 'evt-ask',
  String sessionId = 's1',
  String requestId = 'r1',
}) {
  return <String, dynamic>{
    'type': 'device_event',
    'event': 'tool_permission_request',
    'event_id': eventId,
    'session_id': sessionId,
    'request_id': requestId,
    'payload': <String, dynamic>{
      'request_id': requestId,
      'session_id': sessionId,
      'tool_name': 'shell',
      'permission_class': 'execute',
      'scope': 'once',
    },
  };
}

class _Harness extends StatefulWidget {
  const _Harness({required this.build, required this.onService});

  final NotificationService Function() build;
  final void Function(NotificationService service) onService;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  late final NotificationService _service = widget.build();

  @override
  void initState() {
    super.initState();
    widget.onService(_service);
    unawaited(_service.start());
  }

  @override
  void dispose() {
    unawaited(_service.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

void main() {
  late _FakeAdapter adapter;
  late NotificationService service;
  late NotificationPresence presence;
  late NotificationPreferences preferences;
  late NotificationPermissionStatus permission;
  late DateTime now;

  Future<void> mount(WidgetTester tester) async {
    now = DateTime.utc(2026, 1, 1, 12);
    presence = NotificationPresence.none;
    preferences = const NotificationPreferences();
    permission = NotificationPermissionStatus.granted;
    adapter = _FakeAdapter();
    final events = StreamController<Map<String, dynamic>>.broadcast();
    addTearDown(events.close);

    await tester.pumpWidget(
      _Harness(
        build: () => NotificationService(
          adapter: adapter,
          eventStreams: <Stream<Map<String, dynamic>>>[events.stream],
          copyResolver: (NotificationKind kind) => _copy,
          readPreferences: () => preferences,
          readPermission: () => permission,
          readPresence: () => presence,
          readApprovalActionLabels: () => _copy.actionLabels,
          actionRouter: _idleActionRouter(() => now),
          // A long window keeps the decision independent of wall-clock timing;
          // the quiet-window and expiry tests drive these values themselves.
          quietWindow: NotificationQuietWindow(
            duration: Duration.zero,
            clock: () => now,
          ),
          clock: () => now,
        ),
        onService: (value) => service = value,
      ),
    );
    await tester.pump();
    expect(adapter.initialized, isTrue, reason: 'the bridge initializes the platform adapter');
  }

  group('notification display matrix', () {
    testWidgets('raises one OS notification while the window is hidden', (tester) async {
      await mount(tester);

      final decision = await service.handleEvent(_ask());

      expect(decision!.outcome.name, 'display');
      expect(adapter.shown, hasLength(1));
      expect(adapter.shown.single.title, 'Approve the command?');
      expect(adapter.shown.single.body, 'shell wants to run ls');
    });

    testWidgets('suppresses the ask that is already on screen', (tester) async {
      await mount(tester);
      presence = const NotificationPresence(
        windowVisible: true,
        deviceId: 'd1',
        sessionId: 's1',
        requestId: 'r1',
      );

      final decision = await service.handleEvent(_ask());

      expect(decision!.outcome.name, 'suppressedOnScreen');
      expect(adapter.shown, isEmpty);
    });

    testWidgets('raises when the focused window shows a different session', (tester) async {
      await mount(tester);
      presence = const NotificationPresence(
        windowVisible: true,
        deviceId: 'd1',
        sessionId: 'another-session',
      );

      final decision = await service.handleEvent(_ask());

      expect(decision!.outcome.name, 'display');
      expect(adapter.shown, hasLength(1));
    });

    testWidgets('raises even when the selected session is hidden in the tray', (tester) async {
      await mount(tester);
      presence = const NotificationPresence(
        windowVisible: false,
        deviceId: 'd1',
        sessionId: 's1',
        requestId: 'r1',
      );

      final decision = await service.handleEvent(_ask());

      expect(decision!.outcome.name, 'display');
      expect(adapter.shown, hasLength(1));
    });

    testWidgets('deduplicates the same event delivered over both routes', (tester) async {
      await mount(tester);

      final first = await service.handleEvent(_ask());
      // The cloud copy carries the same canonical event id.
      final second = await service.handleEvent(_ask());

      expect(first!.outcome.name, 'display');
      expect(second!.outcome.name, 'dropDuplicate');
      expect(adapter.shown, hasLength(1));
    });

    testWidgets('replaces rather than stacks a repeated ask in one session', (tester) async {
      await mount(tester);

      await service.handleEvent(_ask(eventId: 'evt-1', requestId: 'r1'));
      await service.handleEvent(_ask(eventId: 'evt-2', requestId: 'r2'));

      expect(adapter.shown, hasLength(2));
      expect(
        adapter.shown.first.id,
        adapter.shown.last.id,
        reason: 'session + kind collapses to one OS notification id',
      );
    });

    testWidgets('suppresses a replay restored by a reconnect', (tester) async {
      await mount(tester);
      final events = NotificationQuietWindow(
        duration: const Duration(seconds: 10),
        clock: () => now,
      );
      final replayService = NotificationService(
        adapter: adapter,
        eventStreams: const <Stream<Map<String, dynamic>>>[],
        copyResolver: (NotificationKind kind) => _copy,
        readPreferences: () => preferences,
        readPermission: () => permission,
        readPresence: () => presence,
        actionRouter: _idleActionRouter(() => now),
        quietWindow: events,
        clock: () => now,
      );
      addTearDown(replayService.dispose);

      replayService.onTransportConnected();
      final decision = await replayService.handleEvent(_ask(eventId: 'replayed-ask'));

      expect(decision!.outcome.name, 'suppressedQuietWindow');
      expect(adapter.shown, isEmpty);
    });

    testWidgets('raises a genuinely new ask after the quiet window closes', (tester) async {
      await mount(tester);
      final window = NotificationQuietWindow(
        duration: const Duration(seconds: 10),
        clock: () => now,
      );
      final replayService = NotificationService(
        adapter: adapter,
        eventStreams: const <Stream<Map<String, dynamic>>>[],
        copyResolver: (NotificationKind kind) => _copy,
        readPreferences: () => preferences,
        readPermission: () => permission,
        readPresence: () => presence,
        actionRouter: _idleActionRouter(() => now),
        quietWindow: window,
        clock: () => now,
      );
      addTearDown(replayService.dispose);

      replayService.onTransportConnected();
      now = now.add(const Duration(seconds: 11));
      final decision = await replayService.handleEvent(_ask(eventId: 'fresh-ask'));

      expect(decision!.outcome.name, 'display');
      expect(adapter.shown, hasLength(1));
    });

    testWidgets('withdraws the ask notification once the request resolves', (tester) async {
      await mount(tester);
      await service.handleEvent(_permissionRequest());
      final decision = await service.handleEvent(_ask());
      expect(decision!.outcome.name, 'display');
      final presentedId = adapter.shown.single.id;

      await service.handleEvent(<String, dynamic>{
        'type': 'device_event',
        'event': 'tool_permission_resolved',
        'event_id': 'evt-resolved',
        'session_id': 's1',
        'request_id': 'r1',
        'payload': <String, dynamic>{'request_id': 'r1', 'session_id': 's1'},
      });

      expect(adapter.cancelled, <int>[presentedId]);
    });

    testWidgets('an approval pressed on the notification reaches the ask responder',
        (tester) async {
      await mount(tester);
      // The action path is wired exactly as the bridge wires it: the router
      // answers through the pending ask, never from the notification payload.
      final responses = <NotificationActionIntent>[];
      DeviceSuspendedRequest? pending;
      final router = NotificationActionRouter(
        readPendingAsk: (sessionId) => pending?.sessionId == sessionId ? pending : null,
        openSession: (payload) async {},
        respondToAsk: (request, intent, payload) async => responses.add(intent),
        clock: () => DateTime.utc(2026, 1, 1, 12),
      );
      final events = StreamController<Map<String, dynamic>>.broadcast();
      addTearDown(events.close);
      final actionService = NotificationService(
        adapter: adapter,
        eventStreams: <Stream<Map<String, dynamic>>>[events.stream],
        copyResolver: (NotificationKind kind) => _copy,
        readPreferences: () => preferences,
        readPermission: () => permission,
        readPresence: () => presence,
        actionRouter: router,
        quietWindow: NotificationQuietWindow(duration: Duration.zero, clock: () => now),
        clock: () => now,
      );
      addTearDown(actionService.dispose);
      await actionService.start();
      await actionService.handleEvent(_permissionRequest());
      pending = DeviceSuspendedRequest.fromJson(<String, dynamic>{
        'request_id': 'r1',
        'session_id': 's1',
        'tool_name': 'shell',
        'permission_class': 'execute',
        'scope': 'once',
      });
      await actionService.handleEvent(_ask());
      final presented = adapter.shown.single;

      adapter.onResponse!(
        NotificationPlatformResponse(
          payload: presented.payload,
          actionId: NotificationAction.allowOnceId,
        ),
      );
      await tester.pump();

      expect(responses, <NotificationActionIntent>[NotificationActionIntent.allowOnce]);
    });

    testWidgets('an approval with no pending ask sends nothing', (tester) async {
      await mount(tester);
      final responses = <NotificationActionIntent>[];
      final router = NotificationActionRouter(
        readPendingAsk: (sessionId) => null,
        openSession: (payload) async {},
        respondToAsk: (request, intent, payload) async => responses.add(intent),
        clock: () => now,
      );
      final events = StreamController<Map<String, dynamic>>.broadcast();
      addTearDown(events.close);
      final staleService = NotificationService(
        adapter: adapter,
        eventStreams: <Stream<Map<String, dynamic>>>[events.stream],
        copyResolver: (NotificationKind kind) => _copy,
        readPreferences: () => preferences,
        readPermission: () => permission,
        readPresence: () => presence,
        actionRouter: router,
        quietWindow: NotificationQuietWindow(duration: Duration.zero, clock: () => now),
        clock: () => now,
      );
      addTearDown(staleService.dispose);
      await staleService.start();
      await staleService.handleEvent(_ask());
      final presented = adapter.shown.single;

      adapter.onResponse!(
        NotificationPlatformResponse(payload: presented.payload, actionId: NotificationAction.denyId),
      );
      await tester.pump();

      expect(responses, isEmpty);
    });

    testWidgets('does not raise anything after the service is disposed', (tester) async {
      await mount(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();

      final decision = await service.handleEvent(_ask());

      expect(decision, isNull);
      expect(adapter.shown, isEmpty);
    });
  });
}
