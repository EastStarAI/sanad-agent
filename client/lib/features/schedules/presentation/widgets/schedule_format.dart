import 'package:flutter/material.dart';
import 'package:sanad_client/features/schedules/domain/models/schedule.dart';
import 'package:sanad_client/features/schedules/domain/models/schedule_run.dart';
import 'package:sanad_client/l10n/app_localizations.dart';

/// Presentation-only formatting for the Schedules surfaces (Task 139 C2, C5).
///
/// Everything here renders values the Agent already decided. The recurrence
/// summary is composed from the structured row fields (`kind`, `interval`,
/// `at_time`, `weekdays`, `month_day`, `zone`) so no Agent English sentence ever
/// becomes UI copy, and no occurrence is calculated on the Client: the next
/// instant is the Agent's `next_run_at`, only re-rendered in the schedule's own
/// zone.

/// The stored zone offset of [zone], or `null` for the device's local zone.
///
/// `zone` is `local` or a fixed offset such as `+03:00` (Task 139 D3). Anything
/// this Client cannot read as a fixed offset is treated as local instead of
/// shifting an instant into a wrong zone.
Duration? parseScheduleZoneOffset(String? zone) {
  final token = zone?.trim();
  if (token == null || token.isEmpty) return null;
  final normalized = token.toUpperCase();
  if (normalized == 'LOCAL' || normalized == 'UTC' || normalized == 'Z') {
    return normalized == 'LOCAL' ? null : Duration.zero;
  }
  final match = RegExp(r'^([+-])(\d{1,2}):?(\d{2})$').firstMatch(token);
  if (match == null) return null;
  final sign = match.group(1) == '-' ? -1 : 1;
  final hours = int.tryParse(match.group(2) ?? '') ?? 0;
  final minutes = int.tryParse(match.group(3) ?? '') ?? 0;
  return Duration(minutes: sign * (hours * 60 + minutes));
}

/// [instant] as the wall clock of [zone].
///
/// The shifted `DateTime` keeps its fields equal to the zone's wall clock, which
/// is exactly what the date and time formatters read.
DateTime scheduleWallClock(DateTime instant, String? zone) {
  final offset = parseScheduleZoneOffset(zone);
  final utc = instant.toUtc();
  return offset == null ? utc : utc.add(offset);
}

/// A date and time rendered in the schedule's own [zone].
String formatScheduleInstant(
  BuildContext context,
  DateTime instant, {
  String? zone,
}) {
  final material = MaterialLocalizations.of(context);
  final wallClock = scheduleWallClock(instant, zone);
  final date = material.formatMediumDate(wallClock);
  return '$date ${formatScheduleTimeOfDay(context, TimeOfDay.fromDateTime(wallClock))}';
}

/// A wall-clock time (`HH:MM`) rendered for the current locale.
///
/// An unreadable token is returned verbatim rather than replaced, so a stored
/// value the Client cannot parse is still visible instead of silently dropped.
String formatScheduleTimeOfDay(BuildContext context, TimeOfDay? time) {
  if (time == null) return '';
  final alwaysUse24Hour =
      MediaQuery.maybeOf(context)?.alwaysUse24HourFormat ?? false;
  return MaterialLocalizations.of(
    context,
  ).formatTimeOfDay(time, alwaysUse24HourFormat: alwaysUse24Hour);
}

/// Parses the stored `HH:MM` token of a daily, weekly, or monthly schedule.
TimeOfDay? parseScheduleClockTime(String? atTime) {
  final token = atTime?.trim();
  if (token == null || token.isEmpty) return null;
  final match = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(token);
  if (match == null) return null;
  final hour = int.tryParse(match.group(1) ?? '');
  final minute = int.tryParse(match.group(2) ?? '');
  if (hour == null || minute == null) return null;
  if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;
  return TimeOfDay(hour: hour, minute: minute);
}

/// The stored `HH:MM` token of [time], for a request payload.
String formatScheduleClockToken(TimeOfDay time) =>
    '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

/// The localized recurrence sentence of [schedule], or `null` for a shape this
/// Client does not know (it then renders no summary at all instead of guessing).
String? scheduleRecurrenceSummary({
  required Schedule schedule,
  required AppLocalizations l10n,
  required BuildContext context,
}) {
  final time = formatScheduleTimeOfDay(
    context,
    parseScheduleClockTime(schedule.atTime),
  );
  switch (schedule.kind) {
    case ScheduleKind.once:
      final nextRunAt = schedule.nextRunAt;
      if (nextRunAt == null) return l10n.scheduleSummaryOncePast;
      return l10n.scheduleSummaryOnce(
        formatScheduleInstant(context, nextRunAt, zone: schedule.zone),
      );
    case ScheduleKind.interval:
      return l10n.scheduleSummaryInterval(schedule.intervalMinutes ?? 0);
    case ScheduleKind.daily:
      return time.isEmpty ? l10n.scheduleRecurrenceDaily : l10n.scheduleSummaryDaily(time);
    case ScheduleKind.weekly:
      final weekdayNames = schedule.weekdays
          .map((day) => scheduleWeekdayLabel(day, l10n))
          .toList(growable: false);
      if (weekdayNames.isEmpty) return l10n.scheduleRecurrenceWeekly;
      final separator = Directionality.of(context) == TextDirection.rtl ? '، ' : ', ';
      if (time.isEmpty) return l10n.scheduleRecurrenceWeekly;
      return l10n.scheduleSummaryWeekly(weekdayNames.join(separator), time);
    case ScheduleKind.monthly:
      final dayOfMonth = schedule.monthDay;
      if (dayOfMonth == null) return l10n.scheduleRecurrenceMonthly;
      return l10n.scheduleSummaryMonthly(
        dayOfMonth,
        time.isEmpty ? '--:--' : time,
      );
    case ScheduleKind.unknown:
      return null;
  }
}

