// Plan 174f — the per-device preference model, its storage, and the test action.
//
// These tests pin the two invariants the Settings surface depends on: a choice
// belongs to one device, and a choice can only lower what the Agent decided.
// They also pin the exact declaration the Agent registers, because that shape is
// the contract between the two codebases.

import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/notifications/data/notification_preferences_store.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_action.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_kind.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_permission_status.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_platform_adapter.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_preferences.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_urgency.dart';
import 'package:sanad_client/features/notifications/domain/services/notification_display_policy.dart';
import 'package:sanad_client/features/notifications/presentation/bloc/notification_settings_cubit.dart';
import 'package:sanad_client/features/notifications/presentation/bloc/notification_settings_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeAdapter implements NotificationPlatformAdapter {
  _FakeAdapter({this.supported = true, this.permission = NotificationPermissionStatus.granted});

  final bool supported;
  NotificationPermissionStatus permission;

  @override
  bool get isSupported => supported;

  @override
  bool get supportsApprovalActions => supported;

  @override
  Future<void> initialize({
    NotificationPlatformResponseCallback? onResponse,
    Map<NotificationActionIntent, String> approvalActionLabels =
        const <NotificationActionIntent, String>{},
  }) async {}

  @override
  Future<NotificationPermissionStatus> checkPermission() async => permission;

  @override
  Future<NotificationPermissionStatus> requestPermission() async => permission;

  @override
  Future<NotificationPlatformResponse?> readLaunchResponse() async => null;

  @override
  Future<void> show(NotificationPresentationRequest request) async {}

  @override
  Future<bool> cancel(int notificationId) async => true;

  @override
  Future<void> cancelAll() async {}

  @override
  Future<bool> openSystemSettings() async => true;

  @override
  Future<void> dispose() async {}
}

