import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:sanad_client/features/notifications/data/notification_preferences_store.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_kind.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_permission_status.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_platform_adapter.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_preferences.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_urgency.dart';
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
class NotificationSettingsCubit extends Cubit<NotificationSettingsState> {
  NotificationSettingsCubit({
    required NotificationPreferencesStore store,
    required NotificationPlatformAdapter adapter,
    NotificationPreferencesPublisher? publishPreferences,
  })  : _store = store,
        _adapter = adapter,
        _publishPreferences = publishPreferences,
        super(NotificationSettingsState(
          platformSupported: adapter.isSupported,
          preferences: store.read(),
          permissionRequested: store.wasPermissionRequested,
        ));

  final NotificationPreferencesStore _store;
  final NotificationPlatformAdapter _adapter;
  final NotificationPreferencesPublisher? _publishPreferences;

  NotificationTestSender? _testSender;

  bool _loaded = false;

  /// Attaches the running pipeline's test action. Absent when this build has no
  /// notification surface, in which case Settings reports it as unavailable.
  void attachTestSender(NotificationTestSender sender) {
    _testSender = sender;
  }

  /// Reads the stored choices and the current OS permission.
  ///
  /// Safe to call again: an explicit refusal must be reflected without an app
  /// restart, so the Settings surface refreshes on open, on resume, and after a
  /// request.
  Future<void> load() async {
    final preferences = _store.read();
    final permission = await _readPermission();
    _loaded = true;
    if (isClosed) return;
    emit(
      state.copyWith(
        loading: false,
        platformSupported: _adapter.isSupported,
        preferences: preferences,
        permission: permission,
        permissionRequested: _store.wasPermissionRequested,
      ),
    );
  }

  /// Re-reads only the OS permission, leaving preferences untouched.
  Future<void> refreshPermission() async {
    final permission = await _readPermission();
    if (isClosed) return;
    emit(state.copyWith(permission: permission, permissionRequested: _store.wasPermissionRequested));
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

  /// Asks the OS, and only ever because the user pressed the Settings action.
  Future<void> requestPermission() async {
    if (!_adapter.isSupported || state.requestingPermission) return;
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

  /// Opens the system notification pane after a refusal. No second prompt
  /// exists on macOS, so this is the only way back.
  Future<bool> openSystemSettings() => _adapter.openSystemSettings();

  /// Raises one test notification and records what it proved.
  ///
  /// The sender is the running pipeline, so the probe applies the same
  /// permission, preference, urgency, and platform rules a real notification
  /// does. A missing sender, a thrown error, or a suppressed decision becomes a
  /// localized explanation instead of a silent press.
  Future<void> sendTestNotification() async {
    if (state.sendingTest) return;
    final sender = _testSender;
    if (sender == null) {
      _emitTestOutcome(NotificationTestOutcome.unsupported);
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
        _ => NotificationTestOutcome.failed,
      };

  /// Stores a change, publishes it, then reflects it.
  ///
  /// The order matters: a failed write must not leave the UI claiming a choice
  /// the pipeline will not read back, so state is emitted from the stored value.
  Future<void> _persist(NotificationPreferences preferences) async {
    await _store.write(preferences);
    if (isClosed) return;
    emit(state.copyWith(preferences: preferences));
    _publishPreferences?.call(preferences);
  }

  Future<NotificationPermissionStatus> _readPermission() async {
    if (!_adapter.isSupported) return NotificationPermissionStatus.unsupported;
    try {
      return await _adapter.checkPermission();
    } catch (_) {
      return NotificationPermissionStatus.unavailable;
    }
  }

  /// Whether [load] has completed at least once.
  bool get isLoaded => _loaded;
}
