import 'package:flutter/material.dart';
import 'package:sanad_client/features/schedules/domain/models/schedule.dart';
import 'package:sanad_client/features/schedules/domain/models/schedule_request.dart';
import 'package:sanad_client/features/schedules/presentation/widgets/schedule_format.dart';
import 'package:sanad_client/l10n/app_localizations.dart';

/// The recurrence half of the schedule form (Task 139 C2, S6).
///
/// It holds only what the picker edits and serializes exactly the fields its own
/// kind owns, so the form can never send a mixed shape. Everything the Agent
/// decides stays with the Agent: this class does not compute an occurrence and
/// does not validate the vocabulary — it only refuses to send an obviously
/// incomplete definition, and `schedule.preview` answers validity.
class ScheduleRecurrenceDraft {
  const ScheduleRecurrenceDraft({
    this.kind = ScheduleKind.daily,
    this.intervalMinutes = 30,
    this.atTime,
    this.weekdays = const <ScheduleWeekday>{},
    this.monthDay,
    this.at,
  });

  final ScheduleKind kind;
  final int intervalMinutes;

  /// Wall-clock time of a daily, weekly, or monthly shape.
  final TimeOfDay? atTime;

  final Set<ScheduleWeekday> weekdays;
  final int? monthDay;

  /// The instant of a `once` shape.
  final DateTime? at;

  /// Whether this shape uses a wall-clock time.
  bool get usesClockTime =>
      kind == ScheduleKind.daily || kind == ScheduleKind.weekly || kind == ScheduleKind.monthly;

  /// The stored recurrence of [schedule], for the editor's initial value.
  ///
  /// A `once` keeps its instant only while that instant is still ahead: an
  /// elapsed one-off has no future occurrence to edit, so the form asks for a
  /// new one instead of re-sending a stale value.
  factory ScheduleRecurrenceDraft.fromSchedule(Schedule schedule) {
    final now = DateTime.now().toUtc();
    final nextRunAt = schedule.nextRunAt;
    return ScheduleRecurrenceDraft(
      kind: schedule.kind.isSendable ? schedule.kind : ScheduleKind.daily,
      intervalMinutes: schedule.intervalMinutes ?? 30,
      atTime: parseScheduleClockTime(schedule.atTime) ?? const TimeOfDay(hour: 9, minute: 0),
      weekdays: schedule.weekdays.toSet(),
      monthDay: schedule.monthDay ?? 1,
      at: schedule.kind == ScheduleKind.once && nextRunAt != null && nextRunAt.isAfter(now)
          ? nextRunAt
          : null,
    );
  }

  ScheduleRecurrenceDraft copyWith({
    ScheduleKind? kind,
    int? intervalMinutes,
    TimeOfDay? atTime,
    Set<ScheduleWeekday>? weekdays,
    int? monthDay,
    DateTime? at,
  }) {
    return ScheduleRecurrenceDraft(
      kind: kind ?? this.kind,
      intervalMinutes: intervalMinutes ?? this.intervalMinutes,
      atTime: atTime ?? this.atTime,
      weekdays: weekdays ?? this.weekdays,
      monthDay: monthDay ?? this.monthDay,
      at: at ?? this.at,
    );
  }

  /// The same shape with the clock time cleared, so an unreadable token is a
  /// missing time instead of a silent keep of the previous value.
  ScheduleRecurrenceDraft clearTime() => ScheduleRecurrenceDraft(
    kind: kind,
    intervalMinutes: intervalMinutes,
    weekdays: weekdays,
    monthDay: monthDay,
    at: at,
  );

  /// The same shape with the day of month cleared.
  ScheduleRecurrenceDraft clearMonthDay() => ScheduleRecurrenceDraft(
    kind: kind,
    intervalMinutes: intervalMinutes,
    atTime: atTime,
    weekdays: weekdays,
    at: at,
  );

  /// The request definition of this draft, in the selected [zone].
  ScheduleDefinitionInput toDefinition({String? zone}) {
    final orderedWeekdays = kind == ScheduleKind.weekly
        ? (weekdays.toList()..sort((a, b) => a.index.compareTo(b.index)))
        : const <ScheduleWeekday>[];
    return ScheduleDefinitionInput(
      kind: kind,
      zone: zone,
      intervalMinutes: kind == ScheduleKind.interval ? intervalMinutes : null,
      atTime: usesClockTime
          ? formatScheduleClockToken(atTime ?? const TimeOfDay(hour: 9, minute: 0))
          : null,
      at: kind == ScheduleKind.once ? at?.toUtc().toIso8601String() : null,
      weekdays: orderedWeekdays,
      monthDay: kind == ScheduleKind.monthly ? monthDay : null,
    );
  }

  /// Whether the shape carries every field its kind needs.
  bool get isComplete => toDefinition().isComplete();

  /// The localized reason this shape cannot be sent, or `null` when it can.
  String? validationError(AppLocalizations l10n) {
    switch (kind) {
      case ScheduleKind.once:
        if (at == null) return l10n.scheduleOnceRequired;
        if (!at!.isAfter(DateTime.now())) return l10n.scheduleOnceRequired;
        return null;
      case ScheduleKind.interval:
        return intervalMinutes > 0 ? null : l10n.scheduleIntervalRequired;
      case ScheduleKind.daily:
        return atTime == null ? l10n.scheduleTimeRequired : null;
      case ScheduleKind.weekly:
        if (atTime == null) return l10n.scheduleTimeRequired;
        return weekdays.isEmpty ? l10n.scheduleWeekdaysRequired : null;
      case ScheduleKind.monthly:
        if (atTime == null) return l10n.scheduleTimeRequired;
        final day = monthDay;
        return day == null || day < 1 || day > 31 ? l10n.scheduleDayOfMonthRequired : null;
      case ScheduleKind.unknown:
        return l10n.schedulePreviewInvalid;
    }
  }
}

