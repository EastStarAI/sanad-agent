import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_kind.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_permission_status.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_urgency.dart';
import 'package:sanad_client/features/notifications/domain/models/web_push_capability.dart';
import 'package:sanad_client/features/notifications/presentation/bloc/notification_settings_cubit.dart';
import 'package:sanad_client/features/notifications/presentation/bloc/notification_settings_state.dart';
import 'package:sanad_client/features/notifications/presentation/notification_copy_source.dart';
import 'package:sanad_client/l10n/app_localizations.dart';
import 'package:sanad_client/utils/app_platform.dart';

import '../settings_widgets.dart';

/// Settings → Notifications.
///
/// The page states the OS permission, offers the ask only when the OS has not
/// been asked yet, and owns the global switch plus one row per kind with its
/// current urgency. It never raises a notification and never decides one: it
/// edits the same state the display pipeline reads, so a change takes effect on
/// the next event, and its one test action runs through that same pipeline.
///
/// Everything here is device-scoped by design: these choices belong to this
/// Client, not to the account, which is why the page says so instead of implying
/// a shared setting.
class NotificationsPage extends StatefulWidget {
  const NotificationsPage({super.key});

  @override
  State<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends State<NotificationsPage> {
  @override
  void initState() {
    super.initState();
    // Reading the OS permission is an explicit page action, never a build side
    // effect, so opening Settings is what refreshes it.
    unawaited(context.read<NotificationSettingsCubit>().load());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return BlocBuilder<NotificationSettingsCubit, NotificationSettingsState>(
      builder: (context, state) {
        return PageFrame(
          title: l10n.notifications,
          subtitle: state.webPush.isWebPlatform ? l10n.notificationsWebSubtitle : l10n.notificationsSubtitle,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _PermissionCard(state: state, l10n: l10n),
              const SizedBox(height: 16),
              _PreferencesCard(state: state, l10n: l10n),
              const SizedBox(height: 16),
              _TestCard(state: state, l10n: l10n),
              const SizedBox(height: 16),
              _LimitsCard(l10n: l10n),
            ],
          ),
        );
      },
    );
  }
}

class _PermissionCard extends StatelessWidget {
  const _PermissionCard({required this.state, required this.l10n});

