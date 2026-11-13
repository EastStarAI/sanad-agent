import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sanad_client/core/navigation/conversation_destination.dart';
import 'package:sanad_client/features/notifications/application/notification_presence_store.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_action.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_deep_link.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_kind.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_payload.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_permission_status.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_preferences.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_urgency.dart';
import 'package:sanad_client/features/notifications/domain/services/notification_display_policy.dart';
import 'package:sanad_client/features/notifications/presentation/notification_presence_reporter.dart';
import 'package:sanad_client/features/notifications/presentation/notification_window_presence_reporter.dart';
import 'package:sanad_client/infrastructure/platform/desktop_lifecycle_manager.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_cubit.dart';

import '../../helpers/composer_conversation_scope.dart';

/// The window manager is a native plugin; the manager under test only needs the
/// record it publishes.
class _FakeWindowAdapter implements DesktopWindowManagerAdapter {
  int hides = 0;
  int shows = 0;
  int focuses = 0;

  @override
  Future<void> hide() async => hides++;

  @override
  Future<void> show() async => shows++;

  @override
  Future<void> focus() async => focuses++;

  @override
  Future<void> setPreventClose(bool prevent) async {}

  @override
  Future<void> destroy() async {}
}

/// The ask the policy is asked about: one session, one request.
final NotificationPayload _ask = NotificationPayload(
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

NotificationDisplayOutcome _decide(NotificationPresenceStore store) {
  return NotificationDisplayPolicy.decide(
    payload: _ask,
    alreadyProcessed: false,
    preferences: const NotificationPreferences(),
    permission: NotificationPermissionStatus.granted,
    quietWindowOpen: false,
    presence: store.presence,
    now: DateTime.utc(2026, 1, 1, 12),
  ).outcome;
}

void main() {
  late NotificationPresenceStore presence;
  late _FakeWindowAdapter windowAdapter;
  late DesktopLifecycleManager lifecycle;
  late StubSessionCubit sessionCubit;

  setUp(() {
    presence = NotificationPresenceStore();
    windowAdapter = _FakeWindowAdapter();
    lifecycle = DesktopLifecycleManager(windowAdapter: windowAdapter);
    sessionCubit = StubSessionCubit();
  });

  tearDown(() async {
    lifecycle.dispose();
    await sessionCubit.close();
  });

  /// Mounts the two presence writers the app mounts: the window record above the
  /// router, and the routed conversation surface inside it.
  Future<void> mountReporters(WidgetTester tester) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<NotificationPresenceStore>.value(value: presence),
          BlocProvider<SessionCubit>.value(value: sessionCubit),
        ],
        child: NotificationWindowPresenceReporter(
          lifecycleManager: lifecycle,
          child: NotificationPresenceReporter(
            destination: const ConversationDestination.session(
              deviceId: 'd1',
              sessionId: 's1',
            ),
            child: const Material(child: SizedBox.shrink()),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('the window record, not an OS transition, flips the display decision',
      (tester) async {
    await mountReporters(tester);

    // Same session, same request, window on screen: the prompt is already in
    // front of the user, so no banner is raised.
    expect(presence.presence.windowVisible, isTrue);
    expect(_decide(presence), NotificationDisplayOutcome.suppressedOnScreen);

    // Close-to-tray: the deterministic hide every desktop platform performs.
    await lifecycle.hideWindow();
    await tester.pump();

    expect(windowAdapter.hides, 1);
    expect(presence.presence.windowVisible, isFalse);
    expect(
      _decide(presence),
      NotificationDisplayOutcome.display,
      reason: 'a hidden window is not presence, even for the selected session',
    );

    // The user restored the window; the same ask is on screen again.
    await lifecycle.showWindow();
    await tester.pump();

    expect(windowAdapter.shows, 1);
    expect(windowAdapter.focuses, 1);
    expect(presence.presence.windowVisible, isTrue);
    expect(_decide(presence), NotificationDisplayOutcome.suppressedOnScreen);
  });

  testWidgets('a lifecycle resume cannot claim a window the manager still holds hidden',
      (tester) async {
    await mountReporters(tester);
    await lifecycle.hideWindow();
    await tester.pump();
    expect(_decide(presence), NotificationDisplayOutcome.display);

    // A dock-icon click can activate the process without restoring the window;
    // the OS signal must not override the hide the Client performed itself.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();

    expect(presence.presence.windowVisible, isFalse);
    expect(_decide(presence), NotificationDisplayOutcome.display);
  });

  testWidgets('without a desktop manager the lifecycle state still reports presence',
      (tester) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<NotificationPresenceStore>.value(value: presence),
          BlocProvider<SessionCubit>.value(value: sessionCubit),
        ],
        child: NotificationWindowPresenceReporter(
          child: NotificationPresenceReporter(
            destination: const ConversationDestination.session(
              deviceId: 'd1',
              sessionId: 's1',
            ),
            child: const Material(child: SizedBox.shrink()),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(_decide(presence), NotificationDisplayOutcome.suppressedOnScreen);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();

    expect(presence.presence.windowVisible, isFalse);
    expect(_decide(presence), NotificationDisplayOutcome.display);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(_decide(presence), NotificationDisplayOutcome.suppressedOnScreen);
  });
}
