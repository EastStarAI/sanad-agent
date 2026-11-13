import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_kind.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_permission_status.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_urgency.dart';
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
          subtitle: l10n.notificationsSubtitle,
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
          if (state.needsPermissionRequest) ...[
            const SizedBox(height: 16),
            FilledButton(
              key: const ValueKey('notification_permission_request_btn'),
              onPressed: state.requestingPermission
                  ? null
                  : () => unawaited(cubit.requestPermission()),
              child: Text(l10n.notificationsEnable),
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

  String _description(AppLocalizations l10n) {
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
/// The subtitle states what this device can actually do, not only what the kind
/// is set to: while the OS refuses notifications, or while no notification
/// service is reachable, the row says so instead of describing the alert style
/// it would use if delivery worked.
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
      secondary: PopupMenuButton<NotificationUrgency>(
        key: ValueKey('notification_kind_${kind.wire}_urgency'),
        enabled: enabled && !state.unavailable,
        tooltip: l10n.notificationsUrgencyChange,
        icon: const Icon(Icons.tune_rounded),
        onSelected: (value) => unawaited(cubit.setKindUrgency(kind, value)),
        itemBuilder: (context) => [
          _urgencyItem(NotificationUrgency.high, l10n.notificationsUrgencyAlert),
          _urgencyItem(NotificationUrgency.normal, l10n.notificationsUrgencyBannerOnly),
        ],
      ),
    );
  }

  PopupMenuItem<NotificationUrgency> _urgencyItem(NotificationUrgency value, String text) {
    final selected = state.ceilingFor(kind) == value;
    return PopupMenuItem<NotificationUrgency>(
      key: ValueKey('notification_kind_${kind.wire}_urgency_${value.wire}'),
      value: value,
      child: Row(
        children: [
          if (selected)
            const Padding(
              padding: EdgeInsetsDirectional.only(end: 8),
              child: Icon(Icons.check, size: 16),
            ),
          Text(text),
        ],
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