/// The label a surface shows for [schedule]: its name, else a bounded preview of
/// its task, else its identity.
String scheduleDisplayLabel(Schedule schedule, AppLocalizations l10n) {
  final name = schedule.name?.trim();
  if (name != null && name.isNotEmpty) return name;
  final firstLine = schedule.task
      .split('\n')
      .map((line) => line.trim())
      .firstWhere((line) => line.isNotEmpty, orElse: () => '');
  if (firstLine.isEmpty) return l10n.scheduleDerivedLabel(schedule.id);
  const maxLength = 64;
  return firstLine.length <= maxLength
      ? firstLine
      : '${firstLine.substring(0, maxLength).trimRight()}…';
}

/// The localized weekday of a weekly shape.
String scheduleWeekdayLabel(ScheduleWeekday day, AppLocalizations l10n) {
  return switch (day) {
    ScheduleWeekday.mon => l10n.scheduleWeekdayMon,
    ScheduleWeekday.tue => l10n.scheduleWeekdayTue,
    ScheduleWeekday.wed => l10n.scheduleWeekdayWed,
    ScheduleWeekday.thu => l10n.scheduleWeekdayThu,
    ScheduleWeekday.fri => l10n.scheduleWeekdayFri,
    ScheduleWeekday.sat => l10n.scheduleWeekdaySat,
    ScheduleWeekday.sun => l10n.scheduleWeekdaySun,
  };
}

/// The localized label of a recurrence kind, for the picker and for a shape the
/// summary cannot express.
String scheduleKindLabel(ScheduleKind kind, AppLocalizations l10n) {
  return switch (kind) {
    ScheduleKind.once => l10n.scheduleRecurrenceOnce,
    ScheduleKind.interval => l10n.scheduleRecurrenceInterval,
    ScheduleKind.daily => l10n.scheduleRecurrenceDaily,
    ScheduleKind.weekly => l10n.scheduleRecurrenceWeekly,
    ScheduleKind.monthly => l10n.scheduleRecurrenceMonthly,
    ScheduleKind.unknown => l10n.scheduleRunStatusUnknown,
  };
}

/// The localized conversation mode of [schedule].
String scheduleConversationModeLabel(
  ScheduleConversationMode mode,
  AppLocalizations l10n,
) {
  return switch (mode) {
    ScheduleConversationMode.continuous => l10n.scheduleModeContinuous,
    ScheduleConversationMode.newEachRun => l10n.scheduleModeNewEachRun,
    ScheduleConversationMode.unknown => l10n.scheduleModeUnknown,
  };
}

/// The owner line of a schedule: its conversation, or the device itself.
String scheduleOwnerLabel({
  required Schedule schedule,
  required AppLocalizations l10n,
}) {
  final ownerSessionId = schedule.ownerSessionId;
  if (ownerSessionId == null) return l10n.scheduleOwnedByDevice;
  final title = schedule.ownerSessionTitle?.trim();
  return l10n.scheduleOwnedByConversation(
    title != null && title.isNotEmpty ? title : ownerSessionId,
  );
}

/// The localized status of one run.
String scheduleRunStatusLabel(ScheduleRunStatus status, AppLocalizations l10n) {
  return switch (status) {
    ScheduleRunStatus.running => l10n.scheduleRunStatusRunning,
    ScheduleRunStatus.succeeded => l10n.scheduleRunStatusSucceeded,
    ScheduleRunStatus.failed => l10n.scheduleRunStatusFailed,
    ScheduleRunStatus.skipped => l10n.scheduleRunStatusSkipped,
    ScheduleRunStatus.unknown => l10n.scheduleRunStatusUnknown,
  };
}

/// The localized trigger of one run.
String scheduleRunTriggerLabel(ScheduleRunTrigger trigger, AppLocalizations l10n) {
  return switch (trigger) {
    ScheduleRunTrigger.scheduled => l10n.scheduleRunTriggerScheduled,
    ScheduleRunTrigger.manual => l10n.scheduleRunTriggerManual,
    ScheduleRunTrigger.recovery => l10n.scheduleRunTriggerRecovery,
    ScheduleRunTrigger.unknown => l10n.scheduleRunTriggerUnknown,
  };
}

/// The localized outcome of a schedule's most recent dispatch.
String scheduleLastOutcomeLabel(ScheduleLastOutcome outcome, AppLocalizations l10n) {
  return switch (outcome) {
    ScheduleLastOutcome.fired => l10n.scheduleLastOutcomeFired,
    ScheduleLastOutcome.error => l10n.scheduleLastOutcomeError,
    ScheduleLastOutcome.skippedMissed => l10n.scheduleLastOutcomeSkipped,
    ScheduleLastOutcome.unknown => l10n.scheduleLastOutcomeUnknown,
  };
}

/// A compact, locale-neutral duration such as `840ms`, `12s`, `3m 4s`, or `2h 5m`.
///
/// `null` — a run that has not reached a terminal state — renders nothing.
String? formatScheduleDuration(int? durationMs) {
  if (durationMs == null || durationMs < 0) return null;
  if (durationMs < 1000) return '${durationMs}ms';
  final totalSeconds = (durationMs / 1000).round();
  if (totalSeconds < 60) return '${totalSeconds}s';
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;
  if (hours > 0) return '${hours}h ${minutes}m';
  return '${minutes}m ${seconds}s';
}
