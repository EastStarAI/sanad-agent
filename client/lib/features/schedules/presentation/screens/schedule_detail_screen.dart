import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:sanad_client/core/di/injection.dart';
import 'package:sanad_client/features/schedules/data/schedules_client.dart';
import 'package:sanad_client/features/schedules/presentation/bloc/schedules_cubit.dart';
import 'package:sanad_client/features/schedules/presentation/schedule_device_scope.dart';

/// One schedule's detail and run history (Task 139 C1, C2, S8).
///
/// This item (139-06) owns the data client, the cubit, and the route contract
/// only. The screen creates the one feature cubit from DI for the route's device,
/// calls [SchedulesCubit.load] and [SchedulesCubit.openDetail] once from
/// [initState], and renders a placeholder. 139-07 replaces the body with the
/// Details and Run history tabs and owns the device chrome and sidebar
/// integration.
class ScheduleDetailScreen extends StatefulWidget {
  const ScheduleDetailScreen({
    super.key,
    required this.deviceId,
    required this.scheduleId,
  });

  final String deviceId;
  final String scheduleId;

  @override
  State<ScheduleDetailScreen> createState() => _ScheduleDetailScreenState();
}

class _ScheduleDetailScreenState extends State<ScheduleDetailScreen> {
  late final SchedulesCubit _cubit;

  @override
  void initState() {
    super.initState();
    _cubit = SchedulesCubit(
      client: getIt<SchedulesClient>(),
      device: () => ScheduleDeviceScope.resolve(widget.deviceId),
    );
    unawaited(_cubit.load());
    unawaited(_cubit.openDetail(widget.scheduleId));
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
        key: Key('schedule_detail_screen'),
        // 139-07 renders the detail here. The placeholder deliberately carries
        // no copy, so this item adds no localization key.
        body: SizedBox.expand(key: Key('schedule_detail_screen_body')),
      ),
    );
  }
}
