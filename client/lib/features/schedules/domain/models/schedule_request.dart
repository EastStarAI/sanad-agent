import 'package:equatable/equatable.dart';
import 'package:sanad_client/features/schedules/domain/models/schedule.dart';

/// A candidate schedule definition: the recurrence half of a create, an update,
/// or a preview request (Task 139 protocol §4.1, §4.2).
///
/// It serializes only the fields its own [kind] owns, so a candidate can never
/// carry a mixed shape the Agent would have to reject. [zone] is `local` or a
/// fixed offset such as `+03:00` — the Agent owns the arithmetic either way.
class ScheduleDefinitionInput extends Equatable {
  const ScheduleDefinitionInput({
    required this.kind,
    this.zone,
    this.intervalMinutes,
    this.atTime,
    this.at,
    this.weekdays = const <ScheduleWeekday>[],
    this.monthDay,
  });

  final ScheduleKind kind;

  /// `local` or a fixed offset; omitted when `null`.
  final String? zone;

  /// Interval shape, in minutes.
  final int? intervalMinutes;

  /// Daily/weekly/monthly wall-clock time as `HH:MM`.
  final String? atTime;

  /// Once shape, as an ISO-8601 instant.
  final String? at;

  /// Weekly shape days.
  final List<ScheduleWeekday> weekdays;

  /// Monthly shape day of month.
  final int? monthDay;

  /// The stored definition of [schedule], for the edit form's initial value.
  factory ScheduleDefinitionInput.fromSchedule(Schedule schedule) {
    return ScheduleDefinitionInput(
      kind: schedule.kind,
      zone: schedule.zone,
      intervalMinutes: schedule.intervalMinutes,
      atTime: schedule.atTime,
      weekdays: schedule.weekdays,
      monthDay: schedule.monthDay,
    );
  }

  /// The wire payload of this definition.
  ///
  /// A kind this Client does not know cannot be expressed on the wire, so it is
  /// a programming error rather than a request.
  Map<String, dynamic> toWirePayload() {
    if (!kind.isSendable) {
      throw StateError('A schedule definition needs a known kind.');
    }
    final zoneValue = _nonBlank(zone);
    return {
      'kind': kind.name,
      if (zoneValue != null) 'zone': zoneValue,
      if (kind == ScheduleKind.interval && intervalMinutes != null) 'interval_minutes': intervalMinutes,
      if (kind == ScheduleKind.once && _nonBlank(at) != null) 'at': _nonBlank(at),
      if (_usesCalendarTime && _nonBlank(atTime) != null) 'time': _nonBlank(atTime),
      if (kind == ScheduleKind.weekly && weekdays.isNotEmpty)
        'weekdays': [for (final day in weekdays) day.wireName],
      if (kind == ScheduleKind.monthly && monthDay != null) 'day_of_month': monthDay,
    };
  }

  bool get _usesCalendarTime =>
      kind == ScheduleKind.daily || kind == ScheduleKind.weekly || kind == ScheduleKind.monthly;

  /// Whether [toWirePayload] carries a value for every field its shape needs.
  ///
  /// This is a *request-shape* check, not a validation copy: the Agent remains
  /// the authority on whether a definition is valid, and `schedule.preview`
  /// answers that question. It exists so the form never sends an obviously
  /// incomplete definition.
  bool isComplete() => switch (kind) {
    ScheduleKind.once => _nonBlank(at) != null,
    ScheduleKind.interval => (intervalMinutes ?? 0) > 0,
    ScheduleKind.daily => _nonBlank(atTime) != null,
    ScheduleKind.weekly => _nonBlank(atTime) != null && weekdays.isNotEmpty,
    ScheduleKind.monthly => _nonBlank(atTime) != null && (monthDay ?? 0) > 0,
    ScheduleKind.unknown => false,
  };

  @override
  List<Object?> get props => [kind, zone, intervalMinutes, atTime, at, weekdays, monthDay];
}

