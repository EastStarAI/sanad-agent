import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/notifications/data/notification_preferences_store.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_action.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_kind.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_permission_status.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_platform_adapter.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_preferences.dart';
import 'package:sanad_client/features/notifications/presentation/bloc/notification_settings_cubit.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeAdapter implements NotificationPlatformAdapter {
  _FakeAdapter({
    this.permission = NotificationPermissionStatus.unknown,
    this.supported = true,
    this.requestResult = NotificationPermissionStatus.granted,
  });

  NotificationPermissionStatus permission;
  NotificationPermissionStatus requestResult;
  final bool supported;
  int requests = 0;
  int opens = 0;

  @override
  bool get isSupported => supported;

  @override
  bool get supportsApprovalActions => supported;

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
  Future<NotificationPermissionStatus> checkPermission() async => permission;

  @override
  Future<NotificationPermissionStatus> requestPermission() async {
    requests++;
    permission = requestResult;
    return requestResult;
  }

  @override
  Future<void> show(NotificationPresentationRequest request) async {}

  @override
  Future<bool> cancel(int notificationId) async => true;

  @override
  Future<void> cancelAll() async {}

  @override
  Future<bool> openSystemSettings() async {
    opens++;
    return true;
  }

  @override
  Future<void> dispose() async {}
}

void main() {
  group('NotificationPreferences', () {
    test('enables every kind by default', () {
      const preferences = NotificationPreferences();

      for (final kind in NotificationKind.values) {
        expect(preferences.isKindEnabled(kind), isTrue, reason: '${kind.wire} ships enabled');
      }
      expect(preferences.allows(NotificationKind.permissionRequest), isTrue);
    });

    test('a disabled kind is recorded and everything else stays enabled', () {
      final preferences = const NotificationPreferences().withKind(NotificationKind.failed, false);

      expect(preferences.isKindEnabled(NotificationKind.failed), isFalse);
      expect(preferences.isKindEnabled(NotificationKind.completed), isTrue);
      expect(preferences.toKindTokenMap(), <String, bool>{'failed': false});
    });

    test('re-enabling a kind removes its stored token', () {
      final disabled = const NotificationPreferences().withKind(NotificationKind.failed, false);
      final reenabled = disabled.withKind(NotificationKind.failed, true);

      expect(reenabled.toKindTokenMap(), isEmpty);
      expect(reenabled.isKindEnabled(NotificationKind.failed), isTrue);
    });

    test('the global switch overrides a per-kind enable', () {
      final preferences = const NotificationPreferences().withEnabled(false);

      expect(preferences.allows(NotificationKind.permissionRequest), isFalse);
    });

    test('stored tokens this build does not know are ignored', () {
      final restored = NotificationPreferences.fromStored(
        enabled: true,
        kindTokens: <String, bool>{'future_kind': false, 'completed': false},
      );

      expect(restored.isKindEnabled(NotificationKind.completed), isFalse);
      expect(restored.toKindTokenMap(), <String, bool>{'completed': false});
    });
  });

  group('NotificationPreferencesStore', () {
    test('defaults to enabled with no stored values', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final store = NotificationPreferencesStore(await SharedPreferences.getInstance());

      expect(store.read().enabled, isTrue);
      expect(store.read().kindOverrides, isEmpty);
      expect(store.wasPermissionRequested, isFalse);
    });

    test('round-trips the global switch and disabled kinds', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final preferences = await SharedPreferences.getInstance();
      final store = NotificationPreferencesStore(preferences);

      await store.write(
        const NotificationPreferences()
            .withEnabled(false)
            .withKind(NotificationKind.blocked, false),
      );
      await store.markPermissionRequested();

      final restored = store.read();
      expect(restored.enabled, isFalse);
      expect(restored.isKindEnabled(NotificationKind.blocked), isFalse);
      expect(store.wasPermissionRequested, isTrue);
      expect(
        preferences.getStringList(NotificationPreferencesStore.disabledKindsKey),
        <String>['blocked'],
      );
    });
  });

  group('NotificationSettingsCubit', () {
    Future<NotificationSettingsCubit> make(WidgetTester tester, _FakeAdapter adapter) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final cubit = NotificationSettingsCubit(
        store: NotificationPreferencesStore(await SharedPreferences.getInstance()),
        adapter: adapter,
      );
      addTearDown(cubit.close);
      return cubit;
    }

    testWidgets('load reads the OS permission without prompting', (tester) async {
      final adapter = _FakeAdapter(permission: NotificationPermissionStatus.denied);
      final cubit = await make(tester, adapter);

      await cubit.load();

      expect(cubit.state.permission, NotificationPermissionStatus.denied);
      expect(cubit.state.platformSupported, isTrue);
      expect(cubit.state.loading, isFalse);
      expect(adapter.requests, 0, reason: 'reading permission must never prompt');
    });

    testWidgets('requestPermission asks once and records the answer', (tester) async {
      final adapter = _FakeAdapter(requestResult: NotificationPermissionStatus.denied);
      final cubit = await make(tester, adapter);
      await cubit.load();

      expect(cubit.state.needsPermissionRequest, isTrue);
      await cubit.requestPermission();

      expect(adapter.requests, 1);
      expect(cubit.state.permission, NotificationPermissionStatus.denied);
      expect(cubit.state.permissionRequested, isTrue);
      expect(cubit.state.needsPermissionRequest, isFalse);
      expect(cubit.state.permissionDenied, isTrue);
    });

    testWidgets('refreshPermission reflects an OS revocation without a restart', (tester) async {
      final adapter = _FakeAdapter(permission: NotificationPermissionStatus.granted);
      final cubit = await make(tester, adapter);
      await cubit.load();
      expect(cubit.state.permission, NotificationPermissionStatus.granted);

      adapter.permission = NotificationPermissionStatus.denied;
      await cubit.refreshPermission();

      expect(cubit.state.permission, NotificationPermissionStatus.denied);
    });

    testWidgets('an unsupported platform never offers a permission ask', (tester) async {
      final adapter = _FakeAdapter(supported: false);
      final cubit = await make(tester, adapter);

      await cubit.load();

      expect(cubit.state.platformSupported, isFalse);
      expect(cubit.state.permission, NotificationPermissionStatus.unsupported);
      expect(cubit.state.needsPermissionRequest, isFalse);
      expect(cubit.state.unavailable, isTrue);
    });

    testWidgets('a failing permission read degrades to unavailable', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final cubit = NotificationSettingsCubit(
        store: NotificationPreferencesStore(await SharedPreferences.getInstance()),
        adapter: _ThrowingAdapter(),
      );
      addTearDown(cubit.close);

      await cubit.load();

      expect(cubit.state.permission, NotificationPermissionStatus.unavailable);
    });

    testWidgets('openSystemSettings delegates to the platform', (tester) async {
      final adapter = _FakeAdapter();
      final cubit = await make(tester, adapter);
      await cubit.load();

      expect(await cubit.openSystemSettings(), isTrue);
      expect(adapter.opens, 1);
    });
  });
}

class _ThrowingAdapter extends _FakeAdapter {
  @override
  Future<NotificationPermissionStatus> checkPermission() async {
    throw StateError('platform channel unavailable');
  }
}
