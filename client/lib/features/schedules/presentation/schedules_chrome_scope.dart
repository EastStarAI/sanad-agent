import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:sanad_client/core/di/injection.dart';
import 'package:sanad_client/features/devices/presentation/bloc/device_cubit.dart';
import 'package:sanad_client/features/devices/presentation/bloc/device_state.dart';
import 'package:sanad_client/features/schedules/data/schedules_client.dart';
import 'package:sanad_client/features/schedules/domain/models/schedule_run_failure_notice.dart';
import 'package:sanad_client/features/schedules/presentation/bloc/schedules_cubit.dart';
import 'package:sanad_client/features/schedules/presentation/schedule_device_scope.dart';
import 'package:sanad_client/l10n/app_localizations.dart';

/// The device-scoped schedules cubit of the surrounding device chrome
/// (Task 139 C1).
///
/// The sidebar marker, the conversation-delete warning (S23), and the two
/// Schedules routes must read **one** `schedule.list` snapshot, and the sidebar
/// needs [SchedulesCubit] even when no Schedules route is open. This host owns
/// that one cubit for the chrome's active device:
///
/// - it is created for the active device and re-created only when the active
///   device changes;
/// - it reads once from its own lifecycle, never from a build, and re-reads when
///   the device comes back online;
/// - it drops the snapshot when the device goes offline, so no stale row can be
///   presented as current (S18);
/// - it forwards `schedule.run_failed` as a localized, non-modal notice that
///   carries no error text and is never stored.
class SchedulesChromeScope extends StatefulWidget {
  const SchedulesChromeScope({super.key, required this.child});

  final Widget child;

  @override
  State<SchedulesChromeScope> createState() => _SchedulesChromeScopeState();
}

class _SchedulesChromeScopeState extends State<SchedulesChromeScope> {
  SchedulesCubit? _cubit;
  String? _deviceId;
  bool _online = false;
  StreamSubscription<DeviceState>? _deviceSubscription;
  StreamSubscription<ScheduleRunFailureNotice>? _failureSubscription;

  @override
  void initState() {
    super.initState();
    final deviceCubit = context.read<DeviceCubit>();
    _applyDevice(deviceCubit.state, initial: true);
    _deviceSubscription = deviceCubit.stream.listen(_applyDevice);
  }

  @override
  void dispose() {
    unawaited(_deviceSubscription?.cancel());
    unawaited(_failureSubscription?.cancel());
    unawaited(_cubit?.close());
    super.dispose();
  }

  void _applyDevice(DeviceState state, {bool initial = false}) {
    final device = state is DeviceActive ? state.activeAgent : null;
    final deviceId = device?.id;
    final online = device?.isOnline ?? false;

    if (deviceId != _deviceId) {
      final previous = _cubit;
      _deviceId = deviceId;
      _online = online;
      // The schedules protocol client is registered by Client DI beside the other
      // device clients. A chrome pumped without it (a focused harness) gets an
      // inert scope: no request, no marker, no notice, instead of a crash.
      final hasClient = getIt.isRegistered<SchedulesClient>();
      _cubit = deviceId == null || !hasClient
          ? null
          : SchedulesCubit(
              client: getIt<SchedulesClient>(),
              device: () => ScheduleDeviceScope.resolve(deviceId),
            );
      _bindRunFailures();
      if (previous != null) unawaited(previous.close());
      final created = _cubit;
      if (created != null) unawaited(created.load());
      if (!initial) setState(() {});
      return;
    }

    if (online == _online) return;
    _online = online;
    final cubit = _cubit;
    if (cubit == null) return;
    if (online) {
      unawaited(cubit.load());
    } else {
      cubit.markDeviceUnavailable();
    }
    if (!initial) setState(() {});
  }

  void _bindRunFailures() {
    unawaited(_failureSubscription?.cancel());
    _failureSubscription = null;
    final cubit = _cubit;
    if (cubit == null) return;
    _failureSubscription = cubit.runFailures.listen(_showRunFailure);
  }

  /// A failed run is announced once, without error text and without being
  /// stored: the durable record is the run history row plus the failure badge
  /// (S16, S22).
  void _showRunFailure(ScheduleRunFailureNotice notice) {
    if (!mounted) return;
    final l10n = AppLocalizations.of(context);
    if (l10n == null) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    final name = notice.scheduleName?.trim();
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          key: const Key('schedule_failure_notice'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.scheduleFailureNotice(
                  name != null && name.isNotEmpty ? name : l10n.scheduleDerivedLabel(notice.scheduleId),
                ),
              ),
              if (notice.suggestPause)
                Text(
                  l10n.scheduleFailureSuggestion,
                  key: const Key('schedule_failure_notice_suggestion'),
                  style: const TextStyle(fontSize: 12),
                ),
            ],
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final cubit = _cubit;
    final deviceId = _deviceId;
    if (cubit == null || deviceId == null) return widget.child;
    return SchedulesScope(deviceId: deviceId, cubit: cubit, child: widget.child);
  }
}

/// The device-scoped schedules cubit, offered to the sidebar and the Schedules
/// routes without adding a second list read.
class SchedulesScope extends InheritedWidget {
  const SchedulesScope({
    super.key,
    required this.deviceId,
    required this.cubit,
    required super.child,
  });

  final String deviceId;
  final SchedulesCubit cubit;

  /// The chrome's schedules cubit for [deviceId], or `null` when this subtree has
  /// no such scope (a surface pumped on its own) or the scope belongs to another
  /// device.
  static SchedulesCubit? cubitFor(BuildContext context, String deviceId) {
    final scope = context.dependOnInheritedWidgetOfExactType<SchedulesScope>();
    if (scope == null || scope.deviceId != deviceId) return null;
    return scope.cubit;
  }

  /// The active device the scope is bound to, or `null`.
  static String? deviceIdOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SchedulesScope>()?.deviceId;

  @override
  bool updateShouldNotify(SchedulesScope oldWidget) =>
      oldWidget.deviceId != deviceId || oldWidget.cubit != cubit;
}

/// Whether [sessionId] owns at least one schedule on [deviceId] (Task 139 S23).
///
/// The conversation delete confirmation reads this to warn that the schedules
/// depending on the conversation will be paused rather than deleted. It is
/// derived from the chrome's one `schedule.list` snapshot, so it costs no
/// extra command, and it answers `false` when this subtree has no schedules
/// scope at all.
bool conversationOwnsSchedules(BuildContext context, String deviceId, String sessionId) {
  final cubit = SchedulesScope.cubitFor(context, deviceId);
  if (cubit == null) return false;
  return cubit.state.conversationIdsWithSchedules.contains(sessionId);
}
