import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:sanad_client/features/notifications/application/notification_platform_readiness.dart';
import 'package:sanad_client/features/notifications/application/web_push_subscription_service.dart';
import 'package:sanad_client/features/notifications/data/notification_preferences_store.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_kind.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_permission_status.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_platform_adapter.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_preferences.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_urgency.dart';
import 'package:sanad_client/features/notifications/domain/models/web_push_capability.dart';
import 'package:sanad_client/features/notifications/domain/models/web_push_display_policy.dart';
import 'package:sanad_client/features/notifications/domain/services/notification_display_policy.dart';
import 'package:sanad_client/features/notifications/presentation/bloc/notification_settings_state.dart';

/// Runs one user-pressed test notification and reports the display decision.
///
/// The sender is attached by the running pipeline rather than constructed here,
/// so Settings never owns a second way to raise a notification.
typedef NotificationTestSender = Future<NotificationDisplayOutcome?> Function();

/// Announces that this device's notification choices changed, so the Agent can
/// apply them to the next dispatch that names this device.
typedef NotificationPreferencesPublisher = void Function(
  NotificationPreferences preferences,
);

/// The single owner of notification permission state and preferences.
///
/// The display pipeline reads the same instance the Settings surface edits, so
/// turning a kind off takes effect on the next event instead of after a
/// restart, and an OS revocation seen on resume is honoured by the next
/// notification.
///
/// On a browser it also owns the push projection: the permission action runs the
/// whole subscription lifecycle, because a browser permission without a
/// registered endpoint cannot deliver anything while the tab is closed.
class NotificationSettingsCubit extends Cubit<NotificationSettingsState> {
  NotificationSettingsCubit({
    required NotificationPreferencesStore store,
    required NotificationPlatformAdapter adapter,
    WebPushSubscriptionService? webPush,
    // The pipeline releases this once the platform objects exist. Without it a
    // read that arrives first reports the platform as unavailable, which the
    // display policy then honours for every Agent-raised notification.
    NotificationPlatformReadiness? platformReadiness,
    // A change belongs to this device, so it is also re-declared to the Agent
    // this Client is attached to. It never travels through the account: no
    // other device's choices change, and the relay only forwards an opaque
    // registration field.
    NotificationPreferencesPublisher? publishPreferences,
  })  : _store = store,
        _adapter = adapter,
        _webPush = webPush,
        _platformReadiness = platformReadiness,
        _publishPreferences = publishPreferences,
        super(
          NotificationSettingsState(
            platformSupported: adapter.isSupported,
            canOpenSystemSettings: adapter.canOpenSystemSettings,
            preferences: store.read(),
            permissionRequested: store.wasPermissionRequested,
            webPush: webPush?.settings ?? const WebPushSettings(),
          ),
        ) {
    final service = _webPush;
    if (service != null) {
      _webPushSubscription = service.changes.listen((settings) {
        if (isClosed) return;
        emit(state.copyWith(webPush: settings));
      });
    }
  }

  final NotificationPreferencesStore _store;
  final NotificationPlatformAdapter _adapter;
  final WebPushSubscriptionService? _webPush;
  final NotificationPlatformReadiness? _platformReadiness;
  StreamSubscription<WebPushSettings>? _webPushSubscription;
  final NotificationPreferencesPublisher? _publishPreferences;

  NotificationTestSender? _testSender;

  bool _loaded = false;

  /// Attaches the running pipeline's test action. Absent when this build has no
  /// notification surface, in which case Settings reports it as unavailable.
  ///
  /// [kind] is the kind the pipeline's probe borrows, so the page can name the
  /// alert style the result describes: a user who quietened that kind gets a
  /// quieter probe, and saying which row it follows is what keeps that honest.
  void attachTestSender(NotificationTestSender sender, {NotificationKind? kind}) {
    _testSender = sender;
    if (isClosed) return;
    emit(state.copyWith(testSenderAttached: true, testKind: kind));
  }

  /// Reads the stored choices and the current OS permission.
  ///
  /// Safe to call again: an explicit refusal must be reflected without an app
  /// restart, so the Settings surface refreshes on open, on resume, and after a
  /// request.
  Future<void> load() async {
    final preferences = _store.read();
    final permission = await _readPermission();
    final webPush = await _readWebPush();
    _loaded = true;
    if (isClosed) return;
    emit(
      state.copyWith(
        loading: false,
        platformSupported: _adapter.isSupported,
        canOpenSystemSettings: _adapter.canOpenSystemSettings,
        preferences: preferences,
        permission: permission,
        permissionRequested: _store.wasPermissionRequested,
        webPush: webPush,
      ),
    );
    await _publishDisplayPolicy(preferences);
  }

  /// Re-reads only the OS permission and the browser subscription, leaving
  /// preferences untouched.
  Future<void> refreshPermission() async {
    final permission = await _readPermission();
    final webPush = await _readWebPush();
    if (isClosed) return;
    emit(
      state.copyWith(
        permission: permission,
        permissionRequested: _store.wasPermissionRequested,
        webPush: webPush,
      ),
    );
  }

  Future<void> setEnabled(bool enabled) async {
    final preferences = state.preferences.withEnabled(enabled);
    await _persist(preferences);
  }

  Future<void> setKindEnabled(NotificationKind kind, bool enabled) async {
    final preferences = state.preferences.withKind(kind, enabled);
    await _persist(preferences);
  }

  /// Lowers how loudly [kind] interrupts, or restores the product default when
  /// [ceiling] is `null`.
  Future<void> setKindUrgency(NotificationKind kind, NotificationUrgency? ceiling) async {
    final preferences = state.preferences.withKindUrgency(kind, ceiling);
    await _persist(preferences);
  }

