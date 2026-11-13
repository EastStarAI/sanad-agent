// Plan 174g (H1) — the cold-start permission probe must not be a race.
//
// Every Client start used to report `permission=unavailable` while the same
// session bus answered `GetCapabilities`, because Settings read the permission
// before the Linux adapter had built the D-Bus object that answers it, and the
// display policy refuses anything that is not `granted`.
//
// This test reproduces that cold start: a platform that throws on a permission
// read until it is initialized, the production ordering (the cubit loads
// unawaited at app scope, the pipeline starts separately), and an Agent-raised
// notification that must still reach the platform without Settings ever being
// opened.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/domain/models/device_suspended_request.dart';
import 'package:sanad_client/features/notifications/application/notification_action_router.dart';
import 'package:sanad_client/features/notifications/application/notification_platform_readiness.dart';
import 'package:sanad_client/features/notifications/application/notification_service.dart';
import 'package:sanad_client/features/notifications/data/notification_preferences_store.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_action.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_copy.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_kind.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_payload.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_permission_status.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_presence.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_platform_adapter.dart';
import 'package:sanad_client/features/notifications/domain/services/notification_display_policy.dart';
import 'package:sanad_client/features/notifications/domain/services/notification_quiet_window.dart';
import 'package:sanad_client/features/notifications/presentation/bloc/notification_settings_cubit.dart';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A platform whose permission answer depends on initialization, exactly like
/// the Linux adapter: the capability call addresses a remote object that
/// `initialize` is what creates.
class _ColdStartAdapter implements NotificationPlatformAdapter {
  final List<NotificationPresentationRequest> shown = <NotificationPresentationRequest>[];
  bool initialized = false;

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
  }

  @override
  Future<NotificationPermissionStatus> checkPermission() async {
    if (!initialized) {
      throw StateError('the platform object does not exist before initialize');
    }
    return NotificationPermissionStatus.granted;
  }

  @override
  Future<NotificationPermissionStatus> requestPermission() => checkPermission();

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

final NotificationCopy _copy = NotificationCopy(
  title: 'Fallback title',
  body: 'Fallback body',
  actionLabels: const <NotificationActionIntent, String>{
    NotificationActionIntent.open: 'Open',
  },
);

/// The canonical Agent envelope for a completed run.
Map<String, dynamic> _completedRun({String eventId = 'evt-completed'}) => <String, dynamic>{
      'type': 'device_event',
      'event': 'notification',
      'event_id': eventId,
      'session_id': 's1',
      'payload': <String, dynamic>{
        'kind': NotificationKind.completed.wire,
        'urgency': 'normal',
        'title': 'Run finished',
        'body': 'The run finished in 4m.',
        'deep_link': <String, dynamic>{'session_id': 's1'},
      },
    };

