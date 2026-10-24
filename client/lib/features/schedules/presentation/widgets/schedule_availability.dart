import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/schedules/presentation/bloc/schedules_cubit.dart';

/// Whether a schedule action may be offered or submitted (Task 139 C4, S18).
///
/// Two independent facts can make the device unable to answer, and either one
/// must close every action:
///
/// - the inventory may still report the device online while the schedules
///   transport has already failed, which the cubit reports as
///   [SchedulesStatus.deviceUnavailable];
/// - the device may simply be offline.
///
/// The list, the detail, the row actions, and the editor all ask this one
/// predicate, so no surface can offer an action while it renders the Unavailable
/// banner, and no action can be submitted against a device that already told this
/// Client it cannot answer.
bool scheduleActionsEnabled({
  required DeviceConfig? device,
  required SchedulesState state,
}) {
  if (device == null || !device.isOnline) return false;
  return state.status != SchedulesStatus.deviceUnavailable;
}