  final NotificationSettingsState state;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<NotificationSettingsCubit>();
    return SettingsCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.notificationsPermission,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(_description(l10n)),
          if (_offersEnable) ...[
            const SizedBox(height: 16),
            FilledButton(
              key: const ValueKey('notification_permission_request_btn'),
              onPressed: state.requestingPermission ? null : () => unawaited(cubit.requestPermission()),
              child: Text(
                state.webPush.failure == WebPushFailure.registrationFailed
                    ? l10n.notificationsWebRetry
                    : l10n.notificationsEnable,
              ),
            ),
          ],
          if (_offersDisable) ...[
            const SizedBox(height: 16),
            OutlinedButton(
              key: const ValueKey('notification_web_push_disable_btn'),
              onPressed: state.requestingPermission ? null : () => unawaited(cubit.disableWebPush()),
              child: Text(l10n.notificationsWebDisable),
            ),
          ],
          if (state.permissionDenied) ...[
            const SizedBox(height: 8),
            // A revoked OS permission does not change the in-app switch, and the
            // page reports the contradiction instead of hiding it. The system
            // pane is the only way back: macOS never shows a second prompt.
            if (state.permissionDeniedWhileEnabled) ...[
              Text(
                l10n.notificationsPermissionDeniedWhileEnabled,
                key: const ValueKey('notification_permission_conflict'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              const SizedBox(height: 8),
            ],
          ],
          if (state.permissionDenied && state.canOpenSystemSettings) ...[
            const SizedBox(height: 8),
            OutlinedButton(
              key: const ValueKey('notification_open_settings_btn'),
              onPressed: () => unawaited(cubit.openSystemSettings()),
              child: Text(l10n.notificationsOpenSettings),
            ),
          ],
        ],
      ),
    );
  }

  /// A browser asks only through the full lifecycle; a native platform keeps
  /// the OS-only ask that the shared pipeline already owned.
  ///
  /// A refused or unacknowledged registration is reported as a failure with a
  /// retry, because Settings must never claim delivery the relay did not accept.
  bool get _offersEnable {
    if (state.requestingPermission) return false;
    if (!state.webPush.isWebPlatform) return state.needsPermissionRequest;
    if (!state.webPush.canSubscribe || state.webPush.isSubscribed) return false;
    if (state.permissionDenied) return false;
    if (state.permission == NotificationPermissionStatus.unavailable) return false;
    return state.webPush.failure != WebPushFailure.signInRequired;
  }

  /// The browser subscription exists even when the relay refused it, so the
  /// user can still withdraw it instead of being left with a permission the
  /// product reports as unusable.
  bool get _offersDisable =>
      state.webPush.isWebPlatform &&
      (state.webPush.isSubscribed || state.webPush.failure == WebPushFailure.registrationFailed) &&
      !state.requestingPermission;

  String _description(AppLocalizations l10n) {
    final web = state.webPush;
    if (web.isWebPlatform) {
      switch (web.availability) {
        case WebPushAvailability.installRequired:
          return l10n.notificationsWebInstallRequiredBody;
        case WebPushAvailability.unconfigured:
          return l10n.notificationsWebUnconfiguredBody;
        case WebPushAvailability.unsupported:
          return l10n.notificationsWebUnsupportedBody;
        case WebPushAvailability.ready:
          if (web.failure == WebPushFailure.registrationFailed) {
            return l10n.notificationsWebRegistrationFailedBody;
          }
          if (web.failure == WebPushFailure.signInRequired) {
            return l10n.notificationsWebSignInRequiredBody;
          }
          if (web.isSubscribed) return l10n.notificationsWebEnabledBody;
          if (state.permissionDenied) return l10n.notificationsWebPermissionDeniedBody;
          if (state.permission == NotificationPermissionStatus.unavailable) {
            return l10n.notificationsPermissionUnavailableBody;
          }
          if (state.needsPermissionRequest) return l10n.notificationsPermissionNotAskedBody;
          return l10n.notificationsWebDisabledBody;
      }
    }
    if (!state.platformSupported) return l10n.notificationsUnsupportedBody;
    if (state.permissionDenied) return l10n.notificationsPermissionDeniedBody;
    if (state.permission == NotificationPermissionStatus.unavailable) {
      return l10n.notificationsPermissionUnavailableBody;
    }
    if (state.needsPermissionRequest) return l10n.notificationsPermissionNotAskedBody;
    return l10n.notificationsPermissionGrantedBody;
  }
}

class _PreferencesCard extends StatelessWidget {
  const _PreferencesCard({required this.state, required this.l10n});

  final NotificationSettingsState state;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<NotificationSettingsCubit>();
    final copy = NotificationCopySource(l10n);
    return SettingsCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile.adaptive(
            key: const ValueKey('notification_global_toggle'),
            contentPadding: EdgeInsets.zero,
            title: Text(l10n.notificationsAllow),
            subtitle: Text(l10n.notificationsAllowSubtitle),
            value: state.preferences.enabled,
            onChanged: state.unavailable
                ? null
                : (value) => unawaited(cubit.setEnabled(value)),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              l10n.notificationsPerDeviceScope,
              key: const ValueKey('notification_per_device_scope'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          const Divider(height: 24),
          Text(
            l10n.notificationsKinds,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          for (final kind in NotificationKind.values)
            _KindRow(
              kind: kind,
              state: state,
              l10n: l10n,
              label: copy.labelFor(kind),
              cubit: cubit,
            ),
        ],
      ),
    );
  }
}

/// One kind: on/off, and how loudly it may interrupt.
///
/// The row separates two facts that used to share one line. The subtitle states
/// what this device can actually do — off, no notification service, a revoked OS
/// permission — while the urgency control states the stored ceiling. That is why
/// the control is a labeled pill rather than an unlabeled glyph: at rest it names
/// the value it will apply, so `Alert` and `Banner only` no longer render
/// identically, and the label is the same word the menu lists.
class _KindRow extends StatelessWidget {
  const _KindRow({
    required this.kind,
    required this.state,
    required this.l10n,
    required this.label,
    required this.cubit,
  });

  final NotificationKind kind;
  final NotificationSettingsState state;
  final AppLocalizations l10n;
  final String label;
  final NotificationSettingsCubit cubit;

