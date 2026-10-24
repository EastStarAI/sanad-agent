import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:sanad_client/core/di/injection.dart';
import 'package:sanad_client/core/navigation/app_routes.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/schedules/data/schedules_client.dart';
import 'package:sanad_client/features/schedules/domain/models/schedule.dart';
import 'package:sanad_client/features/schedules/presentation/bloc/schedules_cubit.dart';
import 'package:sanad_client/features/schedules/presentation/schedule_device_scope.dart';
import 'package:sanad_client/features/schedules/presentation/widgets/schedule_availability.dart';
import 'package:sanad_client/features/schedules/presentation/widgets/schedule_editor_sheet.dart';
import 'package:sanad_client/features/schedules/presentation/widgets/schedule_row.dart';
import 'package:sanad_client/features/schedules/presentation/widgets/schedules_state_views.dart';
import 'package:sanad_client/l10n/app_localizations.dart';

/// The device-scoped Schedules list (Task 139 C1, C2, C4).
///
/// It renders the five presentations of C4 — loading, empty with the create
/// action, a typed error with Retry, an unavailable banner with every action
/// disabled and no list presented as current, and the loaded list — and it
/// requests nothing from [build]: [SchedulesCubit.load] runs once from
/// [initState] and again from Retry, and the cubit coalesces a read that is
/// already in flight.
///
/// [cubit] is the chrome's device-scoped cubit when the page is hosted inside
/// the device chrome, so the sidebar marker, the conversation-delete warning,
/// and this page share one `schedule.list` snapshot. A page built on its own (a
/// focused test, or a route without the chrome) creates its own.
class SchedulesScreen extends StatefulWidget {
  const SchedulesScreen({super.key, required this.deviceId, this.cubit});

  final String deviceId;

  /// The chrome-owned cubit for this device, or `null` to own one.
  final SchedulesCubit? cubit;

  @override
  State<SchedulesScreen> createState() => _SchedulesScreenState();
}

class _SchedulesScreenState extends State<SchedulesScreen> {
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
    // Opening the list is an intent to see the current state; a read that is
    // already in flight is joined instead of duplicated.
    unawaited(_cubit.load());
  }

  @override
  void dispose() {
    if (_ownsCubit) unawaited(_cubit.close());
    super.dispose();
  }

  DeviceConfig? get _device => ScheduleDeviceScope.resolve(widget.deviceId);

  Future<void> _openEditor({required DeviceConfig? device, Schedule? schedule}) async {
    await ScheduleEditorSheet.show(context, cubit: _cubit, device: device, schedule: schedule);
    // A successful mutation re-reads inside the cubit; nothing is patched here.
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colorScheme = Theme.of(context).colorScheme;
    final device = _device;
    final deviceOnline = device?.isOnline ?? false;

    return BlocProvider<SchedulesCubit>.value(
      value: _cubit,
      child: Container(
        key: const Key('schedules_screen'),
        color: Colors.transparent,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
            child: BlocBuilder<SchedulesCubit, SchedulesState>(
              builder: (context, state) {
                // One predicate for the banner, the create action, and every row
                // action, so a state that reports the device unavailable cannot
                // leave a sibling action open (S18).
                final enabled = scheduleActionsEnabled(device: device, state: state);
                return Column(
                  key: const Key('schedules_screen_body'),
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                l10n.schedules,
                                style: Theme.of(
                                  context,
                                ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
                              ),
                              if (device != null)
                                Text(
                                  device.name,
                                  style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 12),
                                ),
                            ],
                          ),
                        ),
                        FilledButton.icon(
                          key: const Key('schedules_create_btn'),
                          onPressed: enabled ? () => unawaited(_openEditor(device: device)) : null,
                          icon: const Icon(Icons.add_rounded, size: 18),
                          label: Text(l10n.newSchedule),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Expanded(
                      child: enabled
                          ? _buildState(context, state, device)
                          : Align(
                              alignment: AlignmentDirectional.topStart,
                              child: SchedulesUnavailableBanner(
                                // Retry only when the device itself is online; an
                                // offline device is never asked.
                                onRetry: deviceOnline ? () => unawaited(_cubit.load()) : null,
                              ),
                            ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildState(
    BuildContext context,
    SchedulesState state,
    DeviceConfig? device,
  ) {
    if (state.showsList) {
      return ListView.builder(
        key: const Key('schedules_list'),
        padding: const EdgeInsets.only(bottom: 24),
        itemCount: state.schedules.length,
        itemBuilder: (context, index) {
          final schedule = state.schedules[index];
          return ScheduleRow(
            schedule: schedule,
            actionsEnabled: true,
            onOpen: () => context.go(
              AppRoutes.scheduleDetailLocation(widget.deviceId, schedule.id),
            ),
            onEdit: () => unawaited(_openEditor(device: device, schedule: schedule)),
          );
        },
      );
    }
    return switch (state.status) {
      SchedulesStatus.empty => Align(
        alignment: AlignmentDirectional.topStart,
        child: SchedulesEmptyView(
          // The list only reaches this branch when an action is allowed.
          onCreate: () => unawaited(_openEditor(device: device)),
        ),
      ),
      SchedulesStatus.error => Align(
        alignment: AlignmentDirectional.topStart,
        child: SchedulesErrorView(
          failure: state.failure,
          onRetry: () => unawaited(_cubit.load()),
        ),
      ),
      _ => const SchedulesLoadingView(),
    };
  }
}
