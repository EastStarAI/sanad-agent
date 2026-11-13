import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_kind.dart';
import 'package:sanad_client/features/notifications/domain/models/notification_permission_status.dart';
import 'package:sanad_client/features/notifications/domain/models/web_push_capability.dart';
import 'package:sanad_client/features/notifications/presentation/bloc/notification_settings_cubit.dart';
import 'package:sanad_client/features/notifications/presentation/bloc/notification_settings_state.dart';
import 'package:sanad_client/features/notifications/presentation/notification_copy_source.dart';
import 'package:sanad_client/l10n/app_localizations.dart';

import '../settings_widgets.dart';

/// Settings → Notifications.
///
/// The page states the OS permission, offers the ask only when the OS has not
/// been asked yet, and owns the global plus per-kind switches. It never raises a
/// notification and never decides one: it edits the same state the display
/// pipeline reads, so a change takes effect on the next event.
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
              child: Text(l10n.notificationsEnable),
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
          if (state.permissionDenied && state.canOpenSystemSettings) ...[
            const SizedBox(height: 16),
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
  bool get _offersEnable {
    if (state.requestingPermission) return false;
    if (!state.webPush.isWebPlatform) return state.needsPermissionRequest;
    if (!state.webPush.canSubscribe || state.webPush.isSubscribed) return false;
    if (state.permissionDenied) return false;
    if (state.permission == NotificationPermissionStatus.unavailable) return false;
    return state.webPush.failure != WebPushFailure.signInRequired;
  }

  bool get _offersDisable => state.webPush.isWebPlatform && state.webPush.isSubscribed && !state.requestingPermission;

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
          const Divider(height: 24),
          Text(
            l10n.notificationsKinds,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          for (final kind in NotificationKind.values)
            SwitchListTile.adaptive(
              key: ValueKey('notification_kind_${kind.wire}_toggle'),
              contentPadding: EdgeInsets.zero,
              title: Text(copy.labelFor(kind)),
              value: state.isKindEnabled(kind),
              onChanged: !state.preferences.enabled || state.unavailable
                  ? null
                  : (value) => unawaited(cubit.setKindEnabled(kind, value)),
            ),
        ],
      ),
    );
  }
}
