// Plan 174g (M2) — a language change must reach the OS action label.
//
// Linux builds the freedesktop action array per notification, but the Client
// used to pass no default-action name at all, so the plugin kept the copy it
// registered at `initialize`. Switching to Arabic mid-session therefore left an
// English `Open` on an otherwise Arabic notification until the next launch.
//
// These tests prove the label is resolved per presentation from the language in
// use, and that a request without one keeps the registered copy instead of
// presenting a blank button.

import 'dart:async';

import 'package:flutter/widgets.dart';
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
import 'package:sanad_client/features/notifications/domain/models/notification_presence.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_preferences.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_urgency.dart';
import 'package:sanad_client/features/notifications/domain/services/notification_quiet_window.dart';
import 'package:sanad_client/features/notifications/infrastructure/notification_action_labels.dart';
import 'package:sanad_client/features/notifications/infrastructure/notification_backend_native.dart';
import 'package:sanad_client/features/notifications/presentation/notification_copy_source.dart';
import 'package:sanad_client/l10n/app_localizations.dart';

class _RecordingAdapter implements NotificationPlatformAdapter {
  final List<NotificationPresentationRequest> shown = <NotificationPresentationRequest>[];

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
  }) async {}

  @override
  Future<NotificationPermissionStatus> checkPermission() async => NotificationPermissionStatus.granted;

  @override
  Future<NotificationPermissionStatus> requestPermission() async => NotificationPermissionStatus.granted;

  @override
  Future<NotificationPlatformResponse?> readLaunchResponse() async => null;

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

NotificationActionRouter _idleRouter() => NotificationActionRouter(
      readPendingAsk: (String sessionId) => null,
      openSession: (payload) async {},
      respondToAsk: (DeviceSuspendedRequest request, NotificationActionIntent intent, NotificationPayload payload) async {},
    );

Map<String, dynamic> _completed({required String eventId}) => <String, dynamic>{
      'type': 'device_event',
      'event': 'notification',
      'event_id': eventId,
      'session_id': 's1',
      'payload': <String, dynamic>{
        'kind': NotificationKind.completed.wire,
        'urgency': 'normal',
        'title': 'Run finished',
        'body': 'The run finished.',
        'deep_link': <String, dynamic>{'session_id': 's1'},
      },
    };

void main() {
  test('the open action label follows the language in use, without a restart', () async {
    final adapter = _RecordingAdapter();
    final english = NotificationCopySource(lookupAppLocalizations(const Locale('en')));
    final arabic = NotificationCopySource(lookupAppLocalizations(const Locale('ar')));

    // The bridge resolves the copy from the locale cubit on every presentation;
    // this variable stands in for that live locale.
    var copy = english;
    final events = StreamController<Map<String, dynamic>>.broadcast();
    addTearDown(events.close);
    final service = NotificationService(
      adapter: adapter,
      eventStreams: <Stream<Map<String, dynamic>>>[events.stream],
      copyResolver: (NotificationKind kind) => copy.copyFor(kind),
      readPreferences: () => const NotificationPreferences(),
      readPermission: () => NotificationPermissionStatus.granted,
      readPresence: () => NotificationPresence.none,
      readApprovalActionLabels: () => copy.approvalActionLabels,
      actionRouter: _idleRouter(),
      quietWindow: NotificationQuietWindow(duration: Duration.zero),
    );
    addTearDown(service.dispose);

    await service.handleEvent(_completed(eventId: 'evt-en'));
    copy = arabic;
    await service.handleEvent(_completed(eventId: 'evt-ar'));

    expect(adapter.shown, hasLength(2));
    expect(adapter.shown.first.openActionLabel, english.approvalActionLabels[NotificationActionIntent.open]);
    expect(
      adapter.shown.last.openActionLabel,
      arabic.approvalActionLabels[NotificationActionIntent.open],
      reason: 'the label is resolved when the notification is raised, not at initialization',
    );
    expect(
      adapter.shown.first.openActionLabel,
      isNot(adapter.shown.last.openActionLabel),
      reason: 'a language change must produce different copy',
    );
  });

  test('a request with no resolved label keeps the registered copy', () async {
    final adapter = _RecordingAdapter();
    final events = StreamController<Map<String, dynamic>>.broadcast();
    addTearDown(events.close);
    final service = NotificationService(
      adapter: adapter,
      eventStreams: <Stream<Map<String, dynamic>>>[events.stream],
      copyResolver: (NotificationKind kind) => const NotificationCopy(
        title: 'Title',
        body: 'Body',
        actionLabels: <NotificationActionIntent, String>{},
      ),
      readPreferences: () => const NotificationPreferences(),
      readPermission: () => NotificationPermissionStatus.granted,
      readPresence: () => NotificationPresence.none,
      // An empty map is what a caller without labels supplies; the adapter's
      // English fallback keeps the OS from showing a blank button.
      readApprovalActionLabels: () => const <NotificationActionIntent, String>{},
      actionRouter: _idleRouter(),
      quietWindow: NotificationQuietWindow(duration: Duration.zero),
    );
    addTearDown(service.dispose);

    await service.handleEvent(_completed(eventId: 'evt-empty'));

    expect(adapter.shown.single.openActionLabel, isNull);
    expect(
      NotificationActionLabels.linuxDefaultActionName(const <NotificationActionIntent, String>{}),
      NotificationActionLabels.english[NotificationActionIntent.open],
      reason: 'the registered fallback is the English open label, never a raw intent name',
    );
  });

  test('the freedesktop presentation carries the request label', () {
    const request = NotificationPresentationRequest(
      id: 7,
      title: 'Run finished',
      body: 'The run finished.',
      urgency: NotificationUrgency.normal,
      payload: '{}',
      openActionLabel: 'Label under test',
    );

    final details = FlutterLocalNotificationsAdapter.linuxDetailsFor(request);

    expect(details.defaultActionName, 'Label under test');
    expect(details.urgency, isNotNull);
    expect(
      FlutterLocalNotificationsAdapter.linuxDetailsFor(
        const NotificationPresentationRequest(
          id: 7,
          title: 'Run finished',
          body: 'The run finished.',
          urgency: NotificationUrgency.normal,
          payload: '{}',
        ),
      ).defaultActionName,
      isNull,
      reason: 'absent a label the plugin keeps the copy it registered at initialization',
    );
  });
}