NotificationActionRouter _idleRouter() => NotificationActionRouter(
      readPendingAsk: (String sessionId) => null,
      openSession: (payload) async {},
      respondToAsk: (DeviceSuspendedRequest request, NotificationActionIntent intent, NotificationPayload payload) async {},
    );

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test('an Agent notification reaches the platform before Settings is opened', () async {
    final adapter = _ColdStartAdapter();
    final readiness = NotificationPlatformReadiness();
    final store = NotificationPreferencesStore(await SharedPreferences.getInstance());
    final cubit = NotificationSettingsCubit(
      store: store,
      adapter: adapter,
      platformReadiness: readiness,
    );
    addTearDown(cubit.close);

    // The developer is on a fresh Client: the cubit exists, its permission is
    // still unread, and nothing has initialized the platform.
    expect(cubit.state.permission, NotificationPermissionStatus.unknown);
    expect(adapter.initialized, isFalse);

    final events = StreamController<Map<String, dynamic>>.broadcast();
    addTearDown(events.close);
    final service = NotificationService(
      adapter: adapter,
      eventStreams: <Stream<Map<String, dynamic>>>[events.stream],
      copyResolver: (NotificationKind kind) => _copy,
      readPreferences: () => cubit.state.preferences,
      // The policy reads the same projection Settings shows, which is what makes
      // the cold-start answer matter beyond the page.
      readPermission: () => cubit.state.permission,
      readPresence: () => NotificationPresence.none,
      actionRouter: _idleRouter(),
      quietWindow: NotificationQuietWindow(duration: Duration.zero),
    );
    addTearDown(service.dispose);

    // ...and the bridge starts the pipeline, which releases the read and
    // publishes it before any event is consumed.
    await service.start(
      onPlatformReady: () async {
        readiness.complete();
        await cubit.load();
      },
    );

    expect(adapter.initialized, isTrue);
    expect(
      cubit.state.permission,
      NotificationPermissionStatus.granted,
      reason: 'the read waits for the platform objects instead of reporting them missing',
    );

    final decision = await service.handleEvent(_completedRun());

    expect(decision!.shouldDisplay, isTrue);
    expect(decision.outcome, NotificationDisplayOutcome.display);
    expect(adapter.shown, hasLength(1),
        reason: 'an Agent-raised notification is deliverable without opening Settings');
    expect(adapter.shown.single.title, 'Run finished');
  });

  test('the startup line reports the permission the platform actually has', () async {
    // The observed symptom was the log line itself:
    // `notification service started (supported=true permission=unavailable
    // coldStart=none)` against a live notification service.
    final lines = <String>[];
    final subscription = Logger('notifications').onRecord.listen((record) => lines.add(record.message));
    addTearDown(subscription.cancel);

    final adapter = _ColdStartAdapter();
    final readiness = NotificationPlatformReadiness();
    final cubit = NotificationSettingsCubit(
      store: NotificationPreferencesStore(await SharedPreferences.getInstance()),
      adapter: adapter,
      platformReadiness: readiness,
    );
    addTearDown(cubit.close);
    final events = StreamController<Map<String, dynamic>>.broadcast();
    addTearDown(events.close);
    final service = NotificationService(
      adapter: adapter,
      eventStreams: <Stream<Map<String, dynamic>>>[events.stream],
      copyResolver: (NotificationKind kind) => _copy,
      readPreferences: () => cubit.state.preferences,
      readPermission: () => cubit.state.permission,
      readPresence: () => NotificationPresence.none,
      actionRouter: _idleRouter(),
      quietWindow: NotificationQuietWindow(duration: Duration.zero),
    );
    addTearDown(service.dispose);

    await service.start(
      onPlatformReady: () async {
        readiness.complete();
        await cubit.load();
      },
    );

    final startup = lines.firstWhere(
      (line) => line.startsWith('notification service started'),
      orElse: () => '',
    );
    expect(startup, isNotEmpty, reason: 'the pipeline reports its own start');
    expect(startup, contains('permission=granted'));
    expect(startup, isNot(contains('permission=unavailable')));
  });

  test('a read that waits is answered once the pipeline releases it', () async {
    final adapter = _ColdStartAdapter();
    final readiness = NotificationPlatformReadiness();
    final cubit = NotificationSettingsCubit(
      store: NotificationPreferencesStore(await SharedPreferences.getInstance()),
      adapter: adapter,
      platformReadiness: readiness,
    );
    addTearDown(cubit.close);

    final load = cubit.load();
    expect(readiness.isReady, isFalse);

    adapter.initialized = true;
    readiness.complete();
    await load;

    expect(readiness.isReady, isTrue);
    expect(cubit.state.permission, NotificationPermissionStatus.granted);
  });

  test('a stalled initialization is bounded and the read reports the truth', () async {
    // A platform that never releases the gate must not keep Settings loading
    // forever: the wait is bounded, the read runs anyway, and the platform's own
    // failure becomes the honest answer.
    final adapter = _ColdStartAdapter();
    final readiness = NotificationPlatformReadiness(timeout: const Duration(milliseconds: 20));
    final cubit = NotificationSettingsCubit(
      store: NotificationPreferencesStore(await SharedPreferences.getInstance()),
      adapter: adapter,
      platformReadiness: readiness,
    );
    addTearDown(cubit.close);

    await cubit.load();

    expect(readiness.isReady, isFalse, reason: 'nothing ever released the gate');
    expect(cubit.state.permission, NotificationPermissionStatus.unavailable,
        reason: 'the read proceeded and reported what the platform answered');
  });

  test('a platform that is not initialized yet reports the failure it had', () async {
    // No readiness gate: the old behavior is kept for a surface with no
    // pipeline, so the assertion documents the defect this task fixed instead of
    // hiding it behind the new ordering.
    final adapter = _ColdStartAdapter();
    final cubit = NotificationSettingsCubit(
      store: NotificationPreferencesStore(await SharedPreferences.getInstance()),
      adapter: adapter,
    );
    addTearDown(cubit.close);

    await cubit.load();

    expect(cubit.state.permission, NotificationPermissionStatus.unavailable);
  });
}