  @override
  Widget build(BuildContext context) {
    final enabled = state.isKindEnabled(kind);
    final ceiling = state.ceilingFor(kind);
    return SwitchListTile.adaptive(
      key: ValueKey('notification_kind_${kind.wire}_toggle'),
      contentPadding: EdgeInsets.zero,
      title: Text(label),
      subtitle: Text(_urgencyDescription(ceiling, enabled: enabled)),
      value: enabled,
      onChanged: !state.preferences.enabled || state.unavailable
          ? null
          : (value) => unawaited(cubit.setKindEnabled(kind, value)),
      secondary: _UrgencyControl(
        kind: kind,
        state: state,
        l10n: l10n,
        cubit: cubit,
        enabled: enabled,
        ceiling: ceiling,
      ),
    );
  }

  String _urgencyDescription(NotificationUrgency ceiling, {required bool enabled}) {
    if (!enabled) return l10n.notificationsUrgencyOff;
    // Nothing reaches the OS without permission, so the row reports the block
    // instead of a banner-and-sound claim the pipeline would refuse to honour.
    if (state.unavailable) return l10n.notificationsUrgencyNoService;
    if (!state.permission.canDisplay) return l10n.notificationsUrgencyBlockedByPermission;
    return ceiling.isInterruptive
        ? l10n.notificationsUrgencyAlertHint
        : l10n.notificationsUrgencyBannerOnlyHint;
  }
}

/// The per-kind urgency control: a labeled, value-bearing menu button.
///
/// It owns both halves of the affordance — the pill the user sees and the menu
/// that changes it — so the word on the pill and the words in the menu cannot
/// drift apart. The pill keeps the setting's own name (`Alert` / `Banner only`)
/// and the menu puts the delivery it means underneath that name
/// (`Banner and sound` / `Banner without sound`), which is one vocabulary with
/// its explanation instead of two names for one setting.
class _UrgencyControl extends StatelessWidget {
  const _UrgencyControl({
    required this.kind,
    required this.state,
    required this.l10n,
    required this.cubit,
    required this.enabled,
    required this.ceiling,
  });

  final NotificationKind kind;
  final NotificationSettingsState state;
  final AppLocalizations l10n;
  final NotificationSettingsCubit cubit;
  final bool enabled;
  final NotificationUrgency ceiling;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final interactive = enabled && !state.unavailable;
    // The control is dimmed when the row cannot deliver, but it still states the
    // stored ceiling: the subtitle next to it is what reports the block.
    final light = !interactive;