  /// Asks the user's platform, and only ever because the user pressed the
  /// Settings action.
  ///
  /// A browser runs the full lifecycle: permission, subscription, and account
  /// registration. A native platform keeps the OS-only ask.
  Future<void> requestPermission() async {
    if (!_adapter.isSupported || state.requestingPermission) return;
    final service = _webPush;
    if (service != null && state.usesWebPushLifecycle) {
      emit(state.copyWith(requestingPermission: true));
      WebPushSettings settings;
      try {
        settings = await service.enable();
      } catch (_) {
        settings = service.settings.copyWith(failure: WebPushFailure.registrationFailed);
      }
      final permission = await _readPermission();
      await _store.markPermissionRequested();
      if (isClosed) return;
      emit(
        state.copyWith(
          requestingPermission: false,
          permission: permission,
          permissionRequested: true,
          webPush: settings,
        ),
      );
      return;
    }

    emit(state.copyWith(requestingPermission: true));
    NotificationPermissionStatus status;
    try {
      status = await _adapter.requestPermission();
    } catch (_) {
      status = NotificationPermissionStatus.unavailable;
    }
    await _store.markPermissionRequested();
    if (isClosed) return;
    emit(
      state.copyWith(
        requestingPermission: false,
        permission: status,
        permissionRequested: true,
      ),
    );
  }

  /// Withdraws this browser from the account. A native build has nothing to
  /// withdraw.
  Future<void> disableWebPush() async {
    final service = _webPush;
    if (service == null || state.requestingPermission) return;
    emit(state.copyWith(requestingPermission: true));
    WebPushSettings settings;
    try {
      settings = await service.disable();
    } catch (_) {
      settings = service.settings;
    }
    if (isClosed) return;
    emit(state.copyWith(requestingPermission: false, webPush: settings));
  }

  /// Opens the system notification pane after a refusal. No second prompt
  /// exists on macOS, so this is the only way back.
  Future<bool> openSystemSettings() => _adapter.openSystemSettings();

  /// Raises one test notification and records what it proved.
  ///
  /// The sender is the running pipeline, so the probe applies the same
  /// permission, preference, urgency, and platform rules a real notification
  /// does. A missing sender, a thrown error, or a suppressed decision becomes a
  /// localized explanation instead of a silent press, and a presentation the
  /// platform refused is reported as a failure rather than as success.
  Future<void> sendTestNotification() async {
    if (state.sendingTest) return;
    final sender = _testSender;
    if (sender == null) {
      _emitTestOutcome(NotificationTestOutcome.failed);
      return;
    }
    emit(state.copyWith(sendingTest: true, clearTestOutcome: true));
    NotificationDisplayOutcome? outcome;
    try {
      outcome = await sender();
    } catch (_) {
      outcome = null;
    }
    if (isClosed) return;
    emit(
      state.copyWith(
        sendingTest: false,
        testOutcome: _mapTestOutcome(outcome),
        testSequence: state.testSequence + 1,
      ),
    );
  }

  void _emitTestOutcome(NotificationTestOutcome outcome) {
    if (isClosed) return;
    emit(state.copyWith(testOutcome: outcome, testSequence: state.testSequence + 1));
  }

  static NotificationTestOutcome _mapTestOutcome(NotificationDisplayOutcome? outcome) =>
      switch (outcome) {
        NotificationDisplayOutcome.display => NotificationTestOutcome.shown,
        NotificationDisplayOutcome.suppressedDisabled => NotificationTestOutcome.kindDisabled,
        NotificationDisplayOutcome.suppressedPermission => NotificationTestOutcome.permissionDenied,
        NotificationDisplayOutcome.dropUnsupported => NotificationTestOutcome.unsupported,
        NotificationDisplayOutcome.presentationFailed => NotificationTestOutcome.failed,
        _ => NotificationTestOutcome.failed,
      };

  /// Stores a change, publishes it, then reflects it.
  ///
  /// The order matters: a failed write must not leave the UI claiming a choice
  /// the pipeline will not read back, so state is emitted from the stored value.
  ///
  /// The browser projection is refreshed before the Agent is told, so a muting
  /// change reaches the worker that raises closed-tab alerts as well as the
  /// dispatch that names this device.
  Future<void> _persist(NotificationPreferences preferences) async {
    await _store.write(preferences);
    await _publishDisplayPolicy(preferences);
    if (isClosed) return;
    emit(state.copyWith(preferences: preferences));
    _publishPreferences?.call(preferences);
  }

  Future<NotificationPermissionStatus> _readPermission() async {
    if (!_adapter.isSupported) return NotificationPermissionStatus.unsupported;
    // A platform builds the objects it answers with during initialization, so a
    // read that arrives first waits for the pipeline instead of throwing and
    // being reported as `unavailable`. The display policy treats anything but
    // `granted` as a refusal, so this ordering is what keeps an Agent-raised
    // notification deliverable before Settings is ever opened.
    await _platformReadiness?.ready;
    try {
      return await _adapter.checkPermission();
    } catch (_) {
      return NotificationPermissionStatus.unavailable;
    }
  }

  Future<WebPushSettings> _readWebPush() async {
    final service = _webPush;
    if (service == null) return const WebPushSettings();
    try {
      return await service.refresh();
    } catch (_) {
      return service.settings;
    }
  }

  Future<void> _publishDisplayPolicy(NotificationPreferences preferences) async {
    final service = _webPush;
    if (service == null) return;
    await service.publishDisplayPolicy(
      WebPushDisplayPolicy(enabled: preferences.enabled, mutedKinds: preferences.mutedKinds),
    );
  }

  /// Whether [load] has completed at least once.
  bool get isLoaded => _loaded;

  @override
  Future<void> close() async {
    await _webPushSubscription?.cancel();
    return super.close();
  }
}
