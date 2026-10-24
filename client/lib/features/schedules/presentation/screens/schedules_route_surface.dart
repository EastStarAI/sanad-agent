import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:sanad_client/features/devices/presentation/bloc/device_cubit.dart';
import 'package:sanad_client/features/devices/presentation/bloc/device_state.dart';
import 'package:sanad_client/features/schedules/presentation/schedules_chrome_scope.dart';
import 'package:sanad_client/features/schedules/presentation/screens/schedule_detail_screen.dart';
import 'package:sanad_client/features/schedules/presentation/screens/schedules_screen.dart';

/// The content slot of the device chrome for the two Schedules routes
/// (Task 139 C1).
///
/// A Schedules route renders inside the real device chrome and sidebar exactly
/// like a conversation route, which is why the route is hosted by `HomeScreen`
/// instead of a standalone page: the sidebar needs HomeScreen's provider tree.
/// This widget is what HomeScreen renders in its content slot — it resolves the
/// chrome's one device-scoped `SchedulesCubit` and hands it to the page, so the
/// sidebar marker, the conversation-delete warning, and the page read the same
/// `schedule.list` snapshot.
///
/// It also aligns the chrome with the device the route names: a deep link to
/// another device's schedule selects that device, exactly as a conversation
/// route does, instead of showing one device's sidebar beside another's rows.
class SchedulesRouteSurface extends StatefulWidget {
  const SchedulesRouteSurface({super.key, required this.deviceId, this.scheduleId});

  final String deviceId;

  /// `null` renders the list; a value renders that schedule's detail.
  final String? scheduleId;

  @override
  State<SchedulesRouteSurface> createState() => _SchedulesRouteSurfaceState();
}

class _SchedulesRouteSurfaceState extends State<SchedulesRouteSurface> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || widget.deviceId.isEmpty) return;
      final deviceCubit = context.read<DeviceCubit>();
      final active = switch (deviceCubit.state) {
        DeviceActive(:final activeAgent) => activeAgent,
        _ => null,
      };
      if (active?.id == widget.deviceId) return;
      unawaited(deviceCubit.setActiveAgent(widget.deviceId));
    });
  }

  @override
  Widget build(BuildContext context) {
    final cubit = SchedulesScope.cubitFor(context, widget.deviceId);
    final scheduleId = widget.scheduleId;
    if (scheduleId == null) {
      return SchedulesScreen(deviceId: widget.deviceId, cubit: cubit);
    }
    return ScheduleDetailScreen(
      deviceId: widget.deviceId,
      scheduleId: scheduleId,
      cubit: cubit,
    );
  }
}