/// The kind picker plus the fields that kind owns (S6).
///
/// Every field reports its own value to [onChanged]; the errors are owned by the
/// hosting form, which validates on submit, so a field never blocks typing.
class ScheduleRecurrenceFields extends StatelessWidget {
  const ScheduleRecurrenceFields({
    super.key,
    required this.draft,
    required this.onChanged,
    required this.onPickOnceInstant,
    this.onTimeInput,
    this.timeError,
    this.intervalError,
    this.monthDayError,
    this.weekdaysError,
    this.onceError,
  });

  final ScheduleRecurrenceDraft draft;
  final ValueChanged<ScheduleRecurrenceDraft> onChanged;

  /// Opens the date and time pickers for a `once` shape.
  final VoidCallback onPickOnceInstant;

  /// The raw text of the clock-time field, so the hosting form can tell a
  /// missing time from an unreadable one.
  final ValueChanged<String>? onTimeInput;

  final String? timeError;
  final String? intervalError;
  final String? monthDayError;
  final String? weekdaysError;
  final String? onceError;

  static const List<ScheduleKind> selectableKinds = [
    ScheduleKind.once,
    ScheduleKind.interval,
    ScheduleKind.daily,
    ScheduleKind.weekly,
    ScheduleKind.monthly,
  ];

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.scheduleRecurrence,
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
        ),
        const SizedBox(height: 8),
        Wrap(
          key: const Key('schedule_editor_kind_picker'),
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final kind in selectableKinds)
              ChoiceChip(
                key: Key('schedule_editor_kind_${kind.name}'),
                label: Text(scheduleKindLabel(kind, l10n)),
                selected: draft.kind == kind,
                onSelected: (_) => onChanged(draft.copyWith(kind: kind)),
              ),
          ],
        ),
        const SizedBox(height: 12),
        ..._kindFields(context, l10n),
      ],
    );
  }

  List<Widget> _kindFields(BuildContext context, AppLocalizations l10n) {
    switch (draft.kind) {
      case ScheduleKind.once:
        final at = draft.at;
        return [
          OutlinedButton.icon(
            key: const Key('schedule_editor_once_field'),
            onPressed: onPickOnceInstant,
            icon: const Icon(Icons.event_outlined, size: 18),
            label: Text(
              at == null
                  ? l10n.scheduleOnceRequired
                  : formatScheduleInstant(context, at.toUtc(), zone: null),
            ),
          ),
          _errorText(onceError),
        ];
      case ScheduleKind.interval:
        return [
          TextFormField(
            key: const Key('schedule_editor_interval_field'),
            keyboardType: TextInputType.number,
            initialValue: '${draft.intervalMinutes}',
            decoration: InputDecoration(
              labelText: l10n.scheduleInterval,
              errorText: intervalError,
            ),
            onChanged: (value) => onChanged(
              draft.copyWith(intervalMinutes: int.tryParse(value.trim()) ?? 0),
            ),
          ),
        ];
      case ScheduleKind.daily:
      case ScheduleKind.weekly:
      case ScheduleKind.monthly:
        return [
          TextFormField(
            key: const Key('schedule_editor_time_field'),
            initialValue: draft.atTime == null ? '' : formatScheduleClockToken(draft.atTime!),
            decoration: InputDecoration(
              labelText: l10n.scheduleTime,
              hintText: '09:00',
              errorText: timeError,
            ),
            onChanged: (value) {
              onTimeInput?.call(value);
              final parsed = parseScheduleClockTime(value);
              onChanged(parsed == null ? draft.clearTime() : draft.copyWith(atTime: parsed));
            },
          ),
          if (draft.kind == ScheduleKind.weekly) ...[
            const SizedBox(height: 12),
            Text(
              l10n.scheduleWeekdays,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final day in ScheduleWeekday.values)
                  FilterChip(
                    key: Key('schedule_editor_weekday_${day.wireName}'),
                    label: Text(scheduleWeekdayLabel(day, l10n)),
                    selected: draft.weekdays.contains(day),
                    onSelected: (selected) {
                      final next = Set<ScheduleWeekday>.of(draft.weekdays);
                      if (selected) {
                        next.add(day);
                      } else {
                        next.remove(day);
                      }
                      onChanged(draft.copyWith(weekdays: next));
                    },
                  ),
              ],
            ),
            _errorText(weekdaysError),
          ],
          if (draft.kind == ScheduleKind.monthly) ...[
            const SizedBox(height: 12),
            TextFormField(
              key: const Key('schedule_editor_day_of_month_field'),
              keyboardType: TextInputType.number,
              initialValue: draft.monthDay?.toString() ?? '',
              decoration: InputDecoration(
                labelText: l10n.scheduleDayOfMonth,
                errorText: monthDayError,
              ),
              onChanged: (value) {
                final parsed = int.tryParse(value.trim());
                onChanged(parsed == null ? draft.clearMonthDay() : draft.copyWith(monthDay: parsed));
              },
            ),
          ],
        ];
      case ScheduleKind.unknown:
        return const [];
    }
  }

  Widget _errorText(String? error) {
    if (error == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Text(error, style: const TextStyle(fontSize: 12, color: Color(0xFFB3261E))),
    );
  }
}
