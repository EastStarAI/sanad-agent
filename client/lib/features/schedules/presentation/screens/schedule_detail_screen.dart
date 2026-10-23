import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:sanad_client/core/di/injection.dart';
import 'package:sanad_client/core/navigation/app_routes.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/schedules/data/schedules_client.dart';
import 'package:sanad_client/features/schedules/domain/models/schedule_error.dart';
import 'package:sanad_client/features/schedules/presentation/bloc/schedules_cubit.dart';
import 'package:sanad_client/features/schedules/presentation/schedule_device_scope.dart';
import 'package:sanad_client/features/schedules/presentation/widgets/schedule_details_tab.dart';
import 'package:sanad_client/features/schedules/presentation/widgets/schedule_run_history_tab.dart';
import 'package:sanad_client/features/schedules/presentation/widgets/schedules_state_views.dart';
import 'package:sanad_client/l10n/app_localizations.dart';

/// One schedule's detail and run history (Task 139 C1, C2, S8).
///
/// Two tabs: **Details** — the recurrence, the owner, the stored route, the
/// conversation mode, and the actions — and **Run history**, which lists each
/// run with its status, duration, error, and Open conversation (S20).
///
/// Like the list, it renders inside the device chrome, requests nothing from
/// [build], and reads its row from the same `schedule.list` snapshot as the
/// sidebar marker. [cubit] is the chrome-owned cubit when hosted there.
class ScheduleDetailScreen extends StatefulWidget {
  const ScheduleDetailScreen({
    super.key,
    required this.deviceId,
    required this.scheduleId,
    this.cubit,
  });

  final String deviceId;
  final String scheduleId;

  /// The chrome-owned cubit for this device, or `null` to own one.
  final SchedulesCubit? cubit;

  @override
  State<ScheduleDetailScreen> createState() => _ScheduleDetailScreenState();
}

class _ScheduleDetailScreenState extends State<ScheduleDetailScreen> {
  late final SchedulesCubit _cubit;
  late final bool _ownsCubit;

  @override
  void initState() {
    super.initState();
    final provided = widget.cubit;
    _ownsCubit = provided == null;
    _cubit =
        provided ??
        SchedulesCubit(
          client: getIt<SchedulesClient>(),
          device: () => ScheduleDeviceScope.resolve(widget.deviceId),
        );
    unawaited(_cubit.load());
    unawaited(_cubit.openDetail(widget.scheduleId));
  }

  @override
  void dispose() {
    if (_ownsCubit) {
      unawaited(_cubit.close());
    } else {
      // The chrome's cubit outlives this page; the open detail does not.
      _cubit.closeDetail();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colorScheme = Theme.of(context).colorScheme;
    final device = ScheduleDeviceScope.resolve(widget.deviceId);
    final online = device?.isOnline ?? false;

    return BlocProvider<SchedulesCubit>.value(
      value: _cubit,
      child: Container(
        key: const Key('schedule_detail_screen'),
        color: Colors.transparent,
        child: SafeArea(
          child: DefaultTabController(
            length: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _DetailHeader(deviceId: widget.deviceId, device: device),
                TabBar(
                  key: const Key('schedule_detail_tabs'),
                  labelColor: colorScheme.onSurface,
                  tabs: [
                    Tab(key: const Key('schedule_details_tab_btn'), text: l10n.scheduleDetails),
                    Tab(
                      key: const Key('schedule_run_history_tab_btn'),
                      text: l10n.scheduleRunHistory,
                    ),
                  ],
                ),
                Expanded(
                  child: BlocBuilder<SchedulesCubit, SchedulesState>(
                    builder: (context, state) {
                      final unavailable =
                          !online || state.status == SchedulesStatus.deviceUnavailable;
                      if (unavailable) {
                        return Align(
                          alignment: AlignmentDirectional.topStart,
                          child: Padding(
                            padding: const EdgeInsets.all(20),
                            child: SchedulesUnavailableBanner(
                              onRetry: online ? () => unawaited(_cubit.load()) : null,
                            ),
                          ),
                        );
                      }
                      final schedule = state.scheduleById(widget.scheduleId);
                      if (schedule != null) {
                        return TabBarView(
                          children: [
                            ScheduleDetailsTab(
                              schedule: schedule,
                              device: device,
                              deviceId: widget.deviceId,
                              actionsEnabled: online,
                            ),
                            ScheduleRunHistoryTab(
                              deviceId: widget.deviceId,
                              scheduleId: widget.scheduleId,
                              actionsEnabled: online,
                            ),
                          ],
                        );
                      }
                      if (state.status == SchedulesStatus.error ||
                          state.status == SchedulesStatus.loaded) {
                        return Align(
                          alignment: AlignmentDirectional.topStart,
                          child: Padding(
                            padding: const EdgeInsets.all(20),
                            child: SchedulesErrorView(
                              failure:
                                  state.failure ??
                                  const ScheduleFailure(code: ScheduleErrorCode.scheduleNotFound),
                              onRetry: () => unawaited(_cubit.load()),
                            ),
                          ),
                        );
                      }
                      return const Padding(
                        padding: EdgeInsets.all(20),
                        child: SchedulesLoadingView(),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DetailHeader extends StatelessWidget {
  const _DetailHeader({required this.deviceId, required this.device});

  final String deviceId;
  final DeviceConfig? device;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 12, 20, 4),
      child: Row(
        children: [
          IconButton(
            key: const Key('schedule_detail_back_btn'),
            tooltip: l10n.schedules,
            icon: const Icon(Icons.arrow_back_rounded, size: 20),
            onPressed: () => context.go(AppRoutes.schedulesLocation(deviceId)),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              l10n.schedules,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: colorScheme.onSurfaceVariant,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