void main() {
  group('per-device urgency ceiling', () {
    test('every kind starts at the product default', () {
      const preferences = NotificationPreferences();

      for (final kind in NotificationKind.values) {
        expect(preferences.ceilingFor(kind), NotificationUrgency.defaultUrgency);
        expect(preferences.urgencyFor(kind, NotificationUrgency.high), NotificationUrgency.high);
      }
      expect(preferences.isProductDefault, isTrue);
    });

    test('a lowered kind never exceeds its ceiling, whatever the Agent decided', () {
      final preferences =
          const NotificationPreferences().withKindUrgency(NotificationKind.completed, NotificationUrgency.normal);

      for (final agentUrgency in NotificationUrgency.values) {
        final actual = preferences.urgencyFor(NotificationKind.completed, agentUrgency);
        expect(
          actual.index,
          lessThanOrEqualTo(NotificationUrgency.normal.index),
          reason: 'the enum runs quietest to loudest, so a ceiling of normal cannot be raised '
              'by an Agent urgency of ${agentUrgency.wire}',
        );
      }
      expect(preferences.urgencyFor(NotificationKind.completed, NotificationUrgency.high),
          NotificationUrgency.normal);
      expect(preferences.urgencyFor(NotificationKind.completed, NotificationUrgency.low),
          NotificationUrgency.low,
          reason: 'a quieter Agent decision is kept');
    });

    test('a ceiling at or above the product default clears the override', () {
      final raised =
          const NotificationPreferences().withKindUrgency(NotificationKind.failed, NotificationUrgency.high);
      final critical =
          const NotificationPreferences().withKindUrgency(NotificationKind.failed, NotificationUrgency.critical);

      expect(raised.kindUrgencyOverrides, isEmpty);
      expect(critical.kindUrgencyOverrides, isEmpty);
    });

    test('a kind can be muted and quiet at the same time, and muting wins', () {
      final preferences = const NotificationPreferences()
          .withKindUrgency(NotificationKind.blocked, NotificationUrgency.normal)
          .withKind(NotificationKind.blocked, false);

      expect(preferences.allows(NotificationKind.blocked), isFalse);
      expect(preferences.ceilingFor(NotificationKind.blocked), NotificationUrgency.normal);
    });

    test('a stored ceiling that would raise a kind is ignored', () {
      final restored = NotificationPreferences.fromStored(
        enabled: true,
        kindTokens: const <String, bool>{},
        urgencyTokens: const <String, String>{
          'completed': 'critical',
          'failed': 'high',
          'blocked': 'quiet_please',
          'future_kind': 'low',
          'permission_request': 'normal',
        },
      );

      expect(restored.ceilingFor(NotificationKind.completed), NotificationUrgency.defaultUrgency);
      expect(restored.ceilingFor(NotificationKind.failed), NotificationUrgency.defaultUrgency);
      expect(restored.ceilingFor(NotificationKind.blocked), NotificationUrgency.defaultUrgency);
      expect(restored.ceilingFor(NotificationKind.permissionRequest), NotificationUrgency.normal);
      expect(restored.kindUrgencyOverrides.length, 1);
    });

    test('the declaration carries only deliberate choices', () {
      final preferences = const NotificationPreferences()
          .withKind(NotificationKind.failed, false)
          .withKindUrgency(NotificationKind.completed, NotificationUrgency.normal);

      expect(preferences.toAgentDeclaration(), <String, dynamic>{
        'enabled': true,
        'kinds': <String, String>{'failed': 'off', 'completed': 'normal'},
      });
    });

    test('an untouched device declares the product default', () {
      expect(const NotificationPreferences().toAgentDeclaration(), <String, dynamic>{
        'enabled': true,
        'kinds': <String, String>{},
      });
    });
  });

  group('per-device storage', () {
    test('round-trips a lowered urgency and a muted kind', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final raw = await SharedPreferences.getInstance();
      final store = NotificationPreferencesStore(raw);

      await store.write(
        const NotificationPreferences()
            .withKindUrgency(NotificationKind.completed, NotificationUrgency.normal)
            .withKind(NotificationKind.blocked, false),
      );

      final restored = store.read();
      expect(restored.ceilingFor(NotificationKind.completed), NotificationUrgency.normal);
      expect(restored.isKindEnabled(NotificationKind.blocked), isFalse);
      expect(
        raw.getStringList(NotificationPreferencesStore.kindUrgencyKey),
        <String>['completed:normal'],
      );
    });

    test('a malformed stored entry is dropped instead of failing the read', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        NotificationPreferencesStore.kindUrgencyKey: <String>[
          'completed',
          ':normal',
          'failed:',
          'blocked:normal:extra',
          'blocked:normal',
        ],
      });
      final store = NotificationPreferencesStore(await SharedPreferences.getInstance());

      final restored = store.read();
      expect(restored.ceilingFor(NotificationKind.blocked), NotificationUrgency.normal);
      expect(restored.ceilingFor(NotificationKind.completed), NotificationUrgency.defaultUrgency);
      expect(restored.ceilingFor(NotificationKind.failed), NotificationUrgency.defaultUrgency);
    });
  });

  group('NotificationSettingsCubit', () {
    Future<NotificationSettingsCubit> make(
      _FakeAdapter adapter, {
      NotificationPreferencesPublisher? publishPreferences,
    }) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final cubit = NotificationSettingsCubit(
        store: NotificationPreferencesStore(await SharedPreferences.getInstance()),
        adapter: adapter,
        publishPreferences: publishPreferences,
      );
      addTearDown(cubit.close);
      return cubit;
    }

    testWidgets('a lowered urgency is stored, published, and re-read', (tester) async {
      final published = <NotificationPreferences>[];
      final cubit = await make(_FakeAdapter(), publishPreferences: published.add);
      await cubit.load();

      await cubit.setKindUrgency(NotificationKind.completed, NotificationUrgency.normal);

      expect(cubit.state.ceilingFor(NotificationKind.completed), NotificationUrgency.normal);
      expect(published, hasLength(1));
      expect(
        published.single.toAgentDeclaration()['kinds'],
        <String, String>{'completed': 'normal'},
        reason: 'the Agent learns this device lowered one kind',
      );
    });

    testWidgets('every choice is announced so the Agent can apply it', (tester) async {
      var published = 0;
      final cubit = await make(_FakeAdapter(), publishPreferences: (_) => published += 1);
      await cubit.load();

      await cubit.setEnabled(false);
      await cubit.setKindEnabled(NotificationKind.failed, false);
      await cubit.setKindUrgency(NotificationKind.failed, NotificationUrgency.normal);

      expect(published, 3, reason: 'a change that is not announced would only reach this device');
    });

    testWidgets('a test notification reports what the pipeline decided', (tester) async {
      final cubit = await make(_FakeAdapter());
      await cubit.load();

      final outcomes = <NotificationDisplayOutcome>[
        NotificationDisplayOutcome.display,
        NotificationDisplayOutcome.suppressedDisabled,
        NotificationDisplayOutcome.suppressedPermission,
        NotificationDisplayOutcome.dropUnsupported,
      ];
      final expected = <NotificationTestOutcome>[
        NotificationTestOutcome.shown,
        NotificationTestOutcome.kindDisabled,
        NotificationTestOutcome.permissionDenied,
        NotificationTestOutcome.unsupported,
      ];

      var index = 0;
      cubit.attachTestSender(() async => outcomes[index]);
      for (var attempt = 0; attempt < outcomes.length; attempt += 1) {
        index = attempt;
        await cubit.sendTestNotification();
        expect(cubit.state.testOutcome, expected[attempt]);
      }
      expect(cubit.state.testSequence, outcomes.length);
      expect(cubit.state.sendingTest, isFalse);
    });

    testWidgets('a thrown or missing sender never claims success', (tester) async {
      final cubit = await make(_FakeAdapter());
      await cubit.load();

      await cubit.sendTestNotification();
      expect(cubit.state.testOutcome, NotificationTestOutcome.unsupported,
          reason: 'no pipeline is attached, so nothing could have been shown');

      cubit.attachTestSender(() async => throw StateError('platform channel closed'));
      await cubit.sendTestNotification();
      expect(cubit.state.testOutcome, NotificationTestOutcome.failed);
    });

    testWidgets('a platform without a surface cannot send a test', (tester) async {
      final cubit = await make(_FakeAdapter(supported: false));
      await cubit.load();

      expect(cubit.state.canSendTest, isFalse);
    });

    testWidgets('a revoked permission while the switch is on is reported', (tester) async {
      final cubit = await make(_FakeAdapter(permission: NotificationPermissionStatus.denied));
      await cubit.load();

      expect(cubit.state.permissionDenied, isTrue);
      expect(cubit.state.preferences.enabled, isTrue);
      expect(cubit.state.permissionDeniedWhileEnabled, isTrue,
          reason: 'the page must report the contradiction and offer the fix path');
    });
  });
}