    return PopupMenuButton<NotificationUrgency>(
      key: ValueKey('notification_kind_${kind.wire}_urgency'),
      enabled: interactive,
      tooltip: l10n.notificationsUrgencyChange,
      onSelected: (value) => unawaited(cubit.setKindUrgency(kind, value)),
      itemBuilder: (context) => [
        _urgencyItem(
          context,
          NotificationUrgency.high,
          name: l10n.notificationsUrgencyAlert,
          detail: l10n.notificationsUrgencyAlertHint,
        ),
        _urgencyItem(
          context,
          NotificationUrgency.normal,
          name: l10n.notificationsUrgencyBannerOnly,
          detail: l10n.notificationsUrgencyBannerOnlyHint,
        ),
      ],
      // `PopupMenuButton.child` drops the `button: true` role the icon form
      // emitted through `IconButton`, so the pill states it: a screen reader must
      // hear a control, not a decorative label.
      child: Semantics(
        button: true,
        child: Container(
          padding: const EdgeInsetsDirectional.only(start: 10, end: 4, top: 4, bottom: 4),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withValues(alpha: light ? 0.35 : 0.65),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: scheme.outline.withValues(alpha: light ? 0.15 : 0.35),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(_icon(), size: 16, color: _tone(scheme, light)),
              const SizedBox(width: 6),
              Text(
                ceiling.isInterruptive
                    ? l10n.notificationsUrgencyAlert
                    : l10n.notificationsUrgencyBannerOnly,
                key: ValueKey('notification_kind_${kind.wire}_urgency_value'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: _tone(scheme, light),
                  fontWeight: FontWeight.w600,
                ),
              ),
              Icon(Icons.arrow_drop_down_rounded, size: 18, color: _tone(scheme, light)),
            ],
          ),
        ),
      ),
    );
  }

  Color _tone(ColorScheme scheme, bool light) => light
      ? scheme.onSurfaceVariant.withValues(alpha: 0.6)
      : scheme.onSurface;

  /// The glyph carries the state at a glance: a sound-on alert, a silent banner,
  /// a permission block, or no delivery at all.
  IconData _icon() {
    if (!enabled || state.unavailable) return Icons.notifications_off_outlined;
    if (!state.permission.canDisplay) return Icons.notifications_paused_outlined;
    return ceiling.isInterruptive ? Icons.notifications_active_outlined : Icons.volume_off_outlined;
  }

  /// One menu row: the setting's name plus the delivery it produces.
  ///
  /// The check slot is reserved for both items, so an unselected row starts at
  /// the same offset as the selected one instead of shifting by a glyph width.
  PopupMenuItem<NotificationUrgency> _urgencyItem(
    BuildContext context,
    NotificationUrgency value, {
    required String name,
    required String detail,
  }) {
    final theme = Theme.of(context);
    return PopupMenuItem<NotificationUrgency>(
      key: ValueKey('notification_kind_${kind.wire}_urgency_${value.wire}'),
      value: value,
      height: 56,
      child: Row(
        children: [
          SizedBox(
            width: 24,
            child: ceiling == value ? const Icon(Icons.check, size: 16) : null,
          ),
          Flexible(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: theme.textTheme.bodyMedium, overflow: TextOverflow.ellipsis),
                Text(
                  detail,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TestCard extends StatelessWidget {
  const _TestCard({required this.state, required this.l10n});

  final NotificationSettingsState state;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final cubit = context.read<NotificationSettingsCubit>();
    final outcome = state.testOutcome;
    return SettingsCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.notificationsTestTitle,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(l10n.notificationsTestSubtitle),
          if (state.testKind != null) ...[
            const SizedBox(height: 4),
            // The probe borrows a real kind, so it inherits that row's alert
            // style. Naming it is what stops a quietened kind from reading as a
            // test that forgot the setting.
            Text(
              l10n.notificationsTestKindNotice(NotificationCopySource(l10n).labelFor(state.testKind!)),
              key: const ValueKey('notification_test_kind_notice'),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic),
            ),
          ],
          const SizedBox(height: 16),
          FilledButton.tonal(
            key: const ValueKey('notification_test_btn'),
            onPressed: state.canSendTest
                ? () => unawaited(cubit.sendTestNotification())
                : null,
            child: Text(
              state.sendingTest
                  ? l10n.notificationsTestSending
                  : l10n.notificationsTestButton,
            ),
          ),
          if (outcome != null) ...[
            const SizedBox(height: 12),
            Text(
              _outcomeText(outcome),
              key: const ValueKey('notification_test_outcome'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ],
      ),
    );
  }

  String _outcomeText(NotificationTestOutcome outcome) => switch (outcome) {
        NotificationTestOutcome.shown => l10n.notificationsTestShown,
        NotificationTestOutcome.kindDisabled => l10n.notificationsTestKindDisabled,
        NotificationTestOutcome.permissionDenied => l10n.notificationsTestPermissionDenied,
        NotificationTestOutcome.unsupported => l10n.notificationsTestUnsupported,
        NotificationTestOutcome.failed => l10n.notificationsTestFailed,
      };
}

/// The limits that are not this page's to change.
class _LimitsCard extends StatelessWidget {
  const _LimitsCard({required this.l10n});

  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    return SettingsCard(
      key: const ValueKey('notification_limits_card'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.notificationsLimitsTitle,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          _limitRow(context, l10n.notificationsLimitsOsWins),
          // The installed web app requirement only exists where the browser
          // surface is the one running this page, so the desktop build does not
          // claim a limit it does not have.
          if (AppPlatform.isWeb) _limitRow(context, l10n.notificationsLimitsIosWebApp),
        ],
      ),
    );
  }

  Widget _limitRow(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsetsDirectional.only(end: 8, top: 2),
              child: Icon(Icons.info_outline, size: 16),
            ),
            Expanded(child: Text(text, style: Theme.of(context).textTheme.bodySmall)),
          ],
        ),
      );
}
