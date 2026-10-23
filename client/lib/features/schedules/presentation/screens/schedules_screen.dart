import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:sanad_client/core/di/injection.dart';
import 'package:sanad_client/features/schedules/data/schedules_client.dart';
import 'package:sanad_client/features/schedules/presentation/bloc/schedules_cubit.dart';
import 'package:sanad_client/features/schedules/presentation/schedule_device_scope.dart';

/// The device-scoped Schedules list (Task 139 C1, C2).
///
/// This item (139-06) owns the data client, the cubit, and the route contract
/// only. The screen creates the one feature cubit from DI for the route's device,
/// calls [SchedulesCubit.load] once from [initState], and renders a placeholder.
/// 139-07 replaces the body with the real list, its actions, and the device
/// chrome and sidebar integration.
///
/// Nothing is requested from [build], so a rebuild cannot re-issue
/// `schedule.list` (Render and Request Independence).
class SchedulesScreen extends StatefulWidget {
  const SchedulesScreen({super.key, required this.deviceId});

  final String deviceId;

  @override
  State<SchedulesScreen> createState() => _SchedulesScreenState();
}

class _SchedulesScreenState extends State<SchedulesScreen> {
  late final SchedulesCubit _cubit;

  @override
  void initState() {
    super.initState();
    _cubit = SchedulesCubit(
      client: getIt<SchedulesClient>(),
      device: () => ScheduleDeviceScope.resolve(widget.deviceId),
    );
    unawaited(_cubit.load());
  }

  @override
  void dispose() {
    unawaited(_cubit.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocProvider<SchedulesCubit>.value(
      value: _cubit,
      child: const Scaffold(
        key: Key('schedules_screen'),
        // 139-07 renders the list here. The placeholder deliberately carries no
        // copy, so this item adds no localization key.
        body: SizedBox.expand(key: Key('schedules_screen_body')),
      ),
    );
  }
}