/// The `schedule.create` payload (Task 139 protocol §4.2).
///
/// It has no `owner_kind` field by construction: the receiving command family
/// decides the kind, so a Client-created schedule is always user-owned (D5) and
/// no code path can claim the model kind.
class ScheduleDraft extends Equatable {
  const ScheduleDraft({
    required this.task,
    required this.definition,
    this.name,
    this.conversationMode,
    this.workspaceId,
    this.providerInstanceId,
    this.model,
  });

  /// The self-contained task text a run sends verbatim (S19).
  final String task;

  final String? name;
  final ScheduleDefinitionInput definition;

  /// Omitted when `null`; the Agent defaults to `continuous`.
  final ScheduleConversationMode? conversationMode;

  /// The conversation route stored with the schedule.
  final String? workspaceId;
  final String? providerInstanceId;
  final String? model;

  Map<String, dynamic> toCreatePayload() {
    final mode = conversationMode;
    return {
      'task': task,
      if (_nonBlank(name) != null) 'name': _nonBlank(name),
      ...definition.toWirePayload(),
      if (mode != null && mode.wireName != null) 'conversation_mode': mode.wireName,
      if (_nonBlank(workspaceId) != null) 'workspace_id': _nonBlank(workspaceId),
      if (_nonBlank(providerInstanceId) != null) 'provider_instance_id': _nonBlank(providerInstanceId),
      if (_nonBlank(model) != null) 'model': _nonBlank(model),
    };
  }

  @override
  List<Object?> get props =>
      [task, name, definition, conversationMode, workspaceId, providerInstanceId, model];
}

/// The `schedule.update` payload (Task 139 protocol §4.3).
///
/// Merge semantics are explicit: an absent member keeps the stored value, a
/// [ScheduleSetting.set] with `null` clears an editable settings column, and a
/// supplied [definition] replaces or merges the recurrence. The owning
/// conversation is not editable and has no field here (S6).
class ScheduleUpdate extends Equatable {
  const ScheduleUpdate({
    required this.id,
    this.task,
    this.name = const ScheduleSetting.keep(),
    this.conversationMode,
    this.workspaceId = const ScheduleSetting.keep(),
    this.providerInstanceId = const ScheduleSetting.keep(),
    this.model = const ScheduleSetting.keep(),
    this.definition,
  });

  final String id;

  /// The new task text, or `null` to keep the stored one.
  final String? task;

  final ScheduleSetting name;

  /// The new mode, or `null` to keep the stored one.
  final ScheduleConversationMode? conversationMode;

  final ScheduleSetting workspaceId;
  final ScheduleSetting providerInstanceId;
  final ScheduleSetting model;

  /// The new definition, or `null` to keep the stored recurrence.
  final ScheduleDefinitionInput? definition;

  /// Whether this update would send nothing, which the protocol rejects as
  /// `invalid_request` because it would recompute an unchanged definition.
  bool get isEmpty =>
      task == null &&
      !name.isPresent &&
      conversationMode == null &&
      !workspaceId.isPresent &&
      !providerInstanceId.isPresent &&
      !model.isPresent &&
      definition == null;

  Map<String, dynamic> toUpdatePayload() {
    final mode = conversationMode;
    return {
      'id': id,
      if (task != null) 'task': task,
      if (name.isPresent) 'name': name.value,
      if (mode != null && mode.wireName != null) 'conversation_mode': mode.wireName,
      if (workspaceId.isPresent) 'workspace_id': workspaceId.value,
      if (providerInstanceId.isPresent) 'provider_instance_id': providerInstanceId.value,
      if (model.isPresent) 'model': model.value,
      ...?definition?.toWirePayload(),
    };
  }

  @override
  List<Object?> get props => [id, task, name, conversationMode, workspaceId, providerInstanceId, model, definition];
}

String? _nonBlank(String? value) {
  final text = value?.trim();
  return text == null || text.isEmpty ? null : text;
}
